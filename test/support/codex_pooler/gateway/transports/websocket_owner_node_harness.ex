defmodule CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness do
  @moduledoc false

  def fake_upstream_boundary(test_pid, opts \\ []) when is_pid(test_pid) do
    block_ref = Keyword.get(opts, :block_ref)
    messages = Keyword.get(opts, :messages, [])
    return_request_result? = Keyword.get(opts, :return_request_result?, false)

    %{
      start: fn -> start_fake_upstream(test_pid) end,
      send: fn upstream_pid, payload, writer ->
        record_frame(upstream_pid, payload, test_pid)
        emit_messages(messages, writer, block_ref, test_pid)
        maybe_request_result(payload, messages, return_request_result?)
      end,
      close: fn upstream_pid -> stop_fake_upstream(upstream_pid, test_pid) end
    }
  end

  defp maybe_request_result(
         %CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request{},
         messages,
         true
       ) do
    {:ok,
     %{
       body: Enum.join(messages, "\n"),
       terminal: "response.completed",
       status: 200,
       headers: [],
       websocket_frame_headers: %{}
     }}
  end

  defp maybe_request_result(_payload, _messages, _return_request_result?), do: :ok

  def fake_upstream_frames(upstream_pid) when is_pid(upstream_pid) do
    Agent.get(upstream_pid, fn state -> Enum.reverse(state.frames) end)
  end

  def fake_persistence_boundary do
    %{
      renew_owner_token: fn _session_id, _owner_lease_token, _opts ->
        {:error, :stale_owner}
      end,
      release_owner_lease: fn _session_id, _owner_lease_token, _reason -> :ok end,
      interrupt_codex_session: fn _session_id, _opts -> :ok end
    }
  end

  def start_owner_runtime do
    caller = self()
    ready_ref = make_ref()

    runtime =
      spawn(fn ->
        Mix.start()

        {:ok, _registry} =
          Registry.start_link(
            keys: :unique,
            name: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Registry
          )

        {:ok, _task_supervisor} =
          Task.Supervisor.start_link(
            name: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.TaskSupervisor
          )

        send(caller, {ready_ref, :ready})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {^ready_ref, :ready} -> {:ok, runtime}
    after
      2_000 -> {:error, :owner_runtime_start_timeout}
    end
  end

  defp start_fake_upstream(test_pid) do
    Agent.start_link(fn -> %{frames: [], closed?: false} end)
    |> tap(fn
      {:ok, upstream_pid} ->
        send(test_pid, {:websocket_owner_harness_upstream_started, upstream_pid})

      _other ->
        :ok
    end)
  end

  defp record_frame(upstream_pid, payload, test_pid) do
    Agent.update(upstream_pid, fn state -> %{state | frames: [payload | state.frames]} end)
    send(test_pid, {:websocket_owner_harness_upstream_sent, upstream_pid})
  end

  defp emit_messages(messages, writer, nil, _test_pid) do
    Enum.each(messages, writer)
  end

  defp emit_messages(messages, writer, block_ref, test_pid) when is_reference(block_ref) do
    {before_barrier, after_barrier} = Enum.split(messages, 1)
    Enum.each(before_barrier, writer)
    send(test_pid, {:websocket_owner_harness_barrier, self(), block_ref})

    receive do
      {:websocket_owner_harness_release, ^block_ref} -> :ok
    after
      5_000 -> raise "timed out waiting for websocket owner harness release"
    end

    Enum.each(after_barrier, writer)
  end

  defp stop_fake_upstream(upstream_pid, test_pid) do
    Agent.update(upstream_pid, fn state -> %{state | closed?: true} end)
    send(test_pid, {:websocket_owner_harness_upstream_closed, upstream_pid})
    Agent.stop(upstream_pid)
  catch
    :exit, _reason -> :ok
  end

  def node_client_opts(nodes, opts \\ []) when is_list(nodes) do
    previous = Process.get(__MODULE__)

    Process.put(__MODULE__, %{
      nodes: nodes,
      calls: Keyword.get(opts, :calls, %{}),
      roles: Keyword.get(opts, :roles, %{})
    })

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Process.delete(__MODULE__)
        value -> Process.put(__MODULE__, value)
      end
    end)

    [node_client: __MODULE__]
  end

  @behaviour CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder.NodeClient

  @impl true
  def connected_app_nodes do
    __MODULE__
    |> Process.get(%{})
    |> Map.get(:nodes, [])
  end

  @impl true
  def app_node?(node) do
    role = node_role(node)
    app_node? = role in [nil, "", "web", "all"]

    send(self(), {
      :websocket_owner_harness_app_node_check,
      %{node: node, role: role, app_node?: app_node?}
    })

    app_node?
  end

  @impl true
  def call_owner(node, module, function, args, timeout) do
    mode = call_mode(node)
    send_call_observation(node, module, function, args, timeout, mode)
    dispatch_call_mode(mode, node, module, function, args)
  end

  defp dispatch_call_mode(:success, _node, module, function, args),
    do: apply(module, function, args)

  defp dispatch_call_mode({:return, result}, _node, _module, _function, _args), do: result

  defp dispatch_call_mode(:timeout, _node, _module, _function, _args),
    do: {:error, :owner_forward_timeout}

  defp dispatch_call_mode(:nodedown, _node, _module, _function, _args),
    do: {:error, :owner_unavailable}

  defp dispatch_call_mode(:raw_timeout, _node, _module, _function, _args), do: exit(:timeout)

  defp dispatch_call_mode(:raw_noconnection, _node, _module, _function, _args),
    do: exit(:noconnection)

  defp dispatch_call_mode(:raw_noproc, _node, _module, _function, _args), do: exit(:noproc)

  defp dispatch_call_mode(:raw_nodedown, node, _module, _function, _args),
    do: exit({:nodedown, node})

  defp dispatch_call_mode(:crash, _node, _module, _function, _args),
    do: raise("simulated remote owner crash")

  # Emulates an owner node still running the previous release: it exports
  # remote_attach_downstream/2 but not /3, so the option-carrying bridge
  # attach raises the same {:exception, :undef, _} error :erpc.call surfaces
  # for a missing remote function, while every other forward works unchanged.
  defp dispatch_call_mode(:old_release, _node, module, function, args) do
    if function == :remote_attach_downstream and length(args) == 3 do
      :erlang.error({:exception, :undef, [{module, function, args, []}]})
    else
      apply(module, function, args)
    end
  end

  defp dispatch_call_mode(
         {:delayed_success, _parent, _release_ref},
         _node,
         module,
         :remote_cancel_downstream,
         args
       ),
       do: apply(module, :remote_cancel_downstream, args)

  defp dispatch_call_mode(
         {:delayed_success, parent, release_ref},
         _node,
         module,
         function,
         args
       )
       when is_pid(parent) and is_reference(release_ref) do
    start_delayed_success(parent, release_ref, module, function, args)
    {:error, :owner_forward_timeout}
  end

  defp start_delayed_success(parent, release_ref, module, function, args) do
    spawn_link(fn ->
      send(parent, {:websocket_owner_harness_delayed_started, self(), release_ref})

      receive do
        {:websocket_owner_harness_release_delayed, ^release_ref} ->
          result = apply(module, function, args)
          send(parent, {:websocket_owner_harness_delayed_result, release_ref, result})
      after
        5_000 ->
          send(
            parent,
            {:websocket_owner_harness_delayed_result, release_ref, {:error, :timeout}}
          )
      end
    end)
  end

  defp node_role(node) do
    roles =
      __MODULE__
      |> Process.get(%{})
      |> Map.get(:roles, %{})

    Map.get(roles, node)
  end

  defp call_mode(node) do
    calls =
      __MODULE__
      |> Process.get(%{})
      |> Map.get(:calls, %{})

    Map.get(calls, node, :success)
  end

  defp send_call_observation(node, module, function, args, timeout, mode) do
    send(self(), {
      :websocket_owner_harness_node_call,
      %{
        node: node,
        module: module,
        function: function,
        arity: length(args),
        timeout: timeout,
        mode: mode
      }
    })
  end
end
