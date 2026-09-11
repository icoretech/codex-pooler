defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.SessionContinuityTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream

  alias CodexPooler.Gateway.Persistence.{
    BridgeAffinity,
    BridgeDemotion,
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPoolerWeb.CodexResponsesSocket

  @tag :bridge_ring
  test "websocket response dispatch keeps DB-backed sticky affinity for a persisted session" do
    first_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_first",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    second_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_second",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(first_upstream)

    second =
      gateway_upstream(setup.pool, second_upstream, "upstream-token-second", compact?: false)

    prime_routing_quota!(second.identity)

    model =
      put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])

    setup = Map.put(setup, :model, model)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-affinity"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("first ws")
               }),
               %{request_id: "ws-affinity-first", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, :first, frame}) end
             )

    assert_received {:websocket_frame, :first, first_frame}
    first_body = CodexPooler.JSON.decode!(first_frame)

    first_assignment =
      assignment_for_response(first_body["id"], setup.assignment, second.assignment)

    setup.pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{
      routing_strategy: "least_recent_success",
      updated_at: DateTime.utc_now()
    })
    |> Repo.update!()

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("second ws")
               }),
               %{request_id: "ws-affinity-second", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, :second, frame}) end
             )

    assert_received {:websocket_frame, :second, second_frame}
    second_body = CodexPooler.JSON.decode!(second_frame)

    second_assignment =
      assignment_for_response(second_body["id"], setup.assignment, second.assignment)

    assert second_assignment.id == first_assignment.id
    assert Repo.aggregate(BridgeAffinity, :count) == 1

    assert [request | _rest] =
             Repo.all(from request in Request, order_by: [desc: request.admitted_at])

    assert request.request_metadata["routing"]["strategy"] == "least_recent_success"
    assert request.request_metadata["routing"]["affinity_status"] == "hit"
    assert request.request_metadata["routing"]["affinity_kind"] == "codex_session"

    assert request.request_metadata["routing"]["selected_bridge_candidate_id"] ==
             first_assignment.id

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ "second ws"
    refute metadata_text =~ "resp_ws_second"
  end

  @tag :websocket_session_assignment_unavailable
  test "websocket continuation fails closed when the persisted session assignment is unavailable" do
    first_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_unavailable_first",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    second_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_unavailable_second_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(first_upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-unavailable"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("first ws")
               }),
               %{request_id: "ws-unavailable-first", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, :first, frame}) end
             )

    assert_received {:websocket_frame, :first, first_frame}
    assert %{"id" => "resp_ws_unavailable_first"} = CodexPooler.JSON.decode!(first_frame)

    persisted_session = Repo.get!(CodexSession, session.id)
    assert persisted_session.pool_upstream_assignment_id == setup.assignment.id

    second =
      gateway_upstream(setup.pool, second_upstream, "upstream-token-second", compact?: false)

    prime_routing_quota!(second.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
      )

    assert {:ok, _assignment} =
             PoolAssignments.disable_pool_assignment(setup.assignment)

    assert {:error, %{code: "pinned_continuation_unavailable", status: 503} = error} =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("second ws"),
                 "previous_response_id" => "resp_ws_unavailable_first"
               }),
               %{request_id: "ws-unavailable-second", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, :second, frame}) end
             )

    assert error.retryable == false
    assert error.requires_new_upstream_session == true
    assert error.recovery["kind"] == "restart_with_full_context"

    assert error.continuity_denial == %{
             "denial_family" => "pinned_continuation_unavailable",
             "continuity_family" => "pinned_codex_session",
             "pin_mode" => "hard",
             "pin_reason" => "previous_response_id",
             "internal_reason" => "assignment_unavailable",
             "pool_upstream_assignment_id" => setup.assignment.id,
             "upstream_identity_id" => setup.identity.id
           }

    refute_received {:websocket_frame, :second, _frame}
    assert FakeUpstream.count(second_upstream) == 0

    assert [denied_request] =
             Repo.all(
               from request in Request,
                 where: request.correlation_id == "ws-unavailable-second"
             )

    assert denied_request.status == "rejected"
    assert denied_request.last_error_code == "pinned_continuation_unavailable"
    refute denied_request.last_error_code == "stream_incomplete"

    metadata_text = inspect(denied_request.request_metadata || %{})
    refute metadata_text =~ "second ws"
    refute metadata_text =~ "resp_ws_unavailable_first"
  end

  @tag :websocket_pinned_reauth_recovery
  test "websocket pinned reauth continuation returns in-frame recovery without fallback or owner replacement" do
    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_pinned_reauth_should_not_dispatch",
          "object" => "response"
        })
      )

    fresh_start_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_pinned_reauth_fresh_start_should_not_dispatch",
          "object" => "response"
        })
      )

    setup = gateway_setup(pinned_upstream)

    fresh_start =
      gateway_upstream(
        setup.pool,
        fresh_start_upstream,
        "upstream-token-ws-pinned-reauth-fresh-start",
        compact?: false
      )

    prime_routing_quota!(fresh_start.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fresh_start.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "turn-ws-pinned-reauth-#{System.unique_integer([:positive])}"
    previous_response_id = "resp_ws_pinned_reauth_#{System.unique_integer([:positive])}"
    visible_input = "visible websocket pinned reauth context must not persist"

    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: turn_state})
    session = pin_session_to_assignment!(session, setup.assignment)

    assert :ok =
             Gateway.register_codex_session_continuity(
               session,
               %{},
               %{"id" => previous_response_id}
             )

    lease_before = active_owner_lease_for_session!(session.id)
    mark_pinned_assignment_reauth_required!(setup)

    assert {:ok, state} =
             CodexResponsesSocket.init(%{
               auth: auth,
               opts: %{
                 request_id: "ws-pinned-reauth-frame",
                 accepted_turn_state: turn_state,
                 client_ip: "127.0.0.1"
               }
             })

    try do
      assert state.codex_session.id == session.id
      assert_owner_lease_not_replaced!(session.id, lease_before)

      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input(visible_input),
          "stream" => true,
          "generate" => true,
          "previous_response_id" => previous_response_id
        })

      {error_frame, logs} =
        capture_native_turn_warning(fn ->
          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, error_frame}, _state_after} = receive_socket_done(state)
          error_frame
        end)

      assert_native_turn_warnings(logs, 1)

      assert_pinned_reauth_websocket_frame!(error_frame)
      refute error_frame =~ previous_response_id
      refute error_frame =~ visible_input
      refute error_frame =~ setup.authorization
      refute error_frame =~ setup.raw_key
      refute error_frame =~ "Bearer "

      assert FakeUpstream.count(pinned_upstream) == 0
      assert FakeUpstream.count(fresh_start_upstream) == 0
      assert_pinned_reauth_rejected_request!("ws-pinned-reauth-frame")
      assert Repo.aggregate(Attempt, :count) == 0

      metadata_text = inspect(Accounting.list_request_logs(setup.pool))
      refute metadata_text =~ previous_response_id
      refute metadata_text =~ visible_input
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.raw_key
      assert_owner_lease_not_replaced!(session.id, lease_before)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :websocket_pinned_reauth_recovery
  test "websocket frame previous_response_id recovers pinned session before using fresh socket session" do
    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_frame_alias_pinned_should_not_dispatch",
          "object" => "response"
        })
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_frame_alias_fallback_should_not_dispatch",
          "object" => "response"
        })
      )

    setup = gateway_setup(pinned_upstream)

    fallback =
      gateway_upstream(
        setup.pool,
        fallback_upstream,
        "upstream-token-ws-frame-alias-fallback",
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
    source_turn_state = "turn-ws-frame-alias-source-#{System.unique_integer([:positive])}"
    fresh_turn_state = "turn-ws-frame-alias-fresh-#{System.unique_integer([:positive])}"
    previous_response_id = "resp_ws_frame_alias_#{System.unique_integer([:positive])}"
    visible_tool_output = "visible websocket frame alias output must not persist"

    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: source_turn_state})
    session = pin_session_to_assignment!(session, setup.assignment)

    assert :ok =
             Gateway.register_codex_session_continuity(
               session,
               %{},
               CodexPooler.JSON.encode!(%{"id" => previous_response_id})
             )

    mark_pinned_assignment_reauth_required!(setup)

    assert {:ok, state} =
             CodexResponsesSocket.init(%{
               auth: auth,
               opts: %{
                 request_id: "ws-frame-alias-pinned-reauth",
                 accepted_turn_state: fresh_turn_state,
                 client_ip: "127.0.0.1"
               }
             })

    try do
      assert state.codex_session.id != session.id

      payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "future_tool_call_output",
              "call_id" => "call_ws_frame_alias",
              "output" => visible_tool_output
            }
          ],
          "stream" => true,
          "generate" => true,
          "previous_response_id" => previous_response_id
        })

      {error_frame, logs} =
        capture_native_turn_warning(fn ->
          assert {:ok, state} = CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state)
          assert {:push, {:text, error_frame}, _state_after} = receive_socket_done(state)
          error_frame
        end)

      assert_native_turn_warnings(logs, 1)

      assert_pinned_reauth_websocket_frame!(error_frame)
      refute error_frame =~ previous_response_id
      refute error_frame =~ visible_tool_output
      refute error_frame =~ setup.authorization
      refute error_frame =~ setup.raw_key
      refute error_frame =~ "Bearer "

      assert FakeUpstream.count(pinned_upstream) == 0
      assert FakeUpstream.count(fallback_upstream) == 0
      assert_pinned_reauth_rejected_request!("ws-frame-alias-pinned-reauth")
      assert Repo.aggregate(Attempt, :count) == 0

      metadata_text = inspect(Accounting.list_request_logs(setup.pool))
      refute metadata_text =~ previous_response_id
      refute metadata_text =~ visible_tool_output
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.raw_key
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :websocket_pinned_reauth_recovery
  test "websocket per-message dispatch returns pinned reauth recovery without fallback attempts" do
    pinned_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_pinned_reauth_dispatch_should_not_run",
          "object" => "response"
        })
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_pinned_reauth_fallback_should_not_run",
          "object" => "response"
        })
      )

    setup = gateway_setup(pinned_upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-ws-pinned-reauth-fallback",
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
    previous_response_id = "resp_ws_pinned_dispatch_#{System.unique_integer([:positive])}"
    visible_tool_output = "visible websocket tool output must not persist"

    {:ok, session} =
      Gateway.start_codex_session(auth, %{previous_response_id: previous_response_id})

    session = pin_session_to_assignment!(session, setup.assignment)
    mark_pinned_assignment_reauth_required!(setup)

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{
            "type" => "future_tool_call_output",
            "call_id" => "call_ws_pinned_reauth",
            "output" => visible_tool_output
          }
        ],
        "stream" => true,
        "generate" => true,
        "previous_response_id" => previous_response_id
      })

    assert {:error, error} =
             execute_websocket_response(
               auth,
               payload,
               %{
                 request_id: "ws-pinned-reauth-dispatch",
                 codex_session: session,
                 previous_response_id: previous_response_id
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_pinned_reauth_gateway_error!(error)
    refute_received {:websocket_frame, _frame}
    assert FakeUpstream.count(pinned_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 0
    assert_pinned_reauth_rejected_request!("ws-pinned-reauth-dispatch")
    assert Repo.aggregate(Attempt, :count) == 0

    metadata_text = inspect({error, Accounting.list_request_logs(setup.pool)})
    refute metadata_text =~ previous_response_id
    refute metadata_text =~ visible_tool_output
    refute metadata_text =~ "call_ws_pinned_reauth"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "upstream-token"
  end

  @tag :websocket_resume
  test "websocket reconnect resumes the same durable alias and owner lease before expiry" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_resume",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "stable-ws-resume"

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: turn_state,
        session_header: "session-resume",
        owner_instance_id: "node-a"
      })

    assert [turn_alias] =
             Repo.all(
               from alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^session.id and
                     alias_record.alias_kind == "turn_state"
             )

    assert turn_alias.alias_hash == :crypto.hash(:sha256, turn_state)

    assert [lease] =
             Repo.all(
               from lease in BridgeOwnerLease,
                 where: lease.codex_session_id == ^session.id and lease.status == "active"
             )

    assert lease.owner_instance_id == "node-a"

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("resume first")
               }),
               %{
                 request_id: "ws-resume-first",
                 codex_session: session,
                 accepted_turn_state: turn_state
               },
               fn frame -> send(self(), {:websocket_frame, :first, frame}) end
             )

    assert_received {:websocket_frame, :first, first_frame}
    assert %{"id" => "resp_ws_resume"} = CodexPooler.JSON.decode!(first_frame)

    Gateway.interrupt_codex_session(session, %{reconnect_window_seconds: 300})

    {:ok, resumed} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: turn_state,
        session_header: "session-resume",
        owner_instance_id: "node-a"
      })

    assert resumed.id == session.id

    assert [renewed_lease] =
             Repo.all(
               from lease in BridgeOwnerLease,
                 where: lease.codex_session_id == ^session.id and lease.status == "active"
             )

    assert renewed_lease.id == lease.id
    assert renewed_lease.lease_token == lease.lease_token
    assert DateTime.compare(renewed_lease.renewed_at, lease.renewed_at) in [:gt, :eq]

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             1
  end

  @tag :http_websocket_continuity
  test "HTTP response id continuity resumes the same durable session for websocket", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_http_to_ws",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> put_req_header("x-codex-turn-state", "http-turn-state")
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("http continuity")
      })

    assert %{"id" => "resp_http_to_ws"} = json_response(conn, 200)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert [http_session] = Repo.all(from(session in CodexSession))

    assert [response_alias] =
             Repo.all(
               from alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^http_session.id and
                     alias_record.alias_kind == "previous_response_id"
             )

    assert response_alias.alias_hash == :crypto.hash(:sha256, "resp_http_to_ws")
    refute inspect(response_alias) =~ "resp_http_to_ws"
    refute inspect(response_alias) =~ "http continuity"

    {:ok, websocket_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "new-websocket-turn-state",
        previous_response_id: "resp_http_to_ws",
        owner_instance_id: "node-ws"
      })

    assert websocket_session.id == http_session.id

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "previous_response_id" => "resp_http_to_ws",
                 "input" => native_text_input("ws continuity")
               }),
               %{
                 request_id: "ws-continuity-turn",
                 codex_session: websocket_session,
                 previous_response_id: "resp_http_to_ws"
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_http_to_ws"} = CodexPooler.JSON.decode!(frame)

    assert websocket_request =
             Enum.find(
               FakeUpstream.requests(upstream),
               &(&1.json["previous_response_id"] == "resp_http_to_ws")
             )

    assert websocket_request.json["previous_response_id"] == "resp_http_to_ws"

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^http_session.id),
             :count
           ) ==
             2
  end

  test "HTTP response id continuity refreshes sticky session quota before fallback candidates", %{
    conn: conn
  } do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    stale_quota_response = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 12,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900,
          "reset_at" => DateTime.to_unix(reset_at)
        }
      }
    }

    first_stale_upstream =
      start_upstream({:path_json, %{"/backend-api/wham/usage" => {200, stale_quota_response}}})

    second_stale_upstream =
      start_upstream({:path_json, %{"/backend-api/wham/usage" => {200, stale_quota_response}}})

    sticky_upstream =
      start_upstream(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, stale_quota_response},
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_sticky_refreshed_quota",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }}
         }}
      )

    setup = gateway_setup(first_stale_upstream, quota?: false)

    second_stale =
      gateway_upstream(setup.pool, second_stale_upstream, "upstream-token-second-stale",
        compact?: false
      )

    sticky =
      gateway_upstream(setup.pool, sticky_upstream, "upstream-token-sticky", compact?: false)

    prime_stale_routing_quota!(setup.identity)
    prime_stale_routing_quota!(second_stale.identity)
    prime_stale_routing_quota!(sticky.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [
          setup.assignment,
          second_stale.assignment,
          sticky.assignment
        ])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{previous_response_id: "resp_sticky_previous"})

    session
    |> Ecto.Changeset.change(%{pool_upstream_assignment_id: sticky.assignment.id})
    |> Repo.update!()

    {:ok, resumed_session} =
      Gateway.start_codex_session(auth, %{previous_response_id: "resp_sticky_previous"})

    assert resumed_session.id == session.id
    assert resumed_session.pool_upstream_assignment_id == sticky.assignment.id

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "previous_response_id" => "resp_sticky_previous",
        "input" => native_text_input("recover sticky session quota")
      })

    assert %{"id" => "resp_sticky_refreshed_quota"} = json_response(conn, 200)

    assert [] = FakeUpstream.requests(first_stale_upstream)
    assert [] = FakeUpstream.requests(second_stale_upstream)

    {_usage_request, response_request} = assert_usage_probe_then_response(sticky_upstream)
    assert response_request.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.request_metadata["codex_session_id"] == session.id
    assert get_in(request.request_metadata, ["quota_decision", "refreshed_stale_quota"]) == true

    assert get_in(request.request_metadata, ["routing", "selected_bridge_candidate_id"]) ==
             sticky.assignment.id

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.pool_upstream_assignment_id == sticky.assignment.id
  end

  test "live upstream websocket continuity refreshes stale sticky quota before rejection" do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    exhausted_quota_response = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 100,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900,
          "reset_at" => DateTime.to_unix(reset_at)
        }
      }
    }

    sticky_upstream =
      start_upstream(
        {:path_json, %{"/backend-api/wham/usage" => {200, exhausted_quota_response}}}
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_live_anchor_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(sticky_upstream, quota?: false)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-ws-live-anchor-fallback",
        compact?: false
      )

    prime_stale_routing_quota!(setup.identity)
    prime_routing_quota!(fallback.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "live-ws-quota"})
    pin_session_to_assignment!(session, setup.assignment)
    {:ok, upstream_websocket_session} = UpstreamWebsocketSession.start_link()

    try do
      assert {:error, %{code: "pinned_continuation_unavailable"} = error} =
               execute_websocket_response(
                 auth,
                 CodexPooler.JSON.encode!(%{
                   "type" => "response.create",
                   "model" => setup.model.exposed_model_id,
                   "input" => native_text_input("live upstream websocket quota rejection"),
                   "stream" => true,
                   "generate" => true
                 }),
                 %{
                   request_id: "ws-live-stale-quota",
                   codex_session: session,
                   upstream_websocket_session: upstream_websocket_session
                 },
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert error.retryable == false
      assert error.requires_new_upstream_session == true
      assert error.recovery["kind"] == "restart_with_full_context"

      assert error.continuity_denial == %{
               "denial_family" => "pinned_continuation_unavailable",
               "continuity_family" => "pinned_codex_session",
               "pin_mode" => "hard",
               "pin_reason" => "live_upstream_websocket",
               "internal_reason" => "quota_exhausted",
               "pool_upstream_assignment_id" => setup.assignment.id,
               "upstream_identity_id" => setup.identity.id
             }
    after
      UpstreamWebsocketSession.close(upstream_websocket_session)
    end

    refute_received {:websocket_frame, _frame}
    assert_usage_probe_requests(sticky_upstream)
    assert FakeUpstream.requests(fallback_upstream) == []
    assert Repo.aggregate(Attempt, :count) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.transport == "websocket"
    assert request.last_error_code == "pinned_continuation_unavailable"
  end

  test "HTTP response id continuity survives expired owner leases", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_http_expired_lease",
          "object" => "response",
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
        })
      )

    setup = gateway_setup(upstream)

    conn =
      conn
      |> auth(setup)
      |> put_req_header("x-codex-turn-state", "http-expired-lease-turn")
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("http continuity past lease")
      })

    assert %{"id" => "resp_http_expired_lease"} = json_response(conn, 200)
    assert [http_session] = Repo.all(from(session in CodexSession))

    expired_at = DateTime.add(DateTime.utc_now(), -30, :second) |> DateTime.truncate(:microsecond)

    http_session
    |> Ecto.Changeset.change(%{owner_lease_expires_at: expired_at})
    |> Repo.update!()

    BridgeOwnerLease
    |> where([lease], lease.codex_session_id == ^http_session.id)
    |> Repo.update_all(set: [expires_at: expired_at, updated_at: expired_at])

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, resumed_session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "later-http-turn-state",
        previous_response_id: "resp_http_expired_lease",
        owner_instance_id: "node-after-http-lease"
      })

    assert resumed_session.id == http_session.id
    assert DateTime.compare(resumed_session.owner_lease_expires_at, expired_at) == :gt

    assert [%BridgeOwnerLease{owner_instance_id: "node-after-http-lease", status: "active"}] =
             Repo.all(
               from lease in BridgeOwnerLease,
                 where: lease.codex_session_id == ^http_session.id and lease.status == "active"
             )
  end

  @tag :demoted_owner
  test "demoted backend does not receive the next websocket turn" do
    demoted_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_demoted_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    active_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_after_demotion",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(demoted_upstream)

    second =
      gateway_upstream(setup.pool, active_upstream, "upstream-token-second", compact?: false)

    prime_routing_quota!(second.identity)

    model =
      put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])

    setup = Map.put(setup, :model, model)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "demotion-turn"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %BridgeDemotion{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      model_identifier: setup.model.exposed_model_id,
      pool_upstream_assignment_id: setup.assignment.id,
      upstream_identity_id: setup.identity.id,
      reason_code: "upstream_5xx",
      status: "active",
      demoted_until: DateTime.add(now, 60, :second),
      attempt_count: 1,
      metadata: %{"source" => "test_demotion"},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("avoid demoted")
               }),
               %{request_id: "after-demotion-turn", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_after_demotion"} = CodexPooler.JSON.decode!(frame)
    assert FakeUpstream.count(demoted_upstream) == 0
    assert FakeUpstream.count(active_upstream) == 1

    assert [%BridgeDemotion{pool_upstream_assignment_id: demoted_assignment_id, status: "active"}] =
             Repo.all(from(demotion in BridgeDemotion))

    assert demoted_assignment_id == setup.assignment.id
  end

  test "soft assigned websocket session can avoid a demoted continuity backend" do
    sticky_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_sticky_demoted_session",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_sticky_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(sticky_upstream)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-fallback", compact?: false)

    prime_routing_quota!(fallback.identity)

    model =
      put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])

    setup = Map.put(setup, :model, model)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "sticky-demoted"})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %BridgeDemotion{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      model_identifier: setup.model.exposed_model_id,
      pool_upstream_assignment_id: setup.assignment.id,
      upstream_identity_id: setup.identity.id,
      reason_code: "upstream_stream_error",
      status: "active",
      demoted_until: DateTime.add(now, 60, :second),
      attempt_count: 1,
      metadata: %{"source" => "test_demotion"},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("preserve sticky session assignment")
               }),
               %{request_id: "sticky-demoted-turn", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_sticky_fallback_should_not_run"} = CodexPooler.JSON.decode!(frame)
    assert FakeUpstream.count(sticky_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 1

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    request = Repo.get!(Request, turn.request_id)
    assert request.transport == "websocket"
    assert request.endpoint == "/backend-api/codex/responses"

    assert get_in(request.request_metadata, ["routing", "affinity_kind"]) == "codex_session"

    assert get_in(request.request_metadata, ["routing", "selected_bridge_candidate_id"]) ==
             fallback.assignment.id

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ "preserve sticky session assignment"
    refute metadata_text =~ "resp_sticky_fallback_should_not_run"

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.pool_upstream_assignment_id == fallback.assignment.id
  end

  test "soft local websocket session alias can avoid an exhausted continuity backend before dispatch" do
    sticky_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_exhausted_sticky_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_soft_alias_quota_fallback",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(sticky_upstream, quota?: false)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-soft-alias-fallback",
        compact?: false
      )

    prime_exhausted_routing_quota!(setup.identity)
    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "soft-ws-quota-#{System.unique_integer([:positive])}"
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: turn_state})

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
                 "input" => native_text_input("soft local alias may fall back before dispatch"),
                 "stream" => true,
                 "generate" => true
               }),
               %{
                 request_id: "ws-soft-alias-quota-fallback",
                 accepted_turn_state: turn_state
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_soft_alias_quota_fallback"} = CodexPooler.JSON.decode!(frame)

    assert FakeUpstream.count(sticky_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 1

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.request_metadata["codex_session_id"] == session.id

    assert get_in(request.request_metadata, ["routing", "selected_bridge_candidate_id"]) ==
             fallback.assignment.id

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.pool_upstream_assignment_id == fallback.assignment.id
    refute attempt.pool_upstream_assignment_id == setup.assignment.id

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.request_id == request.id
    assert turn.status == "succeeded"

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ "soft local alias may fall back before dispatch"
    refute metadata_text =~ "resp_ws_soft_alias_quota_fallback"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upstream-token"
  end

  @tag :hard_pinned_quota_recovery
  test "live upstream websocket session keeps exhausted continuity backend hard pinned" do
    sticky_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_live_sticky_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    fallback_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_live_fallback_should_not_run",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(sticky_upstream, quota?: false)

    fallback =
      gateway_upstream(setup.pool, fallback_upstream, "upstream-token-live-fallback",
        compact?: false
      )

    prime_exhausted_routing_quota!(setup.identity)
    prime_routing_quota!(fallback.identity)

    setup =
      Map.put(
        setup,
        :model,
        put_model_source_assignments!(setup.model, [setup.assignment, fallback.assignment])
      )

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = "live-ws-quota-#{System.unique_integer([:positive])}"
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: turn_state})

    session =
      session
      |> Ecto.Changeset.change(%{pool_upstream_assignment_id: setup.assignment.id})
      |> Repo.update!()

    upstream_websocket_session = start_supervised!(UpstreamWebsocketSession)

    assert {:error, %{code: "pinned_continuation_unavailable", status: 503} = error} =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => native_text_input("live websocket state must not fall back"),
                 "stream" => true,
                 "generate" => true
               }),
               %{
                 request_id: "ws-live-hard-quota-exhausted",
                 codex_session: session,
                 accepted_turn_state: turn_state,
                 upstream_websocket_session: upstream_websocket_session
               },
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert error.retryable == false
    assert error.requires_new_upstream_session == true
    assert error.recovery["kind"] == "restart_with_full_context"

    assert error.continuity_denial == %{
             "denial_family" => "pinned_continuation_unavailable",
             "continuity_family" => "pinned_codex_session",
             "pin_mode" => "hard",
             "pin_reason" => "live_upstream_websocket",
             "internal_reason" => "quota_exhausted",
             "pool_upstream_assignment_id" => setup.assignment.id,
             "upstream_identity_id" => setup.identity.id
           }

    refute_received {:websocket_frame, _frame}
    assert FakeUpstream.count(sticky_upstream) == 0
    assert FakeUpstream.count(fallback_upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0

    assert [request] =
             Repo.all(
               from request in Request,
                 where: request.correlation_id == "ws-live-hard-quota-exhausted"
             )

    assert request.status == "rejected"
    assert request.transport == "websocket"
    assert request.last_error_code == "pinned_continuation_unavailable"

    assert %{
             "denial_family" => "pinned_continuation_unavailable",
             "pin_reason" => "live_upstream_websocket",
             "internal_reason" => "quota_exhausted",
             "pool_upstream_assignment_id" => assignment_id,
             "upstream_identity_id" => identity_id
           } = request.request_metadata["continuity_denial"]

    assert assignment_id == setup.assignment.id
    assert identity_id == setup.identity.id
    assert Repo.all(from(d in BridgeDemotion)) == []
    assert Repo.all(from(c in RoutingCircuitState)) == []

    metadata_text = inspect(request.request_metadata || %{})
    refute metadata_text =~ "live websocket state must not fall back"
    refute metadata_text =~ "resp_ws_live"
    refute metadata_text =~ setup.authorization
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "Bearer "
    refute metadata_text =~ "upstream-token"
  end

  test "stable websocket session key is reused before timeout and replaced after timeout" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-reconnect",
        owner_instance_id: "node-a"
      })

    assert [%BridgeOwnerLease{id: old_lease_id}] =
             Repo.all(
               from lease in BridgeOwnerLease, where: lease.codex_session_id == ^session.id
             )

    Gateway.interrupt_codex_session(session, %{reconnect_window_seconds: 300})

    {:ok, reused} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-reconnect",
        owner_instance_id: "node-a"
      })

    assert reused.id == session.id

    expired_at = DateTime.add(DateTime.utc_now(), -30, :second) |> DateTime.truncate(:microsecond)

    reused
    |> Ecto.Changeset.change(%{status: "interrupted", owner_lease_expires_at: expired_at})
    |> Repo.update!()

    {:ok, replacement} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-reconnect",
        owner_instance_id: "node-b"
      })

    assert replacement.id != session.id
    assert Repo.get!(CodexSession, session.id).status == "closed"
    assert Repo.get!(BridgeOwnerLease, old_lease_id).status == "expired"

    assert [] =
             Repo.all(
               from alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^session.id and
                     alias_record.status == "active"
             )

    assert [%BridgeOwnerLease{owner_instance_id: "node-b", status: "active"}] =
             Repo.all(
               from lease in BridgeOwnerLease, where: lease.codex_session_id == ^replacement.id
             )
  end

  defp mark_pinned_assignment_reauth_required!(setup) do
    setup.identity
    |> Ecto.Changeset.change(%{
      status: "reauth_required",
      metadata: %{
        "base_url" => setup.identity.metadata["base_url"],
        "token_refresh" => %{
          "status" => "reauth_required",
          "reason" => %{
            "code" => "refresh_token_revoked",
            "message" => "synthetic refresh state"
          }
        }
      }
    })
    |> Repo.update!()

    setup.assignment
    |> Ecto.Changeset.change(%{
      health_status: "disabled",
      eligibility_status: "ineligible"
    })
    |> Repo.update!()
  end

  defp active_owner_lease_for_session!(codex_session_id) do
    assert [lease] =
             Repo.all(
               from lease in BridgeOwnerLease,
                 where: lease.codex_session_id == ^codex_session_id and lease.status == "active"
             )

    lease
  end

  defp assert_owner_lease_not_replaced!(codex_session_id, lease_before) do
    lease_after = active_owner_lease_for_session!(codex_session_id)
    assert lease_after.id == lease_before.id
    assert lease_after.lease_token == lease_before.lease_token
  end

  defp assert_pinned_reauth_websocket_frame!(frame) do
    assert %{
             "type" => "error",
             "status" => 503,
             "error" => error
           } = CodexPooler.JSON.decode!(frame)

    assert error["code"] == "pinned_continuation_reauth_required"
    assert error["retryable"] == false
    assert error["requires_new_upstream_session"] == true
    assert error["recovery_kind"] == "restart_with_full_context"
    assert error["recovery"]["kind"] == "restart_with_full_context"
    assert error["recovery"]["anchor_removal"]["body"] == ["previous_response_id"]

    assert error["recovery"]["anchor_removal"]["headers"] == [
             "x-codex-previous-response-id",
             "x-codex-turn-state",
             "x-codex-window-id",
             "x-codex-session-id",
             "session-id",
             "x-session-id",
             "x-session-affinity",
             "session_id",
             "x-codex-conversation-id"
           ]
  end

  defp assert_pinned_reauth_gateway_error!(error) do
    assert error.status == 503
    assert error.code == "pinned_continuation_reauth_required"
    assert error.retryable == false
    assert error.requires_new_upstream_session == true
    assert error.recovery["kind"] == "restart_with_full_context"
    assert error.recovery["anchor_removal"]["body"] == ["previous_response_id"]
  end

  defp assert_pinned_reauth_rejected_request!(correlation_id) do
    assert [request] =
             Repo.all(
               from request in Request,
                 where: request.correlation_id == ^correlation_id
             )

    assert request.status == "rejected"
    assert request.response_status_code == 503
    assert request.last_error_code == "pinned_continuation_reauth_required"
    refute request.request_metadata["requires_new_upstream_session"] == false

    request
  end

  defp assert_usage_probe_then_response(upstream) do
    assert [
             usage_request,
             response_request
           ] = FakeUpstream.requests(upstream)

    assert usage_request.path == "/backend-api/wham/usage"
    {usage_request, response_request}
  end

  defp assert_usage_probe_requests(upstream) do
    assert [usage_request] = FakeUpstream.requests(upstream)

    assert usage_request.path == "/backend-api/wham/usage"
    usage_request
  end
end
