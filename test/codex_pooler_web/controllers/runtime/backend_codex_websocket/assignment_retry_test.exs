defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.AssignmentRetryTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures, only: [request_fixture: 2]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, CodexTurn, RoutingCircuitState}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @websocket_frame_timeout 1_000

  test "fresh websocket upgrade timeout before visible output tries the next eligible assignment" do
    release_ref = make_ref()

    timeout_upstream =
      start_upstream(
        FakeUpstream.websocket_upgrade_timeout(notify: self(), release_ref: release_ref)
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_upgrade_timeout_fallback",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(timeout_upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-fallback", compact?: false)

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        execute_websocket_response(
          auth,
          CodexPooler.JSON.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => native_text_input("fail over before visible websocket output"),
            "stream" => true,
            "generate" => true
          }),
          %{request_id: request_id, connect_timeout_ms: 25},
          fn frame -> send(parent, {:websocket_frame, frame}) end
        )
      end)

    assert_receive {:fake_upstream_timeout_barrier, :websocket_upgrade, upstream_pid,
                    ^release_ref},
                   1_000

    try do
      assert :ok = Task.await(task, 2_000)
    after
      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
    end

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_upgrade_timeout_fallback"} = CodexPooler.JSON.decode!(frame)

    assert FakeUpstream.count(timeout_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 1

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert first_attempt.retryable == true
    assert first_attempt.network_error_code == "upstream_stream_error"

    assert second_attempt.pool_upstream_assignment_id == fallback.assignment.id
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1
    assert request.last_error_code == nil

    metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token"
  end

  test "non-101 websocket upgrade rejection stays classified as upstream_stream_error" do
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
          headers: [
            {"x-upstream-status", "upgrade-denied-sentinel"},
            {"set-cookie", "cookie-sentinel"}
          ]
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    capture_stream_outcome_telemetry(fn ->
      assert {:error,
              %{
                code: "upstream_request_failed",
                message: "upstream request failed",
                status: 502
              }} =
               execute_websocket_response(
                 auth,
                 CodexPooler.JSON.encode!(%{
                   "type" => "response.create",
                   "model" => setup.model.exposed_model_id,
                   "input" => native_text_input("non-101 websocket upgrade rejection"),
                   "stream" => true,
                   "generate" => true
                 }),
                 %{request_id: "ws-upgrade-rejected"},
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_receive {:stream_outcome,
                      %{
                        outcome: "failed",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      refute_received {:stream_outcome, _metadata}
    end)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "websocket"
    assert request.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_stream_error"

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upgrade body sentinel"
    refute metadata_text =~ "upgrade-denied-sentinel"
    refute metadata_text =~ "cookie-sentinel"
    refute metadata_text =~ "upgrade_rejected"
  end

  @tag :feature_websocket_connection_limit_retry
  test "websocket pre-visible upstream close does not replay an accepted request" do
    # Strict finite scenario: the accepted request is sent exactly once and the
    # upstream closes before any terminal; there is no retry entry, so a replay
    # fails the fixture as an unexpected extra request.
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_request(1, FakeUpstream.websocket_sse_then_close([]))
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:error, %{code: "upstream_request_failed"}} =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("retry pre-visible websocket close"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-pre-visible-close-runtime-retry"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    refute_received {:websocket_frame, _unexpected}

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert [first_request] = FakeUpstream.requests(upstream)
    assert first_request.method == "WEBSOCKET"

    assert [first_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "failed"
    refute first_attempt.retryable
    assert first_attempt.network_error_code == "upstream_stream_error"

    assert first_attempt.response_metadata["transport_failure"] == %{
             "connection_age_bucket" => "under_1m",
             "connection_idle_bucket" => "first_request",
             "connection_request_bucket" => "first",
             "connection_use" => "fresh",
             "last_upstream_event_class" => "none",
             "last_upstream_event_type" => "none",
             "peer_close_code" => 1001,
             "peer_close_reason_bytes" => 30,
             "peer_close_reason_present" => true,
             "phase" => "upstream_close",
             "pre_visible_output" => true,
             "reason" => "upstream_websocket_closed_before_terminal",
             "reason_class" => "upstream_websocket_closed_before_terminal",
             "terminal_candidate_seen" => false,
             "terminal_seen" => false,
             "termination_source" => "peer_close_frame",
             "text_frame_count" => 0,
             "transport_signal" => "tcp_data",
             "upstream_committed" => true,
             "websocket_buffer_bucket" => "empty",
             "websocket_fragment_open" => false
           }

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.last_error_code == "upstream_stream_error"

    assert [%BridgeDemotion{reason_code: "upstream_stream_error"}] =
             Repo.all(from(d in BridgeDemotion))

    assert [%RoutingCircuitState{reason_code: "upstream_stream_error"}] =
             Repo.all(from(c in RoutingCircuitState))

    metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token"
    assert :ok = FakeUpstream.verify!(upstream)
  end

  for {family, error} <- [
        {:structured,
         %{
           "code" => "model_not_found",
           "type" => "invalid_request_error",
           "param" => "model",
           "message" => "raw websocket structured model miss sentinel"
         }},
        {:provenance_backed,
         %{
           "type" => "invalid_request_error",
           "param" => "model",
           "message" => "raw websocket provenance model miss sentinel"
         }}
      ] do
    @tag assignment_model_miss_family: family
    test "websocket pre-visible #{family} assignment model miss retries a later assignment" do
      error = unquote(Macro.escape(error))

      first_upstream =
        start_upstream(
          FakeUpstream.sse_stream(
            [
              {"response.failed",
               %{
                 "type" => "response.failed",
                 "response" => %{
                   "id" => "resp_ws_assignment_model_miss",
                   "error" => error
                 }
               }}
            ],
            done: false
          )
        )

      second_upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_ws_assignment_model_fallback_success",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(first_upstream, exposed_model_id: "gpt-example-luna")

      second =
        gateway_upstream(setup.pool, second_upstream, "upstream-token-ws-model-fallback",
          compact?: false
        )

      prime_routing_quota!(second.identity)
      use_routing_strategy!(setup.pool, "bridge_ring", 2)

      setup =
        Map.put(
          setup,
          :model,
          put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
        )

      request_id =
        seed_preferring_assignment(
          [setup.assignment.id, second.assignment.id],
          setup.assignment.id
        )

      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      assert :ok =
               execute_websocket_response(
                 auth,
                 CodexPooler.JSON.encode!(%{
                   "type" => "response.create",
                   "model" => setup.model.exposed_model_id,
                   "input" =>
                     native_text_input("synthetic websocket assignment model failover input"),
                   "stream" => true,
                   "generate" => true
                 }),
                 %{request_id: request_id},
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_received {:websocket_frame, frame}

      assert %{"id" => "resp_ws_assignment_model_fallback_success"} =
               CodexPooler.JSON.decode!(frame)

      refute_received {:websocket_frame, _unexpected}

      assert FakeUpstream.count(first_upstream) == 1
      assert FakeUpstream.count(second_upstream) == 1

      assert [first_attempt, second_attempt] =
               Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

      assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert first_attempt.status == "retryable_failed"
      assert first_attempt.network_error_code == "upstream_model_unavailable"
      assert first_attempt.usage_status == "usage_unknown"
      assert second_attempt.pool_upstream_assignment_id == second.assignment.id
      assert second_attempt.status == "succeeded"
      assert second_attempt.usage_status == "usage_known"

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"
      assert request.retry_count == 1

      assert [settlement] =
               Repo.all(
                 from(entry in LedgerEntry,
                   where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
                 )
               )

      assert settlement.attempt_id == second_attempt.id
      assert settlement.pool_upstream_assignment_id == second.assignment.id
      assert settlement.usage_status == "usage_known"
      assert settlement.total_tokens == 7

      assert %RoutingCircuitState{
               pool_upstream_assignment_id: first_assignment_id,
               model_identifier: "gpt-example-luna",
               route_class: "proxy_websocket",
               reason_code: "upstream_model_unavailable"
             } = Repo.one!(from(c in RoutingCircuitState))

      assert first_assignment_id == setup.assignment.id

      assert %BridgeDemotion{
               pool_upstream_assignment_id: demoted_assignment_id,
               reason_code: "upstream_model_unavailable"
             } = Repo.one!(from(d in BridgeDemotion))

      assert demoted_assignment_id == setup.assignment.id

      persisted = inspect({request, first_attempt, second_attempt})
      refute persisted =~ "raw websocket structured model miss sentinel"
      refute persisted =~ "raw websocket provenance model miss sentinel"
      refute persisted =~ "synthetic websocket assignment model failover input"
      refute persisted =~ setup.authorization
      refute persisted =~ "upstream-token-ws-model-fallback"
    end
  end

  test "websocket attached session model miss retries a later assignment" do
    setup = attached_session_model_fallback_setup("attached-session")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "attached-session"})
    session = pin_session_to_assignment!(session, setup.assignment)

    assert :ok =
             execute_websocket_response(
               auth,
               model_fallback_websocket_payload(setup.model, "attached session"),
               %{request_id: Ecto.UUID.generate(), codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_attached-session_model_fallback"} = CodexPooler.JSON.decode!(frame)
    refute_received {:websocket_frame, _unexpected}

    assert_soft_session_model_fallback!(setup)
  end

  test "websocket same-model successful-turn session model miss retries a later assignment" do
    setup = attached_session_model_fallback_setup("same-model-turn")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "same-model-turn"})
    session = pin_session_to_assignment!(session, setup.assignment)
    insert_successful_session_turn!(setup, session)

    assert :ok =
             execute_websocket_response(
               auth,
               model_fallback_websocket_payload(setup.model, "same model successful turn"),
               %{request_id: Ecto.UUID.generate(), codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_same-model-turn_model_fallback"} = CodexPooler.JSON.decode!(frame)
    refute_received {:websocket_frame, _unexpected}

    assert_soft_session_model_fallback!(setup)
  end

  test "websocket final assignment model miss emits one sanitized terminal failure" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "resp_ws_final_model_miss",
                 "error" => %{
                   "code" => "model_not_found",
                   "message" => "raw final websocket model miss sentinel"
                 }
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream, exposed_model_id: "gpt-example-luna")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("final websocket assignment model miss"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-final-assignment-model-miss"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(frame)
    refute_received {:websocket_frame, _unexpected}
    assert FakeUpstream.count(upstream) == 1

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.retryable == false
    assert attempt.network_error_code == "upstream_model_unavailable"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.retry_count == 0
    assert request.last_error_code == "upstream_model_unavailable"

    persisted = inspect({request, attempt})
    refute persisted =~ "raw final websocket model miss sentinel"
    refute persisted =~ "final websocket assignment model miss"
  end

  test "websocket visible output prevents assignment model failover" do
    first_upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.output_text.delta",
             %{"type" => "response.output_text.delta", "delta" => "visible"}},
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "resp_ws_visible_model_miss",
                 "error" => %{"code" => "model_not_found", "message" => "hidden sentinel"}
               }
             }}
          ],
          done: false
        )
      )

    fallback_upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_ws_fallback_must_not_run"}))

    setup = gateway_setup(first_upstream, exposed_model_id: "gpt-example-luna")

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-ws-visible-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("visible websocket assignment model miss"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: request_id},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    frames =
      receive_websocket_frames_by_type(
        ["response.output_text.delta", "response.failed"],
        @websocket_frame_timeout
      )

    assert frames["response.output_text.delta"]["delta"] == "visible"
    assert frames["response.failed"]["response"]["error"]["code"] == "model_not_found"
    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.retryable == false
  end

  test "live direct websocket keeps an accepted assignment model miss on its established lane" do
    # Strict finite scenario: the anchor and the model-miss turn both ride the
    # established first physical connection; a sibling dispatch or a retry
    # would be an unexpected extra request and fail the fixture.
    pinned_upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_response("resp_live_direct_anchor", 1, 2, 1),
          strict_native_request(
            1,
            FakeUpstream.websocket_text_frames([
              CodexPooler.JSON.encode!(%{
                "type" => "response.failed",
                "response" => %{
                  "id" => "resp_live_direct_model_miss",
                  "error" => %{"code" => "model_not_found", "param" => "model"}
                }
              })
            ])
          )
        ])
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_live_direct_fallback_should_not_run",
          "object" => "response"
        })
      )

    setup = gateway_setup(pinned_upstream, exposed_model_id: "gpt-example-luna")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-live-direct-model-miss",
          accepted_turn_state: "ws-live-direct-model-miss",
          client_ip: "127.0.0.1"
        }
      })

    try do
      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {CodexPooler.JSON.encode!(%{
                    "type" => "response.create",
                    "model" => setup.model.exposed_model_id,
                    "input" => native_text_input("synthetic live direct anchor"),
                    "stream" => true,
                    "generate" => true
                  }), [opcode: :text]},
                 state
               )

      assert {:push, {:text, anchor_frame}, state} = receive_socket_push(state)
      assert %{"id" => "resp_live_direct_anchor"} = CodexPooler.JSON.decode!(anchor_frame)
      assert {:ok, state} = receive_socket_done(state)

      fallback =
        gateway_upstream(setup.pool, fallback_upstream, "upstream-token-live-direct-fallback",
          compact?: false
        )

      prime_routing_quota!(fallback.identity)

      _model =
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {CodexPooler.JSON.encode!(%{
                    "type" => "response.create",
                    "model" => setup.model.exposed_model_id,
                    "input" => native_text_input("synthetic live direct model miss"),
                    "stream" => true,
                    "generate" => true
                  }), [opcode: :text]},
                 state
               )

      assert {:push, {:text, failed_frame}, state} = receive_socket_push(state)
      assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(failed_frame)
      assert {:ok, _state} = receive_socket_done(state)

      assert FakeUpstream.count(pinned_upstream) == 2
      assert FakeUpstream.count(fallback_upstream) == 0

      assert [anchor_request, failed_request] =
               Repo.all(
                 from(request in Request,
                   where: request.pool_id == ^setup.pool.id,
                   order_by: [asc: request.admitted_at]
                 )
               )

      assert anchor_request.status == "succeeded"
      assert failed_request.status == "failed"
      assert failed_request.retry_count == 0

      assert [failed_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^failed_request.id))

      assert failed_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert failed_attempt.status == "failed"
      assert failed_attempt.usage_status == "usage_unknown"
      assert :ok = FakeUpstream.verify!(pinned_upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :feature_websocket_connection_limit_retry
  test "websocket connection limit first event retries same assignment without demotion" do
    upstream =
      start_upstream(
        # Strict finite scenario: the connection-limit terminal arrives on the
        # first physical connection and the retry must land on a replacement
        # connection; an extra send or a reused connection fails the fixture.
        # provenance: observed findings #116 (type error websocket_connection_limit_reached terminal); rest synthetic
        FakeUpstream.strict_sequence([
          strict_native_request(
            1,
            FakeUpstream.websocket_text_frames([
              CodexPooler.JSON.encode!(%{
                "type" => "error",
                "status" => 400,
                "code" => "websocket_connection_limit_reached",
                "param" => "reasoning.effort",
                "message" => "open a replacement websocket connection"
              })
            ])
          ),
          strict_native_response("resp_ws_connection_limit_retry", 2, 4, 3)
        ])
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_connection_limit_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-limit-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    capture_stream_outcome_telemetry(fn ->
      assert :ok =
               execute_websocket_response(
                 auth,
                 CodexPooler.JSON.encode!(%{
                   "type" => "response.create",
                   "model" => setup.model.exposed_model_id,
                   "input" => native_text_input("retry first websocket connection limit"),
                   "stream" => true,
                   "generate" => true
                 }),
                 %{request_id: request_id},
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_receive {:stream_outcome,
                      %{
                        outcome: "succeeded",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      refute_received {:stream_outcome, _metadata}
    end)

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_connection_limit_retry"} = CodexPooler.JSON.decode!(frame)
    refute_received {:websocket_frame, _unexpected}

    assert FakeUpstream.count(upstream) == 2
    assert FakeUpstream.count(fallback_upstream) == 0
    assert :ok = FakeUpstream.verify!(upstream)

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert first_attempt.retryable == true
    assert first_attempt.network_error_code == "websocket_connection_limit_reached"
    assert first_attempt.response_metadata["stream_failure_stage"] == "first_event"

    assert first_attempt.response_metadata["stream_error_code"] ==
             "websocket_connection_limit_reached"

    assert first_attempt.response_metadata["upstream_error_param"] == "reasoning.effort"

    assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert second_attempt.status == "succeeded"

    first_connection = first_attempt.response_metadata["upstream_websocket_connection"]
    second_connection = second_attempt.response_metadata["upstream_websocket_connection"]

    assert %{"lifecycle_id" => first_lifecycle_id} = first_connection
    assert {:ok, ^first_lifecycle_id} = Ecto.UUID.cast(first_lifecycle_id)

    assert %{"lifecycle_id" => second_lifecycle_id} = second_connection
    assert {:ok, ^second_lifecycle_id} = Ecto.UUID.cast(second_lifecycle_id)
    refute first_lifecycle_id == second_lifecycle_id

    assert first_connection == %{
             "lifecycle_id" => first_lifecycle_id,
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           }

    assert second_connection == %{
             "lifecycle_id" => second_lifecycle_id,
             "generation" => 1,
             "reused" => false,
             "reconnected" => false
           }

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1
    assert request.last_error_code == nil

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    metadata_text = inspect({request.request_metadata, first_attempt.response_metadata})
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token"
  end

  @tag :feature_websocket_connection_limit_retry
  test "websocket connection limit retry emits only the eventual exhausted native outcome" do
    connection_limit_failure =
      FakeUpstream.websocket_text_frames([
        CodexPooler.JSON.encode!(%{
          "type" => "error",
          "status" => 400,
          "code" => "websocket_connection_limit_reached",
          "message" => "open a replacement websocket connection"
        })
      ])

    # Strict finite scenario: the first-event connection limit retires the
    # first physical connection and the single retry lands on a replacement
    # connection; a third send fails the fixture as an unexpected extra request.
    upstream =
      start_upstream(
        # provenance: observed findings #116 (type error websocket_connection_limit_reached terminal); rest synthetic
        FakeUpstream.strict_sequence([
          strict_native_request(1, connection_limit_failure),
          strict_native_request(2, connection_limit_failure)
        ])
      )

    setup = gateway_setup(upstream)

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_connection_limit_exhausted_fallback_should_not_run"
        })
      )

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-exhausted-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    capture_stream_outcome_telemetry(fn ->
      assert :ok =
               execute_websocket_response(
                 auth,
                 CodexPooler.JSON.encode!(%{
                   "type" => "response.create",
                   "model" => setup.model.exposed_model_id,
                   "input" =>
                     native_text_input("exhaust the native websocket connection limit retry"),
                   "stream" => true,
                   "generate" => true
                 }),
                 %{request_id: request_id},
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_receive {:stream_outcome,
                      %{
                        outcome: "failed",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      refute_received {:stream_outcome, _metadata}
    end)

    assert_received {:websocket_frame, frame}

    assert %{"type" => "response.failed", "code" => "websocket_connection_limit_reached"} =
             CodexPooler.JSON.decode!(frame)

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.status == "retryable_failed"
    assert first_attempt.retryable == true
    assert second_attempt.status == "failed"
    assert second_attempt.retryable == false
    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.retry_count == 1
    assert request.last_error_code == "websocket_connection_limit_reached"
    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :feature_websocket_connection_limit_retry
  test "websocket connection limit retries after internal rate limit event" do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    # Strict finite scenario: the internal rate-limit event precedes the
    # connection-limit terminal on the first physical connection, and the
    # single retry lands on a replacement connection.
    upstream =
      start_upstream(
        # provenance: observed findings #116 (type error websocket_connection_limit_reached terminal); rest synthetic
        FakeUpstream.strict_sequence([
          strict_native_request(
            1,
            FakeUpstream.websocket_text_frames([
              CodexPooler.JSON.encode!(codex_rate_limits_payload(29, reset_at)),
              CodexPooler.JSON.encode!(%{
                "type" => "error",
                "status" => 400,
                "code" => "websocket_connection_limit_reached",
                "message" => "open a replacement websocket connection"
              })
            ])
          ),
          strict_native_response("resp_ws_connection_limit_after_rate_limits", 2, 4, 3)
        ])
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_connection_limit_after_rate_limits_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-rate-limit-retry-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("retry after internal websocket rate limits"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: request_id, capture_metadata_control?: true},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    frames =
      receive_websocket_frames_by_type(
        ["codex.response.metadata", "codex.rate_limits"],
        @websocket_frame_timeout
      )

    assert %{"type" => "codex.response.metadata"} = frames["codex.response.metadata"]
    assert %{"type" => "codex.rate_limits"} = frames["codex.rate_limits"]

    assert_received {:websocket_frame, retry_metadata_frame}
    assert %{"type" => "codex.response.metadata"} = CodexPooler.JSON.decode!(retry_metadata_frame)

    assert_received {:websocket_frame, frame}

    assert %{"id" => "resp_ws_connection_limit_after_rate_limits"} =
             CodexPooler.JSON.decode!(frame)

    refute_received {:websocket_frame, _unexpected}

    assert FakeUpstream.count(upstream) == 2
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert first_attempt.retryable == true
    assert first_attempt.network_error_code == "websocket_connection_limit_reached"
    assert first_attempt.response_metadata["stream_failure_stage"] == "first_event"

    assert first_attempt.response_metadata["stream_error_code"] ==
             "websocket_connection_limit_reached"

    assert second_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.retry_count == 1
    assert request.last_error_code == nil

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    wait_for_rate_limit_event_tasks()
    assert window = wait_for_rate_limit_event_window(setup.identity, "primary")
    assert window.source == "codex_rate_limit_event"
    assert Decimal.equal?(window.used_percent, Decimal.new("29.0"))
    assert DateTime.compare(window.reset_at, reset_at) == :eq
    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :feature_websocket_connection_limit_retry
  @tag :replay_race
  test "unknown Codex control commits output and prevents websocket retry" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"codex.future_control", %{"type" => "codex.future_control"}},
            {"error",
             %{
               "type" => "error",
               "status" => 400,
               "code" => "websocket_connection_limit_reached",
               "message" => "do not replay visible provider control"
             }}
          ],
          done: false
        )
      )

    fallback_upstream =
      start_upstream(FakeUpstream.json_response(%{"id" => "resp_ws_unknown_control_fallback"}))

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-unknown-control-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    request_id =
      seed_preferring_assignment(
        [setup.assignment.id, fallback.assignment.id],
        setup.assignment.id
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("preserve unknown Codex control visibility"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: request_id, capture_metadata_control?: true},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, metadata_frame}
    assert %{"type" => "codex.response.metadata"} = CodexPooler.JSON.decode!(metadata_frame)

    assert_received {:websocket_frame, provider_frame}
    assert %{"type" => "codex.future_control"} = CodexPooler.JSON.decode!(provider_frame)

    assert_received {:websocket_frame, failed_frame}
    assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(failed_frame)

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.retryable == false

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.retry_count == 0
  end

  defp attached_session_model_fallback_setup(label) do
    pinned_upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "resp_ws_#{label}_model_miss",
                 "error" => %{"code" => "model_not_found", "param" => "model"}
               }
             }}
          ],
          done: false
        )
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_#{label}_model_fallback",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(pinned_upstream, exposed_model_id: "gpt-example-luna")

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-#{label}-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup
    |> Map.put(:fallback, fallback)
    |> Map.put(:pinned_upstream, pinned_upstream)
    |> Map.put(:fallback_upstream, fallback_upstream)
    |> Map.put(
      :model,
      put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
    )
  end

  defp model_fallback_websocket_payload(model, marker) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => model.exposed_model_id,
      "input" => native_text_input("synthetic #{marker} model fallback"),
      "stream" => true,
      "generate" => true
    })
  end

  defp insert_successful_session_turn!(setup, session) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    request =
      request_fixture(setup, %{
        model_id: setup.model.id,
        requested_model: setup.model.exposed_model_id,
        transport: "websocket",
        status: "succeeded",
        usage_status: "usage_known",
        response_status_code: 200,
        completed_at: now
      })

    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      status: "succeeded",
      started_at: now,
      completed_at: now,
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp assert_soft_session_model_fallback!(setup) do
    assert FakeUpstream.count(setup.pinned_upstream) == 1
    assert FakeUpstream.count(setup.fallback_upstream) == 1

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.pool_upstream_assignment_id == setup.assignment.id
    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_model_unavailable"
    assert second_attempt.pool_upstream_assignment_id == setup.fallback.assignment.id
    assert second_attempt.status == "succeeded"

    assert %Request{status: "succeeded", retry_count: 1} =
             Repo.one!(
               from request in Request,
                 where: request.pool_id == ^setup.pool.id and request.transport == "websocket",
                 order_by: [desc: request.admitted_at],
                 limit: 1
             )
  end
end
