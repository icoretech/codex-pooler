defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwarding.CompactionTest do
  use CodexPoolerWeb.ConnCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.RequestClientRetryLink
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.BridgeSessionAlias
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.ReplayRemoteNodeClient
  alias CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport.TurnBudgetNodeClient

  @handoff_detection_timeout_ms 15_000

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      cleanup_local_owner_sessions()
      TurnBudgetNodeClient.reset()
      ReplayRemoteNodeClient.reset()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  test "owner-forwarded native anchored compact uses V2 collect on the current connection" do
    final_release_ref = make_ref()

    compact_item = %{
      "type" => "compaction",
      "encrypted_content" => "synthetic-owner-collect-encrypted"
    }

    frames = fn events -> Enum.map(events, &CodexPooler.JSON.encode!/1) end

    # Strict finite scenario: the anchor, the anchored V2 collect compact, and
    # the final that opens with the compaction item are the only sends, all on
    # the owner's single connection; the final is held frame by frame so the
    # session alias can be checked while it is still pre-visible.
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (compaction v2-shaped created/completed/output_item.done frames, not captured)
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "message"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames(
                frames.([
                  %{
                    "type" => "response.created",
                    "response" => %{
                      "id" => "resp_owner_collect_anchor",
                      "status" => "in_progress"
                    }
                  },
                  %{
                    "type" => "response.completed",
                    "response" => %{
                      "id" => "resp_owner_collect_anchor",
                      "status" => "completed",
                      "output" => []
                    }
                  }
                ])
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_owner_collect_anchor",
                "input.0.type" => "custom_tool_call_output"
              }
            ],
            respond:
              FakeUpstream.websocket_text_frames(
                frames.([
                  %{"type" => "response.output_item.done", "item" => compact_item},
                  %{
                    "type" => "response.completed",
                    "response" => %{
                      "id" => "resp_owner_collect_compact",
                      "status" => "completed",
                      "output" => [compact_item]
                    }
                  }
                ])
              )
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "compaction"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.barrier_websocket_frames(
                frames.([
                  %{
                    "type" => "response.created",
                    "response" => %{
                      "id" => "resp_owner_collect_final",
                      "status" => "in_progress"
                    }
                  },
                  %{
                    "type" => "response.completed",
                    "response" => %{
                      "id" => "resp_owner_collect_final",
                      "status" => "completed",
                      "output" => []
                    }
                  }
                ]),
                notify: self(),
                release_ref: final_release_ref
              )
          )
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    scope = model_serving_scope()
    _revision = set_model_serving_mode!(scope, setup, "full")
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "ws-owner-native-collect", "owner-native-collect")
    native_turn_id = "owner-native-collect-turn"
    context_window_id = "00000000-0000-4000-8000-000000000505"

    turn_metadata = fn request_kind ->
      base = %{
        "turn_id" => native_turn_id,
        "window_id" => "owner-native-collect-window",
        "context_window_id" => context_window_id,
        "window_number" => 1,
        "request_kind" => request_kind
      }

      if request_kind == "compaction" do
        Map.put(base, "compaction", %{
          "trigger" => "auto",
          "reason" => "context_limit",
          "implementation" => "responses_compaction_v2",
          "phase" => "mid_turn",
          "strategy" => "memento"
        })
      else
        base
      end
      |> CodexPooler.JSON.encode!()
    end

    try do
      anchor_payload =
        websocket_payload(setup, "synthetic owner collect anchor", %{
          "request_id" => "ws-owner-native-collect-anchor",
          "client_metadata" => %{
            "turn_id" => native_turn_id,
            "x-codex-turn-metadata" => turn_metadata.("turn")
          }
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({anchor_payload, [opcode: :text]}, state)

      assert {:push, {:text, anchor_frame}, state} = receive_owner_socket_push(state)

      assert %{"response" => %{"id" => "resp_owner_collect_anchor"}} =
               CodexPooler.JSON.decode!(anchor_frame)

      assert {:push, {:text, anchor_terminal_frame}, state} = receive_owner_socket_push(state)
      assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(anchor_terminal_frame)
      assert {:ok, state} = receive_socket_done(state)

      compact_payload =
        CodexPooler.JSON.encode!(%{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => "resp_owner_collect_anchor",
          "input" => [
            %{
              "type" => "custom_tool_call_output",
              "call_id" => "call_owner_collect",
              "output" => "synthetic owner tool output"
            },
            %{"type" => "compaction_trigger"}
          ],
          "stream" => true,
          "generate" => true,
          "request_id" => "ws-owner-native-collect-compact",
          "client_metadata" => %{
            "turn_id" => native_turn_id,
            "x-codex-turn-metadata" => turn_metadata.("compaction")
          }
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({compact_payload, [opcode: :text]}, state)

      assert {:push, {:text, done_frame}, state} = receive_native_collect_socket_push(state)

      assert %{"type" => "response.output_item.done", "item" => ^compact_item} =
               CodexPooler.JSON.decode!(done_frame)

      assert {:push, {:text, completed_frame}, state} = receive_native_collect_socket_push(state)
      assert {:ok, state} = receive_socket_done(state)

      assert %{
               "type" => "response.completed",
               "response" => %{"output" => [^compact_item]}
             } = CodexPooler.JSON.decode!(completed_frame)

      assert [anchor_request, compact_request] = FakeUpstream.requests(upstream)
      assert anchor_request.method == "WEBSOCKET"
      assert compact_request.method == "WEBSOCKET"
      assert anchor_request.websocket_connection_id == compact_request.websocket_connection_id
      assert FakeUpstream.http_request_count(upstream) == 0

      assert [anchor_log, compact_log] = request_logs(setup.pool.id)
      assert anchor_log.transport == "websocket"
      assert compact_log.endpoint == "/backend-api/codex/responses/compact"
      assert compact_log.transport == "websocket"
      assert compact_log.retry_count == 0
      assert compact_log.request_metadata["websocket_owner_forwarding"]["enabled"] == true

      assert [compact_attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_log.id))

      assert compact_attempt.transport == "websocket"
      assert compact_attempt.status == "succeeded"
      assert compact_attempt.response_metadata["upstream_websocket_connection"]["reused"] == true

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^compact_log.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      assert [compact_turn] =
               Repo.all(from(turn in CodexTurn, where: turn.request_id == ^compact_log.id))

      assert compact_turn.status == "succeeded"
      assert compact_turn.final_attempt_id == compact_attempt.id

      assert {:ok, owner} = WebsocketOwnerSession.lookup(state.codex_session.id)

      assert NativeCompactionAdmission.phase(:sys.get_state(owner).native_compaction_admission) ==
               :pending_final

      final_metadata =
        CodexPooler.JSON.encode!(%{
          "turn_id" => native_turn_id,
          "window_id" => "owner-native-collect-final-window",
          "context_window_id" => "00000000-0000-4000-8000-000000000506",
          "window_number" => 2,
          "request_kind" => "turn"
        })

      final_payload =
        websocket_payload(setup, "synthetic owner collect final", %{
          "request_id" => "ws-owner-native-collect-final",
          "client_metadata" => %{
            "turn_id" => native_turn_id,
            "x-codex-turn-metadata" => final_metadata
          },
          "input" => [
            compact_item,
            %{"type" => "message", "role" => "user", "content" => "final"}
          ]
        })

      assert {:ok, state} =
               CodexResponsesSocket.handle_in({final_payload, [opcode: :text]}, state)

      assert_receive {:fake_upstream_frame_barrier, 0, _handler, ^final_release_ref},
                     @handoff_detection_timeout_ms

      try do
        window_hash = :crypto.hash(:sha256, "owner-native-collect-final-window")

        alias_present? =
          Repo.exists?(
            from(alias_record in BridgeSessionAlias,
              where:
                alias_record.codex_session_id == ^state.codex_session.id and
                  alias_record.alias_kind == "session_header" and
                  alias_record.alias_hash == ^window_hash and alias_record.status == "active"
            )
          )

        assert alias_present?

        assert {:ok, reconnect_session} =
                 Gateway.start_codex_session(auth,
                   accepted_turn_state: "new-upgrade-generated-turn-state",
                   session_header_source: "x-codex-window-id",
                   session_header: "owner-native-collect-final-window"
                 )

        assert reconnect_session.id == state.codex_session.id
      after
        :ok = FakeUpstream.release_remaining_frames(upstream, final_release_ref)
      end

      assert {:ok, state} = receive_socket_done(state)

      assert_receive {:fake_upstream_frame_barrier, 2, _handler, ^final_release_ref},
                     @handoff_detection_timeout_ms

      assert [_anchor_request, compact_request, final_request] = FakeUpstream.requests(upstream)
      assert final_request.method == "WEBSOCKET"
      assert final_request.websocket_connection_id == compact_request.websocket_connection_id
      assert FakeUpstream.http_request_count(upstream) == 0

      assert [anchor_log, compact_log, final_log] = request_logs(setup.pool.id)

      request_ids = [anchor_log.id, compact_log.id, final_log.id]
      correlations = Enum.map([anchor_log, compact_log, final_log], & &1.correlation_id)

      assert length(Enum.uniq(correlations)) == 3
      assert length(request_ids) == 3

      attempts =
        Repo.all(
          from(attempt in Attempt,
            where: attempt.request_id in ^request_ids,
            order_by: [asc: attempt.started_at]
          )
        )

      turns =
        Repo.all(
          from(turn in CodexTurn,
            where:
              turn.codex_session_id == ^state.codex_session.id and turn.request_id in ^request_ids,
            order_by: [asc: turn.turn_sequence]
          )
        )

      ledger_entries =
        Repo.all(
          from(entry in LedgerEntry,
            where: entry.request_id in ^request_ids,
            order_by: [asc: entry.occurred_at]
          )
        )

      assert length(attempts) == 3
      assert Enum.all?(attempts, &(&1.status == "succeeded" and &1.transport == "websocket"))
      assert length(turns) == 3
      assert Enum.all?(turns, &(&1.status == "succeeded" and &1.transport_kind == "websocket"))
      assert Enum.count(ledger_entries, &(&1.entry_kind == "reservation")) == 3
      assert Enum.count(ledger_entries, &(&1.entry_kind == "settlement")) == 3

      connection_metadata =
        Enum.map(attempts, &get_in(&1.response_metadata, ["upstream_websocket_connection"]))

      assert Enum.all?(connection_metadata, &is_map/1)
      assert connection_metadata |> Enum.map(& &1["lifecycle_id"]) |> Enum.uniq() |> length() == 1
      assert connection_metadata |> Enum.map(& &1["generation"]) |> Enum.uniq() == [1]
      assert Enum.count(connection_metadata, &(&1["reused"] == false)) == 1
      assert Enum.count(connection_metadata, &(&1["reused"] == true)) == 2

      assert Enum.all?([anchor_log, compact_log, final_log], fn request ->
               request.retry_count == 0 and request.transport == "websocket"
             end)

      assert FakeUpstream.http_request_count(upstream) == 0

      assert final_log.transport == "websocket"
      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, state)
    end
  end

  test "socket preflight admits projected full-history compaction retry after stream close" do
    compact_item = %{"type" => "compaction", "encrypted_content" => "synthetic-retry-compact"}

    terminal = fn id, output ->
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => id,
           "status" => "completed",
           "output" => output
         }
       }}
    end

    {_event_name, anchor_terminal} = terminal.("resp_socket_compact_anchor", [])
    {_event_name, retry_terminal} = terminal.("resp_socket_compact_retry", [compact_item])

    upstream =
      start_upstream(
        # Strict finite scenario: the anchor and the anchored incremental compact
        # share the first connection, the incremental stream closes without a
        # terminal, and the projected full-history retry must arrive without the
        # anchor on the replacement connection with nothing else sent.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{"type" => "response.create"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(anchor_terminal)])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 1,
            json: [
              valid: true,
              equals: %{
                "type" => "response.create",
                "previous_response_id" => "resp_socket_compact_anchor",
                "input.0.type" => "function_call_output"
              }
            ],
            respond: FakeUpstream.websocket_sse_then_close([])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            websocket_connection_ordinal: 2,
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "function_call_output"},
              forbidden: ["previous_response_id"]
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "type" => "response.output_item.done",
                  "item" => compact_item
                }),
                CodexPooler.JSON.encode!(retry_terminal)
              ])
          )
        ])
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, state} = owner_socket(auth, "socket-compact-retry", "socket-compact-retry-state")

    anchor =
      websocket_payload(setup, "synthetic anchor", %{"request_id" => "socket-compact-anchor"})

    assert {:ok, state} = CodexResponsesSocket.handle_in({anchor, [opcode: :text]}, state)
    assert {:push, {:text, _anchor_frame}, state} = receive_owner_socket_push(state)
    assert {:ok, state} = receive_socket_done(state)

    metadata =
      CodexPooler.JSON.encode!(%{
        "turn_id" => "socket-compact-turn",
        "window_id" => "socket-compact-window",
        "context_window_id" => Ecto.UUID.generate(),
        "window_number" => 1,
        "request_kind" => "compaction",
        "compaction" => %{
          "trigger" => "auto",
          "reason" => "context_limit",
          "implementation" => "responses_compaction_v2",
          "phase" => "mid_turn",
          "strategy" => "memento"
        }
      })

    compact = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "previous_response_id" => "resp_socket_compact_anchor",
      "stream" => true,
      "input" => [
        %{"type" => "function_call_output", "call_id" => "call_socket_compact", "output" => ""},
        %{"type" => "compaction_trigger"}
      ],
      "client_metadata" => %{"x-codex-turn-metadata" => metadata}
    }

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {CodexPooler.JSON.encode!(compact), [opcode: :text]},
               state
             )

    assert {:push, {:text, error_frame}, state} = receive_native_collect_socket_push(state)

    assert %{"error" => %{"code" => "upstream_request_failed"}} =
             CodexPooler.JSON.decode!(error_frame)

    retry = compact |> Map.delete("previous_response_id") |> CodexPooler.JSON.encode!()
    assert {:ok, state} = CodexResponsesSocket.handle_in({retry, [opcode: :text]}, state)
    assert {:push, {:text, done_frame}, state} = receive_native_collect_socket_push(state)

    assert %{"type" => "response.output_item.done", "item" => ^compact_item} =
             CodexPooler.JSON.decode!(done_frame)

    assert {:push, {:text, completed_frame}, state} = receive_native_collect_socket_push(state)
    assert %{"type" => "response.completed"} = CodexPooler.JSON.decode!(completed_frame)
    assert {:ok, state} = receive_socket_done(state)

    assert [first, incremental, full_history] = FakeUpstream.requests(upstream)
    assert Enum.all?([first, incremental, full_history], &(&1.method == "WEBSOCKET"))
    assert FakeUpstream.http_request_count(upstream) == 0

    compact_requests =
      Repo.all(
        from(r in Request,
          where:
            r.pool_id == ^setup.pool.id and r.endpoint == "/backend-api/codex/responses/compact"
        )
      )

    assert Enum.sort(Enum.map(compact_requests, & &1.status)) == ["failed", "succeeded"]
    ids = Enum.map(compact_requests, & &1.id)

    assert Repo.aggregate(
             from(l in RequestClientRetryLink,
               where: l.predecessor_request_id in ^ids and l.successor_request_id in ^ids
             ),
             :count
           ) == 1

    assert :ok = FakeUpstream.verify!(upstream)
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
  end

  @tag :no_rollover_history
  test "fresh tool continuation after historical compaction keeps a distinct request claim" do
    call = %{
      "type" => "function_call",
      "call_id" => "call_synthetic_history",
      "name" => "synthetic_lookup",
      "arguments" => "{}"
    }

    upstream =
      start_upstream(
        # Strict finite scenario: the historical turn and the fresh tool
        # continuation are the only two sends, both opening with the compaction
        # history item; the duplicate client retry sends nothing.
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "compaction"}
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_synthetic_history",
                  "object" => "response",
                  "output" => [call]
                })
              ])
          ),
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            json: [
              valid: true,
              equals: %{"type" => "response.create", "input.0.type" => "compaction"}
            ],
            respond:
              FakeUpstream.websocket_text_frames([
                CodexPooler.JSON.encode!(%{
                  "id" => "resp_synthetic_continuation",
                  "object" => "response",
                  "output" => []
                })
              ])
          )
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    metadata = %{
      "turn_id" => "synthetic-history-turn",
      "x-codex-turn-metadata" =>
        CodexPooler.JSON.encode!(%{
          "turn_id" => "synthetic-history-turn",
          "request_kind" => "turn"
        })
    }

    history = [%{"type" => "compaction", "encrypted_content" => "synthetic-history-summary"}]

    {:ok, first_state} =
      owner_socket(auth, "synthetic-history-first", "synthetic-history-session")

    payload = websocket_input_payload(setup, history, %{"client_metadata" => metadata})

    assert {:ok, first_state} =
             CodexResponsesSocket.handle_in({payload, [opcode: :text]}, first_state)

    assert {:push, {:text, frame}, first_state} = receive_owner_socket_push(first_state)
    assert [received_call] = CodexPooler.JSON.decode!(frame)["output"]
    assert received_call == call
    assert {:ok, first_state} = receive_socket_done(first_state)
    assert :ok = CodexResponsesSocket.terminate(:closed, first_state)
    assert [%{status: "succeeded"}] = request_logs(setup.pool.id)

    {:ok, next_state} = owner_socket(auth, "synthetic-history-next", "synthetic-history-session")

    next_input =
      history ++
        [
          received_call,
          %{
            "type" => "function_call_output",
            "call_id" => received_call["call_id"],
            "output" => "synthetic-result"
          }
        ]

    next_payload = websocket_input_payload(setup, next_input, %{"client_metadata" => metadata})

    assert {:ok, prepared} =
             Service.prepare_websocket_response(
               next_payload,
               RequestOptions.build(
                 %{codex_session: next_state.codex_session, api_key_runtime_epoch: 0},
                 "/backend-api/codex/responses",
                 CodexPooler.JSON.decode!(next_payload)
               ),
               fn _ -> :ok end
             )

    assert {:error, :payload_mismatch} =
             Accounting.client_retry_preflight_snapshot(
               next_state.codex_session,
               auth.api_key,
               setup.model,
               %{
                 semantic_turn_digest: prepared.semantic_turn_key,
                 replay_claim_digest: prepared.replay_claim_digest,
                 endpoint: "/backend-api/codex/responses",
                 requested_model: setup.model.exposed_model_id,
                 runtime_revocation_epoch: auth.api_key.runtime_revocation_epoch,
                 anchor_present?: false
               }
             )

    try do
      result = CodexResponsesSocket.handle_in({next_payload, [opcode: :text]}, next_state)
      assert match?({:ok, _}, result), "fresh historical tool continuation was rejected"
      {:ok, next_state} = result
      assert {:push, {:text, _frame}, next_state} = receive_owner_socket_push(next_state)
      assert {:ok, next_state} = receive_socket_done(next_state)

      assert {:ok, retry_state} =
               CodexResponsesSocket.handle_in({next_payload, [opcode: :text]}, next_state)

      assert {:push, {:text, retry_frame}, retry_state} = receive_owner_socket_push(retry_state)
      assert CodexPooler.JSON.decode!(retry_frame)["error"]["code"] == "duplicate_turn"
      assert MapSet.size(retry_state.tasks) == 0
      assert :ok = CodexResponsesSocket.terminate(:closed, retry_state)
      assert [first, second] = request_logs(setup.pool.id)
      assert first.status == "succeeded"
      assert second.status == "succeeded"
      refute first.correlation_id == second.correlation_id
      assert length(await_upstream_requests(upstream, 2)) == 2

      request_ids = [first.id, second.id]

      assert Repo.aggregate(
               from(attempt in Attempt, where: attempt.request_id in ^request_ids),
               :count
             ) == 2

      assert Repo.aggregate(
               from(turn in CodexTurn,
                 where: turn.request_id in ^request_ids and turn.status == "succeeded"
               ),
               :count
             ) == 2

      refute Repo.exists?(
               from(link in RequestClientRetryLink,
                 where: link.predecessor_request_id in ^request_ids
               )
             )

      for request_id <- request_ids do
        kinds =
          Repo.all(
            from(entry in LedgerEntry,
              where: entry.request_id == ^request_id,
              select: entry.entry_kind
            )
          )

        assert Enum.sort(kinds) == ["release", "reservation", "settlement"]
      end

      assert :ok = FakeUpstream.verify!(upstream)
    after
      CodexResponsesSocket.terminate(:closed, next_state)
    end
  end
end
