defmodule CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  @controlled_stages [
    :nonterminal_frames,
    :terminal_frames,
    :task_result,
    :downstream_send_result,
    :invalidation_result,
    :timer_message
  ]

  @spec two_sender_controls() :: %{required(atom()) => reference()}
  def two_sender_controls do
    Map.new(@controlled_stages, &{&1, make_ref()})
  end

  @spec two_sender_upstream_boundary(pid(), map(), keyword()) :: map()
  def two_sender_upstream_boundary(test_pid, controls, opts \\ [])
      when is_pid(test_pid) and is_map(controls) and is_list(opts) do
    nonterminal_frames = Keyword.get(opts, :nonterminal_frames, [])
    terminal_frames = Keyword.get(opts, :terminal_frames, [])
    task_result = Keyword.get(opts, :task_result, :ok)

    %{
      start: fn -> start_fake_upstream(test_pid) end,
      send: fn upstream_pid, payload, writer ->
        record_frame(upstream_pid, payload, test_pid)

        start_controlled_frame_sender(
          test_pid,
          controls,
          writer,
          nonterminal_frames,
          terminal_frames
        )

        await_controlled_release(test_pid, controls, :task_result)
        task_result
      end,
      close: fn upstream_pid -> stop_fake_upstream(upstream_pid, test_pid) end
    }
  end

  @spec controlled_result(pid(), map(), atom(), term()) :: term()
  def controlled_result(test_pid, controls, stage, result)
      when is_pid(test_pid) and is_map(controls) and stage in @controlled_stages do
    await_controlled_release(test_pid, controls, stage)
    result
  end

  @spec controlled_timer_message(pid(), pid(), map(), term()) :: :ok
  def controlled_timer_message(test_pid, target, controls, message)
      when is_pid(test_pid) and is_pid(target) and is_map(controls) do
    await_controlled_release(test_pid, controls, :timer_message)
    send(target, message)
    :ok
  end

  @spec release_controlled(pid(), map(), atom()) :: :ok
  def release_controlled(barrier_pid, controls, stage)
      when is_pid(barrier_pid) and is_map(controls) and stage in @controlled_stages do
    send(barrier_pid, {:websocket_owner_harness_release_controlled, Map.fetch!(controls, stage)})
    :ok
  end

  def fake_upstream_boundary(test_pid, opts \\ []) when is_pid(test_pid) do
    block_ref = Keyword.get(opts, :block_ref)
    messages = Keyword.get(opts, :messages, [])
    return_request_result? = Keyword.get(opts, :return_request_result?, false)
    connection = Keyword.get(opts, :upstream_websocket_connection)

    %{
      start: fn -> start_fake_upstream(test_pid) end,
      send: fn upstream_pid, payload, writer ->
        record_frame(upstream_pid, payload, test_pid)
        emit_messages(messages, writer, block_ref, test_pid)
        maybe_request_result(payload, messages, return_request_result?, connection)
      end,
      close: fn upstream_pid -> stop_fake_upstream(upstream_pid, test_pid) end
    }
  end

  defp maybe_request_result(
         %CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request{},
         messages,
         true,
         connection
       ) do
    result = %{
      body: Enum.join(messages, "\n"),
      terminal: "response.completed",
      status: 200,
      headers: [],
      websocket_frame_headers: %{}
    }

    if is_map(connection) do
      {:ok, Map.put(result, :upstream_websocket_connection, connection)}
    else
      {:ok, result}
    end
  end

  defp maybe_request_result(_payload, _messages, _return_request_result?, _connection), do: :ok

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
        Mix.env(:test)

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

  def put_owner_idle_timeout(timeout) when is_integer(timeout) do
    settings = OperationalSettings.current()

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %{settings | websocket_owner_idle_timeout_ms: timeout}
    )
  end

  def start_owner_with_local_idle_timeout(opts) when is_list(opts) do
    timeout = OperationalSettings.current().websocket_owner_idle_timeout_ms

    WebsocketOwnerSession.start_owner(Keyword.put(opts, :idle_shutdown_ms, timeout))
  end

  def owner_idle_timeout(owner_pid) when is_pid(owner_pid) do
    :sys.get_state(owner_pid).idle_shutdown_ms
  end

  def owner_count(codex_session_id) when is_binary(codex_session_id) do
    Registry.lookup(
      WebsocketOwnerSession.Registry,
      codex_session_id
    )
    |> length()
  end

  def previous_release_attach(codex_session_id, downstream) do
    with {:ok, owner_pid} <-
           WebsocketOwnerSession.lookup(codex_session_id) do
      WebsocketOwnerSession.attach_downstream(owner_pid, downstream)
    end
  end

  def previous_release_submit_request(codex_session_id, downstream, request, _opts) do
    with {:ok, owner_pid} <-
           WebsocketOwnerSession.lookup(codex_session_id) do
      owner_pid
      |> WebsocketOwnerSession.submit_request(downstream, request)
      |> drop_connection_metadata()
    end
  end

  defp drop_connection_metadata({status, result})
       when status in [:ok, :error] and is_map(result) do
    {status, Map.delete(result, :upstream_websocket_connection)}
  end

  defp drop_connection_metadata(result), do: result

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

  defp start_controlled_frame_sender(
         test_pid,
         controls,
         writer,
         nonterminal_frames,
         terminal_frames
       ) do
    spawn_link(fn ->
      await_controlled_release(test_pid, controls, :nonterminal_frames)
      Enum.each(nonterminal_frames, writer)
      await_controlled_release(test_pid, controls, :terminal_frames)
      Enum.each(terminal_frames, writer)
    end)
  end

  defp await_controlled_release(test_pid, controls, stage) do
    release_ref = Map.fetch!(controls, stage)
    send(test_pid, {:websocket_owner_harness_controlled_barrier, stage, self(), release_ref})

    receive do
      {:websocket_owner_harness_release_controlled, ^release_ref} -> :ok
    after
      5_000 -> raise "timed out waiting for websocket owner controlled release"
    end
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

    Process.put(__MODULE__, node_client_state(nodes, opts))

    ExUnit.Callbacks.on_exit(fn ->
      restore_node_client_state(previous)
    end)

    [node_client: __MODULE__]
  end

  @spec with_node_client([node()], keyword(), (keyword() -> term())) :: term()
  def with_node_client(nodes, opts \\ [], fun)
      when is_list(nodes) and is_list(opts) and is_function(fun, 1) do
    previous = Process.get(__MODULE__)
    Process.put(__MODULE__, node_client_state(nodes, opts))

    try do
      fun.(node_client: __MODULE__)
    after
      restore_node_client_state(previous)
    end
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

  defp dispatch_call_mode(
         {:barrier_success, notify, release_ref},
         _node,
         module,
         function,
         args
       )
       when is_pid(notify) and is_reference(release_ref) do
    await_call_barrier(notify, release_ref, function)
    apply(module, function, args)
  end

  defp dispatch_call_mode(
         {:barrier_return, notify, release_ref, result},
         _node,
         _module,
         function,
         _args
       )
       when is_pid(notify) and is_reference(release_ref) do
    await_call_barrier(notify, release_ref, function)
    result
  end

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
    notify = __MODULE__ |> Process.get(%{}) |> Map.get(:notify, self())

    send(notify, {
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

  defp await_call_barrier(notify, release_ref, function) do
    send(
      notify,
      {:websocket_owner_harness_call_barrier, self(), release_ref, function}
    )

    receive do
      {:websocket_owner_harness_release_call, ^release_ref} -> :ok
    after
      5_000 -> raise "timed out waiting for websocket owner RPC harness release"
    end
  end

  defp node_client_state(nodes, opts) do
    %{
      nodes: nodes,
      calls: Keyword.get(opts, :calls, %{}),
      roles: Keyword.get(opts, :roles, %{}),
      notify: Keyword.get(opts, :notify, self())
    }
  end

  defp restore_node_client_state(nil), do: Process.delete(__MODULE__)
  defp restore_node_client_state(previous), do: Process.put(__MODULE__, previous)
end

defmodule CodexPooler.Gateway.Transports.WebsocketOwnerPreviousReleaseCaller do
  @moduledoc false

  @old_result_keys [:body, :headers, :status, :terminal, :websocket_frame_headers]

  def attach_and_submit(owner_node, codex_session_id, downstream, request) do
    forwarder =
      CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder

    with {:ok, attached} <-
           :erpc.call(owner_node, forwarder, :remote_attach_downstream, [
             codex_session_id,
             downstream
           ]),
         {:ok, result} <-
           :erpc.call(owner_node, forwarder, :remote_submit_request, [
             codex_session_id,
             attached,
             request,
             []
           ]) do
      connection_keys =
        result
        |> Map.get(:upstream_websocket_connection, %{})
        |> Map.keys()
        |> Enum.sort()

      send(
        downstream.pid,
        {:websocket_owner_previous_release_caller, node(), connection_keys}
      )

      {:ok, Map.take(result, @old_result_keys)}
    end
  end
end
