defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSessionTest do
  use ExUnit.Case, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.ConnectionUpgrade
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketFrameWriter

  import ExUnit.CaptureLog

  @timeouts %{connect_timeout_ms: 1_000, receive_timeout_ms: 1_000}

  @tag :task_1_pin
  test "PIN-P02 exact legacy typeless binary id remains terminal without status or object" do
    frame = ~s({"id":"resp_pin_legacy_typeless"})
    upstream = start_upstream(FakeUpstream.websocket_text_frames([frame]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{body: body, terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    assert body == "data: #{frame}\n\n"
  end

  @tag :task_1_red
  test "RED-R01 response.done followed by clean close completes before close classification" do
    frame =
      Jason.encode!(%{
        "type" => "response.done",
        "response" => %{"id" => "resp_red_done", "status" => "completed"}
      })

    upstream = start_upstream(FakeUpstream.websocket_text_frames([frame]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{body: body, terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    assert body == "data: #{frame}\n\n"
  end

  test "malformed response.done stays nonterminal until a valid terminal arrives" do
    malformed =
      Jason.encode!(%{
        "type" => "response.done",
        "response" => %{"id" => "resp_malformed_done", "status" => "failed"}
      })

    completed =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_after_malformed", "status" => "completed"}
      })

    upstream =
      start_upstream(FakeUpstream.websocket_text_frames([malformed, completed]))

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, %{body: body, terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    assert body == "data: #{malformed}\n\ndata: #{completed}\n\n"
  end

  test "characterization preserves websocket result body status headers and frame metadata" do
    frame = %{
      "type" => "response.failed",
      "response" => %{
        "id" => "resp_ws_result_characterization",
        "error" => %{"code" => "rate_limit_exceeded"}
      },
      "headers" => %{
        "openai-request-id" => "frame-request-characterization",
        "x-private-header" => "private-header-characterization"
      }
    }

    upstream = start_upstream(FakeUpstream.websocket_text_frames([Jason.encode!(frame)]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    assert {:ok, result} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    expected_frame = Map.delete(frame, "headers")

    assert Map.take(result, [:body, :status, :terminal, :websocket_frame_headers]) == %{
             body: "data: #{Jason.encode!(expected_frame)}\n\n",
             status: 200,
             terminal: "response.failed",
             websocket_frame_headers: %{
               "openai-request-id" => "frame-request-characterization"
             }
           }

    assert Enum.all?(result.headers, fn {name, value} ->
             is_binary(name) and is_binary(value)
           end)

    assert Enum.any?(result.headers, fn {name, value} ->
             name == "sec-websocket-accept" and byte_size(value) > 0
           end)

    refute inspect(result) =~ "private-header-characterization"
  end

  test "same-key requests reuse one FakeUpstream connection and process replacement opens another" do
    upstream =
      start_upstream(
        {:sequence,
         Enum.map(1..3, fn index ->
           FakeUpstream.json_response(%{
             "id" => "resp_ws_connection_characterization_#{index}",
             "object" => "response"
           })
         end)}
      )

    request = websocket_request(FakeUpstream.url(upstream))

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    initial_lifecycle = lifecycle_state(session)
    assert initial_lifecycle.generation == 0

    assert {:ok, first_result} = UpstreamWebsocketSession.request(session, request)

    first_lifecycle = lifecycle_state(session)
    assert first_lifecycle == %{initial_lifecycle | generation: 1}
    assert_connection_metadata(first_result, first_lifecycle, false, false)

    assert {:ok, reused_result} = UpstreamWebsocketSession.request(session, request)

    assert lifecycle_state(session) == first_lifecycle
    assert_connection_metadata(reused_result, first_lifecycle, true, false)
    assert [first_request, second_request] = FakeUpstream.requests(upstream)
    assert first_request.websocket_connection_id == second_request.websocket_connection_id
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    monitor = Process.monitor(session)
    :ok = UpstreamWebsocketSession.close(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000

    {:ok, replacement} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(replacement) end)
    replacement_initial_lifecycle = lifecycle_state(replacement)

    assert replacement_initial_lifecycle.generation == 0
    assert replacement_initial_lifecycle.lifecycle_id != initial_lifecycle.lifecycle_id

    assert {:ok, replacement_result} = UpstreamWebsocketSession.request(replacement, request)

    replacement_lifecycle = %{replacement_initial_lifecycle | generation: 1}
    assert lifecycle_state(replacement) == replacement_lifecycle
    assert_connection_metadata(replacement_result, replacement_lifecycle, false, false)

    assert [first_request, second_request, replacement_request] =
             FakeUpstream.requests(upstream)

    assert first_request.websocket_connection_id == second_request.websocket_connection_id
    assert replacement_request.websocket_connection_id != first_request.websocket_connection_id
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "advances generations 1,1,2 through reuse and transparent reconnect" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success("resp_ws_generation_1"),
           websocket_success("resp_ws_generation_1_reused"),
           FakeUpstream.websocket_sse_then_close([]),
           websocket_success("resp_ws_generation_2")
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = websocket_request(FakeUpstream.url(upstream))
    initial_lifecycle = lifecycle_state(session)

    assert {:ok, initial_result} = UpstreamWebsocketSession.request(session, request)

    generation_one = %{initial_lifecycle | generation: 1}
    assert lifecycle_state(session) == generation_one
    assert_connection_metadata(initial_result, generation_one, false, false)

    assert {:ok, reused_result} = UpstreamWebsocketSession.request(session, request)

    assert lifecycle_state(session) == generation_one
    assert_connection_metadata(reused_result, generation_one, true, false)

    assert {:ok, reconnected_result} = UpstreamWebsocketSession.request(session, request)

    generation_two = %{initial_lifecycle | generation: 2}
    assert lifecycle_state(session) == generation_two
    assert_connection_metadata(reconnected_result, generation_two, false, true)

    assert [first_request, second_request, interrupted_request, reconnected_request] =
             FakeUpstream.requests(upstream)

    assert first_request.websocket_connection_id == second_request.websocket_connection_id
    assert interrupted_request.websocket_connection_id == first_request.websocket_connection_id
    assert reconnected_request.websocket_connection_id != first_request.websocket_connection_id
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "request_once uses an invocation-scoped lifecycle and reaches generation one" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success("resp_ws_once_first"),
           websocket_success("resp_ws_once_second")
         ]}
      )

    request = websocket_request(FakeUpstream.url(upstream))

    assert {{:ok, first_result}, first_trace} = request_once_lifecycle_trace(request)

    assert {{:ok, second_result}, second_trace} = request_once_lifecycle_trace(request)

    assert [%{generation: 0} = first_initial, %{generation: 1} = first_connected] =
             first_trace

    assert first_connected.lifecycle_id == first_initial.lifecycle_id
    assert_connection_metadata(first_result, first_connected, false, false)

    assert [%{generation: 0} = second_initial, %{generation: 1} = second_connected] =
             second_trace

    assert second_connected.lifecycle_id == second_initial.lifecycle_id
    assert_connection_metadata(second_result, second_connected, false, false)
    assert second_initial.lifecycle_id != first_initial.lifecycle_id
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "does not advance generation when TCP connection fails" do
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, %{body: "", reason: %Mint.TransportError{reason: :econnrefused}}} =
             UpstreamWebsocketSession.request(session, websocket_request(closed_tcp_url()))

    assert_disconnected_lifecycle(session, initial_lifecycle)
  end

  test "does not advance generation when FakeUpstream rejects the websocket upgrade" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_upgrade_error(
          %{"error" => %{"code" => "upgrade_rejected"}},
          status: 403
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, failure} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    assert %{body: "", reason: {:websocket_upgrade_failed, 403, _headers}} = failure
    refute Map.has_key?(failure, :upstream_websocket_connection)

    assert_disconnected_lifecycle(session, initial_lifecycle)
    assert FakeUpstream.websocket_connection_count(upstream) == 0
  end

  test "does not advance generation for a malformed HTTP upgrade response" do
    peer = start_raw_websocket_peer(upgrade_mode: :malformed_response)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, %{body: "", reason: %Mint.HTTPError{reason: :invalid_status_line}}} =
             UpstreamWebsocketSession.request(session, websocket_request(peer.url))

    assert_disconnected_lifecycle(session, initial_lifecycle)

    cleanup = stop_raw_websocket_peer(peer)
    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
  end

  test "does not advance generation when Mint rejects websocket creation after status 101" do
    peer = start_raw_websocket_peer(upgrade_mode: :invalid_accept)
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, %{body: "", reason: :invalid_nonce}} =
             UpstreamWebsocketSession.request(session, websocket_request(peer.url))

    assert_disconnected_lifecycle(session, initial_lifecycle)

    cleanup = stop_raw_websocket_peer(peer)
    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
  end

  test "failed reconnect preserves the last successful generation" do
    upstream =
      start_upstream(
        {:sequence,
         [
           websocket_success("resp_ws_before_failed_reconnect"),
           FakeUpstream.websocket_sse_then_close([]),
           FakeUpstream.websocket_upgrade_error(
             %{"error" => %{"code" => "reconnect_rejected"}},
             status: 503
           ),
           websocket_success("resp_ws_after_failed_reconnect")
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = websocket_request(FakeUpstream.url(upstream))
    initial_lifecycle = lifecycle_state(session)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    established_lifecycle = %{initial_lifecycle | generation: 1}
    assert lifecycle_state(session) == established_lifecycle

    assert {:error, failed_reconnect} = UpstreamWebsocketSession.request(session, request)

    assert %{body: "", reason: {:websocket_upgrade_failed, 503, _headers}} = failed_reconnect
    assert_connection_metadata(failed_reconnect, established_lifecycle, true, false)

    assert_disconnected_lifecycle(session, established_lifecycle)
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert [initial_request, interrupted_request] = FakeUpstream.requests(upstream)
    assert initial_request.websocket_connection_id == interrupted_request.websocket_connection_id

    assert {:ok, recovered_result} = UpstreamWebsocketSession.request(session, request)

    recovered_lifecycle = %{initial_lifecycle | generation: 2}
    assert lifecycle_state(session) == recovered_lifecycle
    assert_connection_metadata(recovered_result, recovered_lifecycle, false, false)
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  test "failure after a successful initial send carries only safe connection metadata" do
    upstream = start_upstream(FakeUpstream.websocket_sse_then_close([]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    initial_lifecycle = lifecycle_state(session)

    assert {:error, failure} =
             UpstreamWebsocketSession.request(
               session,
               websocket_request(FakeUpstream.url(upstream))
             )

    assert %{
             body: "",
             reason: :upstream_websocket_closed_before_terminal,
             websocket_frame_headers: %{}
           } = failure

    established_lifecycle = %{initial_lifecycle | generation: 1}
    assert_connection_metadata(failure, established_lifecycle, false, false)
    refute inspect(failure.upstream_websocket_connection) =~ "pid"
    refute inspect(failure.upstream_websocket_connection) =~ "node"
    refute inspect(failure.upstream_websocket_connection) =~ "socket"
  end

  test "peer close exposes only bounded diagnostics and discards the raw reason immediately" do
    raw_reason = "peer-close-private-sentinel-deadbeefcafefeed"

    upstream =
      start_upstream(FakeUpstream.websocket_sse_then_close([], code: 1000, reason: raw_reason))

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    {result, captured_log} =
      with_log(fn ->
        UpstreamWebsocketSession.request(
          session,
          websocket_request(FakeUpstream.url(upstream))
        )
      end)

    assert {:error, failure} = result
    assert failure.reason == :upstream_websocket_closed_before_terminal

    assert Map.take(failure.transport_failure, [
             "peer_close_code",
             "peer_close_reason_present",
             "peer_close_reason_bytes"
           ]) == %{
             "peer_close_code" => 1000,
             "peer_close_reason_present" => true,
             "peer_close_reason_bytes" => byte_size(raw_reason)
           }

    session_state = :sys.get_state(session)
    exception_text = Exception.format(:error, RuntimeError.exception(inspect(failure)), [])

    for surface <- [failure, session_state, exception_text, captured_log] do
      refute inspect(surface) =~ raw_reason
    end

    assert Enum.sort(Map.keys(failure.upstream_websocket_connection)) ==
             [:generation, :lifecycle_id, :reconnected, :reused]
  end

  test "reused request returns unavailable error when session process is gone" do
    {:ok, session} = UpstreamWebsocketSession.start_link([])
    :ok = UpstreamWebsocketSession.close(session)

    request = %Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "{}",
      timeouts: @timeouts,
      writer: fn _text -> :ok end,
      message_mapper: nil
    }

    assert {:error, %{body: "", headers: [], reason: :upstream_websocket_session_unavailable}} =
             UpstreamWebsocketSession.request(session, request)
  end

  test "frame writer preserves websocket send failure reason and updated state" do
    ref = make_ref()
    updated_conn = {:updated_conn, make_ref()}

    state = %{
      conn: :original_conn,
      ref: ref,
      websocket: %Mint.WebSocket{},
      retained_field: :kept
    }

    stream_request_body = fn conn, request_ref, data ->
      assert conn == :original_conn
      assert request_ref == ref
      assert is_binary(data)

      {:error, updated_conn, :synthetic_write_failure}
    end

    assert {:error, :synthetic_write_failure, updated_state} =
             WebsocketFrameWriter.send_frame(
               state,
               {:pong, "codex-pooler"},
               stream_request_body
             )

    assert updated_state.conn == updated_conn
    assert %Mint.WebSocket{} = updated_state.websocket
    assert updated_state.retained_field == :kept
  end

  test "keeps queued GenServer calls while collecting upstream websocket frames" do
    parent = self()
    first_release_ref = make_ref()
    second_release_ref = make_ref()

    events = [
      %{
        "type" => "response.created",
        "response" => %{"id" => "resp_ws_mailbox"}
      },
      %{
        "type" => "response.completed",
        "response" => %{"id" => "resp_ws_mailbox"}
      }
    ]

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.barrier_sse_stream(events,
             notify: parent,
             release_ref: first_release_ref,
             barrier_after: 1
           ),
           FakeUpstream.barrier_sse_stream(events,
             notify: parent,
             release_ref: second_release_ref,
             barrier_after: 1
           )
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])

    request =
      %Request{
        url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
        headers: [{"authorization", "Bearer synthetic-upstream-token"}],
        payload:
          Jason.encode!(%{
            "model" => "upstream-test-model",
            "input" => [%{"type" => "message", "role" => "user", "content" => "sample"}],
            "stream" => true
          }),
        timeouts: @timeouts,
        writer: fn text -> send(parent, {:upstream_websocket_frame, text}) end,
        message_mapper: nil
      }

    request_task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:fake_upstream_chunk_sent, 1}, 1_000
    assert_receive {:fake_upstream_chunk_barrier, 1, barrier_pid, ^first_release_ref}, 1_000

    # The fake's barrier notification races the session's own send path: the
    # server can announce the barrier while the client is still streaming the
    # request body, so a single stack snapshot flakes under CI load. Poll until
    # the session parks in await_sent_request instead.
    assert_stack_eventually_in(session, UpstreamWebsocketSession, :await_sent_request, 2)

    send_task =
      Task.async(fn ->
        UpstreamWebsocketSession.send_request_frame(
          session,
          Jason.encode!(%{"type" => "response.processed", "response_id" => "resp_ws_mailbox"})
        )
      end)

    send(barrier_pid, {:fake_upstream_release_chunk, first_release_ref})

    assert {:ok, %{terminal: "response.completed", status: 200}} = Task.await(request_task, 1_000)
    assert_receive {:fake_upstream_chunk_sent, 2}, 1_000
    assert_receive {:fake_upstream_chunk_sent, 3}, 1_000

    assert {:ok, :sent} = Task.await(send_task, 1_000)
    assert_receive {:fake_upstream_chunk_sent, 1}, 1_000
    assert_receive {:fake_upstream_chunk_barrier, 1, barrier_pid, ^second_release_ref}, 1_000

    send(barrier_pid, {:fake_upstream_release_chunk, second_release_ref})

    assert_receive {:fake_upstream_chunk_sent, 2}, 1_000
    assert_receive {:fake_upstream_chunk_sent, 3}, 1_000
  end

  test "opens a new upstream websocket connection when bearer changes between turns" do
    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.json_response(%{"id" => "resp_ws_old_token", "object" => "response"}),
           FakeUpstream.json_response(%{"id" => "resp_ws_new_token", "object" => "response"})
         ]}
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])
    parent = self()
    url = FakeUpstream.url(upstream) <> "/backend-api/codex/responses"
    initial_lifecycle = lifecycle_state(session)

    request = fn label, bearer, content ->
      %Request{
        url: url,
        headers: [{"authorization", "Bearer #{bearer}"}],
        payload:
          Jason.encode!(%{
            "model" => "upstream-test-model",
            "input" => [%{"type" => "message", "role" => "user", "content" => content}],
            "stream" => true
          }),
        timeouts: @timeouts,
        writer: fn text -> send(parent, {:upstream_websocket_frame, label, text}) end,
        message_mapper: nil
      }
    end

    assert {:ok, old_key_result} =
             UpstreamWebsocketSession.request(
               session,
               request.(:old_token_turn, "old-upstream-token", "first turn")
             )

    assert_receive {:upstream_websocket_frame, :old_token_turn, old_frame}, 1_000
    assert %{"id" => "resp_ws_old_token"} = Jason.decode!(old_frame)
    generation_one = %{initial_lifecycle | generation: 1}
    assert lifecycle_state(session) == generation_one
    assert_connection_metadata(old_key_result, generation_one, false, false)

    assert {:ok, new_key_result} =
             UpstreamWebsocketSession.request(
               session,
               request.(:new_token_turn, "new-upstream-token", "second turn")
             )

    assert_receive {:upstream_websocket_frame, :new_token_turn, new_frame}, 1_000
    assert %{"id" => "resp_ws_new_token"} = Jason.decode!(new_frame)
    generation_two = %{initial_lifecycle | generation: 2}
    assert lifecycle_state(session) == generation_two
    assert_connection_metadata(new_key_result, generation_two, false, false)

    assert [first_request, second_request] = FakeUpstream.requests(upstream)
    assert first_request.websocket_connection_id != second_request.websocket_connection_id
    assert Map.new(first_request.headers)["authorization"] == "Bearer old-upstream-token"
    assert Map.new(second_request.headers)["authorization"] == "Bearer new-upstream-token"
    assert FakeUpstream.websocket_connection_count(upstream) == 2
  end

  @tag :upstream_websocket_pong_liveness
  test "opens a new upstream websocket connection after missing keepalive pong deadline" do
    with_short_keepalive(keepalive_interval_ms: 80, keepalive_pong_timeout_ms: 35)

    peer = start_raw_websocket_peer()
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())
    initial_lifecycle = lifecycle_state(session)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    established_lifecycle = %{initial_lifecycle | generation: 1}
    assert lifecycle_state(session) == established_lifecycle
    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000

    assert :closed = wait_for_raw_websocket_connection_closed(1, 150)
    assert_disconnected_lifecycle(session, established_lifecycle)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert lifecycle_state(session) == %{initial_lifecycle | generation: 2}
    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 2
  end

  @tag :upstream_websocket_pong_liveness
  test "does not close outstanding keepalive before a longer pong timeout expires" do
    with_short_keepalive(keepalive_interval_ms: 25, keepalive_pong_timeout_ms: 120)

    peer = start_raw_websocket_peer()
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000

    assert :timeout = wait_for_raw_websocket_connection_closed(1, 40)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert raw_websocket_peer_connection_count(peer) == 1
    assert :closed = wait_for_raw_websocket_connection_closed(1, 200)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 2
  end

  @tag :upstream_websocket_pong_liveness
  test "keeps upstream websocket connection reusable after exact keepalive pong" do
    with_short_keepalive()

    peer = start_raw_websocket_peer(pong_mode: :match_active_ping)
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 2, _payload_bytes}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 3, _payload_bytes}, 1_000

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 1
  end

  @tag :upstream_websocket_pong_liveness
  test "opens a new upstream websocket connection after mismatched keepalive pong deadline" do
    with_short_keepalive(keepalive_interval_ms: 80, keepalive_pong_timeout_ms: 35)

    peer = start_raw_websocket_peer(pong_mode: :send_mismatched_pong)
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000
    assert :closed = wait_for_raw_websocket_connection_closed(1, 150)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 2
  end

  @tag :upstream_websocket_pong_liveness
  test "opens a new upstream websocket connection after stale old-payload keepalive pong deadline" do
    with_short_keepalive(keepalive_interval_ms: 80, keepalive_pong_timeout_ms: 35)

    peer = start_raw_websocket_peer(pong_mode: :match_active_ping)
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000

    set_raw_websocket_peer_pong_mode(peer, :send_first_ping_payload)

    assert_receive {:raw_upstream_websocket_control, :ping, 1, 2, _payload_bytes}, 1_000
    assert :closed = wait_for_raw_websocket_connection_closed(1, 150)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 2
  end

  @tag :upstream_websocket_pong_liveness
  test "active receive loop fails promptly when pong deadline fires during an in-flight request" do
    with_short_keepalive(keepalive_interval_ms: 25, keepalive_pong_timeout_ms: 150)

    peer = start_raw_websocket_peer()
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn -> UpstreamWebsocketSession.close(session) end)

    request = raw_websocket_request(peer.url, self())

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert_receive {:upstream_websocket_frame, terminal_frame}, 1_000
    assert %{"id" => _id} = Jason.decode!(terminal_frame)

    assert_receive {:raw_upstream_websocket_connection, 1}, 1_000
    assert_receive {:raw_upstream_websocket_control, :ping, 1, 1, _payload_bytes}, 1_000

    set_raw_websocket_peer_response_mode(peer, :hold_after_created)
    started_at = System.monotonic_time(:millisecond)
    request_task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:upstream_websocket_frame, created_frame}, 1_000
    assert %{"type" => "response.created"} = Jason.decode!(created_frame)

    result =
      case Task.yield(request_task, 600) do
        {:ok, result} ->
          result

        nil ->
          Task.shutdown(request_task, :brutal_kill)
          :request_still_waiting
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert {:error,
            %{
              body: body,
              reason: :upstream_websocket_pong_deadline,
              transport_failure: %{
                "pre_visible_output" => false,
                "terminal_seen" => false,
                "text_frame_count" => 1
              }
            }} = result

    assert elapsed_ms < 600
    assert body =~ "response.created"
    assert Process.alive?(session)
    assert :closed = wait_for_raw_websocket_connection_closed(1, 150)

    set_raw_websocket_peer_response_mode(peer, :terminal)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    connection_count = raw_websocket_peer_connection_count(peer)
    cleanup = stop_raw_websocket_peer(peer)

    assert cleanup.alive_tasks == []
    assert cleanup.client_socket_count == 0
    assert connection_count == 2
  end

  test "does not treat response.created as upstream websocket terminal success" do
    parent = self()

    upstream =
      start_upstream(
        FakeUpstream.delayed_sse_stream(
          [
            %{
              "type" => "response.created",
              "response" => %{"id" => "resp_ws_created_only"}
            },
            %{
              "type" => "response.completed",
              "response" => %{"id" => "resp_ws_created_only"}
            }
          ],
          done: false,
          interval_ms: 250
        )
      )

    {:ok, session} = UpstreamWebsocketSession.start_link([])

    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [{"authorization", "Bearer synthetic-upstream-token"}],
      payload:
        Jason.encode!(%{
          "model" => "upstream-test-model",
          "input" => [%{"type" => "message", "role" => "user", "content" => "sample"}],
          "stream" => true
        }),
      timeouts: @timeouts,
      writer: fn text -> send(parent, {:upstream_websocket_frame, text}) end,
      message_mapper: nil
    }

    request_task = Task.async(fn -> UpstreamWebsocketSession.request(session, request) end)

    assert_receive {:upstream_websocket_frame, created_frame}, 1_000
    assert %{"type" => "response.created"} = Jason.decode!(created_frame)
    refute Task.yield(request_task, 50)

    assert {:ok, %{terminal: "response.completed", status: 200}} = Task.await(request_task, 1_000)
    assert_receive {:upstream_websocket_frame, completed_frame}, 1_000
    assert %{"type" => "response.completed"} = Jason.decode!(completed_frame)
  end

  test "returns only bounded retained body while writing every upstream websocket frame" do
    parent = self()

    events =
      [
        %{"type" => "response.created", "response" => %{"id" => "resp_ws_bounded_body"}},
        %{
          "type" => "item/started",
          "item" => %{
            "type" => "sleep",
            "id" => "item_sleep_fixture",
            "duration_ms" => 25
          }
        }
      ] ++
        for index <- 1..240 do
          %{
            "type" => "response.output_text.delta",
            "sequence_number" => index,
            "delta" => String.duplicate("bounded-websocket-retained-body-sentinel", 16)
          }
        end ++
        [
          %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_ws_bounded_body",
              "usage" => %{
                "input_tokens" => 1,
                "output_tokens" => 1,
                "total_tokens" => 2
              }
            }
          }
        ]

    upstream = start_upstream(FakeUpstream.sse_stream(events))
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [{"authorization", "Bearer synthetic-upstream-token"}],
      payload:
        Jason.encode!(%{
          "model" => "upstream-test-model",
          "input" => [%{"type" => "message", "role" => "user", "content" => "sample"}],
          "stream" => true
        }),
      timeouts: @timeouts,
      writer: fn text -> send(parent, {:upstream_websocket_frame, text}) end,
      message_mapper: nil
    }

    assert {:ok, %{body: retained_body, terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    written_frames =
      1..length(events)
      |> Enum.map(fn _index ->
        assert_receive {:upstream_websocket_frame, frame}, 1_000
        frame
      end)

    assert Enum.map(written_frames, &Jason.decode!/1) == events

    full_body =
      written_frames
      |> Enum.map(&["data: ", &1, "\n\n"])
      |> IO.iodata_to_binary()

    assert byte_size(retained_body) <= 65_536
    assert byte_size(retained_body) < byte_size(full_body)
    assert String.ends_with?(full_body, retained_body)
  end

  test "non-101 websocket upgrade failure preserves the leaf reason and drops the body" do
    upstream =
      start_upstream(
        FakeUpstream.websocket_upgrade_error(
          %{
            "error" => %{
              "code" => "upgrade_rejected",
              "message" => "upgrade body sentinel"
            }
          },
          status: 403,
          headers: [{"x-upstream-status", "upgrade-denied-sentinel"}]
        )
      )

    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [{"authorization", "Bearer synthetic-upstream-token"}],
      payload: "{}",
      timeouts: @timeouts,
      writer: fn _text -> :ok end,
      message_mapper: nil
    }

    result = UpstreamWebsocketSession.request_once(request)

    assert {:error,
            %{
              body: "",
              headers: [],
              reason: {:websocket_upgrade_failed, 403, reason_headers},
              websocket_frame_headers: %{}
            }} = result

    assert [
             {"date", _},
             {"content-length", _},
             {"vary", _},
             {"cache-control", _},
             {"x-upstream-status", "upgrade-denied-sentinel"},
             {"content-type", _}
           ] = reason_headers

    refute inspect({reason_headers, result}) =~ "upgrade body sentinel"
  end

  defp websocket_success(response_id) do
    FakeUpstream.json_response(%{"id" => response_id, "object" => "response"})
  end

  defp websocket_request(base_url) do
    url =
      if String.ends_with?(base_url, "/backend-api/codex/responses") do
        base_url
      else
        base_url <> "/backend-api/codex/responses"
      end

    %Request{
      url: url,
      headers: [],
      payload: "{}",
      timeouts: @timeouts,
      writer: fn _text -> :ok end,
      message_mapper: nil
    }
  end

  defp lifecycle_state(session) do
    session
    |> :sys.get_state()
    |> lifecycle_from_state()
  end

  defp lifecycle_from_state(state) do
    lifecycle = Map.take(state, [:lifecycle_id, :generation])

    assert %{lifecycle_id: lifecycle_id, generation: generation} = lifecycle
    assert is_integer(generation) and generation >= 0
    assert {:ok, ^lifecycle_id} = Ecto.UUID.cast(lifecycle_id)
    refute Map.has_key?(state, :pid)
    refute Map.has_key?(state, :node)
    refute Map.has_key?(state, :socket)

    lifecycle
  end

  defp assert_disconnected_lifecycle(session, expected_lifecycle) do
    state = :sys.get_state(session)

    assert lifecycle_from_state(state) == expected_lifecycle
    assert Enum.sort(Map.keys(state)) == [:generation, :lifecycle_id]
  end

  defp assert_connection_metadata(result, lifecycle, reused, reconnected) do
    assert Map.fetch!(result, :upstream_websocket_connection) == %{
             lifecycle_id: lifecycle.lifecycle_id,
             generation: lifecycle.generation,
             reused: reused,
             reconnected: reconnected
           }
  end

  defp closed_tcp_url do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    "http://127.0.0.1:#{port}"
  end

  defp request_once_lifecycle_trace(request) do
    parent = self()
    start_ref = make_ref()
    release_ref = make_ref()
    traced_mfa = {ConnectionUpgrade, :connect_state, 5}
    match_spec = [{:_, [], [{:return_trace}]}]

    {:module, ConnectionUpgrade} = Code.ensure_loaded(ConnectionUpgrade)
    :erlang.trace_pattern(traced_mfa, match_spec, [])

    task =
      Task.async(fn ->
        receive do
          {:start_request_once, ^start_ref} -> :ok
        end

        result = UpstreamWebsocketSession.request_once(request)
        send(parent, {:request_once_complete, self(), result})

        receive do
          {:release_request_once, ^release_ref} -> result
        end
      end)

    try do
      :erlang.trace(task.pid, true, [:call, {:tracer, parent}])
      send(task.pid, {:start_request_once, start_ref})

      result =
        receive do
          {:request_once_complete, pid, result} when pid == task.pid -> result
        after
          1_000 -> flunk("request_once did not complete")
        end

      delivered_ref = :erlang.trace_delivered(task.pid)
      assert_receive {:trace_delivered, pid, ^delivered_ref} when pid == task.pid, 1_000

      trace = collect_lifecycle_trace(task.pid, [])
      send(task.pid, {:release_request_once, release_ref})
      assert Task.await(task, 1_000) == result

      {result, trace}
    after
      :erlang.trace_pattern(traced_mfa, false, [])

      if Process.alive?(task.pid) do
        :erlang.trace(task.pid, false, [:call])
        send(task.pid, {:release_request_once, release_ref})
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  defp collect_lifecycle_trace(pid, acc) do
    receive do
      {:trace, ^pid, :call, {ConnectionUpgrade, :connect_state, [state | _arguments]}} ->
        collect_lifecycle_trace(pid, [lifecycle_from_state(state) | acc])

      {:trace, ^pid, :return_from, {ConnectionUpgrade, :connect_state, 5}, {:ok, state}} ->
        collect_lifecycle_trace(pid, [lifecycle_from_state(state) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp with_short_keepalive(opts \\ []) do
    original_env = Application.get_env(:codex_pooler, UpstreamWebsocketSession, [])

    settings =
      Keyword.merge(
        [
          keepalive_interval_ms: Keyword.get(opts, :keepalive_interval_ms, 25),
          keepalive_pong_timeout_ms: Keyword.get(opts, :keepalive_pong_timeout_ms, 50)
        ],
        opts
      )

    Application.put_env(
      :codex_pooler,
      UpstreamWebsocketSession,
      Keyword.merge(original_env, settings)
    )

    on_exit(fn ->
      Application.put_env(:codex_pooler, UpstreamWebsocketSession, original_env)
    end)
  end

  defp start_raw_websocket_peer(opts \\ []) do
    owner = self()
    supervisor = raw_websocket_peer_supervisor()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             listen_socket: listen_socket,
             accept_pid: nil,
             client_sockets: MapSet.new(),
             connection_count: 0,
             connection_pids: MapSet.new(),
             upgrade_mode: Keyword.get(opts, :upgrade_mode, :valid),
             pong_mode: Keyword.get(opts, :pong_mode, :ignore_ping),
             response_mode: Keyword.get(opts, :response_mode, :terminal),
             stopped?: false
           }
         end}
      )

    peer = %{
      url: "http://127.0.0.1:#{port}/backend-api/codex/responses",
      state: state,
      supervisor: supervisor
    }

    {:ok, accept_pid} =
      Task.Supervisor.start_child(supervisor, fn ->
        raw_websocket_peer_accept_loop(peer, listen_socket, owner)
      end)

    Agent.update(state, &%{&1 | accept_pid: accept_pid})
    on_exit(fn -> stop_raw_websocket_peer(peer) end)

    peer
  end

  defp raw_websocket_peer_supervisor do
    name = :"raw_websocket_peer_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: name})
    name
  end

  defp raw_websocket_request(url, owner) do
    %Request{
      url: url,
      headers: [{"authorization", "Bearer synthetic-upstream-token"}],
      payload:
        Jason.encode!(%{
          "model" => "upstream-test-model",
          "input" => [%{"type" => "message", "role" => "user", "content" => "sample"}],
          "stream" => true
        }),
      timeouts: @timeouts,
      writer: fn text -> send(owner, {:upstream_websocket_frame, text}) end,
      message_mapper: nil
    }
  end

  defp raw_websocket_peer_accept_loop(
         %{state: state, supervisor: supervisor} = peer,
         socket,
         owner
       ) do
    case :gen_tcp.accept(socket, 100) do
      {:ok, client_socket} ->
        connection_id = raw_websocket_peer_track_connection(state, client_socket)
        send(owner, {:raw_upstream_websocket_connection, connection_id})

        {:ok, pid} =
          Task.Supervisor.start_child(supervisor, fn ->
            raw_websocket_peer_connection_loop(state, client_socket, connection_id, owner)
          end)

        Agent.update(state, fn current ->
          %{current | connection_pids: MapSet.put(current.connection_pids, pid)}
        end)

        raw_websocket_peer_accept_loop(peer, socket, owner)

      {:error, :timeout} ->
        unless Agent.get(state, & &1.stopped?) do
          raw_websocket_peer_accept_loop(peer, socket, owner)
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp raw_websocket_peer_track_connection(state, socket) do
    Agent.get_and_update(state, fn current ->
      connection_id = current.connection_count + 1

      updated = %{
        current
        | client_sockets: MapSet.put(current.client_sockets, socket),
          connection_count: connection_id
      }

      {connection_id, updated}
    end)
  end

  defp raw_websocket_peer_connection_loop(state, socket, connection_id, owner) do
    upgrade_mode = Agent.get(state, & &1.upgrade_mode)

    case raw_websocket_peer_upgrade(socket, upgrade_mode) do
      :ok -> raw_websocket_peer_frame_loop(state, socket, connection_id, owner, 0, nil, 0)
      {:error, reason} -> send(owner, {:raw_upstream_websocket_error, connection_id, reason})
    end
  after
    safe_tcp_close(socket)

    if Process.alive?(state) do
      Agent.update(state, fn current ->
        %{
          current
          | client_sockets: MapSet.delete(current.client_sockets, socket),
            connection_pids: MapSet.delete(current.connection_pids, self())
        }
      end)
    end

    send(owner, {:raw_upstream_websocket_connection_closed, connection_id})
  end

  defp raw_websocket_peer_upgrade(socket, mode) do
    with {:ok, headers} <- raw_websocket_peer_read_headers(socket),
         {:ok, key} <- raw_websocket_peer_header(headers, "sec-websocket-key") do
      send_raw_websocket_upgrade(socket, key, mode)
    end
  end

  defp send_raw_websocket_upgrade(socket, _key, :malformed_response) do
    :gen_tcp.send(socket, "not-an-http-upgrade\r\n\r\n")
  end

  defp send_raw_websocket_upgrade(socket, key, mode) when mode in [:valid, :invalid_accept] do
    accept =
      if mode == :valid do
        :sha
        |> :crypto.hash(key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        |> Base.encode64()
      else
        "invalid-websocket-accept"
      end

    :gen_tcp.send(socket, [
      "HTTP/1.1 101 Switching Protocols\r\n",
      "upgrade: websocket\r\n",
      "connection: Upgrade\r\n",
      "sec-websocket-accept: ",
      accept,
      "\r\n\r\n"
    ])
  end

  defp raw_websocket_peer_read_headers(socket, acc \\ "") do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, data} -> raw_websocket_peer_read_headers(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp raw_websocket_peer_header(headers, name) do
    name = String.downcase(name)

    headers
    |> String.split("\r\n")
    |> Enum.find_value(&raw_websocket_peer_matching_header(&1, name))
    |> case do
      {:ok, value} -> {:ok, value}
      nil -> {:error, :missing_websocket_key}
    end
  end

  defp raw_websocket_peer_matching_header(line, name) do
    case String.split(line, ":", parts: 2) do
      [header_name, value] when header_name != "" ->
        if String.downcase(header_name) == name, do: {:ok, String.trim(value)}

      _line ->
        nil
    end
  end

  defp raw_websocket_peer_frame_loop(
         state,
         socket,
         connection_id,
         owner,
         request_count,
         first_ping_payload,
         ping_count
       ) do
    case raw_websocket_peer_recv_frame(socket) do
      {:ok, :text, _payload} ->
        request_count = request_count + 1
        send_raw_websocket_peer_response(state, socket, connection_id, request_count)

        raw_websocket_peer_frame_loop(
          state,
          socket,
          connection_id,
          owner,
          request_count,
          first_ping_payload,
          ping_count
        )

      {:ok, :ping, payload} ->
        ping_count = ping_count + 1
        first_ping_payload = first_ping_payload || payload
        maybe_send_raw_websocket_peer_pong(state, socket, payload, first_ping_payload)

        send(
          owner,
          {:raw_upstream_websocket_control, :ping, connection_id, ping_count, byte_size(payload)}
        )

        raw_websocket_peer_frame_loop(
          state,
          socket,
          connection_id,
          owner,
          request_count,
          first_ping_payload,
          ping_count
        )

      {:ok, :pong, payload} ->
        send(
          owner,
          {:raw_upstream_websocket_control, :pong, connection_id, ping_count, byte_size(payload)}
        )

        raw_websocket_peer_frame_loop(
          state,
          socket,
          connection_id,
          owner,
          request_count,
          first_ping_payload,
          ping_count
        )

      {:ok, :close, _payload} ->
        :ok

      {:error, reason} when reason in [:closed, :einval] ->
        :ok

      {:error, reason} ->
        send(owner, {:raw_upstream_websocket_error, connection_id, reason})

      _other ->
        raw_websocket_peer_frame_loop(
          state,
          socket,
          connection_id,
          owner,
          request_count,
          first_ping_payload,
          ping_count
        )
    end
  end

  defp send_raw_websocket_peer_response(state, socket, connection_id, request_count) do
    response =
      case Agent.get(state, & &1.response_mode) do
        :hold_after_created ->
          %{
            "type" => "response.created",
            "response" => %{"id" => "resp_raw_ws_#{connection_id}_#{request_count}"}
          }

        :terminal ->
          %{"id" => "resp_raw_ws_#{connection_id}_#{request_count}"}
      end

    :ok = :gen_tcp.send(socket, raw_websocket_server_text_frame(Jason.encode!(response)))
  end

  defp maybe_send_raw_websocket_peer_pong(state, socket, payload, first_ping_payload) do
    case Agent.get(state, & &1.pong_mode) do
      :match_active_ping ->
        :ok = :gen_tcp.send(socket, raw_websocket_server_pong_frame(payload))

      :send_mismatched_pong ->
        :ok = :gen_tcp.send(socket, raw_websocket_server_pong_frame("mismatched-pong"))

      :send_first_ping_payload ->
        :ok = :gen_tcp.send(socket, raw_websocket_server_pong_frame(first_ping_payload))

      :ignore_ping ->
        :ok
    end
  end

  defp raw_websocket_peer_recv_frame(socket) do
    with {:ok, <<first, second>>} <- :gen_tcp.recv(socket, 2, 1_000),
         opcode <- Bitwise.band(first, 0x0F),
         masked? <- Bitwise.band(second, 0x80) == 0x80,
         {:ok, payload_length} <-
           raw_websocket_peer_payload_length(socket, Bitwise.band(second, 0x7F)),
         {:ok, mask} <- raw_websocket_peer_mask(socket, masked?),
         {:ok, payload} <- raw_websocket_peer_payload(socket, payload_length) do
      {:ok, raw_websocket_peer_opcode(opcode), raw_websocket_peer_unmask(payload, mask)}
    end
  end

  defp raw_websocket_peer_payload_length(_socket, length) when length < 126, do: {:ok, length}

  defp raw_websocket_peer_payload_length(socket, 126) do
    with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, 1_000), do: {:ok, length}
  end

  defp raw_websocket_peer_payload_length(socket, 127) do
    with {:ok, <<length::64>>} <- :gen_tcp.recv(socket, 8, 1_000), do: {:ok, length}
  end

  defp raw_websocket_peer_mask(socket, true), do: :gen_tcp.recv(socket, 4, 1_000)
  defp raw_websocket_peer_mask(_socket, false), do: {:ok, nil}

  defp raw_websocket_peer_payload(_socket, 0), do: {:ok, ""}
  defp raw_websocket_peer_payload(socket, length), do: :gen_tcp.recv(socket, length, 1_000)

  defp raw_websocket_peer_unmask(payload, nil), do: payload

  defp raw_websocket_peer_unmask(payload, mask) do
    mask
    |> :binary.copy(div(byte_size(payload) + 3, 4))
    |> binary_part(0, byte_size(payload))
    |> :crypto.exor(payload)
  end

  defp raw_websocket_peer_opcode(0x1), do: :text
  defp raw_websocket_peer_opcode(0x8), do: :close
  defp raw_websocket_peer_opcode(0x9), do: :ping
  defp raw_websocket_peer_opcode(0xA), do: :pong
  defp raw_websocket_peer_opcode(_opcode), do: :unknown

  defp raw_websocket_server_text_frame(payload) when byte_size(payload) < 126 do
    <<0x81, byte_size(payload), payload::binary>>
  end

  defp raw_websocket_server_text_frame(payload) when byte_size(payload) <= 65_535 do
    <<0x81, 126, byte_size(payload)::16, payload::binary>>
  end

  defp raw_websocket_server_text_frame(payload) do
    <<0x81, 127, byte_size(payload)::64, payload::binary>>
  end

  defp raw_websocket_server_pong_frame(payload) when byte_size(payload) < 126 do
    <<0x8A, byte_size(payload), payload::binary>>
  end

  defp set_raw_websocket_peer_pong_mode(%{state: state}, mode) do
    Agent.update(state, &%{&1 | pong_mode: mode})
  end

  defp set_raw_websocket_peer_response_mode(%{state: state}, mode) do
    Agent.update(state, &%{&1 | response_mode: mode})
  end

  defp raw_websocket_peer_connection_count(%{state: state}) do
    Agent.get(state, & &1.connection_count)
  end

  defp wait_for_raw_websocket_connection_closed(connection_id, timeout_ms) do
    receive do
      {:raw_upstream_websocket_connection_closed, ^connection_id} -> :closed
    after
      timeout_ms -> :timeout
    end
  end

  defp stop_raw_websocket_peer(%{state: state}) do
    if Process.alive?(state) do
      snapshot =
        Agent.get_and_update(state, fn current ->
          safe_tcp_close(current.listen_socket)
          Enum.each(current.client_sockets, &safe_tcp_close/1)

          {%{
             accept_pid: current.accept_pid,
             connection_pids: MapSet.to_list(current.connection_pids)
           }, %{current | stopped?: true}}
        end)

      pids = [snapshot.accept_pid | snapshot.connection_pids] |> Enum.filter(&is_pid/1)
      Enum.each(pids, &wait_for_process_stop/1)

      %{
        alive_tasks: Enum.filter(pids, &Process.alive?/1),
        client_socket_count: Agent.get(state, &MapSet.size(&1.client_sockets))
      }
    else
      %{alive_tasks: [], client_socket_count: 0}
    end
  end

  defp wait_for_process_stop(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        500 -> Process.demonitor(ref, [:flush])
      end
    end
  end

  defp safe_tcp_close(socket) when is_port(socket), do: :gen_tcp.close(socket)
  defp safe_tcp_close(_socket), do: :ok

  defp stack_has_mfa?(stacktrace, module, function, arity) do
    Enum.any?(stacktrace, fn
      {^module, ^function, ^arity, _location} -> true
      _frame -> false
    end)
  end

  defp assert_stack_eventually_in(pid, module, function, arity, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    unless poll_stack_until(pid, module, function, arity, deadline) do
      flunk("expected #{inspect(module)}.#{function}/#{arity} on the stack of #{inspect(pid)}")
    end
  end

  defp poll_stack_until(pid, module, function, arity, deadline) do
    parked? =
      case Process.info(pid, :current_stacktrace) do
        {:current_stacktrace, stacktrace} -> stack_has_mfa?(stacktrace, module, function, arity)
        _dead -> false
      end

    cond do
      parked? ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          10 -> :ok
        end

        poll_stack_until(pid, module, function, arity, deadline)
    end
  end
end
