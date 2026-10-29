defmodule CodexPoolerWeb.Runtime.NativeCompactionPendingScenario do
  @moduledoc false

  import Ecto.Query
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_shared_peer_window_owner!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityDrain, ActivityRegistry, UpstreamWebsocketSession, WebsocketOwnerSession}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.{DownstreamKeepaliveScenario, WebsocketCleanupFence}

  @path "/backend-api/codex/responses"
  @compact_path @path <> "/compact"
  @budget 15_000
  @watchdog 1_500
  @anchor "resp_pending_anchor000000001"
  @compact "resp_pending_compact00000001"
  @lite "ws_request_header_x_openai_internal_codex_responses_lite"

  @spec run!(String.t(), atom(), atom(), keyword()) :: :ok
  def run!(mode, topology, form, opts \\ []) do
    outcome = Keyword.get(opts, :outcome, :complete)
    peer = configure_environment!(outcome, topology, opts)
    hold = make_ref()
    expectations = sequence(hold, form)
    expectations = if outcome == :complete, do: expectations, else: Enum.take(expectations, 2)
    upstream = start_upstream(FakeUpstream.strict_sequence(expectations))
    on_exit(fn -> release_on_exit(upstream, hold) end)
    setup = gateway_setup(upstream, compact?: true)
    set_model_serving_mode!(model_serving_scope(), setup, mode)
    thread = Ecto.UUID.generate()
    window = thread <> ":0"

    if peer do
      owner = start_shared_peer_window_owner!(setup, window, peer)
      assert node(owner.owner_pid) == peer
    end

    client = connect!(setup, thread, window) |> Map.put(:answer_pings?, outcome != :ignore_pong)
    on_exit(fn -> release_on_exit(upstream, hold) end)
    first = payload(setup, mode, thread, window, [prompt()], Ecto.UUID.generate())
    {client, first_events} = client |> send!(first) |> terminal!()
    assert List.last(first_events)["type"] == "response.completed"
    await!(fn -> Enum.all?(requests(setup), &(&1.status == "succeeded")) end)
    compact = compact_payload(first, form)
    client = send!(client, compact)
    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^hold}, @budget
    [request] = Enum.filter(requests(setup), &(&1.endpoint == @compact_path))
    [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    {client, control} = next_text!(client, @watchdog)
    assert control == %{"type" => pending_type()}
    context = %{client: client, request: request, attempt: attempt, upstream: upstream, hold: hold, setup: setup, mode: mode, thread: thread, topology: topology}

    case outcome do
      :complete -> complete!(context)
      :timeout -> timeout!(context)
      :client_close -> client_close!(context)
      :frozen_source -> frozen_source!(context)
      :drain -> drain!(context)
      :ignore_pong -> no_pong!(context)
    end
  end

  defp configure_environment!(outcome, topology, opts) do
    receive_timeout = if outcome == :timeout, do: 2_000, else: 10_000
    idle_timeout = if outcome in [:complete, :ignore_pong], do: 2_000, else: 10_000
    DownstreamKeepaliveScenario.put_settings!([upstream_receive_timeout_ms: receive_timeout, websocket_idle_timeout_ms: idle_timeout], topology != :direct)
    previous = CodexPooler.TestAppEnv.restore_on_exit(UpstreamWebsocketSession)
    interval = Keyword.get(opts, :pending_interval_ms, 100)
    Application.put_env(:codex_pooler, UpstreamWebsocketSession, Keyword.put(previous, :compaction_pending_interval_ms, interval))
    peer = Keyword.get(opts, :peer_node)
    if peer, do: configure_peer!(peer, interval)
    if peer, do: enter_peer_owner_topology!()
    peer
  end

  defp complete!(%{client: client, request: request, attempt: attempt, upstream: upstream, hold: hold, setup: setup, mode: mode, thread: thread}) do
    began = System.monotonic_time(:millisecond)
    {client, count} = pending_until!(client, began + 2_100, 1)
    assert count > 1
    assert Repo.reload!(request).status == "in_progress"
    assert Repo.reload!(attempt).status == "in_progress"
    refute Map.has_key?(Repo.reload!(attempt).response_metadata || %{}, "downstream_delivery")
    assert FakeUpstream.physical_counts(upstream).websocket_generation == 2
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"), :count) == 0
    {_transport, handler} = :sys.get_state(client.socket)
    state = handler.connection.websock_state
    assert Map.get(state, :native_turn_output_task_pids, MapSet.new()) == MapSet.new()

    :ok = FakeUpstream.release_remaining_frames(upstream, hold)
    {client, events} = terminal!(client)
    output = Enum.filter(events, &(&1["type"] == "response.output_item.done"))
    assert length(output) == 1
    assert hd(output)["item"]["type"] == "compaction"
    assert List.last(events)["type"] == "response.completed"
    await!(fn -> Repo.reload!(request).status == "succeeded" and is_map(Repo.reload!(attempt).response_metadata["downstream_delivery"]) end)
    receipt = Repo.reload!(attempt).response_metadata["downstream_delivery"]
    assert receipt["outcome"] == "delivered"
    assert receipt["terminal_class"] == "response.completed"
    assert receipt["frames_after_visible"] == 2
    assert receipt["completed_items"] == 1
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"), :count) == 1
    resumed = payload(setup, mode, thread, thread <> ":1", [item(), prompt()], Ecto.UUID.generate())
    {client, resumed_events} = client |> send!(resumed) |> terminal!()
    assert List.last(resumed_events)["type"] == "response.completed"
    await!(fn -> length(requests(setup)) == 3 and Enum.all?(requests(setup), &(&1.status == "succeeded")) end)
    assert FakeUpstream.physical_counts(upstream).websocket_generation == 3
    assert FakeUpstream.physical_counts(upstream).http_generation == 0
    assert :ok = FakeUpstream.verify!(upstream)
    Mint.HTTP.close(client.conn)
    WebsocketCleanupFence.await_session_cleanups!()
    :ok
  end

  defp timeout!(ctx) do
    began = System.monotonic_time(:millisecond)
    {client, events} = terminal!(ctx.client)
    assert List.last(events)["type"] in ["error", "response.failed"]
    assert Enum.count(events, &(&1["type"] == pending_type())) > 2
    refute Enum.any?(events, &(&1["type"] == "response.output_item.done"))
    assert System.monotonic_time(:millisecond) - began < 4_000
    await!(fn -> Repo.reload!(ctx.request).status == "failed" end)
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^ctx.request.id), :count) == 1
    assert FakeUpstream.physical_counts(ctx.upstream).websocket_generation == 2
    Mint.HTTP.close(client.conn)
    FakeUpstream.release_remaining_frames(ctx.upstream, ctx.hold)
    WebsocketCleanupFence.await_session_cleanups!()
    :ok
  end

  defp client_close!(ctx) do
    Mint.HTTP.close(ctx.client.conn)
    await!(fn -> Repo.reload!(ctx.request).status == "failed" end)
    assert Repo.reload!(ctx.request).last_error_code == "client_disconnected"
    assert FakeUpstream.physical_counts(ctx.upstream).websocket_generation == 2
    FakeUpstream.release_remaining_frames(ctx.upstream, ctx.hold)
    WebsocketCleanupFence.await_session_cleanups!()
    :ok
  end

  defp drain!(ctx) do
    {_transport, handler} = :sys.get_state(ctx.client.socket)
    state = handler.connection.websock_state
    [task] = MapSet.to_list(state.tasks)
    entry = Enum.find(ActivityRegistry.activities(), &(&1.pid == task))
    refute Map.get(entry, :terminal_delivered?, false)

    policy = %{
      now_ms: fn -> System.monotonic_time(:millisecond) end,
      schedule_wait: fn recipient, token, wait -> Process.send_after(recipient, {:rollout_drain_wait_elapsed, token}, wait) end,
      cancel_wait: fn timer, _token ->
        Process.cancel_timer(timer)
        :ok
      end,
      owner_post_deadline_call_budget_ms: 5_000
    }

    drain = Task.async(fn -> ActivityDrain.drain(entry, System.monotonic_time(:millisecond) - 1, policy, ActivityRegistry) end)
    owner_drain = if ctx.topology == :local, do: Task.async(fn -> WebsocketOwnerSession.drain_owner(state.websocket_owner_pid) end)
    {client, events} = terminal!(ctx.client)
    assert List.last(events)["type"] in ["error", "response.failed"]
    refute Enum.any?(events, &(&1["type"] == "response.output_item.done"))
    Task.await(drain, @budget)
    if owner_drain, do: Task.await(owner_drain, @budget)
    await!(fn -> Repo.reload!(ctx.request).status == "failed" end)
    assert Repo.reload!(ctx.request).last_error_code == "owner_drained"
    Mint.HTTP.close(client.conn)
    FakeUpstream.release_remaining_frames(ctx.upstream, ctx.hold)
    WebsocketCleanupFence.await_session_cleanups!()
    :ok
  end

  defp no_pong!(ctx) do
    count = until_idle_close!(ctx.client, 0)
    assert count > 2
    await!(fn -> Repo.reload!(ctx.request).status == "failed" end)
    assert Repo.reload!(ctx.request).last_error_code == "client_disconnected"
    FakeUpstream.release_remaining_frames(ctx.upstream, ctx.hold)
    WebsocketCleanupFence.await_session_cleanups!()
    :ok
  end

  defp until_idle_close!(client, count) do
    next =
      try do
        {:text, next_text!(client, @watchdog)}
      rescue
        e in ExUnit.AssertionError ->
          assert e.message == "socket closed before terminal: 1002"
          :closed
      end

    case next do
      :closed ->
        count

      {:text, {client, event}} ->
        assert event == %{"type" => pending_type()}
        until_idle_close!(client, count + 1)
    end
  end

  defp frozen_source!(ctx) do
    {_transport, handler} = :sys.get_state(ctx.client.socket)
    state = handler.connection.websock_state
    upstream = if ctx.topology == :direct, do: state.upstream_websocket_session, else: :sys.get_state(state.websocket_owner_pid).upstream_pid
    on_exit(fn -> resume_source(upstream) end)
    assert :erlang.suspend_process(upstream)

    try do
      {client, count} = until_watchdog!(ctx.client, 0)
      assert count <= 1, "a frozen receive actor continued authorizing pending text"
      Mint.HTTP.close(client.conn)
    after
      resume_source(upstream)
    end

    await!(fn -> Repo.reload!(ctx.request).status == "failed" end)
    FakeUpstream.release_remaining_frames(ctx.upstream, ctx.hold)
    WebsocketCleanupFence.await_session_cleanups!()
    :ok
  end

  defp resume_source(upstream) do
    :erlang.resume_process(upstream)
  rescue
    ArgumentError -> :ok
  end

  defp until_watchdog!(client, count) do
    next =
      try do
        {:text, next_text!(client, @watchdog)}
      rescue
        e in ExUnit.AssertionError ->
          assert e.message == "text-only client watchdog expired"
          :expired
      end

    case next do
      :expired ->
        {client, count}

      {:text, {next_client, event}} ->
        assert event == %{"type" => pending_type()}
        assert count < 2, "a frozen receive actor continued authorizing pending text"
        until_watchdog!(next_client, count + 1)
    end
  end

  defp release_on_exit(upstream, hold) do
    FakeUpstream.release_remaining_frames(upstream, hold)
  catch
    :exit, {:noproc, _call} -> :ok
  end

  defp configure_peer!(peer, interval) do
    previous = :erpc.call(peer, Application, :get_env, [:codex_pooler, UpstreamWebsocketSession, []])
    on_exit(fn -> :erpc.call(peer, Application, :put_env, [:codex_pooler, UpstreamWebsocketSession, previous]) end)
    :erpc.call(peer, Application, :put_env, [:codex_pooler, UpstreamWebsocketSession, Keyword.put(previous, :compaction_pending_interval_ms, interval)])
  end

  defp sequence(hold, form) do
    compact_json = if form == :anchored, do: [valid: true, equals: %{"previous_response_id" => @anchor}], else: [valid: true, forbidden: ["previous_response_id"]]

    [
      FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, respond: FakeUpstream.websocket_text_frames(events(@anchor, []))),
      FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, json: compact_json, respond: FakeUpstream.barrier_websocket_frames(events(@compact, [item()]), notify: self(), release_ref: hold)),
      FakeUpstream.expect_request(method: "WEBSOCKET", websocket_connection_ordinal: 1, respond: FakeUpstream.websocket_text_frames(events("resp_pending_resume000000001", [])))
    ]
  end

  defp connect!(setup, thread, window) do
    port = start_public_endpoint!()
    sockets = WebsocketCleanupFence.listener_sockets()
    headers = [{"session-id", thread}, {"thread-id", thread}, {"x-codex-window-id", window}]
    {conn, websocket, ref, _headers} = public_websocket_connect_with_request_headers!(port, setup, thread, @path, headers)
    %{conn: conn, websocket: websocket, ref: ref, queued: [], socket: WebsocketCleanupFence.await_new_listener_socket!(sockets)}
  end

  defp send!(client, payload) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, CodexPooler.JSON.encode!(payload))
    %{client | conn: conn, websocket: websocket}
  end

  # This consumer deliberately bypasses the generic helper that hides controls.
  # Ping/Pong frames never renew its text-only idle deadline.
  defp next_text!(client, timeout), do: read_text!(client, System.monotonic_time(:millisecond) + timeout)
  defp read_text!(%{queued: [{:closed, code} | _rest]}, _deadline), do: flunk("socket closed before terminal: #{code}")
  defp read_text!(%{queued: [text | rest]} = client, _deadline) when is_binary(text), do: {%{client | queued: rest}, CodexPooler.JSON.decode!(text)}

  defp read_text!(client, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    message = receive_mint_socket_message!(client.conn, remaining, "text-only client watchdog expired")
    {:ok, conn, responses} = Mint.WebSocket.stream(client.conn, message)
    client = Enum.reduce(responses, %{client | conn: conn}, &decode_response/2)
    read_text!(client, deadline)
  end

  defp decode_response({:data, ref, data}, %{ref: ref} = client) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(client.websocket, data)
    Enum.reduce(frames, %{client | websocket: websocket}, &decode_frame/2)
  end

  defp decode_response(_response, client), do: client
  defp decode_frame({:text, text}, client), do: %{client | queued: client.queued ++ [text]}

  defp decode_frame({:ping, _data}, %{answer_pings?: false} = client), do: client

  defp decode_frame({:ping, data}, client) do
    {:ok, websocket, encoded} = Mint.WebSocket.encode(client.websocket, {:pong, data})
    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, encoded)
    %{client | conn: conn, websocket: websocket}
  end

  defp decode_frame({:pong, _data}, client), do: client
  defp decode_frame({:close, code, _reason}, client), do: %{client | queued: client.queued ++ [{:closed, code}]}

  defp pending_until!(client, deadline, count) do
    {client, control} = next_text!(client, @watchdog)
    assert control == %{"type" => pending_type()}
    if System.monotonic_time(:millisecond) >= deadline, do: {client, count + 1}, else: pending_until!(client, deadline, count + 1)
  end

  defp terminal!(client, events \\ []) do
    {client, event} = next_text!(client, @budget)
    events = events ++ [event]
    if event["type"] in ["response.completed", "response.failed", "error"], do: {client, events}, else: terminal!(client, events)
  end

  defp requests(setup), do: Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))

  defp await!(condition) do
    deadline = System.monotonic_time(:millisecond) + @budget
    await!(condition, deadline)
  end

  defp await!(condition, deadline) do
    if condition.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "accounting did not reach the expected state"

      receive do
      after
        10 -> await!(condition, deadline)
      end
    end
  end

  defp compact_payload(first, form) do
    input = if form == :anchored, do: [%{"type" => "compaction_trigger"}], else: first["input"] ++ [%{"type" => "compaction_trigger"}]
    turn = Ecto.UUID.generate()
    metadata = first["client_metadata"]["x-codex-turn-metadata"] |> CodexPooler.JSON.decode!() |> Map.merge(%{"request_kind" => "compaction", "turn_id" => turn, "root_turn_id" => turn, "compaction" => %{"trigger" => "auto", "reason" => "context_limit", "implementation" => "responses_compaction_v2", "phase" => "pre_turn", "strategy" => "memento"}})
    compact = first |> Map.put("input", input) |> put_in(["client_metadata", "turn_id"], turn) |> put_in(["client_metadata", "root_turn_id"], turn) |> put_in(["client_metadata", "x-codex-turn-metadata"], CodexPooler.JSON.encode!(metadata))
    if form == :anchored, do: Map.put(compact, "previous_response_id", @anchor), else: compact
  end

  defp payload(setup, mode, thread, window, input, turn) do
    turn_metadata = %{"session_id" => thread, "thread_id" => thread, "turn_id" => turn, "root_turn_id" => turn, "window_id" => window, "window_number" => if(String.ends_with?(window, ":1"), do: 1, else: 0), "context_window_id" => Ecto.UUID.generate(), "request_kind" => "turn"}
    input = if mode == "lite", do: [%{"type" => "additional_tools", "role" => "developer", "tools" => []} | input], else: input
    metadata = %{"x-codex-turn-metadata" => CodexPooler.JSON.encode!(turn_metadata), "session_id" => thread, "thread_id" => thread, "turn_id" => turn, "root_turn_id" => turn, "x-codex-window-id" => window}
    base = %{"type" => "response.create", "model" => setup.model.exposed_model_id, "input" => input, "stream" => true, "store" => false, "client_metadata" => metadata, "reasoning" => %{"effort" => "low"}, "tool_choice" => "auto"}

    case mode do
      "full" -> Map.merge(base, %{"instructions" => "synthetic instructions", "tools" => [], "parallel_tool_calls" => true})
      "lite" -> base |> Map.put("parallel_tool_calls", false) |> put_in(["client_metadata", @lite], "true")
    end
  end

  defp pending_type, do: CodexPooler.CompatibilityMatrix.fixture!(:responses_chat).compaction_recovery_boundary.backend_compaction_trigger.websocket_bridge.pending_control.event["type"]

  defp prompt, do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic pending scenario"}]}
  defp item, do: %{"type" => "compaction", "encrypted_content" => "synthetic-pending-compaction"}

  defp events(id, output) do
    Enum.map(output, &CodexPooler.JSON.encode!(%{"type" => "response.output_item.done", "item" => &1})) ++
      [CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"id" => id, "status" => "completed", "output" => output, "usage" => %{"input_tokens" => 20, "output_tokens" => 10, "total_tokens" => 30}}})]
  end
end
