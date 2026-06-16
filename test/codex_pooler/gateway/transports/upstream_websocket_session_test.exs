defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSessionTest do
  use ExUnit.Case, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketFrameWriter

  @timeouts %{connect_timeout_ms: 1_000, receive_timeout_ms: 1_000}

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

    assert {:current_stacktrace, stacktrace} = Process.info(session, :current_stacktrace)
    assert stack_has_mfa?(stacktrace, UpstreamWebsocketSession, :await_sent_request, 2)

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

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp stack_has_mfa?(stacktrace, module, function, arity) do
    Enum.any?(stacktrace, fn
      {^module, ^function, ^arity, _location} -> true
      _frame -> false
    end)
  end
end
