defmodule CodexPooler.InstanceSettings.Cache do
  @moduledoc false

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger

  alias CodexPooler.InstanceSettings.Settings
  alias Phoenix.PubSub

  @pubsub CodexPooler.PubSub
  @topic "instance_settings"
  @applied_topic "instance_settings:applied"
  @message_tag __MODULE__
  @cache_key {__MODULE__, :current}
  @cache_version 1
  @cache_miss {__MODULE__, :cache_miss}
  @retry_initial_interval_ms 1_000
  @retry_max_interval_ms 30_000
  @reconciliation_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec current() :: Settings.t()
  def current do
    case :persistent_term.get(@cache_key, @cache_miss) do
      {@cache_version, %Settings{} = settings} -> settings
      @cache_miss -> load_current()
      {_other_version, %Settings{}} -> load_current()
    end
  end

  @spec put(Settings.t()) :: {:ok, Settings.t()} | {:error, term()}
  def put(%Settings{} = settings) do
    GenServer.call(__MODULE__, {:put, settings})
  catch
    :exit, _reason -> {:error, :cache_unavailable}
  end

  @spec put_for_test(Settings.t()) :: :ok
  def put_for_test(%Settings{} = settings),
    do: GenServer.call(__MODULE__, {:put_for_test, settings})

  @spec broadcast_update(Settings.t()) :: :ok | {:error, term()}
  def broadcast_update(%Settings{} = settings) do
    message = {@message_tag, {:updated, settings.lock_version}}

    case Process.whereis(__MODULE__) do
      cache when is_pid(cache) -> PubSub.broadcast_from(@pubsub, cache, @topic, message)
      nil -> PubSub.broadcast(@pubsub, @topic, message)
    end
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(@pubsub, @topic)

  @spec subscribe_applied() :: :ok | {:error, term()}
  def subscribe_applied, do: PubSub.subscribe(@pubsub, @applied_topic)

  @spec snapshot_for_test() :: term()
  def snapshot_for_test, do: :persistent_term.get(@cache_key, @cache_miss)

  @spec restore_for_test(term()) :: :ok
  def restore_for_test(snapshot), do: GenServer.call(__MODULE__, {:restore, snapshot})

  @spec reset_for_test() :: :ok
  def reset_for_test, do: GenServer.call(__MODULE__, :reset_for_test)

  @impl true
  def init(opts) do
    _ = subscribe()

    state =
      opts
      |> new_state()
      |> schedule_reconciliation()

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    {_settings, state} = reload(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:current, _from, %{cached: %Settings{} = settings} = state) do
    {settings, state} = publish_success(state, settings)
    {:reply, settings, state}
  end

  def handle_call(:current, _from, state) do
    {settings, state} = reload(state)
    {:reply, settings, state}
  end

  def handle_call({:put, %Settings{}}, _from, state) do
    case load_settings() do
      {:ok, settings} ->
        {settings, state} = publish_success(state, settings)
        {:reply, {:ok, settings}, state}

      {:error, reason} ->
        {_settings, state} = publish_failure(state, reason)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_for_test, %Settings{} = settings}, _from, state) do
    {_settings, state} = publish_success(state, settings)
    {:reply, :ok, state}
  end

  # Restores the published entry verbatim so a caller can hand back exactly what
  # it captured, including a cold-fallback snapshot that `put/1` would otherwise
  # relabel as database-backed. Teardown leaves background DB work stopped;
  # explicit reset and normal database publication resume reconciliation.
  def handle_call({:restore, snapshot}, _from, state) do
    {:reply, :ok, restore_snapshot(state, snapshot)}
  end

  def handle_call(:reset_for_test, _from, state) do
    {:reply, :ok, state |> restore_snapshot(@cache_miss) |> schedule_reconciliation()}
  end

  @impl true
  def handle_info({@message_tag, {:updated, lock_version}}, state)
      when is_integer(lock_version) do
    state =
      state
      |> cancel_retry()
      |> Map.put(:retry_attempt, 0)
      |> Map.put(:desired_lock_version, lock_version)

    {_settings, state} = reload(state)
    {:noreply, state}
  end

  def handle_info(
        {@message_tag, {:retry, generation}},
        %{retry_timer: %{generation: generation, attempt: attempt}} = state
      ) do
    state = %{state | retry_timer: nil, retry_attempt: attempt + 1}
    {_settings, state} = reload(state)
    {:noreply, state}
  end

  def handle_info({@message_tag, {:retry, _stale_generation}}, state),
    do: {:noreply, state}

  def handle_info(
        {@message_tag, {:reconcile, generation}},
        %{reconciliation_timer: %{generation: generation}} = state
      ) do
    state = %{state | reconciliation_timer: nil}
    {:noreply, reconcile(state)}
  end

  def handle_info({@message_tag, {:reconcile, _stale_generation}}, state),
    do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_timers(state)
    :ok
  end

  defp load_current do
    GenServer.call(__MODULE__, :current)
  catch
    :exit, _reason -> publish_cold_fallback()
  end

  defp restore_snapshot(state, snapshot) do
    state = cancel_timers(state)

    case snapshot do
      {@cache_version, %Settings{}} -> :persistent_term.put(@cache_key, snapshot)
      _missing_or_stale -> :persistent_term.erase(@cache_key)
    end

    new_state([], state.retry_generation, state.reconciliation_generation)
  end

  defp reload(state) do
    case load_settings() do
      {:ok, settings} -> publish_success(state, settings)
      {:error, reason} -> publish_failure(state, reason)
    end
  end

  defp publish_success(state, %Settings{} = settings) do
    settings = settings |> Settings.mark_loaded(:database) |> clear_virtual_secrets()
    :persistent_term.put(@cache_key, {@cache_version, settings})

    :ok =
      PubSub.local_broadcast(
        @pubsub,
        @applied_topic,
        {@message_tag, {:applied, settings.lock_version}},
        PubSub
      )

    state =
      state
      |> cancel_retry()
      |> cancel_reconciliation()
      |> Map.merge(%{
        cached: settings,
        health: :ready,
        desired_lock_version: settings.lock_version,
        retry_attempt: 0
      })
      |> schedule_reconciliation()

    {settings, state}
  end

  defp publish_failure(state, reason) do
    warm_cache? = match?(%Settings{}, state.cached)
    log_db_failure(reason, warm_cache?)

    {settings, state} =
      case state.cached do
        %Settings{} = settings ->
          {settings, %{state | health: :degraded}}

        nil ->
          settings = publish_cold_fallback()
          {settings, %{state | health: :cold}}
      end

    state = state |> schedule_retry() |> ensure_reconciliation()
    {settings, state}
  end

  defp reconcile(state) do
    case load_lock_version() do
      {:ok, lock_version}
      when is_nil(state.cached) or state.health == :cold or
             state.cached.lock_version != lock_version ->
        {_settings, state} = reload(state)
        state

      {:ok, lock_version} ->
        state
        |> cancel_retry()
        |> Map.merge(%{
          health: :ready,
          desired_lock_version: lock_version,
          retry_attempt: 0
        })
        |> schedule_reconciliation()

      {:error, reason} ->
        {_settings, state} = publish_failure(state, reason)
        state
    end
  end

  defp publish_cold_fallback do
    settings = Settings.fallback_default() |> clear_virtual_secrets()
    :persistent_term.put(@cache_key, {@cache_version, settings})
    settings
  end

  defp clear_virtual_secrets(%Settings{} = settings) do
    %Settings{
      settings
      | metrics: %{settings.metrics | bearer_token: nil, bearer_token_action: nil},
        smtp: %{settings.smtp | password: nil, password_action: nil}
    }
  end

  defp load_settings do
    {:ok, ensure_singleton_with_repo!()}
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp load_lock_version do
    query =
      from(settings in Settings, where: settings.singleton == true, select: settings.lock_version)

    {:ok, repo().one(query)}
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp ensure_singleton_with_repo! do
    repo = repo()
    settings = Settings.default()

    repo.insert(settings, on_conflict: :nothing, conflict_target: :singleton)
    repo.get!(Settings, true)
  end

  defp repo do
    :codex_pooler
    |> Application.get_env(CodexPooler.InstanceSettings, [])
    |> Keyword.get(:repo, CodexPooler.Repo)
  end

  defp new_state(opts, retry_generation \\ 0, reconciliation_generation \\ 0) do
    config = Keyword.merge(Application.get_env(:codex_pooler, __MODULE__, []), opts)
    cached = published_database_snapshot()

    %{
      cached: cached,
      health: if(cached, do: :ready, else: :cold),
      desired_lock_version: if(cached, do: cached.lock_version, else: nil),
      retry_timer: nil,
      retry_attempt: 0,
      retry_generation: retry_generation,
      reconciliation_timer: nil,
      reconciliation_generation: reconciliation_generation,
      retry_initial_interval_ms:
        Keyword.get(config, :retry_initial_interval_ms, @retry_initial_interval_ms),
      retry_max_interval_ms: Keyword.get(config, :retry_max_interval_ms, @retry_max_interval_ms),
      reconciliation_interval_ms:
        Keyword.get(config, :reconciliation_interval_ms, @reconciliation_interval_ms),
      timer_module: Keyword.get(config, :timer_module, Process)
    }
  end

  defp published_database_snapshot do
    case :persistent_term.get(@cache_key, @cache_miss) do
      {@cache_version, %Settings{db_available?: true} = settings} -> settings
      _other -> nil
    end
  end

  defp schedule_retry(%{retry_timer: nil} = state) do
    generation = state.retry_generation + 1

    delay =
      retry_delay(
        state.retry_initial_interval_ms,
        state.retry_max_interval_ms,
        state.retry_attempt
      )

    ref =
      state.timer_module.send_after(
        self(),
        {@message_tag, {:retry, generation}},
        delay
      )

    %{
      state
      | retry_generation: generation,
        retry_timer: %{
          ref: ref,
          generation: generation,
          attempt: state.retry_attempt,
          delay: delay
        }
    }
  end

  defp schedule_retry(state), do: state

  defp retry_delay(initial, _maximum, 0), do: initial

  defp retry_delay(initial, maximum, attempt) when attempt > 0 do
    Enum.reduce(1..attempt, initial, fn _step, delay -> min(delay * 2, maximum) end)
  end

  defp schedule_reconciliation(state) do
    state = cancel_reconciliation(state)
    generation = state.reconciliation_generation + 1

    ref =
      state.timer_module.send_after(
        self(),
        {@message_tag, {:reconcile, generation}},
        state.reconciliation_interval_ms
      )

    %{
      state
      | reconciliation_generation: generation,
        reconciliation_timer: %{ref: ref, generation: generation}
    }
  end

  defp ensure_reconciliation(%{reconciliation_timer: nil} = state),
    do: schedule_reconciliation(state)

  defp ensure_reconciliation(state), do: state

  defp cancel_retry(%{retry_timer: nil} = state),
    do: %{state | retry_generation: state.retry_generation + 1}

  defp cancel_retry(state) do
    _ = state.timer_module.cancel_timer(state.retry_timer.ref)
    %{state | retry_timer: nil, retry_generation: state.retry_generation + 1}
  end

  defp cancel_reconciliation(%{reconciliation_timer: nil} = state),
    do: %{state | reconciliation_generation: state.reconciliation_generation + 1}

  defp cancel_reconciliation(state) do
    _ = state.timer_module.cancel_timer(state.reconciliation_timer.ref)

    %{
      state
      | reconciliation_timer: nil,
        reconciliation_generation: state.reconciliation_generation + 1
    }
  end

  defp cancel_timers(state), do: state |> cancel_retry() |> cancel_reconciliation()

  defp log_db_failure(reason, warm_cache?) do
    Logger.warning(fn ->
      "instance settings db load failed warm_cache=#{warm_cache?} exception=#{reason_label(reason)}"
    end)
  end

  defp reason_label(%{__struct__: module}), do: inspect(module)
  defp reason_label(_reason), do: "unknown"
end
