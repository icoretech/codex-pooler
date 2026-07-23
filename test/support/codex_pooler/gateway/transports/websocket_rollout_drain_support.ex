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

    # A safety net so a test that forgets to release the probe fails instead of
    # hanging the suite. It must stay well above every drain budget under test,
    # or a loaded machine lets this fire first and reports a synthetic
    # `:owner_unavailable` for a drain that was merely slow to be released. A
    # test that abandons its probe on purpose should pass a short
    # `:release_timeout_ms` so teardown does not wait out this default.
    @release_timeout_ms 15_000

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
         release_timeout_ms: Keyword.get(opts, :release_timeout_ms, @release_timeout_ms)
       }}
    end

    @impl GenServer
    def handle_cast(:begin_drain, state), do: {:noreply, state}

    @impl GenServer
    def handle_call(:owner_status, _from, state) do
      {:reply, {:ok, %{active_turn?: false}}, state}
    end

    def handle_call(:drain, _from, %{key: key, parent: parent} = state) do
      send(parent, {:rollout_drain_probe_started, key})

      result =
        receive do
          {:release_rollout_drain_probe, ^key} -> :ok
        after
          state.release_timeout_ms -> {:error, :owner_unavailable}
        end

      {:stop, :normal, result, state}
    end
  end

  defmodule ActiveShutdownProbeOwner do
    @moduledoc false

    use GenServer

    # Safety net only; see the note on `DrainProbeOwner`.
    @release_timeout_ms 15_000

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
    def handle_cast(:begin_drain, state), do: {:noreply, state}

    @impl GenServer
    def handle_call(:owner_status, _from, state) do
      {:reply, {:ok, %{active_turn?: false}}, state}
    end

    def handle_call(:drain, _from, %{key: key, parent: parent} = state) do
      drain_calls = state.drain_calls + 1
      send(parent, {:active_shutdown_probe_started, key, drain_calls})

      receive do
        {:release_active_shutdown_probe, ^key} -> :ok
      after
        @release_timeout_ms -> exit(:active_shutdown_probe_timeout)
      end

      {:reply, :ok, %{state | drain_calls: drain_calls}}
    end

    def handle_call(:drain_calls, _from, state) do
      {:reply, state.drain_calls, state}
    end
  end

  defmodule VirtualDeadline do
    @moduledoc false

    use GenServer

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @spec now_ms(pid()) :: integer()
    def now_ms(deadline), do: GenServer.call(deadline, :now_ms)

    @spec schedule_wait(pid(), pid(), reference(), non_neg_integer()) :: reference()
    def schedule_wait(deadline, recipient, wait_token, wait_ms) do
      GenServer.call(deadline, {:schedule_wait, recipient, wait_token, wait_ms})
    end

    @spec cancel_wait(pid(), reference()) :: :ok
    def cancel_wait(deadline, wait_ref), do: GenServer.call(deadline, {:cancel_wait, wait_ref})

    @spec advance(pid(), non_neg_integer()) :: :ok
    def advance(deadline, elapsed_ms), do: GenServer.call(deadline, {:advance, elapsed_ms})

    @spec waiter_pids(pid()) :: [pid()]
    def waiter_pids(deadline), do: GenServer.call(deadline, :waiter_pids)

    @impl GenServer
    def init(opts) do
      {:ok,
       %{
         now_ms: Keyword.get(opts, :now_ms, 0),
         parent: Keyword.fetch!(opts, :parent),
         waiters: %{}
       }}
    end

    @impl GenServer
    def handle_call(:now_ms, _from, state), do: {:reply, state.now_ms, state}

    def handle_call(:waiter_pids, _from, state) do
      waiters =
        Map.filter(state.waiters, fn {_wait_ref, waiter} ->
          Process.alive?(waiter.recipient)
        end)

      waiter_pids = Enum.map(waiters, fn {_wait_ref, waiter} -> waiter.recipient end)
      {:reply, waiter_pids, %{state | waiters: waiters}}
    end

    def handle_call({:schedule_wait, recipient, wait_token, wait_ms}, _from, state) do
      wait_ref = make_ref()
      monitor_ref = Process.monitor(recipient)
      send(state.parent, {:rollout_drain_deadline_wait, self(), wait_ms})

      waiter = %{
        until_ms: state.now_ms + wait_ms,
        recipient: recipient,
        wait_token: wait_token,
        monitor_ref: monitor_ref
      }

      {:reply, wait_ref, %{state | waiters: Map.put(state.waiters, wait_ref, waiter)}}
    end

    def handle_call({:cancel_wait, wait_ref}, _from, state) do
      {:reply, :ok, remove_waiter(state, wait_ref)}
    end

    def handle_call({:advance, elapsed_ms}, _from, state) do
      now_ms = state.now_ms + elapsed_ms

      {ready, waiting} =
        Map.split_with(state.waiters, fn {_wait_ref, waiter} -> waiter.until_ms <= now_ms end)

      Enum.each(ready, fn {_wait_ref, waiter} ->
        Process.demonitor(waiter.monitor_ref, [:flush])
        send(waiter.recipient, {:rollout_drain_wait_elapsed, waiter.wait_token})
      end)

      {:reply, :ok, %{state | now_ms: now_ms, waiters: waiting}}
    end

    @impl GenServer
    def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
      waiters =
        Map.reject(state.waiters, fn {_wait_ref, waiter} -> waiter.monitor_ref == monitor_ref end)

      {:noreply, %{state | waiters: waiters}}
    end

    defp remove_waiter(state, wait_ref) do
      case Map.pop(state.waiters, wait_ref) do
        {nil, _waiters} ->
          state

        {waiter, waiters} ->
          Process.demonitor(waiter.monitor_ref, [:flush])
          %{state | waiters: waiters}
      end
    end
  end

  defmodule WaitingOwner do
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

    @spec complete_turn(pid()) :: :ok
    def complete_turn(owner), do: GenServer.call(owner, :complete_turn)

    @spec lose_lease(pid()) :: :ok
    def lose_lease(owner), do: GenServer.call(owner, :lose_lease)

    @impl GenServer
    def init(opts) do
      {:ok,
       %{
         active_turn?: Keyword.get(opts, :active_turn?, true),
         begin_drain_calls: 0,
         drain_calls: 0,
         key: Keyword.fetch!(opts, :key),
         parent: Keyword.fetch!(opts, :parent)
       }}
    end

    @impl GenServer
    def handle_cast(:begin_drain, state) do
      begin_drain_calls = state.begin_drain_calls + 1
      send(state.parent, {:rollout_drain_begin_wait, state.key, begin_drain_calls})
      {:noreply, %{state | begin_drain_calls: begin_drain_calls}}
    end

    @impl GenServer
    def handle_call(:owner_status, _from, state) do
      {:reply, {:ok, %{active_turn?: state.active_turn?}}, state}
    end

    def handle_call(:complete_turn, _from, state) do
      send(state.parent, {:rollout_drain_terminal_delivered, state.key})
      {:reply, :ok, %{state | active_turn?: false}}
    end

    def handle_call(:lose_lease, _from, state) do
      send(state.parent, {:rollout_drain_lease_lost, state.key})
      {:stop, {:shutdown, :stale_owner}, :ok, state}
    end

    def handle_call(:drain, _from, state) do
      drain_calls = state.drain_calls + 1
      outcome = if state.active_turn?, do: :aborted, else: :completed
      send(state.parent, {:rollout_drain_owner_stopped, state.key, outcome, drain_calls})
      {:stop, :normal, :ok, %{state | drain_calls: drain_calls}}
    end
  end

  defmodule SlowFinalStatusOwner do
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
         status_calls: 0
       }}
    end

    @impl GenServer
    def handle_cast(:begin_drain, state), do: {:noreply, state}

    @impl GenServer
    def handle_call(:owner_status, _from, %{status_calls: 0} = state) do
      {:reply, {:ok, %{active_turn?: true}}, %{state | status_calls: 1}}
    end

    def handle_call(:owner_status, _from, state) do
      send(state.parent, {:slow_final_owner_status_started, state.key})

      receive do
        {:release_slow_final_owner_status, key} when key == state.key -> :ok
      end

      {:reply, {:ok, %{active_turn?: false}}, %{state | status_calls: state.status_calls + 1}}
    end

    def handle_call(:drain, _from, state) do
      send(state.parent, {:slow_final_owner_drain_started, state.key})

      receive do
        {:release_slow_final_owner_drain, key} when key == state.key -> :ok
      end

      {:stop, :normal, :ok, state}
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

  @spec configure_drain_marker!() :: String.t()
  def configure_drain_marker! do
    previous_config = Application.get_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)

    marker_path =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-drain-marker-#{System.unique_integer([:positive])}"
      )

    File.write!(marker_path, "draining")

    Application.put_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus,
      drain_marker_path: marker_path
    )

    ExUnit.Callbacks.on_exit(fn ->
      File.rm(marker_path)

      if previous_config do
        Application.put_env(
          :codex_pooler,
          CodexPooler.Gateway.OperationalStatus,
          previous_config
        )
      else
        Application.delete_env(:codex_pooler, CodexPooler.Gateway.OperationalStatus)
      end
    end)

    marker_path
  end

  @spec start_virtual_deadline(pid(), keyword()) :: pid()
  def start_virtual_deadline(parent, opts \\ []) when is_pid(parent) do
    ExUnit.Callbacks.start_supervised!({VirtualDeadline, Keyword.put(opts, :parent, parent)})
  end

  @spec deadline_options(pid()) :: keyword()
  def deadline_options(deadline) when is_pid(deadline) do
    [
      deadline: %{
        now_ms: fn -> VirtualDeadline.now_ms(deadline) end,
        schedule_wait: fn recipient, wait_token, wait_ms ->
          VirtualDeadline.schedule_wait(deadline, recipient, wait_token, wait_ms)
        end,
        cancel_wait: fn wait_ref, _wait_token ->
          VirtualDeadline.cancel_wait(deadline, wait_ref)
        end
      }
    ]
  end

  @spec start_rollout_drain_harness(pid(), keyword()) :: %{deadline: pid(), name: atom()}
  def start_rollout_drain_harness(parent, opts \\ []) when is_pid(parent) do
    deadline = start_virtual_deadline(parent, opts)
    drain_name = :"rollout-drain-harness-#{System.unique_integer([:positive])}"

    start_opts = [name: drain_name] ++ deadline_options(deadline)

    {RolloutDrain, start_opts}
    |> Supervisor.child_spec(id: {RolloutDrain, drain_name})
    |> ExUnit.Callbacks.start_supervised!()

    %{deadline: deadline, name: drain_name}
  end

  @spec restore_env(String.t(), String.t() | nil) :: :ok
  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  # Bounded by wall clock rather than by a fixed number of yields: a loaded
  # machine burns a spin budget long before the second caller has joined the
  # drain, which turns "the machine was busy" into "the waiters never
  # registered".
  @waiter_timeout_ms 5_000

  @spec await_active_drain_waiters(GenServer.server(), pos_integer(), pos_integer()) ::
          :ok | {:error, :timeout}
  def await_active_drain_waiters(drain_name, expected_count, timeout_ms \\ @waiter_timeout_ms) do
    await_active_drain_waiters_until(
      drain_name,
      expected_count,
      System.monotonic_time(:millisecond) + timeout_ms
    )
  end

  defp await_active_drain_waiters_until(drain_name, expected_count, deadline_ms) do
    case :sys.get_state(drain_name) do
      %{active_drain: %{waiters: waiters}} when length(waiters) >= expected_count ->
        :ok

      _state ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          {:error, :timeout}
        else
          receive do
          after
            1 -> await_active_drain_waiters_until(drain_name, expected_count, deadline_ms)
          end
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
