defmodule CodexPooler.InstanceSettings.Cache do
  @moduledoc false

  use GenServer

  require Logger

  alias CodexPooler.InstanceSettings.Settings
  alias Phoenix.PubSub

  @pubsub CodexPooler.PubSub
  @topic "instance_settings"
  @message_tag __MODULE__

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec current() :: Settings.t()
  def current do
    GenServer.call(__MODULE__, :current)
  catch
    :exit, {:noproc, {GenServer, :call, [__MODULE__, :current, _timeout]}} ->
      Settings.fallback_default()
  end

  @spec put(Settings.t()) :: :ok
  def put(%Settings{} = settings), do: GenServer.call(__MODULE__, {:put, settings})

  @spec broadcast_update(Settings.t()) :: :ok | {:error, term()}
  def broadcast_update(%Settings{} = settings) do
    PubSub.broadcast(@pubsub, @topic, {@message_tag, {:updated, settings.lock_version}})
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(@pubsub, @topic)

  @spec reset_for_test() :: :ok
  def reset_for_test, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_state) do
    _ = subscribe()
    {:ok, %{cached: nil}}
  end

  @impl true
  def handle_call(:current, _from, %{cached: %Settings{} = settings} = state) do
    settings = Settings.mark_loaded(settings, :database)

    {:reply, settings, %{state | cached: settings}}
  end

  def handle_call(:current, _from, %{cached: nil} = state) do
    case load_settings(state.cached) do
      {:ok, settings} -> {:reply, settings, %{state | cached: settings}}
      {:fallback, settings} -> {:reply, settings, state}
    end
  end

  def handle_call({:put, %Settings{} = settings}, _from, state) do
    {:reply, :ok, %{state | cached: Settings.mark_loaded(settings, :database)}}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{cached: nil}}
  end

  @impl true
  def handle_info(
        {@message_tag, {:updated, lock_version}},
        %{cached: %Settings{lock_version: lock_version}} = state
      ) do
    {:noreply, state}
  end

  def handle_info({@message_tag, {:updated, _lock_version}}, state) do
    case load_settings(state.cached) do
      {:ok, settings} -> {:noreply, %{state | cached: settings}}
      {:fallback, _settings} -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp load_settings(last_known_good) do
    settings = ensure_singleton_with_repo!()
    {:ok, Settings.mark_loaded(settings, :database)}
  rescue
    exception ->
      log_db_failure(exception, not is_nil(last_known_good))

      case last_known_good do
        %Settings{} = settings -> {:fallback, settings}
        nil -> {:fallback, Settings.fallback_default()}
      end
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

  defp log_db_failure(reason, warm_cache?) do
    Logger.warning(fn ->
      "instance settings db load failed warm_cache=#{warm_cache?} exception=#{reason_label(reason)}"
    end)
  end

  defp reason_label(%{__struct__: module}), do: inspect(module)
end
