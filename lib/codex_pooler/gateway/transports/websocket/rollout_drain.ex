defmodule CodexPooler.Gateway.Transports.Websocket.RolloutDrain do
  @moduledoc false

  use GenServer

  require Logger

  alias CodexPooler.Gateway.Transports.Websocket.{
    WebsocketOwnerContract,
    WebsocketOwnerSession
  }

  @registry WebsocketOwnerSession.Registry
  @default_timeout_ms 50_000
  @drain_poll_interval_ms 200
  @owner_call_timeout_ms WebsocketOwnerContract.default_owner_call_timeout_ms()
  @default_owner_post_deadline_call_budget_ms @owner_call_timeout_ms * 2
  @owner_task_finish_margin_ms 500
  @drain_deadline_floor_ms 10

  @type summary :: %{
          required(:result) => :ok | :error,
          required(:owners_seen) => non_neg_integer(),
          required(:owners_drained) => non_neg_integer(),
          required(:owners_idle) => non_neg_integer(),
          required(:owners_failed) => non_neg_integer(),
          required(:turns_completed) => non_neg_integer(),
          required(:turns_aborted) => non_neg_integer(),
          required(:timeout_ms) => pos_integer(),
          required(:elapsed_ms) => non_neg_integer(),
          required(:already_draining?) => boolean()
        }

  @type deadline :: %{
          required(:now_ms) => (-> integer()),
          required(:schedule_wait) => (pid(), reference(), non_neg_integer() -> term()),
          required(:cancel_wait) => (term(), reference() -> :ok)
        }

  @type option ::
          {:name, GenServer.server()}
          | {:timeout_ms, pos_integer()}
          | {:deadline, deadline()}
          | {:deadline_margin_ms, non_neg_integer()}
          | {:deadline_floor_ms, non_neg_integer()}
          | {:owner_post_deadline_call_budget_ms, pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec draining?([option()]) :: boolean()
  def draining?(opts \\ []) do
    opts
    |> configured_server_name()
    |> call_if_started(:draining?, false)
  end

  @spec start_drain([option()]) :: summary()
  def start_drain(opts \\ []) do
    timeout_ms = timeout_ms(opts)
    drain_policy = drain_policy(opts)

    call_drain(
      opts,
      {:start_drain, timeout_ms, drain_policy},
      timeout_ms,
      coordinator_call_timeout_ms(timeout_ms, drain_policy)
    )
  end

  @spec drain_for_shutdown() :: summary()
  def drain_for_shutdown do
    timeout_ms = configured_timeout_ms()

    call_drain(
      [],
      {:drain_for_shutdown, timeout_ms},
      timeout_ms,
      conservative_call_timeout_ms(timeout_ms)
    )
  end

  @spec configured_timeout_ms() :: pos_integer()
  def configured_timeout_ms do
    "CODEX_POOLER_WEBSOCKET_DRAIN_TIMEOUT_MS"
    |> System.get_env()
    |> parse_timeout_ms()
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       draining?: false,
       active_drain: nil,
       shutdown_started_at_ms: nil,
       shutdown_timeout_ms: nil,
       drain_policy: drain_policy(opts)
     }}
  end

  @impl GenServer
  def handle_call(:draining?, _from, state) do
    {:reply, state.draining?, state}
  end

  def handle_call(
        {:start_drain, _timeout_ms, _drain_policy},
        from,
        %{active_drain: active_drain} = state
      )
      when is_map(active_drain) do
    active_drain = %{active_drain | waiters: [from | active_drain.waiters]}
    {:noreply, %{state | active_drain: active_drain}}
  end

  def handle_call({:start_drain, timeout_ms, drain_policy}, from, state) do
    start_owner_drain(timeout_ms, from, state, false, drain_policy)
  end

  def handle_call(
        {:drain_for_shutdown, timeout_ms},
        from,
        %{active_drain: active_drain} = state
      )
      when is_map(active_drain) do
    active_drain = %{active_drain | waiters: [from | active_drain.waiters]}

    {:noreply,
     state
     |> ensure_shutdown_budget_started(timeout_ms)
     |> Map.put(:active_drain, active_drain)}
  end

  def handle_call({:drain_for_shutdown, timeout_ms}, from, state) do
    case shutdown_timeout_budget(state) do
      :not_started ->
        start_owner_drain(timeout_ms, from, state, true, state.drain_policy)

      {:remaining, remaining_timeout_ms} ->
        start_owner_drain(remaining_timeout_ms, from, state, true, state.drain_policy)

      :exhausted ->
        summary = empty_summary(:ok, state.shutdown_timeout_ms, true)
        log_drain_finished(summary)
        {:reply, summary, state}
    end
  end

  @impl GenServer
  def handle_info({:rollout_drain_finished, ref, summary}, %{active_drain: %{ref: ref}} = state) do
    Enum.each(state.active_drain.waiters, &GenServer.reply(&1, summary))
    {:noreply, %{state | active_drain: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec drain_local_owners(pos_integer(), boolean(), map()) :: summary()
  defp drain_local_owners(timeout_ms, already_draining?, drain_policy) do
    started_at = System.monotonic_time(:millisecond)
    deadline_started_at = drain_policy.now_ms.()
    owners = local_owner_sessions()

    counters =
      owners
      |> Task.async_stream(
        fn {_key, owner} ->
          drain_owner_after_turn(owner, timeout_ms, deadline_started_at, drain_policy)
        end,
        max_concurrency: max(1, length(owners)),
        on_timeout: :kill_task,
        ordered: false,
        timeout: owner_task_timeout_ms(timeout_ms, drain_policy)
      )
      |> Enum.reduce(empty_counters(), &count_owner_result/2)

    elapsed_ms = max(0, System.monotonic_time(:millisecond) - started_at)
    owners_seen = length(owners)

    %{
      result: drain_result(counters.owners_failed),
      owners_seen: owners_seen,
      owners_drained: counters.owners_drained,
      owners_idle: counters.owners_idle,
      owners_failed: counters.owners_failed,
      turns_completed: counters.turns_completed,
      turns_aborted: counters.turns_aborted,
      timeout_ms: timeout_ms,
      elapsed_ms: elapsed_ms,
      already_draining?: already_draining?
    }
  end

  defp local_owner_sessions do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_key, owner} -> is_pid(owner) and Process.alive?(owner) end)
  end

  defp drain_owner(owner) do
    WebsocketOwnerSession.drain_owner(owner)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  defp drain_owner_after_turn(owner, timeout_ms, started_at, drain_policy) do
    :ok = WebsocketOwnerSession.begin_drain(owner)
    owner_ref = Process.monitor(owner)

    outcome =
      owner
      |> await_turn_outcome(
        owner_ref,
        poll_deadline_ms(timeout_ms, started_at, drain_policy),
        drain_policy
      )
      |> drain_settled_owner(owner)

    Process.demonitor(owner_ref, [:flush])
    outcome
  end

  defp await_turn_outcome(owner, owner_ref, deadline_ms, drain_policy) do
    case owner_status(owner, owner_ref) do
      {:ok, %{active_turn?: false}} ->
        :idle

      {:ok, %{active_turn?: true}} ->
        poll_active_turn(owner, owner_ref, deadline_ms, drain_policy)

      {:error, :owner_unavailable} ->
        :failed
    end
  end

  defp poll_active_turn(owner, owner_ref, deadline_ms, drain_policy) do
    remaining_ms = max(0, deadline_ms - drain_policy.now_ms.())

    if remaining_ms == 0 do
      :aborted
    else
      wait_ms = min(@drain_poll_interval_ms, remaining_ms)

      case wait_or_owner_down(owner_ref, drain_policy, wait_ms) do
        :owner_down ->
          :failed

        :elapsed ->
          poll_owner_status(owner, owner_ref, deadline_ms, drain_policy)

        :wait_failed ->
          :failed
      end
    end
  end

  defp poll_owner_status(owner, owner_ref, deadline_ms, drain_policy) do
    case owner_status(owner, owner_ref) do
      {:ok, %{active_turn?: false}} ->
        :completed

      {:ok, %{active_turn?: true}} ->
        poll_active_turn(owner, owner_ref, deadline_ms, drain_policy)

      {:error, :owner_unavailable} ->
        :failed
    end
  end

  defp owner_status(owner, owner_ref) do
    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        {:error, :owner_unavailable}
    after
      0 ->
        WebsocketOwnerSession.owner_status(owner)
    end
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  defp wait_or_owner_down(owner_ref, drain_policy, wait_ms) do
    wait_token = make_ref()

    try do
      wait_ref = drain_policy.schedule_wait.(self(), wait_token, wait_ms)

      receive do
        {:DOWN, ^owner_ref, :process, _owner, _reason} ->
          :ok = drain_policy.cancel_wait.(wait_ref, wait_token)
          :owner_down

        {:rollout_drain_wait_elapsed, ^wait_token} ->
          :elapsed
      end
    catch
      _kind, _reason ->
        :wait_failed
    end
  end

  defp drain_settled_owner(:failed, _owner), do: {:error, :owner_unavailable}

  defp drain_settled_owner(outcome, owner) do
    case drain_owner(owner) do
      :ok -> {:ok, outcome}
      {:error, _reason} = error -> error
    end
  end

  defp count_owner_result({:ok, {:ok, outcome}}, counters) do
    counters
    |> Map.update!(:owners_drained, &(&1 + 1))
    |> count_outcome(outcome)
  end

  defp count_owner_result(_result, counters) do
    Map.update!(counters, :owners_failed, &(&1 + 1))
  end

  defp count_outcome(counters, :idle), do: Map.update!(counters, :owners_idle, &(&1 + 1))

  defp count_outcome(counters, :completed),
    do: Map.update!(counters, :turns_completed, &(&1 + 1))

  defp count_outcome(counters, :aborted),
    do: Map.update!(counters, :turns_aborted, &(&1 + 1))

  defp empty_counters do
    %{owners_drained: 0, owners_idle: 0, owners_failed: 0, turns_completed: 0, turns_aborted: 0}
  end

  defp drain_result(0), do: :ok
  defp drain_result(_owners_failed), do: :error

  defp call_drain(opts, request, timeout_ms, call_timeout) do
    case GenServer.whereis(configured_server_name(opts)) do
      nil ->
        summary = empty_summary(:error, timeout_ms, false)
        log_drain_finished(summary)
        summary

      server ->
        GenServer.call(server, request, call_timeout)
    end
  end

  defp start_owner_drain(timeout_ms, from, state, shutdown?, drain_policy) do
    already_draining? = state.draining?
    ref = make_ref()
    caller = self()

    log_drain_started(timeout_ms, already_draining?)

    {:ok, _pid} =
      Task.start(fn ->
        summary = drain_local_owners(timeout_ms, already_draining?, drain_policy)
        log_drain_finished(summary)
        send(caller, {:rollout_drain_finished, ref, summary})
      end)

    active_drain = %{ref: ref, waiters: [from]}

    state =
      state
      |> ensure_shutdown_budget_started(timeout_ms, shutdown?)
      |> Map.merge(%{draining?: true, active_drain: active_drain})

    {:noreply, state}
  end

  defp ensure_shutdown_budget_started(state, timeout_ms, true) do
    ensure_shutdown_budget_started(state, timeout_ms)
  end

  defp ensure_shutdown_budget_started(state, _timeout_ms, false), do: state

  defp ensure_shutdown_budget_started(%{shutdown_started_at_ms: nil} = state, timeout_ms) do
    %{
      state
      | shutdown_started_at_ms: System.monotonic_time(:millisecond),
        shutdown_timeout_ms: timeout_ms
    }
  end

  defp ensure_shutdown_budget_started(state, _timeout_ms), do: state

  defp shutdown_timeout_budget(%{shutdown_started_at_ms: nil}), do: :not_started

  defp shutdown_timeout_budget(state) do
    elapsed_ms = max(0, System.monotonic_time(:millisecond) - state.shutdown_started_at_ms)
    remaining_timeout_ms = max(0, state.shutdown_timeout_ms - elapsed_ms)

    if remaining_timeout_ms > 0 do
      {:remaining, remaining_timeout_ms}
    else
      :exhausted
    end
  end

  defp call_if_started(server_name, request, fallback) do
    case GenServer.whereis(server_name) do
      nil -> fallback
      server -> GenServer.call(server, request)
    end
  end

  defp configured_server_name(opts) do
    Keyword.get(opts, :name) ||
      :codex_pooler
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:server_name, __MODULE__)
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, configured_timeout_ms()) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _invalid -> @default_timeout_ms
    end
  end

  defp drain_policy(opts) do
    deadline =
      Keyword.get(opts, :deadline, %{
        now_ms: fn -> System.monotonic_time(:millisecond) end,
        schedule_wait: fn recipient, wait_token, wait_ms ->
          Process.send_after(recipient, {:rollout_drain_wait_elapsed, wait_token}, wait_ms)
        end,
        cancel_wait: &cancel_timer/2
      })

    owner_post_deadline_call_budget_ms =
      positive_option(
        opts,
        :owner_post_deadline_call_budget_ms,
        @default_owner_post_deadline_call_budget_ms
      )

    default_margin_ms =
      owner_post_deadline_call_budget_ms + @drain_poll_interval_ms +
        @owner_task_finish_margin_ms

    %{
      now_ms: Map.fetch!(deadline, :now_ms),
      schedule_wait: Map.fetch!(deadline, :schedule_wait),
      cancel_wait: Map.fetch!(deadline, :cancel_wait),
      margin_ms: non_negative_option(opts, :deadline_margin_ms, default_margin_ms),
      floor_ms: non_negative_option(opts, :deadline_floor_ms, @drain_deadline_floor_ms),
      owner_post_deadline_call_budget_ms: owner_post_deadline_call_budget_ms
    }
  end

  defp non_negative_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp poll_deadline_ms(timeout_ms, started_at, drain_policy) do
    elapsed_ms = max(0, drain_policy.now_ms.() - started_at)
    remaining_budget_ms = max(0, timeout_ms - elapsed_ms)
    wait_budget_ms = max(remaining_budget_ms - drain_policy.margin_ms, drain_policy.floor_ms)
    drain_policy.now_ms.() + wait_budget_ms
  end

  defp owner_task_timeout_ms(timeout_ms, drain_policy) do
    poll_budget_ms = max(timeout_ms - drain_policy.margin_ms, drain_policy.floor_ms)

    max(
      timeout_ms,
      poll_budget_ms + drain_policy.owner_post_deadline_call_budget_ms +
        @owner_task_finish_margin_ms
    )
  end

  defp coordinator_call_timeout_ms(timeout_ms, drain_policy) do
    owner_task_timeout_ms(timeout_ms, drain_policy) + 1_000
  end

  defp conservative_call_timeout_ms(timeout_ms) do
    timeout_ms + @default_owner_post_deadline_call_budget_ms + @owner_task_finish_margin_ms +
      1_000
  end

  defp cancel_timer(timer_ref, wait_token) do
    _result = Process.cancel_timer(timer_ref)

    receive do
      {:rollout_drain_wait_elapsed, ^wait_token} -> :ok
    after
      0 -> :ok
    end
  end

  defp parse_timeout_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {timeout_ms, ""} when timeout_ms > 0 -> timeout_ms
      _invalid -> @default_timeout_ms
    end
  end

  defp parse_timeout_ms(_value), do: @default_timeout_ms

  defp log_drain_started(timeout_ms, already_draining?) do
    Logger.info(
      "websocket rollout drain started " <>
        "timeout_ms=#{timeout_ms} already_draining=#{already_draining?}"
    )
  end

  defp log_drain_finished(summary) do
    Logger.info(
      "websocket rollout drain finished " <>
        "owners_seen=#{summary.owners_seen} " <>
        "owners_drained=#{summary.owners_drained} " <>
        "owners_idle=#{summary.owners_idle} " <>
        "owners_failed=#{summary.owners_failed} " <>
        "turns_completed=#{summary.turns_completed} " <>
        "turns_aborted=#{summary.turns_aborted} " <>
        "timeout_ms=#{summary.timeout_ms} " <>
        "elapsed_ms=#{summary.elapsed_ms} " <>
        "result=#{summary.result}"
    )
  end

  defp empty_summary(result, timeout_ms, already_draining?) do
    %{
      result: result,
      owners_seen: 0,
      owners_drained: 0,
      owners_idle: 0,
      owners_failed: 0,
      turns_completed: 0,
      turns_aborted: 0,
      timeout_ms: timeout_ms,
      elapsed_ms: 0,
      already_draining?: already_draining?
    }
  end
end
