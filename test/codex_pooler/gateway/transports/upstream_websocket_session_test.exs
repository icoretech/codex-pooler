defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSessionTest do
  use ExUnit.Case, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebSocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebSocketFrameWriter

  @timeouts %{connect_timeout_ms: 1_000, receive_timeout_ms: 1_000}

  test "reused request returns unavailable error when session process is gone" do
    {:ok, session} = UpstreamWebSocketSession.start_link([])
    :ok = UpstreamWebSocketSession.close(session)

    request = %Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: "{}",
      timeouts: @timeouts,
      writer: fn _text -> :ok end,
      message_mapper: nil
    }

    assert {:error, %{body: "", headers: [], reason: :upstream_websocket_session_unavailable}} =
             UpstreamWebSocketSession.request(session, request)
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
             WebSocketFrameWriter.send_frame(
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

    {:ok, session} = UpstreamWebSocketSession.start_link([])

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

    request_task = Task.async(fn -> UpstreamWebSocketSession.request(session, request) end)

    assert_receive {:fake_upstream_chunk_sent, 1}, 1_000
    assert_receive {:fake_upstream_chunk_barrier, 1, barrier_pid, ^first_release_ref}, 1_000

    send_task =
      Task.async(fn ->
        UpstreamWebSocketSession.send_request_frame(
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

    {:ok, session} = UpstreamWebSocketSession.start_link([])

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

    request_task = Task.async(fn -> UpstreamWebSocketSession.request(session, request) end)

    assert_receive {:upstream_websocket_frame, created_frame}, 1_000
    assert %{"type" => "response.created"} = Jason.decode!(created_frame)
    refute Task.yield(request_task, 50)

    assert {:ok, %{terminal: "response.completed", status: 200}} = Task.await(request_task, 1_000)
    assert_receive {:upstream_websocket_frame, completed_frame}, 1_000
    assert %{"type" => "response.completed"} = Jason.decode!(completed_frame)
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

    result = UpstreamWebSocketSession.request_once(request)

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

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end
end
