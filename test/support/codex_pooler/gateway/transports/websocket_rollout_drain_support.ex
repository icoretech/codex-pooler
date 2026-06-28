defmodule CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  @type owner_context :: %{
          required(:codex_session_id) => String.t(),
          required(:owner_lease_token) => String.t(),
          required(:owner_instance_id) => String.t()
        }

  defmodule DrainProbeOwner do
    @moduledoc false

    use GenServer

    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(opts) do
      key = Keyword.fetch!(opts, :key)

      %{
        id: {__MODULE__, key},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      key = Keyword.fetch!(opts, :key)

      GenServer.start_link(__MODULE__, opts,
        name:
          {:via, Registry,
           {CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Registry, key}}
      )
    end

    @impl GenServer
    def init(opts) do
      {:ok, %{key: Keyword.fetch!(opts, :key), parent: Keyword.fetch!(opts, :parent)}}
    end

    @impl GenServer
    def handle_call(:drain, _from, %{key: key, parent: parent} = state) do
      send(parent, {:rollout_drain_probe_started, key})

      receive do
        {:release_rollout_drain_probe, ^key} -> :ok
      after
        1_000 -> exit(:rollout_drain_probe_timeout)
      end

      {:stop, :normal, :ok, state}
    end
  end

  defmodule ActiveShutdownProbeOwner do
    @moduledoc false

    use GenServer

    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(opts) do
      key = Keyword.fetch!(opts, :key)

      %{
        id: {__MODULE__, key},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      key = Keyword.fetch!(opts, :key)

      GenServer.start_link(__MODULE__, opts,
        name:
          {:via, Registry,
           {CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Registry, key}}
      )
    end

    @impl GenServer
    def init(opts) do
      {:ok,
       %{
         key: Keyword.fetch!(opts, :key),
         parent: Keyword.fetch!(opts, :parent),
         drain_calls: 0
       }}
    end

    @impl GenServer
    def handle_call(:drain, _from, %{key: key, parent: parent} = state) do
      drain_calls = state.drain_calls + 1
      send(parent, {:active_shutdown_probe_started, key, drain_calls})

      receive do
        {:release_active_shutdown_probe, ^key} -> :ok
      after
        1_000 -> exit(:active_shutdown_probe_timeout)
      end

      {:reply, :ok, %{state | drain_calls: drain_calls}}
    end

    def handle_call(:drain_calls, _from, state) do
      {:reply, state.drain_calls, state}
    end
  end

  @spec owner_context() :: owner_context()
  def owner_context do
    %{
      codex_session_id: owner_key(),
      owner_lease_token: "owner-token-#{System.unique_integer([:positive])}",
      owner_instance_id: Atom.to_string(node())
    }
  end

  @spec owner_key() :: String.t()
  def owner_key do
    "codex-session-#{System.unique_integer([:positive])}"
  end

  @spec configure_rollout_drain_server(GenServer.server()) :: :ok
  def configure_rollout_drain_server(drain_name) do
    Application.put_env(:codex_pooler, RolloutDrain, server_name: drain_name)
  end

  @spec restore_env(String.t(), String.t() | nil) :: :ok
  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  @spec await_active_drain_waiters(GenServer.server(), pos_integer(), non_neg_integer()) ::
          :ok | {:error, :timeout}
  def await_active_drain_waiters(drain_name, expected_count, attempts_left \\ 1_000)

  def await_active_drain_waiters(_drain_name, _expected_count, 0), do: {:error, :timeout}

  def await_active_drain_waiters(drain_name, expected_count, attempts_left) do
    case :sys.get_state(drain_name) do
      %{active_drain: %{waiters: waiters}} when length(waiters) >= expected_count ->
        :ok

      _state ->
        receive do
        after
          0 -> await_active_drain_waiters(drain_name, expected_count, attempts_left - 1)
        end
    end
  end

  @spec start_owner(owner_context(), keyword()) :: WebsocketOwnerSession.start_result()
  def start_owner(context, opts) do
    WebsocketOwnerSession.start_owner(
      Keyword.merge(opts,
        codex_session_id: context.codex_session_id,
        owner_lease_token: context.owner_lease_token,
        owner_instance_id: context.owner_instance_id
      )
    )
  end

  @spec cleanup_owner_session(String.t()) :: :ok
  def cleanup_owner_session(codex_session_id) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner} ->
        owner_ref = Process.monitor(owner)
        _result = GenServer.stop(owner, :normal, 1_000)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
        after
          1_000 -> :ok
        end

      {:error, :owner_unavailable} ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
