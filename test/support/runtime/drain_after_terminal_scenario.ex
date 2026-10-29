defmodule CodexPoolerWeb.Runtime.DrainAfterTerminalScenario do
  @moduledoc false

  # A drain's cut that lands after a turn's terminal reached the client but
  # before the turn settled (findings#287), shared by the one-node module
  # (`backend_codex_websocket_drain_after_terminal_test.exs`) and the peer-only
  # one (`backend_codex_websocket_drain_after_terminal_peer_test.exs`, whose
  # module boots the owner's VM once). The provider holds its answer at a
  # barrier until the socket's response task (or the owner's turn task) is
  # suspended, so the terminal reaches the client while the turn cannot settle;
  # the test then applies the drain's cut as the rollout drain does and resumes
  # the task.

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [await_socket_connection_state!: 2]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport,
    only: [start_shared_peer_window_owner!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityDrain, ActivityRegistry, WebsocketOwnerSession}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  # Detection budget for a frame, a settlement, a drain's state or a row the
  # test only observes.
  @detection_timeout_ms 15_000
  @turn_path "/backend-api/codex/responses"

  def detection_timeout_ms, do: @detection_timeout_ms

  # `peer_node:` starts the session's owner on that (shared) peer VM before the
  # socket connects; `committed: true` removes the Pool's committed rows at
  # exit.
  def start_turn!(opts \\ []) do
    hold = make_ref()
    upstream = start_upstream(FakeUpstream.strict_sequence([turn_request(FakeUpstream.barrier_websocket_frames(message_events("resp_drain_after_terminal"), notify: self(), release_ref: hold))]))
    setup = gateway_setup(upstream)
    if Keyword.get(opts, :committed, false), do: register_unboxed_pool_cleanup!(setup)
    thread = Ecto.UUID.generate()

    owner =
      case Keyword.get(opts, :peer_node) do
        nil -> nil
        peer_node -> start_shared_peer_window_owner!(setup, "#{thread}:0", peer_node).owner_pid
      end

    {_server, port} = start_public_endpoint_with_server!()
    client = port |> connect!(setup, thread) |> send_frame!(turn_frame(setup, thread))
    %{client: client, setup: setup, upstream: upstream, hold: hold, owner: owner}
  end

  # The provider's answer is held until the turn's task is suspended; then the
  # answer is released and reaches the client whole, while the turn cannot
  # settle.
  def relayed_turn_held!(%{client: client, upstream: upstream, hold: hold} = turn) do
    assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^hold}, @detection_timeout_ms
    state = await_socket_connection_state!(client.socket, &(MapSet.size(Map.get(&1, :tasks, MapSet.new())) > 0))
    [task] = MapSet.to_list(state.tasks)
    true = :erlang.suspend_process(task)
    on_exit(fn -> if Process.alive?(task), do: Process.exit(task, :kill) end)
    :ok = FakeUpstream.release_remaining_frames(upstream, hold)

    {client, events} = receive_until_terminal!(client)
    assert Enum.map(events, & &1["type"]) == ["response.created", "response.output_item.done", "response.completed"]
    assert [%Request{status: "in_progress"}] = pool_requests(turn.setup)

    Map.merge(turn, %{client: client, task: task, state: state})
  end

  # The socket node's drain past its deadline, as `RolloutDrain` runs it for a
  # task of this node: it leaves the task alone (no cancellation reaches it)
  # and holds in its settlement wait, and the task settles and finishes on its
  # own within the post-deadline budget instead of being stopped.
  def assert_task_drain_waits_for_settlement!(turn, kind) do
    entry = activity_entry!(turn.task, kind)
    task_monitor = Process.monitor(turn.task)
    policy = %{now_ms: fn -> System.monotonic_time(:millisecond) end, schedule_wait: &schedule_wait/3, cancel_wait: &cancel_wait/2, owner_post_deadline_call_budget_ms: 5_000}
    assert [%Request{status: "in_progress"}] = pool_requests(turn.setup)
    drain = Task.async(fn -> ActivityDrain.drain(entry, System.monotonic_time(:millisecond) - 1, policy, ActivityRegistry) end)

    :ok = await_drain_holding!(drain, fn -> Process.info(drain.pid, :current_function) == {:current_function, {ActivityDrain, :await_delivered_settlement, 4}} end)

    true = :erlang.resume_process(turn.task)
    assert_receive {:DOWN, ^task_monitor, :process, _task, :normal}, @detection_timeout_ms
    assert {:ok, _outcome} = Task.yield(drain, @detection_timeout_ms)
  end

  # The owner cut as the rollout drain makes it: the owner already finished
  # the turn it forwarded and reports it active only because its settlement
  # is pending. While the task cannot settle, the owner holds the drain in its
  # settlement wait and neither stops nor interrupts the request; once the
  # task settles, the owner stops.
  def assert_owner_cut_waits_for_settlement!(turn, owner) do
    :ok = await_owner_settling!(owner)
    monitor = Process.monitor(owner)
    assert [%Request{status: "in_progress"}] = pool_requests(turn.setup)
    drain = Task.async(fn -> WebsocketOwnerSession.drain_owner(owner) end)

    :ok = await_drain_holding!(drain, fn -> owner_waits_for_settlement?(owner) end)

    true = :erlang.resume_process(turn.task)
    assert Task.await(drain, @detection_timeout_ms) == {:ok, :settled}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, @detection_timeout_ms
  end

  # The drain holds, and has not answered, until the turn settles: it reached
  # the state `holding?` names. A drain that answers first did not wait for
  # the settlement.
  def await_drain_holding!(drain, holding?, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @detection_timeout_ms

    case Task.yield(drain, 0) do
      nil ->
        cond do
          holding?.() ->
            :ok

          System.monotonic_time(:millisecond) > deadline ->
            flunk("the drain neither held for the settlement nor answered")

          true ->
            Process.sleep(5)
            await_drain_holding!(drain, holding?, deadline)
        end

      answered ->
        flunk("the drain answered before the turn settled: #{inspect(answered)}")
    end
  end

  # The drain's cut reached the owner, which holds it until the turn settles.
  def owner_waits_for_settlement?(owner), do: is_map(:sys.get_state(owner).drain_settlement)

  # The owner finished the forwarded turn (its terminal went out and the
  # provider's session answered), and the drain has begun: it reports the turn
  # active only because the settlement is pending.
  def await_owner_settling!(owner) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms

    {:ok, %{active_turn?: false}} =
      Stream.repeatedly(fn -> WebsocketOwnerSession.owner_status(owner) end)
      |> Enum.find(fn
        {:ok, %{active_turn?: false}} ->
          true

        _active ->
          if System.monotonic_time(:millisecond) > deadline, do: flunk("the owner never finished the turn")
          Process.sleep(5)
          false
      end)

    :ok = WebsocketOwnerSession.begin_drain(owner)
    assert {:ok, %{draining?: true, active_turn?: true}} = WebsocketOwnerSession.owner_status(owner)
    :ok
  end

  def assert_settled_as_answered!(setup) do
    assert [row] = await_settled_requests!(setup)
    assert {row.status, row.last_error_code, row.response_status_code, row.usage_status} == {"succeeded", nil, 200, "usage_known"}
    assert [%Attempt{status: "succeeded"}] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^row.id))

    # The reservation, then one settlement with the provider's usage and the
    # reservation's release. The settlement and the release carry one
    # timestamp (`LedgerEntries` writes both with the settlement's), so their
    # order is not asserted.
    entries = Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^row.id, order_by: [asc: entry.created_at], select: {entry.entry_kind, entry.usage_status, entry.input_tokens, entry.output_tokens, entry.total_tokens}))
    assert [{"reservation", _usage, _input, _output, _total} | settled] = entries
    assert Enum.sort(Enum.map(settled, &elem(&1, 0))) == ["release", "settlement"]
    assert Enum.filter(entries, &(elem(&1, 0) == "settlement")) == [{"settlement", "usage_known", 20, 5, 25}]
  end

  def activity_entry!(task, kind) do
    assert %{kind: ^kind} = entry = Enum.find(ActivityRegistry.activities(), &(&1.pid == task))
    entry
  end

  def schedule_wait(recipient, token, wait_ms), do: Process.send_after(recipient, {:rollout_drain_wait_elapsed, token}, wait_ms)

  def cancel_wait(timer, _token) do
    _remaining = Process.cancel_timer(timer)
    :ok
  end

  def pool_requests(setup), do: Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

  def await_settled_requests!(setup) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms

    Stream.repeatedly(fn -> pool_requests(setup) end)
    |> Enum.find(fn rows ->
      cond do
        rows != [] and Enum.all?(rows, &(&1.status not in ["accepted", "in_progress"])) ->
          true

        System.monotonic_time(:millisecond) > deadline ->
          flunk("the turn never settled: #{inspect(Enum.map(rows, & &1.status))}")

        true ->
          Process.sleep(10)
          false
      end
    end)
  end

  def drop!(client) do
    Mint.HTTP.close(client.conn)
    :ok = WebsocketCleanupFence.await_listener_socket_cleanup!(client.socket)
  end

  def receive_until_terminal!(client, events \\ []) do
    {conn, websocket, text} = public_websocket_receive_text!(client.conn, client.websocket, client.ref)
    event = CodexPooler.JSON.decode!(text)
    client = %{client | conn: conn, websocket: websocket}
    events = events ++ [event]

    if event["type"] in ["response.completed", "response.failed", "response.incomplete", "error"],
      do: {client, events},
      else: receive_until_terminal!(client, events)
  end

  # Every frame the client receives within `wait_ms`, the Close included.
  def receive_frames_for!(client, wait_ms) do
    socket = Mint.HTTP.get_socket(client.conn)

    receive do
      {tag, ^socket, _data} = message when tag in [:tcp, :ssl] ->
        {:ok, conn, responses} = Mint.WebSocket.stream(client.conn, message)

        {websocket, frames} =
          Enum.reduce(responses, {client.websocket, []}, fn
            {:data, ref, data}, {websocket, frames} when ref == client.ref ->
              {:ok, websocket, decoded} = Mint.WebSocket.decode(websocket, data)
              {websocket, frames ++ decoded}

            _response, acc ->
              acc
          end)

        {conn, websocket, frames} = answer_server_pings!(conn, websocket, client.ref, frames)
        frames ++ receive_frames_for!(%{client | conn: conn, websocket: websocket}, wait_ms)

      {tag, ^socket} when tag in [:tcp_closed, :ssl_closed] ->
        [:socket_closed]
    after
      wait_ms -> []
    end
  end

  def put_owner_forwarding!(enabled?) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, enabled?)
  end

  defp turn_request(respond) do
    FakeUpstream.expect_request(method: "WEBSOCKET", path: @turn_path, json: [valid: true, equals: %{"type" => "response.create"}], respond: respond)
  end

  defp message_events(response_id) do
    item = %{"type" => "message", "id" => "msg_#{response_id}", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 20, "output_tokens" => 5, "total_tokens" => 25}}}
      ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp connect!(port, setup, thread) do
    before = WebsocketCleanupFence.listener_sockets()
    headers = [{"session-id", thread}, {"thread-id", thread}, {"x-client-request-id", thread}, {"x-codex-window-id", "#{thread}:0"}, {"openai-beta", "responses_websockets=2026-02-06"}]
    {conn, websocket, ref, _response_headers} = public_websocket_connect_with_request_headers!(port, setup, thread, @turn_path, headers)
    socket = WebsocketCleanupFence.await_new_listener_socket!(before)
    %{conn: conn, websocket: websocket, ref: ref, socket: socket}
  end

  defp turn_frame(setup, thread) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "instructions" => "synthetic instructions",
      "input" => native_text_input("synthetic prompt"),
      "tools" => [],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "store" => false,
      "stream" => true,
      "prompt_cache_key" => thread,
      "client_metadata" => %{"session_id" => thread, "thread_id" => thread, "turn_id" => Ecto.UUID.generate()}
    })
  end

  defp send_frame!(client, frame) do
    {conn, websocket} = public_websocket_send_text!(client.conn, client.websocket, client.ref, frame)
    %{client | conn: conn, websocket: websocket}
  end
end
