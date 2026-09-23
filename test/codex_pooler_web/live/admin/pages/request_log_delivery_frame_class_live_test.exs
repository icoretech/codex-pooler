defmodule CodexPoolerWeb.Admin.RequestLogDeliveryFrameClassLiveTest do
  # The native websocket's delivery receipt records the highest class of frame
  # the socket pushed for a turn (`highest_frame_class`, findings#232 row
  # 232-203), which decides whether the released client's identical resend is
  # served, how many items it pushed completed (`completed_items`, row 232-232;
  # shown since row 232-241, never the digests next to it) and, when the
  # connection failed a write before the terminal was written, that failure's
  # class (`write_failure`, row 232-256). The admin request-log drawer shows
  # them next to the other receipt fields. Every receipt here is the one a real
  # socket records: a native turn through the real listener, owner forwarding
  # off (direct task), the fake provider held at a frame barrier right after
  # the cut frame and the client closing its connection there, or a client
  # that stops reading a large turn on a listener with a short send timeout.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, public_websocket_connect!: 3, public_websocket_receive_text!: 3, public_websocket_send_text!: 4, start_public_endpoint!: 0, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.WebsocketCleanupFence

  @timeout_ms 15_000
  @poll_ms 100
  # provenance: observed findings#232 row 232-203 (the frames the released client had received at an item-opening cut: created, in_progress, output_item.added)
  @hold_at 3
  # created, in_progress, output_item.added, content_part.added, delta, output_item.done
  @completed_item_hold_at 6
  # The stalled listener's write fails after this long instead of
  # ThousandIsland's 30 s default; the buffers are shrunk so it blocks at once.
  @send_timeout_ms 300
  @buffer_bytes 4_096
  @stalled_deltas 128
  @stalled_delta_bytes 8_192

  setup :register_and_log_in_user

  @tag slow: "a real native socket cut, its direct cleanup and the recorded receipt before the admin page renders it"
  test "the request-log drawer shows the highest frame class a native socket pushed before the client left", %{conn: conn} do
    %{setup: setup, request_id: request_id, receipt: receipt} = cut_receipt!(@hold_at, "response.output_item.added")

    assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_added", "transport" => "websocket"} = receipt

    view = open_drawer!(conn, setup, request_id)
    row_id = "#request-log-detail-attempt-1-downstream-delivery"

    assert has_element?(view, row_id, "Downstream delivery")
    assert has_element?(view, row_id, "aborted")
    assert has_element?(view, row_id, "terminal none")
    assert has_element?(view, row_id, "highest frame item_added")
    assert has_element?(view, row_id, "websocket")

    refute has_element?(view, row_id, "completed item")
    refute has_element?(view, row_id, "write failed")

    attempt_html = view |> element("#request-log-detail-attempt-1") |> render()
    refute attempt_html =~ "highest_frame_class"
    refute attempt_html =~ "synthetic admin frame class turn"
  end

  @tag slow: "a real native socket cut after a completed item, its direct cleanup and the recorded receipt before the admin page renders it"
  test "the request-log drawer shows how many items a native socket pushed completed, never their digests", %{conn: conn} do
    %{setup: setup, request_id: request_id, receipt: receipt} = cut_receipt!(@completed_item_hold_at, "response.output_item.done")

    assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_done", "completed_items" => 1, "completed_item_digests" => [digest]} = receipt

    view = open_drawer!(conn, setup, request_id)
    row_id = "#request-log-detail-attempt-1-downstream-delivery"

    assert has_element?(view, row_id, "highest frame item_done")
    assert has_element?(view, row_id, "1 completed item")
    refute has_element?(view, row_id, "write failed")

    attempt_html = view |> element("#request-log-detail-attempt-1") |> render()
    refute attempt_html =~ digest
    refute attempt_html =~ "completed_item_digests"
    refute attempt_html =~ "partial answer"
  end

  @tag slow: "a real listener write that has to time out after the client stopped reading and the recorded receipt before the admin page renders it"
  test "the request-log drawer shows the failed write that kept a receipt from delivered", %{conn: conn} do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond: FakeUpstream.websocket_text_frames(stalled_stream_frames("resp_admin_write_failure"))
          )
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    port = start_stalling_endpoint!()

    # The client sends its turn and never reads again, without closing.
    {socket_conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate())
    :ok = :inet.setopts(Mint.HTTP.get_socket(socket_conn), recbuf: @buffer_bytes)
    {:ok, socket_conn} = Mint.HTTP.set_mode(socket_conn, :passive)
    {socket_conn, _websocket} = public_websocket_send_text!(socket_conn, websocket, ref, CodexPooler.JSON.encode!(native_turn_payload(setup.model.exposed_model_id)))

    request_id = await_request_id!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
    receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    _closed = Mint.HTTP.close(socket_conn)
    _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

    assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "delta", "write_failure" => "timeout"} = receipt

    view = open_drawer!(conn, setup, request_id)
    row_id = "#request-log-detail-attempt-1-downstream-delivery"

    assert has_element?(view, row_id, "aborted")
    assert has_element?(view, row_id, "terminal none")
    assert has_element?(view, row_id, "#{receipt["frames_after_visible"]} frames after visible")
    assert has_element?(view, row_id, "write failed timeout")
    refute has_element?(view, row_id, "completed item")
  end

  defp cut_receipt!(hold_at, last_type) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond: FakeUpstream.barrier_websocket_frames(stream_frames("resp_admin_frame_class"), notify: self(), release_ref: release_ref)
          )
        ])
      )

    setup = gateway_setup(upstream)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, "lite")
    port = start_public_endpoint!()

    {socket_conn, websocket, ref} = public_websocket_connect!(port, setup, Ecto.UUID.generate())
    {socket_conn, websocket} = public_websocket_send_text!(socket_conn, websocket, ref, CodexPooler.JSON.encode!(native_turn_payload(setup.model.exposed_model_id)))

    for ordinal <- 0..(hold_at - 1) do
      assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @timeout_ms
      :ok = FakeUpstream.release_frame(upstream, release_ref)
    end

    # The barrier notification is read before any socket frame: the socket
    # helpers consume every message they do not recognise.
    assert_receive {:fake_upstream_frame_barrier, ^hold_at, _handler, ^release_ref}, @timeout_ms
    socket_conn = receive_until!(socket_conn, websocket, ref, last_type)
    assert [%Request{id: request_id}] = pool_requests(setup.pool.id)

    _closed = Mint.HTTP.close(socket_conn)
    receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)
    _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    %{setup: setup, request_id: request_id, receipt: receipt}
  end

  defp open_drawer!(conn, setup, request_id) do
    {:ok, view, _html} = live(conn, ~p"/admin/request-logs?pool_id=#{setup.pool.id}")
    _ = await_request_logs(view)

    render_click(element(view, "#request-log-#{request_id}-open-details"))
    assert_patch(view)
    view
  end

  # The shared listener with a short send timeout and a small send buffer.
  defp start_stalling_endpoint! do
    :ok = WebsocketCleanupFence.install!()

    {:ok, server} =
      Bandit.start_link(
        plug: CodexPoolerWeb.Endpoint,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false,
        thousand_island_options: [transport_options: [send_timeout: @send_timeout_ms, sndbuf: @buffer_bytes]]
      )

    on_exit(fn ->
      try do
        ThousandIsland.stop(server)
      catch
        :exit, _reason -> :ok
      end
    end)

    :ok = WebsocketCleanupFence.install!(server: server)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp stalled_stream_frames(response_id) do
    item_id = "msg_" <> response_id
    chunk = String.duplicate("a", @stalled_delta_bytes)
    item = %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "done", "annotations" => []}]}

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.in_progress", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}}
      ] ++
        for(_delta <- 1..@stalled_deltas, do: %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "delta" => chunk}) ++
        [
          %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
          %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
        ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp await_request_id!(pool_id, deadline_ms) do
    case Repo.all(from(r in Request, where: r.pool_id == ^pool_id, select: r.id)) do
      [request_id] ->
        request_id

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("the turn was never admitted"),
          else: Process.sleep(@poll_ms) && await_request_id!(pool_id, deadline_ms)
    end
  end

  defp stream_frames(response_id) do
    item_id = "msg_" <> response_id
    item = %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "partial answer", "annotations" => []}]}

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.in_progress", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}},
        %{"type" => "response.content_part.added", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => "", "annotations" => []}},
        %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "delta" => "partial answer"},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
      ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp native_turn_payload(model) do
    thread_id = Ecto.UUID.generate()

    %{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic base instructions",
      "stream" => true,
      "store" => false,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => "admin-frame-class-turn",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "admin-frame-class-turn", "request_kind" => "turn"})
      },
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic admin frame class turn"}]}]
    }
  end

  defp receive_until!(conn, websocket, ref, type) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    if CodexPooler.JSON.decode!(text)["type"] == type, do: conn, else: receive_until!(conn, websocket, ref, type)
  end

  defp pool_requests(pool_id), do: Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))

  # The closing socket's cleanup can hold the shared sandbox connection longer
  # than a checkout waits under load; a dropped checkout is retried.
  defp await_receipt!(request_id, deadline_ms) do
    case Repo.all(from(a in Attempt, where: a.request_id == ^request_id)) do
      [%Attempt{response_metadata: %{"downstream_delivery" => %{} = receipt}}] ->
        receipt

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("no delivery receipt for #{request_id} within the budget"),
          else: Process.sleep(@poll_ms) && await_receipt!(request_id, deadline_ms)
    end
  end

  defp await_settled!(request_id, deadline_ms) do
    case Repo.all(from(r in Request, where: r.id == ^request_id and r.status != "in_progress")) do
      [%Request{} = request] ->
        request

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("request never settled"),
          else: Process.sleep(@poll_ms) && await_settled!(request_id, deadline_ms)
    end
  end

  defp await_request_logs(view, attempts \\ 200)

  defp await_request_logs(view, attempts) when attempts > 0 do
    _ = render_async(view)
    state = :sys.get_state(view.pid)

    if state.socket.assigns.request_logs_loading? or state.socket.assigns.request_logs_running? do
      receive do
      after
        1 -> await_request_logs(view, attempts - 1)
      end
    else
      state
    end
  end

  defp await_request_logs(view, 0) do
    flunk("request logs did not finish loading: #{inspect(:sys.get_state(view.pid))}")
  end
end
