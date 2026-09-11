defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ContinuationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    CodexSession,
    CodexTurn,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket

  @tag :websocket_previous_response_bridge
  test "websocket continuity turns preserve client supplied previous_response_id for upstream context" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_bridge",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-previous-bridge",
          accepted_turn_state: "stable-ws-previous-bridge",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_bridge"} = CodexPooler.JSON.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      second_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "second"}],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_bridge"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert {:push, {:text, second_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_bridge"} = CodexPooler.JSON.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.method == "WEBSOCKET"
      assert second_request.method == "WEBSOCKET"
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert first_request.json["type"] == "response.create"
      assert second_request.json["type"] == "response.create"
      assert first_request.json["generate"] == true
      assert second_request.json["generate"] == true
      refute Map.has_key?(first_request.json, "previous_response_id")
      assert second_request.json["previous_response_id"] == "resp_ws_bridge"

      assert second_request.json["input"] == [
               %{"type" => "message", "role" => "user", "content" => "second"}
             ]

      assert [first_log, second_log] =
               Repo.all(
                 from request in Request,
                   where: request.pool_id == ^setup.pool.id,
                   order_by: [asc: request.admitted_at]
               )

      assert first_log.status == "succeeded"
      assert second_log.status == "succeeded"
      assert first_log.response_status_code == 200
      assert second_log.response_status_code == 200

      assert [first_turn, second_turn] =
               Repo.all(
                 from turn in CodexTurn,
                   where: turn.codex_session_id == ^state.codex_session.id,
                   order_by: [asc: turn.turn_sequence]
               )

      assert first_turn.status == "succeeded"
      assert second_turn.status == "succeeded"
      assert second_turn.turn_sequence == 2
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :websocket_persistent_upstream_session
  test "downstream websocket keeps one upstream websocket session across continuation turns" do
    previous_env =
      Application.get_env(
        :codex_pooler,
        UpstreamWebsocketSession,
        []
      )

    Application.put_env(:codex_pooler, UpstreamWebsocketSession,
      keepalive_interval_ms: 20,
      keepalive_pong_timeout_ms: 1_000
    )

    on_exit(fn ->
      Application.put_env(
        :codex_pooler,
        UpstreamWebsocketSession,
        previous_env
      )
    end)

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_persistent",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    FakeUpstream.notify_websocket_controls(upstream, self())

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-persistent-connection",
          accepted_turn_state: "stable-ws-persistent-connection",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_persistent"} = CodexPooler.JSON.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)
      assert_receive {:fake_upstream_websocket_control, :ping, 1}, 1_000

      processed_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.processed",
          "response_id" => "resp_ws_persistent"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({processed_payload, [opcode: :text]}, state)

      assert {:ok, state} = receive_socket_done(state)

      second_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_sample",
              "output" => "sample output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_persistent"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert {:push, {:text, second_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_persistent"} = CodexPooler.JSON.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [first_request, processed_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.method == "WEBSOCKET"
      assert processed_request.method == "WEBSOCKET"
      assert second_request.method == "WEBSOCKET"
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert processed_request.websocket_connection_id == first_request.websocket_connection_id
      refute Map.has_key?(first_request.json, "previous_response_id")

      assert processed_request.json == %{
               "response_id" => "resp_ws_persistent",
               "type" => "response.processed"
             }

      assert second_request.json["previous_response_id"] == "resp_ws_persistent"

      assert second_request.json["input"] == [
               %{
                 "call_id" => "call_sample",
                 "output" => "sample output",
                 "type" => "function_call_output"
               }
             ]
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :continuation_generation_boundary
  test "native continuation guard blocks replacement send and accepts the explicit full retry" do
    previous_response_id = "resp_generation_boundary_sentinel"
    prompt_sentinel = "generation boundary prompt sentinel"
    call_id_sentinel = "call_generation_boundary_sentinel"
    output_sentinel = "generation boundary tool output sentinel"

    upstream =
      start_upstream(
        # Strict finite scenario: the guarded continuation never reaches the
        # upstream, so only the anchor (connection 1) and the explicit full
        # retry (replacement connection 2, no previous response) are sent.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "message"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => previous_response_id,
                  "object" => "response",
                  "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 2,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "message"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_generation_boundary_full_retry",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 8, "output_tokens" => 5, "total_tokens" => 13}
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_generation_boundary_fallback_should_not_run",
          "object" => "response"
        })
      )

    fallback =
      gateway_upstream(
        setup.pool,
        fallback_upstream,
        "upstream-token-generation-boundary-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-generation-boundary",
          accepted_turn_state: "stable-ws-generation-boundary",
          client_ip: "127.0.0.1"
        }
      })

    codex_session =
      state.codex_session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    state = %{state | codex_session: codex_session}

    try do
      first_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{"type" => "message", "role" => "user", "content" => prompt_sentinel}
          ],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state, 10_000)
      assert %{"id" => ^previous_response_id} = CodexPooler.JSON.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state, 10_000)

      assert :ok =
               UpstreamWebsocketSession.invalidate_connection(state.upstream_websocket_session)

      continuation_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => call_id_sentinel,
              "output" => output_sentinel
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => previous_response_id
        })

      continuation_logs =
        capture_log(fn ->
          assert {:ok, next_state} =
                   CodexResponsesSocket.handle_in(
                     {continuation_payload, [opcode: :text]},
                     state
                   )

          assert {:push, {:text, retry_frame}, next_state} =
                   receive_socket_push(next_state, 10_000)

          assert CodexPooler.JSON.decode!(retry_frame) == native_previous_response_retry_event()
          assert {:ok, next_state} = receive_socket_done(next_state, 10_000)
          send(self(), {:generation_boundary_state, next_state})
        end)

      assert_received {:generation_boundary_state, state}
      refute_received {:codex_response_chunk, _task_pid, _extra_terminal}
      assert [first_upstream_request] = FakeUpstream.requests(upstream)
      assert FakeUpstream.websocket_connection_count(upstream) == 2

      full_retry_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{"type" => "message", "role" => "user", "content" => prompt_sentinel},
            %{
              "type" => "function_call_output",
              "call_id" => call_id_sentinel,
              "output" => output_sentinel
            }
          ],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({full_retry_payload, [opcode: :text]}, state)

      assert {:push, {:text, full_retry_frame}, state} = receive_socket_push(state, 10_000)

      assert %{"id" => "resp_generation_boundary_full_retry"} =
               CodexPooler.JSON.decode!(full_retry_frame)

      assert {:ok, _state} = receive_socket_done(state, 10_000)

      assert [^first_upstream_request, full_retry_upstream_request] =
               FakeUpstream.requests(upstream)

      refute Map.has_key?(first_upstream_request.json, "previous_response_id")
      refute Map.has_key?(full_retry_upstream_request.json, "previous_response_id")

      refute first_upstream_request.websocket_connection_id ==
               full_retry_upstream_request.websocket_connection_id

      assert FakeUpstream.websocket_connection_count(upstream) == 2
      assert FakeUpstream.requests(fallback_upstream) == []

      assert [first_request, failed_request, full_retry_request] =
               Repo.all(
                 from(request in Request,
                   where: request.pool_id == ^setup.pool.id,
                   order_by: [asc: request.admitted_at]
                 )
               )

      assert first_request.status == "succeeded"
      assert full_retry_request.status == "succeeded"
      assert failed_request.status == "failed"
      assert failed_request.response_status_code == 200
      assert failed_request.retry_count == 0
      assert failed_request.last_error_code == "stream_incomplete"
      refute get_in(failed_request.request_metadata, ["routing", "demotion_reason"])

      assert [failed_attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^failed_request.id))

      assert failed_attempt.attempt_number == 1
      assert failed_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert failed_attempt.status == "failed"
      assert failed_attempt.retryable == false
      assert failed_attempt.network_error_code == "stream_incomplete"

      assert failed_attempt.response_metadata["upstream_error_code"] ==
               "previous_response_not_found"

      assert failed_attempt.response_metadata["masked_error_code"] == "stream_incomplete"
      assert failed_attempt.response_metadata["upstream_error_param"] == "previous_response_id"

      assert failed_attempt.response_metadata["transport_failure"] == %{
               "connection_use" => "reconnected",
               "phase" => "send_payload",
               "pre_visible_output" => true,
               "reason" => "previous_response_generation_mismatch",
               "reason_class" => "previous_response_generation_mismatch",
               "termination_source" => "continuation_generation_guard",
               "terminal_seen" => false,
               "text_frame_count" => 0,
               "upstream_committed" => false
             }

      assert %{
               "generation" => 2,
               "reconnected" => true,
               "reused" => false
             } = failed_attempt.response_metadata["upstream_websocket_connection"]

      assert [full_retry_attempt] =
               Repo.all(
                 from(attempt in Attempt, where: attempt.request_id == ^full_retry_request.id)
               )

      assert %{
               "generation" => 2,
               "reconnected" => false,
               "reused" => true
             } = full_retry_attempt.response_metadata["upstream_websocket_connection"]

      assert [failed_turn] =
               Repo.all(
                 from(turn in CodexTurn,
                   where:
                     turn.codex_session_id == ^state.codex_session.id and
                       turn.request_id == ^failed_request.id
                 )
               )

      assert failed_turn.status == "failed"
      assert failed_turn.error_code == "stream_incomplete"
      assert failed_turn.final_attempt_id == failed_attempt.id

      assert [failed_settlement] =
               Repo.all(
                 from(entry in LedgerEntry,
                   where:
                     entry.request_id == ^failed_request.id and
                       entry.entry_kind == "settlement"
                 )
               )

      assert failed_settlement.attempt_id == failed_attempt.id
      assert failed_settlement.usage_status == "usage_unknown"

      assert Repo.aggregate(
               from(attempt in Attempt, where: attempt.request_id == ^failed_request.id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(turn in CodexTurn, where: turn.request_id == ^failed_request.id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where:
                   entry.request_id == ^failed_request.id and
                     entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert Repo.get!(CodexSession, state.codex_session.id).pool_upstream_assignment_id ==
               setup.assignment.id

      assert Repo.all(from(demotion in BridgeDemotion)) == []
      assert Repo.all(from(circuit in RoutingCircuitState)) == []

      persisted_metadata =
        inspect({
          Enum.map([first_request, failed_request, full_retry_request], & &1.request_metadata),
          [failed_attempt.response_metadata, full_retry_attempt.response_metadata],
          failed_turn,
          failed_settlement.details
        })

      for private_sentinel <- [
            previous_response_id,
            prompt_sentinel,
            call_id_sentinel,
            output_sentinel,
            continuation_payload,
            setup.authorization,
            "upstream-token-generation-boundary-fallback"
          ] do
        refute persisted_metadata =~ private_sentinel
        refute continuation_logs =~ private_sentinel
      end

      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "persistent upstream websocket does not reconnect after a partial response body" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_partial_close",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-partial-close-no-reconnect",
          accepted_turn_state: "stable-ws-partial-close-no-reconnect",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_partial_close"} = CodexPooler.JSON.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      FakeUpstream.set_mode(
        upstream,
        FakeUpstream.websocket_sse_then_close(
          [
            {"response.output_text.delta",
             %{
               "type" => "response.output_text.delta",
               "response_id" => "resp_ws_partial_close",
               "output_index" => 0,
               "content_index" => 0,
               "delta" => "partial"
             }}
          ],
          reason: "fake upstream closed after partial frame"
        )
      )

      second_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "second"}],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_partial_close"
        })

      {error_frame, logs} =
        capture_native_turn_warning(fn ->
          assert {:ok, state} =
                   CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

          assert {:push, {:text, partial_frame}, state} = receive_socket_push(state)

          assert %{"type" => "response.output_text.delta", "delta" => "partial"} =
                   CodexPooler.JSON.decode!(partial_frame)

          assert {:push, {:text, error_frame}, _state} = receive_socket_done(state)
          error_frame
        end)

      assert_native_turn_warnings(logs, 1)
      assert logs =~ "request_id=ws-partial-close-no-reconnect"
      assert logs =~ "error_code=upstream_request_failed"
      assert logs =~ "reason_code=upstream_request_failed"
      assert logs =~ "visible_output=after_visible_output"
      refute logs =~ "phase=receive"
      refute logs =~ "fake upstream closed after partial frame"
      refute logs =~ "resp_ws_partial_close"

      assert %{"type" => "error", "error" => %{"code" => "upstream_request_failed"}} =
               CodexPooler.JSON.decode!(error_frame)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert second_request.json["previous_response_id"] == "resp_ws_partial_close"

      assert [first_log, second_log] =
               Repo.all(
                 from(r in Request,
                   where: r.pool_id == ^setup.pool.id,
                   order_by: [asc: r.admitted_at]
                 )
               )

      assert first_log.status == "succeeded"
      assert second_log.status == "failed"
      assert second_log.transport == "websocket"
      assert second_log.last_error_code == "upstream_stream_error"

      assert [second_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^second_log.id))

      assert second_attempt.status == "failed"

      assert second_attempt.response_metadata["transport_failure"] == %{
               "connection_age_bucket" => "under_1m",
               "connection_idle_bucket" => "under_5s",
               "connection_request_bucket" => "requests_2_5",
               "connection_use" => "reused",
               "last_upstream_event_class" => "response_event",
               "last_upstream_event_type" => "response.output_text",
               "peer_close_code" => 1001,
               "peer_close_reason_bytes" => 40,
               "peer_close_reason_present" => true,
               "phase" => "upstream_close",
               "pre_visible_output" => false,
               "reason" => "upstream_websocket_closed_before_terminal",
               "reason_class" => "upstream_websocket_closed_before_terminal",
               "terminal_candidate_seen" => false,
               "terminal_seen" => false,
               "termination_source" => "peer_close_frame",
               "text_frame_count" => 1,
               "transport_signal" => "tcp_data",
               "upstream_committed" => true,
               "websocket_buffer_bucket" => "empty",
               "websocket_fragment_open" => false
             }

      metadata_text = inspect(second_attempt.response_metadata)
      refute metadata_text =~ "partial"
      refute metadata_text =~ "fake upstream closed after partial frame"
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.raw_key
      refute metadata_text =~ "Bearer "
      refute metadata_text =~ "upstream-token"

      assert [demotion] = Repo.all(from(d in BridgeDemotion))
      assert demotion.pool_upstream_assignment_id == setup.assignment.id
      assert demotion.reason_code == "upstream_stream_error"

      assert [circuit] =
               Repo.all(from(c in RoutingCircuitState, where: c.route_class == "proxy_websocket"))

      assert circuit.pool_upstream_assignment_id == setup.assignment.id
      assert circuit.reason_code == "upstream_stream_error"
      assert circuit.failure_count == 1
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "concurrent downstream websocket frames queue behind the active upstream turn" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_ws_parallel",
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-concurrent-frames",
          accepted_turn_state: "stable-ws-concurrent-frames",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "main turn"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert_receive {:fake_upstream_chunk_barrier, 0, first_upstream_pid, ^release_ref}, 1_000

      second_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "sidecar turn"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      send(first_upstream_pid, {:fake_upstream_release_chunk, release_ref})

      assert_receive {:fake_upstream_chunk_barrier, 0, second_upstream_pid, ^release_ref}, 1_000
      send(second_upstream_pid, {:fake_upstream_release_chunk, release_ref})

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(first_frame)
      assert {:push, {:text, second_frame}, state} = receive_socket_push(state)
      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(second_frame)
      assert {:ok, state} = receive_socket_done(state)
      assert {:ok, _state} = receive_socket_done(state)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "tool output websocket continuations wait for the active upstream turn" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_ws_ordered_tool",
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-ordered-tool-continuation",
          accepted_turn_state: "stable-ws-ordered-tool-continuation",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "main turn"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert_receive {:fake_upstream_chunk_barrier, 0, first_upstream_pid, ^release_ref}, 1_000

      second_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_ordered_tool",
              "output" => "sample output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_ordered_tool"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      refute_receive {:fake_upstream_chunk_barrier, 0, _second_upstream_pid, ^release_ref}, 100

      send(first_upstream_pid, {:fake_upstream_release_chunk, release_ref})

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      assert_receive {:fake_upstream_chunk_barrier, 0, second_upstream_pid, ^release_ref}, 1_000
      send(second_upstream_pid, {:fake_upstream_release_chunk, release_ref})

      assert {:push, {:text, second_frame}, state} = receive_socket_push(state)
      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      assert first_request.websocket_connection_id == second_request.websocket_connection_id
      assert second_request.json["previous_response_id"] == "resp_ws_ordered_tool"

      assert [%{"type" => "function_call_output", "call_id" => "call_ordered_tool"}] =
               second_request.json["input"]
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "direct websocket preserves schema-bound output while compressing an unbound output" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_schema_bound_compression",
          "object" => "response",
          "status" => "completed"
        })
      )

    setup =
      gateway_setup(upstream,
        exposed_model_id: "gpt-4o",
        upstream_model_id: "gpt-4o",
        pricing_ref: "gpt-4o"
      )

    setup.pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(request_compression_enabled: true)
    |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-schema-bound-compression",
          accepted_turn_state: "stable-ws-schema-bound-compression",
          client_ip: "127.0.0.1"
        }
      })

    schema_bound_output =
      CodexPooler.JSON.encode!(%{"rows" => Enum.to_list(1..160)}, pretty: true)

    unbound_output = CodexPooler.JSON.encode!(%{"rows" => Enum.to_list(161..320)}, pretty: true)

    assert byte_size(schema_bound_output) > 512
    assert byte_size(unbound_output) > 512

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "tools" => [
          %{
            "type" => "function",
            "name" => "schema_bound_direct_fixture",
            "output_schema" => %{"type" => "object"}
          },
          %{"type" => "function", "name" => "unbound_direct_fixture"}
        ],
        "input" => [
          %{
            "type" => "function_call",
            "call_id" => "call_direct_schema_bound",
            "name" => "schema_bound_direct_fixture",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call",
            "call_id" => "call_direct_unbound",
            "name" => "unbound_direct_fixture",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_direct_schema_bound",
            "output" => schema_bound_output
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_direct_unbound",
            "output" => unbound_output
          }
        ],
        "stream" => true,
        "generate" => true
      })

    try do
      assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
      assert {:push, {:text, frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_schema_bound_compression"} = CodexPooler.JSON.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [captured] = FakeUpstream.requests(upstream)

      schema_bound_item =
        Enum.find(captured.json["input"], fn item ->
          item["type"] == "function_call_output" and
            item["call_id"] == "call_direct_schema_bound"
        end)

      unbound_item =
        Enum.find(captured.json["input"], fn item ->
          item["type"] == "function_call_output" and item["call_id"] == "call_direct_unbound"
        end)

      assert schema_bound_item["output"] == schema_bound_output

      assert CodexPooler.JSON.decode!(schema_bound_item["output"]) ==
               CodexPooler.JSON.decode!(schema_bound_output)

      assert unbound_item["output"] != unbound_output

      assert CodexPooler.JSON.decode!(unbound_item["output"]) ==
               CodexPooler.JSON.decode!(unbound_output)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

      assert %{
               "candidate_count" => 1,
               "compressed_count" => 1,
               "protected_tool_output_skipped_count" => 1,
               "status" => "compressed",
               "transport" => "websocket"
             } = attempt.response_metadata["payload_compression"]
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "downstream websocket does not inject last response id when continuation omits previous_response_id" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_auto_previous",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-no-auto-previous-response-id",
          accepted_turn_state: "stable-ws-no-auto-previous-response-id",
          client_ip: "127.0.0.1"
        }
      })

    try do
      first_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({first_payload, [opcode: :text]}, state)

      assert {:push, {:text, first_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_auto_previous"} = CodexPooler.JSON.decode!(first_frame)
      assert {:ok, state} = receive_socket_done(state)

      second_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [%{"type" => "message", "role" => "user", "content" => "follow-up"}],
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({second_payload, [opcode: :text]}, state)

      assert {:push, {:text, second_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_auto_previous"} = CodexPooler.JSON.decode!(second_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [first_request, second_request] = FakeUpstream.requests(upstream)
      refute Map.has_key?(first_request.json, "previous_response_id")
      refute Map.has_key?(second_request.json, "previous_response_id")
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "websocket Full-to-Lite tool continuations keep previous_response_id after the tools prefix" do
    upstream =
      start_upstream(
        # Strict finite scenario: the anchor carries no previous response and
        # the Lite continuation keeps it behind the tools prefix on the same
        # physical connection.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_ws_tool_origin",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_ws_tool_origin",
                "input.0.type" => "additional_tools",
                "input.1.type" => "function_call_output"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_ws_tool_continuation",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "full")
    _revision = set_model_serving_mode!(scope, setup, "lite", revision)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    tool_output = "sample output"
    tool_call_id = "call_sample"
    previous_response_id = "resp_ws_tool_origin"

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-tool-continuation",
          accepted_turn_state: "stable-ws-tool-continuation",
          client_ip: "127.0.0.1"
        }
      })

    try do
      anchor_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("anchor"),
          "stream" => true,
          "generate" => true
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, state)

      assert {:push, {:text, anchor_frame}, state} = receive_socket_push(state)
      assert %{"id" => ^previous_response_id} = CodexPooler.JSON.decode!(anchor_frame)
      assert {:ok, state} = receive_socket_done(state)

      continuation_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => tool_call_id,
              "output" => tool_output
            }
          ],
          "tools" => [
            %{
              "type" => "function",
              "name" => "sample_lookup",
              "parameters" => %{
                "type" => "object",
                "properties" => %{},
                "required" => []
              }
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => previous_response_id
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({continuation_payload, [opcode: :text]}, state)

      assert {:push, {:text, frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_tool_continuation"} = CodexPooler.JSON.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [anchor_request, captured] = FakeUpstream.requests(upstream)
      assert anchor_request.websocket_connection_id == captured.websocket_connection_id
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["previous_response_id"] == previous_response_id
      assert captured.json["type"] == "response.create"
      assert captured.json["generate"] == true

      assert [tools_prefix, captured_tool_output] = captured.json["input"]
      assert tools_prefix["type"] == "additional_tools"
      assert tools_prefix["role"] == "developer"
      assert [%{"name" => "sample_lookup"}] = tools_prefix["tools"]

      assert captured_tool_output == %{
               "type" => "function_call_output",
               "call_id" => tool_call_id,
               "output" => tool_output
             }

      assert [_anchor_request, request] =
               Repo.all(
                 from(request in Request,
                   where: request.pool_id == ^setup.pool.id,
                   order_by: [asc: request.admitted_at]
                 )
               )

      assert request.endpoint == "/backend-api/codex/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"
      assert request.response_status_code == 200
      assert request.usage_status == "usage_known"
      assert request.request_metadata["codex_session_id"] == state.codex_session.id

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.transport == "websocket"
      assert attempt.status == "succeeded"
      assert attempt.upstream_status_code == 200

      assert [_anchor_turn, turn] =
               Repo.all(
                 from(turn in CodexTurn,
                   where: turn.codex_session_id == ^state.codex_session.id,
                   order_by: [asc: turn.turn_sequence]
                 )
               )

      assert turn.request_id == request.id
      assert turn.status == "succeeded"
      assert turn.transport_kind == "websocket"
      assert turn.completed_at
      assert turn.final_attempt_id == attempt.id

      session = Repo.get!(CodexSession, state.codex_session.id)
      assert session.status == "active"
      assert session.pool_upstream_assignment_id == setup.assignment.id

      persistence_text =
        inspect({request.request_metadata, attempt.response_metadata, session, turn})

      refute persistence_text =~ setup.authorization
      refute persistence_text =~ previous_response_id
      refute persistence_text =~ tool_call_id
      refute persistence_text =~ tool_output
      refute persistence_text =~ "upstream-token"
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "websocket custom tool output continuations keep previous_response_id for upstream context" do
    upstream =
      start_upstream(
        # Strict finite scenario: the custom tool continuation must carry the
        # anchor response id on the same physical connection.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_ws_custom_tool_origin",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_ws_custom_tool_origin",
                "input.0.type" => "custom_tool_call_output"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_ws_custom_tool_continuation",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-custom-tool-continuation",
          accepted_turn_state: "stable-ws-custom-tool",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {anchor_payload(setup.model.exposed_model_id), [opcode: :text]},
                 state
               )

      assert {:push, {:text, anchor_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_custom_tool_origin"} = CodexPooler.JSON.decode!(anchor_frame)
      assert {:ok, state} = receive_socket_done(state)

      continuation_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "custom_tool_call_output",
              "call_id" => "call_sample",
              "name" => "sample_tool",
              "output" => "sample output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_custom_tool_origin"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({continuation_payload, [opcode: :text]}, state)

      assert {:push, {:text, frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_custom_tool_continuation"} = CodexPooler.JSON.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [anchor_request, captured] = FakeUpstream.requests(upstream)
      assert anchor_request.websocket_connection_id == captured.websocket_connection_id
      assert captured.json["previous_response_id"] == "resp_ws_custom_tool_origin"
      assert captured.json["type"] == "response.create"
      assert captured.json["generate"] == true
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "future tool output continuations keep previous_response_id by shape" do
    upstream =
      start_upstream(
        # Strict finite scenario: the anchor carries no previous response and
        # the continuation must keep it on the same physical connection.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_ws_future_tool_origin",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_ws_future_tool_origin",
                "input.0.type" => "future_tool_call_output"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_ws_future_tool_continuation",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-future-tool-continuation",
          accepted_turn_state: "stable-ws-future-tool",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {anchor_payload(setup.model.exposed_model_id), [opcode: :text]},
                 state
               )

      assert {:push, {:text, anchor_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_future_tool_origin"} = CodexPooler.JSON.decode!(anchor_frame)
      assert {:ok, state} = receive_socket_done(state)

      continuation_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "future_tool_call_output",
              "call_id" => "future_call_sample",
              "output" => "future sample output"
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => "resp_ws_future_tool_origin"
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({continuation_payload, [opcode: :text]}, state)

      assert {:push, {:text, frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_ws_future_tool_continuation"} = CodexPooler.JSON.decode!(frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert [anchor_request, captured] = FakeUpstream.requests(upstream)
      assert anchor_request.websocket_connection_id == captured.websocket_connection_id
      assert captured.json["previous_response_id"] == "resp_ws_future_tool_origin"

      assert captured.json["input"] |> List.first() |> Map.fetch!("type") ==
               "future_tool_call_output"

      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "HTTP custom tool output continuations keep previous_response_id", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.require_json_field(
          "previous_response_id",
          %{
            "id" => "resp_http_custom_tool_continuation",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          },
          %{"error" => %{"code" => "missing_custom_tool_context"}}
        )
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_sample",
            "name" => "sample_tool",
            "output" => "sample output"
          }
        ],
        "previous_response_id" => "resp_http_custom_tool_origin"
      })

    assert %{"id" => "resp_http_custom_tool_continuation"} = json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["previous_response_id"] == "resp_http_custom_tool_origin"
    refute Map.has_key?(captured.json, "type")
  end

  test "gateway debug mode logs safe continuation decisions and stores request metadata" do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{gateway_debug?: true}
    )

    on_exit(fn ->
      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    upstream =
      start_upstream(
        # Strict finite scenario: the debug-logged continuation must still
        # preserve the anchor response id on the same physical connection.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_ws_debug_tool_origin",
                  "object" => "response"
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_ws_debug_tool_origin",
                "input.0.type" => "custom_tool_call_output"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_ws_debug_tool_continuation",
                  "object" => "response",
                  "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-debug-tool-continuation",
          accepted_turn_state: "stable-ws-debug-tool",
          client_ip: "127.0.0.1"
        }
      })

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {anchor_payload(setup.model.exposed_model_id), [opcode: :text]},
               state
             )

    assert {:push, {:text, anchor_frame}, state} = receive_socket_push(state)
    assert %{"id" => "resp_ws_debug_tool_origin"} = CodexPooler.JSON.decode!(anchor_frame)
    assert {:ok, state} = receive_socket_done(state)

    continuation_payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "metadata" => %{"debug_note" => "metadata value must stay hidden"},
        "input" => [
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_debug_sample",
            "output" => "debug output must stay hidden"
          }
        ],
        "stream" => true,
        "generate" => true,
        "previous_response_id" => "resp_ws_debug_tool_origin"
      })

    try do
      previous_logger_level = Logger.level()

      log =
        try do
          Logger.configure(level: :info)

          ExUnit.CaptureLog.capture_log([level: :info], fn ->
            assert {:ok, next_state} =
                     CodexResponsesSocket.handle_in(
                       {continuation_payload, [opcode: :text]},
                       state
                     )

            assert {:push, {:text, frame}, next_state} = receive_socket_push(next_state)
            assert %{"id" => "resp_ws_debug_tool_continuation"} = CodexPooler.JSON.decode!(frame)
            assert {:ok, _state} = receive_socket_done(next_state)
          end)
        after
          Logger.configure(level: previous_logger_level)
        end

      assert log =~ "codex_pooler gateway_debug payload"
      assert log =~ "previous_response_id_action=preserved"
      assert log =~ "previous_response_id_clear_preview=resp_ws_debug_too"
      assert log =~ "client_json_bytes="
      assert log =~ "client_approx_tokens="
      assert log =~ "upstream_json_bytes="
      assert log =~ "upstream_approx_tokens="
      assert log =~ "client_entry_count=1"
      assert log =~ "client_chat_entry_count=0"
      assert log =~ "client_string_bytes="
      assert log =~ "custom_tool_call_output"
      refute log =~ "debug output must stay hidden"
      refute log =~ "metadata value must stay hidden"
      refute log =~ "resp_ws_debug_tool_origin"
      refute log =~ "call_debug_sample"

      assert [_anchor_request, request] =
               Repo.all(
                 from(request in Request,
                   where:
                     request.endpoint == "/backend-api/codex/responses" and
                       request.transport == "websocket",
                   order_by: [asc: request.admitted_at]
                 )
               )

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

      debug = attempt.response_metadata["gateway_debug"]
      refute Map.has_key?(debug, "previous_response_id")
      refute Map.has_key?(debug, "previous_response_id_clear_preview")
      assert debug["previous_response_id_summary"]["action"] == "preserved"
      assert debug["previous_response_id_summary"]["preview"] =~ ~r/\A[0-9a-f]{16}\z/
      assert debug["items"]["tool_result_types"] == ["custom_tool_call_output"]
      assert debug["shape"]["client"]["json"]["bytes"] > 0
      assert debug["shape"]["client"]["json"]["approx_tokens"] > 0
      assert debug["shape"]["client"]["json"]["strategy"] == "json_bytes_div_4_ceil"

      assert debug["shape"]["client"]["top_level_keys"] == [
               "generate",
               "input",
               "metadata",
               "model",
               "previous_response_id",
               "stream",
               "type"
             ]

      assert debug["shape"]["client"]["entries"]["count"] == 1

      assert debug["shape"]["client"]["entries"]["item_types"] == %{
               "custom_tool_call_output" => 1
             }

      assert debug["shape"]["client"]["entries"]["tool_result_count"] == 1
      assert debug["shape"]["client"]["chat_entries"]["kind"] == "absent"
      assert debug["shape"]["client"]["string_stats"]["string_bytes"] > 0
      assert debug["shape"]["client"]["string_stats"]["max_string_bytes"] > 0
      assert debug["shape"]["client"]["flags"]["stream"] == true
      assert debug["shape"]["client"]["flags"]["generate"] == true
      assert debug["shape"]["client"]["flags"]["has_previous_response_id"] == true
      assert debug["shape"]["upstream"]["json"]["bytes"] > 0
      assert debug["shape"]["upstream"]["flags"]["has_instructions"] == true

      metadata_text = inspect(debug)
      refute metadata_text =~ "debug output must stay hidden"
      refute metadata_text =~ "metadata value must stay hidden"
      refute metadata_text =~ "resp_ws_debug_too"
      refute metadata_text =~ "call_debug_sample"
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "HTTP Full-to-Lite ordinary continuation drops previous_response_id after the tools prefix",
       %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.reject_json_field(
          "previous_response_id",
          %{
            "id" => "resp_http_bridge",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          },
          %{"error" => %{"code" => "invalid_previous_response_id"}}
        )
      )

    setup = gateway_setup(upstream)
    scope = model_serving_scope()
    revision = set_model_serving_mode!(scope, setup, "full")
    _revision = set_model_serving_mode!(scope, setup, "lite", revision)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("hello"),
        "tools" => [
          %{
            "type" => "function",
            "name" => "sample_lookup",
            "parameters" => %{
              "type" => "object",
              "properties" => %{},
              "required" => []
            }
          }
        ],
        "previous_response_id" => "resp_http_previous"
      })

    assert %{"id" => "resp_http_bridge"} = json_response(conn, 200)
    assert [captured] = FakeUpstream.requests(upstream)
    refute Map.has_key?(captured.json, "previous_response_id")
    assert [%{"type" => "additional_tools"} | _input] = captured.json["input"]
  end

  defp anchor_payload(model_id) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => model_id,
      "input" => native_text_input("anchor"),
      "stream" => true,
      "generate" => true
    })
  end
end
