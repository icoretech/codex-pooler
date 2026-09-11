defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.TerminalErrorsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, CodexTurn, RoutingCircuitState}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @websocket_frame_timeout 1_000

  @tag :websocket_failure
  @tag :replay_race
  test "websocket terminal upstream failure demotes and circuit fails assignment" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "resp_ws_failed",
                 "error" => %{
                   "code" => "upstream_terminal_failure",
                   "param" => "reasoning.effort"
                 },
                 "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "terminal-failure"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("terminal failure"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-terminal-failure", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(frame)
    assert FakeUpstream.count(upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.transport == "websocket"
    assert request.last_error_code == "upstream_terminal_failure"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "upstream_terminal_failure"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.response_metadata["upstream_error_param"] == "reasoning.effort"

    assert [demotion] = Repo.all(from(d in BridgeDemotion))
    assert demotion.pool_upstream_assignment_id == setup.assignment.id
    assert demotion.reason_code == "upstream_terminal_failure"
    assert demotion.status == "active"

    assert [circuit] =
             Repo.all(from(c in RoutingCircuitState, where: c.route_class == "proxy_websocket"))

    assert circuit.pool_upstream_assignment_id == setup.assignment.id
    assert circuit.reason_code == "upstream_terminal_failure"
    assert circuit.failure_count == 1
  end

  test "websocket context length terminal failure does not demote or circuit the assignment" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "resp_ws_context_too_large",
                 "error" => %{"code" => "context_length_exceeded"},
                 "usage" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "context-large"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("too much context"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-context-too-large", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"type" => "response.failed"} = CodexPooler.JSON.decode!(frame)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "context_length_exceeded"
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "context_length_exceeded"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "native websocket remains reusable after a neutral misalignment policy terminal" do
    previous_owner_forwarding =
      Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_registered_websocket_owner_sessions()

      case previous_owner_forwarding do
        nil ->
          Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)

        value ->
          Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    provider_wording = "Provider policy wording remains transient."

    # Strict finite scenario: the neutral policy terminal and the following
    # ordinary turn both ride the first physical connection, and the trailing
    # generate:false warmup never reaches the upstream; a reconnect, fallback
    # dispatch, or warmup send fails the fixture.
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_request(
            1,
            FakeUpstream.websocket_text_frames([
              CodexPooler.JSON.encode!(%{
                "type" => "response.failed",
                "sequence_number" => 9,
                "headers" => %{"authorization" => "must-not-survive"},
                "response" => %{
                  "id" => "resp_ws_policy_terminal",
                  "status" => "failed",
                  "error" => %{
                    "type" => "provider_policy_type",
                    "code" => "misalignment_policy_violation",
                    "message" => provider_wording,
                    "param" => "provider.policy.param",
                    "provider_sibling" => "native-sentinel"
                  }
                }
              })
            ])
          ),
          strict_native_response("resp_ws_after_policy_terminal", 1, 4, 3)
        ])
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_policy_fallback_must_not_run",
          "object" => "response"
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-policy-fallback",
        compact?: false
      )

    prime_routing_quota!(fallback.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup.pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{sticky_websocket_sessions: false})
    |> Repo.update!()

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    circuit =
      %RoutingCircuitState{
        pool_id: setup.pool.id,
        pool_upstream_assignment_id: setup.assignment.id,
        upstream_identity_id: setup.assignment.upstream_identity_id,
        model_identifier: setup.model.exposed_model_id,
        route_class: "proxy_websocket",
        status: "half_open",
        reason_code: "upstream_5xx",
        failure_count: 3,
        success_count: 0,
        opened_at: DateTime.add(now, -120, :second),
        half_opened_at: now,
        metadata: %{"probe_in_flight_count" => 0},
        created_at: DateTime.add(now, -120, :second),
        updated_at: now
      }
      |> Repo.insert!()

    request_id =
      Enum.find_value(1..500, fn index ->
        seed = "native-policy-reuse-bridge-ring-seed-#{index}"

        preferred =
          [setup.assignment.id, fallback.assignment.id]
          |> Enum.max_by(&rendezvous_score(seed, &1))

        if preferred == setup.assignment.id, do: seed
      end) || raise "missing native policy routing seed for #{setup.assignment.id}"

    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()

    {conn, websocket, ref, _response_headers} =
      public_websocket_connect_with_request_headers!(
        port,
        setup,
        "native-policy-reuse-#{System.unique_integer([:positive])}",
        "/backend-api/codex/responses",
        [{"x-request-id", request_id}]
      )

    try do
      first_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic policy terminal"),
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, first_payload)
      {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "response.failed",
               "sequence_number" => 9,
               "response" => %{
                 "id" => "resp_ws_policy_terminal",
                 "status" => "failed",
                 "error" => %{
                   "type" => "provider_policy_type",
                   "code" => "misalignment_policy_violation",
                   "message" => ^provider_wording,
                   "param" => "provider.policy.param",
                   "provider_sibling" => "native-sentinel"
                 }
               }
             } = CodexPooler.JSON.decode!(frame)

      refute frame =~ "authorization"

      assert_receive {Events,
                      %{
                        reason: "request_finalized",
                        payload: %{
                          "request_id" => failed_request_id,
                          "status" => "failed"
                        }
                      }},
                     @websocket_frame_timeout

      neutral = Repo.reload!(circuit)
      assert neutral.status == "half_open"
      assert neutral.reason_code == "upstream_5xx"
      assert neutral.failure_count == 3
      assert neutral.success_count == 0
      assert neutral.metadata["probe_in_flight_count"] == 0

      circuit_handler_id = "native-policy-circuit-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          circuit_handler_id,
          [:codex_pooler, :gateway, :routing, :circuit, :transition],
          fn _event, _measurements, metadata, _config ->
            if metadata.transition == "half_open_to_closed" and metadata.pool_id == setup.pool.id do
              send(test_pid, {:native_policy_circuit_closed, metadata})
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(circuit_handler_id) end)

      second_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic ordinary turn after policy terminal"),
          "stream" => true,
          "generate" => true
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, second_payload)
      {_conn, _websocket, second_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{"id" => "resp_ws_after_policy_terminal"} = CodexPooler.JSON.decode!(second_frame)

      assert_receive {Events,
                      %{
                        reason: "request_finalized",
                        payload: %{
                          "request_id" => succeeded_request_id,
                          "status" => "succeeded"
                        }
                      }},
                     @websocket_frame_timeout

      assert_receive {:native_policy_circuit_closed,
                      %{
                        pool_upstream_assignment_id: assignment_id,
                        route_class: "proxy_websocket"
                      }},
                     @websocket_frame_timeout

      assert assignment_id == setup.assignment.id

      barrier_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [],
          "stream" => true,
          "generate" => false
        })

      {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, barrier_payload)
      {conn, websocket, barrier_created} = public_websocket_receive_text!(conn, websocket, ref)

      {_conn, _websocket, barrier_completed} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert %{"type" => "response.created"} = CodexPooler.JSON.decode!(barrier_created)
      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(barrier_completed)

      assert [first_upstream_request, second_upstream_request] = FakeUpstream.requests(upstream)
      assert first_upstream_request.method == "WEBSOCKET"
      assert second_upstream_request.method == "WEBSOCKET"

      assert first_upstream_request.websocket_connection_id ==
               second_upstream_request.websocket_connection_id

      assert FakeUpstream.websocket_connection_count(upstream) == 1
      assert FakeUpstream.count(fallback_upstream) == 0

      assert [failed_request, succeeded_request] =
               Repo.all(
                 from(request in Request,
                   where: request.pool_id == ^setup.pool.id,
                   order_by: [asc: request.admitted_at]
                 )
               )

      assert failed_request.id == failed_request_id
      assert failed_request.status == "failed"
      assert failed_request.retry_count == 0
      assert failed_request.last_error_code == "misalignment_policy_violation"

      assert succeeded_request.id == succeeded_request_id
      assert succeeded_request.status == "succeeded"
      assert succeeded_request.retry_count == 0
      assert succeeded_request.last_error_code == nil

      assert [failed_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^failed_request.id))

      assert failed_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert failed_attempt.status == "failed"
      refute failed_attempt.retryable
      assert failed_attempt.network_error_code == "misalignment_policy_violation"

      assert failed_attempt.error_message ==
               "This request was blocked due to a misalignment policy violation."

      assert [succeeded_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^succeeded_request.id))

      assert succeeded_attempt.pool_upstream_assignment_id == setup.assignment.id
      assert succeeded_attempt.status == "succeeded"

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where:
                   entry.request_id == ^failed_request.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where:
                   entry.request_id == ^succeeded_request.id and
                     entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert Repo.all(from(d in BridgeDemotion)) == []

      updated = Repo.reload!(circuit)
      assert updated.status == "closed"
      assert updated.reason_code == nil
      assert updated.failure_count == 0
      assert updated.success_count == 1
      assert updated.metadata["probe_in_flight_count"] == 0

      persisted =
        inspect(
          {failed_request.request_metadata, failed_attempt.response_metadata,
           succeeded_request.request_metadata, succeeded_attempt.response_metadata,
           RequestLogs.list(setup.pool)}
        )

      refute persisted =~ provider_wording
      refute persisted =~ "provider.policy.param"
      refute persisted =~ "provider_policy_type"
      assert :ok = FakeUpstream.verify!(upstream)
    after
      Mint.HTTP.close(conn)
    end
  end

  test "websocket invalid first-present error param does not fall back or persist raw values" do
    raw_sentinel = "raw-param-sentinel"

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{
               "type" => "response.failed",
               "response" => %{
                 "id" => "resp_ws_invalid_param",
                 "error" => %{
                   "code" => "unsupported_value",
                   "param" => "invalid param #{raw_sentinel}",
                   "message" => raw_sentinel
                 }
               },
               "error" => %{"param" => "reasoning.effort"}
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("invalid safe parameter precedence"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-invalid-error-param"},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, _frame}
    assert [attempt] = Repo.all(from(a in Attempt))
    refute Map.has_key?(attempt.response_metadata, "upstream_error_param")
    refute inspect(attempt.response_metadata) =~ raw_sentinel
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket top-level upstream error is canonicalized for Codex clients" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "sequence_number" => 1,
               "error" => %{
                 "code" => "context_length_exceeded",
                 "message" => "Input exceeds this model context window."
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "context-large"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("too much context"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-top-level-context-error", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "context_length_exceeded"}}
           } = CodexPooler.JSON.decode!(frame)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "context_length_exceeded"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "context_length_exceeded"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket wrapped status_code previous response error is masked without replaying or circuiting" do
    reset_at = DateTime.utc_now() |> DateTime.add(30, :minute) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "status_code" => 400,
               "error" => %{
                 "code" => "previous_response_not_found",
                 "message" => "Previous response with id 'resp_status_code_missing' not found.",
                 "param" => "previous_response_id"
               },
               "headers" => %{
                 "X-Request-ID" => "ws-frame-previous-request",
                 "X-Codex-Primary-Used-Percent" => 81,
                 "X-Codex-Primary-Window-Minutes" => 300,
                 "X-Codex-Primary-Reset-At" => DateTime.to_iso8601(reset_at),
                 "Should-Not-Persist" => "synthetic-sentinel"
               }
             }}
          ],
          done: false
        )
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_status_code_previous_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-status-code-fallback",
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

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "status-code-missing-previous"})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{"type" => "message", "role" => "user", "content" => "continue"}
                 ],
                 "stream" => true,
                 "generate" => true
               }),
               %{
                 request_id: "ws-status-code-previous-response-not-found",
                 codex_session: session
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert CodexPooler.JSON.decode!(frame) == native_previous_response_retry_event()

    refute frame =~ "resp_status_code_missing"
    refute frame =~ "headers"
    refute frame =~ "ws-frame-previous-request"
    refute frame =~ "synthetic-sentinel"

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert [_request] = FakeUpstream.requests(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "stream_incomplete"
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert attempt.response_metadata["websocket_frame_headers"] == %{
             "x-codex-primary-reset-at" => DateTime.to_iso8601(reset_at),
             "x-codex-primary-used-percent" => "81",
             "x-codex-primary-window-minutes" => "300",
             "x-request-id" => "ws-frame-previous-request"
           }

    refute attempt.response_metadata["upstream_error_code"] == "error"

    assert window = wait_for_response_header_window(setup.identity, "primary")
    assert window.source == "codex_response_headers"
    assert Decimal.eq?(window.used_percent, Decimal.new("81"))

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket multiline previous response error frame is masked without replaying or circuiting" do
    previous_response_id = "resp_multiline_missing"
    request_content = "multiline previous response request content sentinel"

    raw_upstream_frame =
      CodexPooler.JSON.encode!(
        %{
          "type" => "error",
          "status" => 400,
          "error" => %{
            "type" => "invalid_request_error",
            "code" => "previous_response_not_found",
            "param" => "previous_response_id",
            "message" =>
              "Previous response with id '#{previous_response_id}' not found for #{request_content}."
          },
          "headers" => %{
            "X-Request-ID" => "ws-multiline-previous-request",
            "Authorization" => "synthetic-auth-redacted",
            "Should-Not-Persist" => "synthetic-sentinel",
            "X-Arbitrary-Debug" => ["drop-array"]
          }
        },
        pretty: true
      )

    assert raw_upstream_frame =~ "
"

    upstream = start_upstream(FakeUpstream.websocket_text_frames([raw_upstream_frame]))

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_multiline_previous_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-multiline-fallback",
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

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "multiline-missing-previous"})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{"type" => "message", "role" => "user", "content" => request_content}
                 ],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-multiline-previous-response-not-found", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert CodexPooler.JSON.decode!(frame) == native_previous_response_retry_event()

    refute frame =~ previous_response_id
    refute frame =~ request_content
    refute frame =~ raw_upstream_frame
    refute frame =~ "headers"
    refute frame =~ "synthetic-auth-redacted"
    refute frame =~ "synthetic-sentinel"
    refute frame =~ "drop-array"

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert [captured] = FakeUpstream.requests(upstream)
    refute Map.has_key?(captured.json, "previous_response_id")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "stream_incomplete"
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])
    refute Map.has_key?(request.request_metadata || %{}, "websocket_frame_headers")

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert attempt.response_metadata["websocket_frame_headers"] == %{
             "x-request-id" => "ws-multiline-previous-request"
           }

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ raw_upstream_frame
    refute metadata_text =~ previous_response_id
    refute metadata_text =~ request_content
    refute metadata_text =~ "synthetic-auth-redacted"
    refute metadata_text =~ "synthetic-sentinel"
    refute metadata_text =~ "drop-array"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket wrapped status_code rate limit error records useful upstream metadata" do
    reset_at = DateTime.utc_now() |> DateTime.add(90, :minute) |> DateTime.truncate(:second)

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "status_code" => 429,
               "error" => %{
                 "code" => "rate_limit_exceeded",
                 "message" => "rate limited"
               },
               "headers" => %{
                 "OpenAI-Request-ID" => "ws-frame-openai-request",
                 "X-Codex-Rate-Limit-Reached-Type" => "workspace_member_usage_limit_reached",
                 "X-Codex-Primary-Used-Percent" => 96,
                 "X-Codex-Primary-Window-Minutes" => 300,
                 "X-Codex-Primary-Reset-At" => DateTime.to_iso8601(reset_at),
                 "Authorization" => "synthetic-auth-redacted",
                 "Set-Cookie" => "synthetic-session-cookie=drop",
                 "Should-Not-Persist" => "synthetic-sentinel",
                 "X-Arbitrary-Debug" => "drop-me",
                 "X-Request-ID" => ["drop-array"]
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "rate-limit"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("hit a websocket rate limit"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-status-code-rate-limit", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "rate_limit_exceeded"}}
           } = CodexPooler.JSON.decode!(frame)

    refute frame =~ ~s("code":"error")
    refute frame =~ "stream_incomplete"
    refute frame =~ "headers"
    refute frame =~ "ws-frame-openai-request"
    refute frame =~ "synthetic-auth-redacted"
    refute frame =~ "synthetic-session-cookie"
    refute frame =~ "synthetic-sentinel"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "rate_limit_exceeded"
    refute Map.has_key?(request.request_metadata || %{}, "websocket_frame_headers")

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "rate_limit_exceeded"
    assert attempt.response_metadata["error_kind"] == "rate_limit_exceeded"
    assert attempt.response_metadata["status_code"] == 200

    assert attempt.response_metadata["websocket_frame_headers"] == %{
             "openai-request-id" => "ws-frame-openai-request",
             "x-codex-primary-reset-at" => DateTime.to_iso8601(reset_at),
             "x-codex-primary-used-percent" => "96",
             "x-codex-primary-window-minutes" => "300",
             "x-codex-rate-limit-reached-type" => "workspace_member_usage_limit_reached"
           }

    refute attempt.response_metadata["upstream_error_code"] == "error"
    refute Map.has_key?(attempt.response_metadata, "masked_error_code")

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "synthetic-auth-redacted"
    refute metadata_text =~ "synthetic-session-cookie"
    refute metadata_text =~ "synthetic-sentinel"
    refute metadata_text =~ "drop-me"

    assert window = wait_for_response_header_window(setup.identity, "primary")
    assert window.source == "codex_response_headers"
    assert Decimal.eq?(window.used_percent, Decimal.new("96"))
    assert window.metadata["rate_limit_reached_type"] == "workspace_member_usage_limit_reached"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "rate_limit_exceeded"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  test "websocket wrapped status_code message-only server error fails safely without raw body metadata" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "status_code" => 500,
               "message" => "upstream failed"
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "server-error"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("trigger websocket server error"),
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-status-code-message-only-server-error", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{
               "error" => %{"code" => "server_error", "message" => "upstream failed"}
             }
           } = CodexPooler.JSON.decode!(frame)

    refute frame =~ ~s("code":"error")
    refute frame =~ "stream_incomplete"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "server_error"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "server_error"
    assert attempt.response_metadata["error_kind"] == "server_error"
    assert attempt.response_metadata["status_code"] == 200
    refute attempt.response_metadata["upstream_error_code"] == "error"
    refute Map.has_key?(attempt.response_metadata, "masked_error_code")

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ ~s("type":"error")
    refute metadata_text =~ ~s("status_code":500)
    refute metadata_text =~ "upstream failed"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ "upstream-token"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "server_error"
  end

  test "websocket previous response terminal failure is masked without replaying or circuiting" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"error",
             %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "type" => "invalid_request_error",
                 "param" => "previous_response_id",
                 "message" => "Previous response with id 'resp_missing' not found."
               }
             }}
          ],
          done: false
        )
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_previous_missing_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-fallback", compact?: false)

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "missing-previous"})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{"type" => "message", "role" => "user", "content" => "continue"}
                 ],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-previous-response-not-found", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "stream_incomplete"}}
           } = CodexPooler.JSON.decode!(frame)

    assert attempt = Repo.one(from(a in Attempt))
    assert attempt.transport == "websocket"

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert [_request] = FakeUpstream.requests(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "stream_incomplete"
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  for upstream_code <- ["previous_response_not_found", "invalid_previous_response_id"] do
    @upstream_code upstream_code
    @tag :continuation_generation_boundary
    test "websocket handles explicit #{upstream_code} without replaying or circuiting" do
      upstream_code = @upstream_code
      upstream_message_sentinel = "private upstream generation boundary message"
      upstream_header_sentinel = "private-upstream-generation-boundary-header"
      request_content_sentinel = "private generation boundary request content"

      upstream =
        start_upstream(
          FakeUpstream.sse_stream(
            [
              {"error",
               %{
                 "type" => "error",
                 "status" => 400,
                 "error" => %{
                   "type" => "invalid_request_error",
                   "code" => upstream_code,
                   "message" => upstream_message_sentinel
                 },
                 "headers" => %{
                   "Authorization" => "Bearer #{upstream_header_sentinel}",
                   "Should-Not-Persist" => upstream_header_sentinel
                 }
               }}
            ],
            done: false
          )
        )

      fallback_upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_ws_explicit_previous_fallback_should_not_run",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream)

      fallback =
        gateway_upstream(setup.pool, fallback_upstream, "upstream-token-explicit-fallback",
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

      {:ok, session} =
        Gateway.start_codex_session(auth, %{accepted_turn_state: "explicit-#{upstream_code}"})

      session =
        session
        |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
        |> Repo.update!()

      assert :ok =
               execute_websocket_response(
                 auth,
                 CodexPooler.JSON.encode!(%{
                   "type" => "response.create",
                   "model" => setup.model.exposed_model_id,
                   "input" => [
                     %{
                       "type" => "message",
                       "role" => "user",
                       "content" => request_content_sentinel
                     }
                   ],
                   "stream" => true,
                   "generate" => true
                 }),
                 %{request_id: "ws-explicit-#{upstream_code}", codex_session: session},
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_received {:websocket_frame, frame}

      decoded_frame = CodexPooler.JSON.decode!(frame)

      if upstream_code == "previous_response_not_found" do
        assert decoded_frame == native_previous_response_retry_event()
      else
        assert %{
                 "type" => "response.failed",
                 "response" => %{
                   "error" => %{
                     "code" => "stream_incomplete",
                     "message" => "upstream stream incomplete"
                   }
                 }
               } = decoded_frame

        refute frame =~ upstream_code
      end

      refute frame =~ "resp_explicit_"
      refute frame =~ upstream_message_sentinel
      refute frame =~ upstream_header_sentinel
      refute frame =~ request_content_sentinel

      assert FakeUpstream.count(upstream) == 1
      assert FakeUpstream.count(fallback_upstream) == 0
      assert [_request] = FakeUpstream.requests(upstream)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "failed"
      assert request.response_status_code == 200
      assert request.last_error_code == "stream_incomplete"
      refute get_in(request.request_metadata, ["routing", "demotion_reason"])

      assert [attempt] = Repo.all(from(a in Attempt))
      assert attempt.network_error_code == "stream_incomplete"
      assert attempt.response_metadata["upstream_error_code"] == upstream_code
      assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

      metadata_text = inspect({request.request_metadata, attempt.response_metadata})
      refute metadata_text =~ upstream_message_sentinel
      refute metadata_text =~ upstream_header_sentinel
      refute metadata_text =~ request_content_sentinel
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ "upstream-token-explicit-fallback"

      assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
      assert turn.status == "failed"
      assert turn.error_code == "stream_incomplete"

      assert Repo.all(from(d in BridgeDemotion)) == []
      assert Repo.all(from(c in RoutingCircuitState)) == []
    end
  end

  test "websocket previous response terminal failure after partial output is masked without replaying" do
    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.output_text.delta",
             %{"type" => "response.output_text.delta", "delta" => "partial"}},
            {"error",
             %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "type" => "invalid_request_error",
                 "param" => "previous_response_id",
                 "message" => "Previous response with id 'resp_partial_missing' not found."
               }
             }}
          ],
          done: false
        )
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_partial_missing_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-fallback", compact?: false)

    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "partial-missing"})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [
                   %{"type" => "message", "role" => "user", "content" => "continue"}
                 ],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-partial-previous-response-not-found", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, partial_frame}

    assert %{"type" => "response.output_text.delta", "delta" => "partial"} =
             CodexPooler.JSON.decode!(partial_frame)

    assert_received {:websocket_frame, terminal_frame}

    assert %{
             "type" => "response.failed",
             "response" => %{
               "error" => %{
                 "code" => "stream_incomplete",
                 "message" => "upstream stream incomplete"
               }
             }
           } = CodexPooler.JSON.decode!(terminal_frame)

    refute terminal_frame =~ "previous_response_not_found"
    refute terminal_frame =~ "resp_partial_missing"

    assert FakeUpstream.count(upstream) == 1
    assert FakeUpstream.count(fallback_upstream) == 0
    assert [_request] = FakeUpstream.requests(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 200
    assert request.last_error_code == "stream_incomplete"
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.network_error_code == "stream_incomplete"
    assert attempt.response_metadata["upstream_error_code"] == "previous_response_not_found"
    assert attempt.response_metadata["masked_error_code"] == "stream_incomplete"

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.status == "failed"
    assert turn.error_code == "stream_incomplete"

    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []
  end

  defp wait_for_response_header_window(identity, window_kind, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    identity
    |> QuotaWindows.list_quota_windows()
    |> Enum.find(&(&1.source == "codex_response_headers" and &1.window_kind == window_kind))
    |> case do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> wait_for_response_header_window(identity, window_kind, deadline)
          end
        else
          flunk("expected Codex response header quota window for #{window_kind}")
        end

      window ->
        window
    end
  end
end
