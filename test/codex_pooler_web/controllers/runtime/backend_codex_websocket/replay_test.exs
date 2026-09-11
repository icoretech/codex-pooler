defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.ReplayTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestReplayEntitlement}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @websocket_frame_timeout 1_000
  @large_websocket_frame_timeout 5_000
  # Detection budget for a server-side connection teardown the test only
  # observes, never a scenario timeout.
  @connection_shutdown_timeout_ms 15_000

  @tag :same_connection_distinct_turns
  test "distinct websocket messages sharing connection request id both dispatch and account" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_same_connection",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "same-connection"})
    opts = %{request_id: "connection-request-id", codex_session: session}

    first_payload =
      CodexPooler.JSON.encode!(%{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("first")
      })

    second_payload =
      CodexPooler.JSON.encode!(%{
        "model" => setup.model.exposed_model_id,
        "input" => native_text_input("second")
      })

    assert :ok =
             execute_websocket_response(auth, first_payload, opts, fn frame ->
               send(self(), {:websocket_frame, :first, frame})
             end)

    assert :ok =
             execute_websocket_response(auth, second_payload, opts, fn frame ->
               send(self(), {:websocket_frame, :second, frame})
             end)

    assert_received {:websocket_frame, :first, _frame}
    assert_received {:websocket_frame, :second, _frame}
    assert FakeUpstream.count(upstream) == 2
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
    assert Repo.aggregate(from(a in Attempt), :count) == 2

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             2

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.entry_kind == "settlement"),
             :count
           ) == 2
  end

  @tag :duplicate_turn
  @tag :replay_matrix
  @tag :strict_fake_upstream
  test "released 0.151.0 same-socket native tool continuation without previous response gets a request claim" do
    previous_response_id = "resp_native_tool_continuation_anchor"
    logical_turn_id = "native-tool-continuation-turn"
    released_thread_id = Ecto.UUID.generate()
    released_context_window_id = Ecto.UUID.generate()

    released_turn_metadata =
      CodexPooler.JSON.encode!(%{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => released_thread_id,
        "thread_id" => released_thread_id,
        "turn_id" => logical_turn_id,
        "request_kind" => "turn",
        "window_id" => "#{released_thread_id}:1",
        "window_number" => 1,
        "context_window_id" => released_context_window_id,
        "sandbox_mode" => "danger-full-access"
      })

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (metadata field set mirrors the released 0.151.0 client; frames invented)
        FakeUpstream.strict_sequence([
          strict_native_response(previous_response_id, 1, 4, 3),
          strict_native_response("resp_native_tool_continuation_complete", 1, 5, 2)
        ])
      )

    setup = gateway_setup(upstream)

    identity =
      setup.identity
      |> UpstreamIdentity.changeset(%{
        metadata: saved_reset_metadata(upstream, 1),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    setup = %{setup | identity: identity}
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "native-tool-continuation-socket",
          accepted_turn_state: "native-tool-continuation-state",
          client_ip: "127.0.0.1"
        }
      })

    anchor = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "client_metadata" => %{
        "turn_id" => logical_turn_id,
        "x-codex-turn-metadata" => released_turn_metadata
      },
      "input" => native_text_input("anchor"),
      "stream" => true,
      "generate" => true
    }

    continuation = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "client_metadata" => %{
        "turn_id" => logical_turn_id,
        "x-codex-turn-metadata" => released_turn_metadata
      },
      "input" => [
        %{
          "type" => "function_call_output",
          "call_id" => "call_native_tool_continuation",
          "output" => "synthetic continuation output"
        }
      ],
      "stream" => true,
      "generate" => true
    }

    try do
      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {CodexPooler.JSON.encode!(anchor), [opcode: :text]},
                 state
               )

      assert {:push, {:text, anchor_frame}, state} = receive_socket_push(state)
      assert %{"id" => ^previous_response_id} = CodexPooler.JSON.decode!(anchor_frame)
      assert {:ok, state} = receive_socket_done(state)

      assert {:ok, state} =
               CodexResponsesSocket.handle_in(
                 {CodexPooler.JSON.encode!(continuation), [opcode: :text]},
                 state
               )

      assert {:push, {:text, continuation_frame}, state} = receive_socket_push(state)

      assert %{"id" => "resp_native_tool_continuation_complete"} =
               CodexPooler.JSON.decode!(continuation_frame)

      assert {:ok, state} = receive_socket_done(state)

      assert [anchor_request, continuation_request] =
               Repo.all(
                 from request in Request,
                   where: request.pool_id == ^setup.pool.id,
                   order_by: [asc: request.admitted_at]
               )

      {:ok, logical_identity} =
        WebsocketTurnIdentity.resolve(anchor, state.codex_session.id)

      assert {:ok, ^logical_identity} =
               WebsocketTurnIdentity.resolve(continuation, state.codex_session.id)

      assert anchor_request.correlation_id == logical_identity.turn_claim_key

      assert continuation_request.correlation_id ==
               WebsocketTurnIdentity.request_claim_key(
                 logical_identity.semantic_turn_key,
                 continuation
               )

      refute anchor_request.correlation_id == continuation_request.correlation_id
      assert Repo.aggregate(from(a in Attempt), :count) == 2

      assert [1, 2] ==
               Repo.all(
                 from turn in CodexTurn,
                   where: turn.codex_session_id == ^state.codex_session.id,
                   order_by: [asc: turn.turn_sequence],
                   select: turn.turn_sequence
               )

      assert Repo.aggregate(
               from(entry in LedgerEntry, where: entry.entry_kind == "settlement"),
               :count
             ) == 2

      assert FakeUpstream.count(upstream) == 2

      prime_weekly_exhausted_quota!(identity)
      saved_reset_before_replay = Repo.reload!(identity).metadata["saved_reset_redemption"]

      assert {:error, %{status: 409, code: "duplicate_turn"}} =
               execute_websocket_response(
                 auth,
                 CodexPooler.JSON.encode!(continuation),
                 %{
                   request_id: "native-tool-continuation-replay",
                   codex_session: state.codex_session
                 },
                 fn frame -> send(self(), {:websocket_frame, :replay, frame}) end
               )

      refute_received {:websocket_frame, :replay, _frame}
      assert FakeUpstream.count(upstream) == 2
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
      assert Repo.aggregate(from(a in Attempt), :count) == 2

      assert Repo.aggregate(
               from(turn in CodexTurn, where: turn.codex_session_id == ^state.codex_session.id),
               :count
             ) == 2

      assert Repo.aggregate(
               from(entry in LedgerEntry, where: entry.entry_kind == "settlement"),
               :count
             ) == 2

      assert Repo.reload!(identity).metadata["saved_reset_redemption"] ==
               saved_reset_before_replay

      refute Enum.any?(FakeUpstream.requests(upstream), fn request ->
               request.path == "/api/codex/rate-limit-reset-credits/consume"
             end)

      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "qualifying native continuation denial persists the request claim without changing the turn claim" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    setup.api_key
    |> Ecto.Changeset.change(maximum_reasoning_effort: "medium")
    |> Repo.update!()

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "denial-state"})

    payload = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "previous_response_id" => "resp_qualifying_denial_anchor",
      "client_metadata" => %{"turn_id" => "qualifying-denial-turn"},
      "input" => [
        %{
          "type" => "function_call_output",
          "call_id" => "call_qualifying_denial",
          "output" => "synthetic denial output"
        }
      ],
      "reasoning" => %{"effort" => "high"},
      "stream" => true,
      "generate" => true
    }

    assert {:ok, logical_identity} = WebsocketTurnIdentity.resolve(payload, session.id)

    request_claim_key =
      WebsocketTurnIdentity.request_claim_key(logical_identity.semantic_turn_key, payload)

    assert {:error, %{status: 400, code: "reasoning_effort_not_allowed"}} =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(payload),
               %{request_id: "qualifying-denial-frame", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    refute_received {:websocket_frame, _frame}
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert request.correlation_id == request_claim_key
    refute request.correlation_id == logical_identity.turn_claim_key

    assert request.request_metadata["gateway_denial"]["code"] == "reasoning_effort_not_allowed"
  end

  test "released memory metadata is rejected before native websocket lifecycle work" do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "unexpected"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    sentinel = "raw-memory-diagnostic-sentinel"

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "memory-non-native",
          accepted_turn_state: "memory-non-native-state",
          client_ip: "127.0.0.1"
        }
      })

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            CodexPooler.JSON.encode!(%{
              "session_id" => sentinel,
              "thread_id" => Ecto.UUID.generate(),
              "request_kind" => "memory"
            })
        },
        "input" => native_text_input("memory must not enter native turn lifecycle")
      })

    try do
      {result, log} =
        with_log(fn -> CodexResponsesSocket.handle_in({payload, [opcode: :text]}, state) end)

      assert {:push, {:text, error_frame}, state} = result
      assert log =~ "route_class=proxy_websocket"
      assert log =~ "frame_class=response_create"
      assert log =~ "request_kind_class=memory"
      assert log =~ "rejection_class=unsupported_request_kind"
      refute log =~ sentinel

      assert %{"type" => "error", "status" => 400, "error" => %{"code" => "invalid_request"}} =
               CodexPooler.JSON.decode!(error_frame)

      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
      assert Repo.aggregate(from(a in Attempt), :count) == 0

      assert Repo.aggregate(
               from(t in CodexTurn, where: t.codex_session_id == ^state.codex_session.id),
               :count
             ) == 0
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  @tag :duplicate_turn
  test "duplicate explicit websocket turn id does not double account attempts or usage" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_duplicate_turn",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "duplicate-turn"})

    opts = %{request_id: "connection-request-id", codex_session: session}

    payload =
      CodexPooler.JSON.encode!(%{
        "model" => setup.model.exposed_model_id,
        "turn_id" => "duplicate-turn-id",
        "input" => native_text_input("dedupe me")
      })

    assert :ok =
             execute_websocket_response(auth, payload, opts, fn frame ->
               send(self(), {:websocket_frame, :first, frame})
             end)

    assert_received {:websocket_frame, :first, _frame}

    assert {:error, %{code: "duplicate_turn"}} =
             execute_websocket_response(auth, payload, opts, fn frame ->
               send(self(), {:websocket_frame, :duplicate, frame})
             end)

    refute_received {:websocket_frame, :duplicate, _frame}
    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    assert Repo.aggregate(from(a in Attempt), :count) == 1

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             1

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.entry_kind == "settlement"),
             :count
           ) == 1
  end

  @tag :replay_matrix
  test "pre-visible disconnected native tool continuation recovers on byte-identical replay" do
    thread_id = Ecto.UUID.generate()

    payload = fn model ->
      %{
        "type" => "response.create",
        "model" => model,
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            CodexPooler.JSON.encode!(%{
              "session_id" => thread_id,
              "thread_id" => thread_id,
              "turn_id" => "replay-tool-continuation",
              "request_kind" => "turn"
            })
        },
        "input" => [
          %{
            "type" => "function_call_output",
            "call_id" => "call_replay_boundary",
            "output" => "synthetic replay output"
          }
        ],
        "instructions" => "synthetic replay instructions",
        "tools" => [
          %{
            "type" => "function",
            "name" => "sample_tool",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        ],
        "stream" => true,
        "generate" => true
      }
    end

    assert_replay_red_boundary(payload)
  end

  @tag :replay_matrix
  test "pre-visible disconnected compact final recovers on byte-identical replay" do
    thread_id = Ecto.UUID.generate()

    payload = fn model ->
      %{
        "type" => "response.create",
        "model" => model,
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            CodexPooler.JSON.encode!(%{
              "session_id" => thread_id,
              "thread_id" => thread_id,
              "turn_id" => "replay-compact-final",
              "request_kind" => "turn"
            })
        },
        "input" => [
          %{
            "type" => "compaction",
            "encrypted_content" => "synthetic-compact-boundary"
          }
        ],
        "stream" => true,
        "generate" => true
      }
    end

    assert_replay_red_boundary(payload)
  end

  @tag :replay_matrix
  @tag :replay_race
  test "a second disconnect after consumed replay cannot create generation N+2" do
    thread_id = Ecto.UUID.generate()
    first_release_ref = make_ref()
    second_release_ref = make_ref()

    upstream =
      start_upstream(
        # Strict finite scenario: generation zero and the single replay each
        # get one send on their own connection; the third client attempt is
        # fenced as a duplicate turn and must never reach the upstream.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "function_call_output"}
            ],
            respond:
              FakeUpstream.websocket_close_without_terminal_barrier(
                notify: self(),
                release_ref: first_release_ref,
                code: 1001,
                reason: "synthetic generation zero disconnect"
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 2,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "function_call_output"}
            ],
            respond:
              FakeUpstream.websocket_close_without_terminal_barrier(
                notify: self(),
                release_ref: second_release_ref,
                code: 1001,
                reason: "synthetic generation one disconnect"
              )
          )
        ])
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)

    previous_owner_forwarding =
      Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      case previous_owner_forwarding do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    {:ok, _auth} = Access.authenticate_authorization_header(setup.authorization)
    turn_state = Ecto.UUID.generate()

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            CodexPooler.JSON.encode!(%{
              "session_id" => thread_id,
              "thread_id" => thread_id,
              "turn_id" => "repeated-generation-one-disconnect",
              "request_kind" => "turn"
            })
        },
        "input" => [
          %{
            "type" => "function_call_output",
            "call_id" => "call_repeated_generation_one_disconnect",
            "output" => "synthetic replay output"
          }
        ],
        "stream" => true,
        "generate" => true
      })

    {server, port} = start_public_endpoint_with_server!()
    {first_conn, first_websocket, first_ref} = public_websocket_connect!(port, setup, turn_state)

    {first_conn, _first_websocket} =
      public_websocket_send_text!(first_conn, first_websocket, first_ref, payload)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, first_upstream_pid,
                    ^first_release_ref},
                   @large_websocket_frame_timeout

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt_n] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(turn.codex_session_id)
    first_downstream = :sys.get_state(owner_pid).downstream
    assert :suspended = WebsocketOwnerSession.detach_downstream(owner_pid, first_downstream)
    send(first_upstream_pid, {:fake_upstream_release_websocket, first_release_ref})

    assert %Attempt{replay_generation: 0, status: "retryable_failed"} =
             Repo.get!(Attempt, attempt_n.id)

    {replay_conn, replay_websocket, replay_ref} =
      public_websocket_connect!(port, setup, turn_state)

    {replay_conn, _replay_websocket} =
      public_websocket_send_text!(replay_conn, replay_websocket, replay_ref, payload)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, second_upstream_pid,
                    ^second_release_ref},
                   @large_websocket_frame_timeout

    assert [persisted_attempt_n, attempt_n_plus_one] =
             Repo.all(
               from(a in Attempt,
                 where: a.request_id == ^request.id,
                 order_by: [asc: a.attempt_number]
               )
             )

    assert persisted_attempt_n.id == attempt_n.id
    assert attempt_n_plus_one.replay_generation == 1
    assert attempt_n_plus_one.status == "in_progress"
    replay_downstream = :sys.get_state(owner_pid).downstream
    assert :ok = WebsocketOwnerSession.detach_downstream(owner_pid, replay_downstream)
    send(second_upstream_pid, {:fake_upstream_release_websocket, second_release_ref})

    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"status" => "failed"}
                    }},
                   @connection_shutdown_timeout_ms

    assert %Request{status: "failed", last_error_code: "client_disconnected"} =
             Repo.get!(Request, request.id)

    assert %Attempt{status: "failed", network_error_code: "client_disconnected"} =
             Repo.get!(Attempt, attempt_n_plus_one.id)

    assert %RequestReplayEntitlement{status: "consumed", closed_at: %DateTime{}} =
             Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

    {third_conn, third_websocket, third_ref} = public_websocket_connect!(port, setup, turn_state)

    {third_conn, third_websocket} =
      public_websocket_send_text!(third_conn, third_websocket, third_ref, payload)

    {third_conn, _third_websocket, third_frame} =
      public_websocket_receive_text!(third_conn, third_websocket, third_ref)

    assert %{"error" => %{"code" => "duplicate_turn"}} = CodexPooler.JSON.decode!(third_frame)
    assert FakeUpstream.count(upstream) == 2
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 2

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "release"
             ),
             :count
           ) == 1

    assert %CodexTurn{status: "interrupted", final_attempt_id: final_attempt_id} =
             Repo.get!(CodexTurn, turn.id)

    assert final_attempt_id == attempt_n_plus_one.id
    {:ok, connections} = ThousandIsland.connection_pids(server)
    connection_monitors = Enum.map(connections, &{&1, Process.monitor(&1)})
    _result = Mint.HTTP.close(first_conn)
    _result = Mint.HTTP.close(replay_conn)
    _result = Mint.HTTP.close(third_conn)

    Enum.each(connection_monitors, fn {pid, monitor} ->
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, @connection_shutdown_timeout_ms
    end)

    await_websocket_owner_absent!(turn.codex_session_id)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  @tag :duplicate_turn
  @tag :replay_matrix
  test "compaction-shaped explicit websocket turn remains behind the durable duplicate fence" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_compaction_shape_duplicate",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "shape-duplicate"})

    opts = %{request_id: "shape-connection-request", codex_session: session}

    payload =
      CodexPooler.JSON.encode!(%{
        "model" => setup.model.exposed_model_id,
        "turn_id" => "shape-duplicate-turn-id",
        "input" => [%{"type" => "compaction", "encrypted_content" => "synthetic-compact"}]
      })

    assert :ok = execute_websocket_response(auth, payload, opts, fn _frame -> :ok end)

    assert {:error, %{code: "duplicate_turn"}} =
             execute_websocket_response(auth, payload, opts, fn _frame -> :ok end)

    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    assert Repo.aggregate(Attempt, :count) == 1

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             1
  end

  @tag :saved_reset_duplicate_turn
  @tag :replay_race
  test "duplicate explicit websocket turn id does not auto redeem saved reset before rejection" do
    upstream =
      start_upstream(
        {:path_json,
         %{
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_duplicate_turn_saved_reset",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }},
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" => {200, saved_reset_usage_payload(0)}
         }}
      )

    setup = gateway_setup(upstream)

    identity =
      setup.identity
      |> UpstreamIdentity.changeset(%{
        metadata: saved_reset_metadata(upstream, 1),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    setup = %{setup | identity: identity}
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "duplicate-reset"})

    opts = %{request_id: "connection-request-id", codex_session: session}

    payload =
      CodexPooler.JSON.encode!(%{
        "model" => setup.model.exposed_model_id,
        "turn_id" => "duplicate-reset-turn-id",
        "input" => native_text_input("dedupe me before reset")
      })

    forged_compaction_payload =
      CodexPooler.JSON.encode!(%{
        "model" => setup.model.exposed_model_id,
        "turn_id" => "duplicate-reset-turn-id",
        "input" => [
          %{
            "type" => "compaction",
            "encrypted_content" => "synthetic-forged-saved-reset-compaction"
          }
        ]
      })

    assert :ok =
             execute_websocket_response(auth, payload, opts, fn frame ->
               send(self(), {:websocket_frame, :first, frame})
             end)

    assert_received {:websocket_frame, :first, _frame}
    assert [%{path: "/backend-api/codex/responses"}] = FakeUpstream.requests(upstream)

    prime_weekly_exhausted_quota!(identity)
    saved_reset_before_rejection = Repo.reload!(identity).metadata["saved_reset_redemption"]

    assert {:error, %{code: "duplicate_turn"}} =
             execute_websocket_response(auth, forged_compaction_payload, opts, fn frame ->
               send(self(), {:websocket_frame, :duplicate, frame})
             end)

    refute_received {:websocket_frame, :duplicate, _frame}

    assert [%{path: "/backend-api/codex/responses"}] = FakeUpstream.requests(upstream)
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1
    assert Repo.aggregate(from(a in Attempt), :count) == 1

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             1

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.entry_kind == "settlement"),
             :count
           ) == 1

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.entry_kind == "reservation"),
             :count
           ) == 1

    reloaded_identity = Repo.reload!(identity)
    assert reloaded_identity.metadata["saved_reset_redemption"] == saved_reset_before_rejection
    refute inspect(reloaded_identity.metadata) =~ "synthetic-forged-saved-reset-compaction"
  end

  @tag :duplicate_turn
  @tag :replay_race
  test "concurrent identical native tool continuations admit exactly one lifecycle" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_concurrent_duplicate_turn",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Gateway.start_codex_session(auth, %{accepted_turn_state: "duplicate-race"})

    opts = %{request_id: "connection-request-id", codex_session: session}
    parent = self()
    logical_turn_id = "duplicate-race-turn-id"

    anchor =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "client_metadata" => %{"turn_id" => logical_turn_id},
        "input" => native_text_input("anchor")
      })

    assert :ok = execute_websocket_response(auth, anchor, opts, fn _frame -> :ok end)

    payload =
      CodexPooler.JSON.encode!(%{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "client_metadata" => %{"turn_id" => logical_turn_id},
        "previous_response_id" => "resp_concurrent_duplicate_turn",
        "input" => [
          %{
            "type" => "function_call_output",
            "call_id" => "call_concurrent_duplicate_turn",
            "output" => "synthetic concurrent output"
          }
        ]
      })

    tasks =
      for label <- [:first, :second] do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:duplicate_turn_task_ready, label, self()})

          receive do
            :run_duplicate_turn_request -> :ok
          after
            5_000 -> flunk("duplicate turn task #{label} was not released")
          end

          execute_websocket_response(auth, payload, opts, fn frame ->
            send(parent, {:websocket_frame, label, frame})
          end)
        end)
      end

    task_pids =
      for _label <- [:first, :second] do
        assert_receive {:duplicate_turn_task_ready, _label, pid}, 5_000
        pid
      end

    Enum.each(task_pids, &send(&1, :run_duplicate_turn_request))

    results = Task.await_many(tasks, 10_000)

    assert Enum.count(results, &match?(:ok, &1)) == 1
    assert Enum.count(results, &match?({:error, %{code: "duplicate_turn"}}, &1)) == 1

    # The admitted continuation uses the upstream websocket on a fresh
    # connection, so it receives the exact client retry signal before its
    # payload is sent: only the anchor reaches the upstream.
    assert_receive {:websocket_frame, _label, frame}, @websocket_frame_timeout
    refute_received {:websocket_frame, _label, _frame}

    assert %{"type" => "error", "error" => %{"code" => "previous_response_not_found"}} =
             CodexPooler.JSON.decode!(frame)

    assert FakeUpstream.count(upstream) == 1
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
    assert Repo.aggregate(from(a in Attempt), :count) == 2

    assert Repo.aggregate(from(t in CodexTurn, where: t.codex_session_id == ^session.id), :count) ==
             2

    assert Repo.aggregate(
             from(entry in LedgerEntry, where: entry.entry_kind == "settlement"),
             :count
           ) == 2
  end

  for {label, legacy_snapshot?} <- [
        {"with a preserved snapshot", false},
        {"from a legacy snapshot", true}
      ] do
    @tag :replay_matrix
    @tag legacy_snapshot?: legacy_snapshot?
    test "native replay #{label} never relays a provider x-models-etag",
         %{legacy_snapshot?: legacy_snapshot?} do
      previous_owner_forwarding =
        Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

      on_exit(fn ->
        case previous_owner_forwarding do
          nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
          value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
        end
      end)

      release_ref = make_ref()
      provider_etag = ~s(W/"provider-models-etag-replay-sentinel")

      # Strict finite scenario: the initial send dies pre-visibly on the first
      # connection; the byte-identical replay on the replacement connection gets a
      # provider codex.response.metadata frame carrying its own x-models-etag
      # before the terminal, and nothing else reaches the upstream.
      upstream =
        start_upstream(
          # provenance: synthetic_adversarial (header names from the released Codex client; values invented)
          FakeUpstream.strict_sequence([
            strict_native_request(
              1,
              FakeUpstream.websocket_close_without_terminal_barrier(
                notify: self(),
                release_ref: release_ref,
                code: 1001,
                reason: "synthetic pre-visible replay etag disconnect"
              )
            ),
            strict_native_request(
              2,
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "type" => "codex.response.metadata",
                  "headers" => %{
                    "x-models-etag" => provider_etag,
                    "openai-model" => "synthetic-provider-model",
                    "x-reasoning-included" => "true"
                  }
                }),
                CodexPooler.JSON.encode!(%{
                  "type" => "response.completed",
                  "response" => %{
                    "id" => "resp_replay_etag_completed_1234",
                    "status" => "completed",
                    "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}
                  }
                })
              ])
            )
          ])
        )

      setup = gateway_setup(upstream)
      assert :ok = Events.subscribe_pool(setup.pool)
      thread_id = Ecto.UUID.generate()
      turn_state = Ecto.UUID.generate()

      raw_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "client_metadata" => %{
            "x-codex-turn-metadata" =>
              CodexPooler.JSON.encode!(%{
                "session_id" => thread_id,
                "thread_id" => thread_id,
                "turn_id" => "replay-provider-etag",
                "request_kind" => "turn"
              })
          },
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_replay_provider_etag",
              "output" => "synthetic replay etag output"
            }
          ],
          "stream" => true,
          "generate" => true
        })

      {server, port} = start_public_endpoint_with_server!()
      {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
      {conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)

      assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid,
                      ^release_ref},
                     @large_websocket_frame_timeout

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
      assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(turn.codex_session_id)
      owner_state = :sys.get_state(owner_pid)

      assert :suspended =
               WebsocketOwnerSession.detach_downstream(owner_pid, owner_state.downstream)

      send(upstream_pid, {:fake_upstream_release_websocket, release_ref})

      assert %RequestReplayEntitlement{status: "armed"} =
               Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

      assert [%Attempt{replay_generation: 0, status: "retryable_failed"} = initial_attempt] =
               Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

      persisted_etag =
        get_in(initial_attempt.response_metadata, ["native_replay_preparation", "models_etag"])

      assert <<"W/\"cp-models-v1-", _digest::binary-size(64), "\"">> = persisted_etag

      if legacy_snapshot? do
        # An original attempt settled before the snapshot carried the models ETag.
        initial_attempt
        |> Ecto.Changeset.change(
          response_metadata:
            update_in(
              initial_attempt.response_metadata,
              ["native_replay_preparation"],
              &Map.delete(&1, "models_etag")
            )
        )
        |> Repo.update!()
      end

      {replay_conn, replay_websocket, replay_ref} =
        public_websocket_connect!(port, setup, turn_state)

      {replay_conn, replay_websocket} =
        public_websocket_send_text!(replay_conn, replay_websocket, replay_ref, raw_payload)

      {replay_conn, _replay_websocket, frames} =
        receive_raw_texts_until_terminal!(replay_conn, replay_websocket, replay_ref, [])

      assert_receive {Events,
                      %{reason: "request_finalized", payload: %{"status" => "succeeded"}}},
                     @connection_shutdown_timeout_ms

      # The native replay path is the only one that settles a generation 1
      # attempt on the original request; a fresh dispatch would open a new one.
      assert [
               %Attempt{replay_generation: 0, status: "retryable_failed"},
               %Attempt{replay_generation: 1, status: "succeeded"}
             ] =
               Repo.all(
                 from(a in Attempt,
                   where: a.request_id == ^request.id,
                   order_by: [asc: a.attempt_number]
                 )
               )

      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 1

      decoded = Enum.map(frames, &CodexPooler.JSON.decode!/1)
      frame_types = Enum.map(decoded, & &1["type"])
      assert List.last(frame_types) == "response.completed"

      for frame <- frames do
        refute frame =~ "provider-models-etag-replay-sentinel",
               "provider x-models-etag reached the client; frame types: #{inspect(frame_types)}"
      end

      models_conn = build_conn() |> auth(setup) |> get("/backend-api/codex/models")
      assert [models_etag] = get_resp_header(models_conn, "etag")

      etag_frames = Enum.filter(decoded, &get_in(&1, ["headers", "x-models-etag"]))
      metadata_frames = Enum.filter(decoded, &(&1["type"] == "codex.response.metadata"))
      assert persisted_etag == models_etag

      if legacy_snapshot? do
        # Without a preserved value the replay authors no ETag of its own.
        assert etag_frames == [], "frame types: #{inspect(frame_types)}"
        assert frame_types == ["codex.response.metadata", "response.completed"]
      else
        assert [
                 %{
                   "type" => "codex.response.metadata",
                   "headers" => %{"x-models-etag" => ^models_etag}
                 }
               ] = etag_frames,
               "expected exactly one Pooler-authored metadata event; frame types: #{inspect(frame_types)}"

        assert hd(decoded) == hd(etag_frames)

        assert frame_types == [
                 "codex.response.metadata",
                 "codex.response.metadata",
                 "response.completed"
               ]
      end

      provider_headers = List.last(metadata_frames)["headers"]
      refute Map.has_key?(provider_headers, "x-models-etag")
      assert provider_headers["x-reasoning-included"] == "true"

      {:ok, connections} = ThousandIsland.connection_pids(server)
      connection_monitors = Enum.map(connections, &{&1, Process.monitor(&1)})
      _result = Mint.HTTP.close(replay_conn)
      _result = Mint.HTTP.close(conn)

      Enum.each(connection_monitors, fn {pid, monitor} ->
        assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, @connection_shutdown_timeout_ms
      end)

      await_websocket_owner_absent!(turn.codex_session_id)
      assert :ok = FakeUpstream.verify!(upstream)
    end
  end

  # Collects every downstream text frame, internal control events included,
  # until a terminal event arrives. Only socket messages are taken so pool
  # events stay in the mailbox for the finalization assertion.
  defp receive_raw_texts_until_terminal!(conn, websocket, ref, acc) do
    receive do
      {tag, _socket, _data} = message when tag in [:tcp, :tcp_error] ->
        stream_raw_texts!(conn, websocket, ref, acc, message)

      {:tcp_closed, _socket} = message ->
        stream_raw_texts!(conn, websocket, ref, acc, message)
    after
      @large_websocket_frame_timeout -> flunk("timed out waiting for a terminal websocket frame")
    end
  end

  defp stream_raw_texts!(conn, websocket, ref, acc, message) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {websocket, texts} = decode_raw_texts!(responses, websocket, ref)
        acc = acc ++ texts

        if Enum.any?(texts, &terminal_text?/1),
          do: {conn, websocket, acc},
          else: receive_raw_texts_until_terminal!(conn, websocket, ref, acc)

      {:error, conn, reason, _responses} ->
        Mint.HTTP.close(conn)
        flunk("websocket receive failed: #{inspect(reason)}")

      :unknown ->
        receive_raw_texts_until_terminal!(conn, websocket, ref, acc)
    end
  end

  defp decode_raw_texts!(responses, websocket, ref) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, ^ref, data}, {current, texts} -> append_raw_texts!(current, texts, data)
      {:done, ^ref}, _acc -> flunk("websocket closed before a terminal frame")
      _part, current_acc -> current_acc
    end)
  end

  defp append_raw_texts!(websocket, texts, data) do
    case decode_public_websocket_data!(websocket, data) do
      {:ok, websocket, new_texts} -> {websocket, texts ++ new_texts}
      {:cont, {:cont, websocket}} -> {websocket, texts}
    end
  end

  defp terminal_text?(text) do
    match?(
      {:ok, %{"type" => type}}
      when type in ["response.completed", "response.failed", "response.incomplete", "error"],
      CodexPooler.JSON.decode(text)
    )
  end

  defp assert_replay_red_boundary(payload_builder) do
    previous_owner_forwarding =
      Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      case previous_owner_forwarding do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    release_ref = make_ref()

    # Strict finite scenario: the initial send dies pre-visibly on the first
    # physical connection, the byte-identical replay lands on a replacement
    # connection, and the single fresh turn after the replay continues from
    # the replayed response; the altered and duplicate sends are fenced before
    # the upstream, so any further send fails the fixture.
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          strict_native_request(
            1,
            FakeUpstream.websocket_close_without_terminal_barrier(
              notify: self(),
              release_ref: release_ref,
              code: 1001,
              reason: "synthetic pre-visible downstream death"
            )
          ),
          strict_native_request(
            2,
            FakeUpstream.websocket_text_frames([
              CodexPooler.JSON.encode!(%{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_replay_completed_123456",
                  "status" => "completed",
                  "usage" => %{
                    "input_tokens" => 3,
                    "output_tokens" => 2,
                    "total_tokens" => 5
                  }
                }
              })
            ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_replay_completed_123456"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "type" => "response.completed",
                  "response" => %{
                    "id" => "resp_replay_fresh_turn_123456",
                    "status" => "completed",
                    "usage" => %{
                      "input_tokens" => 2,
                      "output_tokens" => 1,
                      "total_tokens" => 3
                    }
                  }
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    serving_scope = model_serving_scope()
    serving_revision = set_model_serving_mode!(serving_scope, setup, "lite")

    setup.api_key
    |> Ecto.Changeset.change(maximum_reasoning_effort: "medium")
    |> Repo.update!()

    assert :ok = Events.subscribe_pool(setup.pool)
    turn_state = Ecto.UUID.generate()
    payload = payload_builder.(setup.model.exposed_model_id)
    raw_payload = CodexPooler.JSON.encode!(payload)
    {server, port} = start_public_endpoint_with_server!()
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, _websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, upstream_pid, ^release_ref},
                   @large_websocket_frame_timeout

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert [turn] = Repo.all(from(t in CodexTurn, where: t.request_id == ^request.id))
    assert byte_size(turn.semantic_turn_digest) == 32
    assert get_in(request.request_metadata, ["websocket_owner_forwarding", "enabled"]) == true
    assert request.correlation_id =~ ~r/\Acodex-(?:request|turn):[A-Za-z0-9_-]{43}\z/

    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(turn.codex_session_id)
    owner_state = :sys.get_state(owner_pid)

    assert :suspended = WebsocketOwnerSession.detach_downstream(owner_pid, owner_state.downstream)

    assert %{active_turn: nil, suspended_replay: %{provisional_status: :armed}} =
             :sys.get_state(owner_pid)

    assert %Request{status: "in_progress", response_status_code: nil} =
             Repo.get!(Request, request.id)

    assert %RequestReplayEntitlement{status: "armed"} =
             Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

    send(upstream_pid, {:fake_upstream_release_websocket, release_ref})

    assert %CodexTurn{status: "in_progress", first_visible_output_at: nil, final_attempt_id: nil} =
             Repo.get!(CodexTurn, turn.id)

    assert %Attempt{
             id: initial_attempt_id,
             replay_generation: 0,
             status: "retryable_failed",
             network_error_code: "client_disconnected"
           } = Repo.get!(Attempt, attempt.id)

    assert initial_attempt_id == attempt.id

    _revision = set_model_serving_mode!(serving_scope, setup, "full", serving_revision)

    counts_before = replay_boundary_counts(setup.pool.id, turn.codex_session_id, request.id)
    assert counts_before.reservations == 1
    assert counts_before.settlements == 0
    assert counts_before.entitlements == 1

    {altered_conn, altered_websocket, altered_ref} =
      public_websocket_connect!(port, setup, turn_state)

    altered_payload = Map.put(payload, "instructions", "altered synthetic instructions")

    {altered_conn, altered_websocket} =
      public_websocket_send_text!(
        altered_conn,
        altered_websocket,
        altered_ref,
        CodexPooler.JSON.encode!(altered_payload)
      )

    {altered_conn, _altered_websocket, altered_frame} =
      public_websocket_receive_text!(altered_conn, altered_websocket, altered_ref)

    assert %{"status" => 409, "error" => %{"code" => "duplicate_turn"}} =
             CodexPooler.JSON.decode!(altered_frame)

    assert FakeUpstream.count(upstream) == 1

    assert replay_boundary_counts(setup.pool.id, turn.codex_session_id, request.id) ==
             counts_before

    {retry_conn, retry_websocket, retry_ref} = public_websocket_connect!(port, setup, turn_state)

    {retry_conn, retry_websocket} =
      public_websocket_send_text!(retry_conn, retry_websocket, retry_ref, raw_payload)

    {retry_conn, retry_websocket, retry_frame} =
      public_websocket_receive_text!(retry_conn, retry_websocket, retry_ref)

    retry_result = CodexPooler.JSON.decode!(retry_frame)
    assert %{"type" => "response.completed"} = retry_result

    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"status" => "succeeded"}
                    }},
                   @connection_shutdown_timeout_ms

    assert %Request{status: "succeeded"} = Repo.get!(Request, request.id)

    counts_after = replay_boundary_counts(setup.pool.id, turn.codex_session_id, request.id)
    assert counts_after.requests == 1
    assert counts_after.turns == 1
    assert counts_after.reservations == 1
    assert counts_after.attempts == 2
    assert counts_after.settlements == 1
    assert counts_after.releases == 1
    assert counts_after.entitlements == 1
    assert FakeUpstream.count(upstream) == 2

    assert [initial_send, replay_send] = FakeUpstream.requests(upstream)
    assert initial_send.path == "/backend-api/codex/responses"
    assert replay_send.path == "/backend-api/codex/responses"

    initial_payload = CodexPooler.JSON.decode!(initial_send.body)
    replay_payload = CodexPooler.JSON.decode!(replay_send.body)

    changed_fields =
      (Map.keys(initial_payload) ++ Map.keys(replay_payload))
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(initial_payload, &1) != Map.get(replay_payload, &1)))
      |> Enum.map(fn field ->
        if field in ~w(client_metadata input instructions reasoning tools parallel_tool_calls),
          do: field,
          else: "other"
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert changed_fields == []
    byte_identical? = initial_send.body == replay_send.body
    assert byte_identical?

    assert %Request{status: "succeeded"} = Repo.get!(Request, request.id)

    assert %CodexTurn{status: "succeeded", final_attempt_id: replay_attempt_id} =
             Repo.get!(CodexTurn, turn.id)

    assert %Attempt{replay_generation: 1, status: "succeeded"} =
             Repo.get!(Attempt, replay_attempt_id)

    assert %RequestReplayEntitlement{status: "consumed", closed_at: %DateTime{}} =
             Repo.get_by!(RequestReplayEntitlement, request_id: request.id)

    persisted =
      inspect(
        {request.request_metadata, turn,
         Repo.all(from(a in Attempt, where: a.request_id == ^request.id))}
      )

    refute persisted =~ setup.authorization
    refute persisted =~ raw_payload

    assert FakeUpstream.count(upstream) == 2

    {retry_conn, _retry_websocket} =
      assert_replay_followup_requests(
        {retry_conn, retry_websocket, retry_ref},
        payload,
        %{
          setup: setup,
          upstream: upstream,
          turn: turn,
          request: request,
          original_counts: counts_after
        }
      )

    {:ok, connections} = ThousandIsland.connection_pids(server)
    connection_monitors = Enum.map(connections, &{&1, Process.monitor(&1)})
    _result = Mint.HTTP.close(retry_conn)
    _result = Mint.HTTP.close(altered_conn)
    _result = Mint.HTTP.close(conn)

    Enum.each(connection_monitors, fn {pid, monitor} ->
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, @connection_shutdown_timeout_ms
    end)

    await_websocket_owner_absent!(turn.codex_session_id)
    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp assert_replay_followup_requests(
         {conn, websocket, ref},
         payload,
         %{
           setup: setup,
           upstream: upstream,
           turn: turn,
           request: request,
           original_counts: original_counts
         }
       ) do
    {conn, websocket} =
      Enum.reduce(
        [payload, payload],
        {conn, websocket},
        fn duplicate, {current_conn, current_websocket} ->
          {current_conn, current_websocket} =
            public_websocket_send_text!(
              current_conn,
              current_websocket,
              ref,
              CodexPooler.JSON.encode!(duplicate)
            )

          {current_conn, current_websocket, frame} =
            public_websocket_receive_text!(current_conn, current_websocket, ref)

          assert %{"status" => 409, "error" => %{"code" => "duplicate_turn"}} =
                   CodexPooler.JSON.decode!(frame)

          assert FakeUpstream.count(upstream) == 2

          assert replay_boundary_counts(setup.pool.id, turn.codex_session_id, request.id) ==
                   original_counts

          {current_conn, current_websocket}
        end
      )

    fresh_payload =
      update_in(payload, ["client_metadata", "x-codex-turn-metadata"], fn encoded ->
        encoded
        |> CodexPooler.JSON.decode!()
        |> Map.put("turn_id", "fresh-after-replay")
        |> CodexPooler.JSON.encode!()
      end)
      |> Map.put("input", [])
      |> Map.put("previous_response_id", "resp_replay_completed_123456")

    {conn, websocket} =
      public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(fresh_payload))

    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)
    assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(frame)

    assert_receive {Events, %{reason: "request_finalized", payload: %{"status" => "succeeded"}}},
                   @connection_shutdown_timeout_ms

    assert FakeUpstream.count(upstream) == 3
    assert replay_boundary_counts(setup.pool.id, turn.codex_session_id, request.id).attempts == 2

    assert Repo.aggregate(
             from(t in CodexTurn, where: t.codex_session_id == ^turn.codex_session_id),
             :count
           ) == 2

    {conn, websocket}
  end

  defp replay_boundary_counts(pool_id, session_id, request_id) do
    %{
      requests:
        Repo.aggregate(from(request in Request, where: request.pool_id == ^pool_id), :count),
      attempts:
        Repo.aggregate(from(attempt in Attempt, where: attempt.request_id == ^request_id), :count),
      turns:
        Repo.aggregate(
          from(turn in CodexTurn, where: turn.codex_session_id == ^session_id),
          :count
        ),
      reservations:
        Repo.aggregate(
          from(entry in LedgerEntry,
            where: entry.request_id == ^request_id and entry.entry_kind == "reservation"
          ),
          :count
        ),
      settlements:
        Repo.aggregate(
          from(entry in LedgerEntry,
            where: entry.request_id == ^request_id and entry.entry_kind == "settlement"
          ),
          :count
        ),
      releases:
        Repo.aggregate(
          from(entry in LedgerEntry,
            where: entry.request_id == ^request_id and entry.entry_kind == "release"
          ),
          :count
        ),
      entitlements:
        Repo.aggregate(
          from(entitlement in RequestReplayEntitlement,
            where: entitlement.request_id == ^request_id
          ),
          :count
        )
    }
  end

  defp await_websocket_owner_absent!(codex_session_id) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner_pid} ->
        monitor = Process.monitor(owner_pid)

        try do
          GenServer.stop(owner_pid, :shutdown, @connection_shutdown_timeout_ms)
        catch
          :exit, {:noproc, _details} -> :ok
        end

        assert_receive {:DOWN, ^monitor, :process, ^owner_pid, _reason},
                       @connection_shutdown_timeout_ms

      {:error, :owner_unavailable} ->
        :ok
    end

    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(codex_session_id)
  end
end
