defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketCompactionFailureTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    CodexTurn,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  @raw_sentinel "synthetic-v2-terminal-private-message"
  @detection_timeout_ms 15_000

  test "V2 native collector preserves valid identifiers and omits malformed optionals" do
    cases = [
      {%{
         "type" => "compaction",
         "encrypted_content" => "synthetic-native-encrypted",
         "id" => "cmp_valid_native_id",
         "internal_chat_message_metadata_passthrough" => %{
           "turn_id" => "turn_valid_native_id",
           "ignored" => @raw_sentinel
         },
         "summary" => @raw_sentinel
       },
       %{
         "type" => "compaction",
         "encrypted_content" => "synthetic-native-encrypted",
         "id" => "cmp_valid_native_id",
         "internal_chat_message_metadata_passthrough" => %{
           "turn_id" => "turn_valid_native_id"
         }
       }},
      {%{
         "type" => "compaction",
         "encrypted_content" => "synthetic-native-encrypted",
         "id" => ["malformed-optional-id"],
         "internal_chat_message_metadata_passthrough" => %{
           "turn_id" => ["malformed-optional-turn-id"]
         }
       }, %{"type" => "compaction", "encrypted_content" => "synthetic-native-encrypted"}}
    ]

    for {source_item, expected_item} <- cases do
      mode =
        FakeUpstream.sse_stream([
          native_compaction_item_event(source_item),
          {"response.completed",
           %{
             "type" => "response.completed",
             "response" => %{"id" => "resp_native_success", "status" => "completed"}
           }}
        ])

      upstream = start_upstream(mode)
      setup = gateway_setup(upstream, compact?: true)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, session} = Websocket.start_codex_session(auth, %{})

      assert :ok =
               Service.execute_websocket_response(
                 auth,
                 compact_payload(setup),
                 native_options(session, compact_payload(setup)),
                 fn frame -> send(self(), {:native_frame, frame}) end
               )

      assert_receive {:native_frame, done_frame}, 15_000
      assert_receive {:native_frame, completed_frame}, 15_000

      assert %{"type" => "response.output_item.done", "item" => ^expected_item} =
               Jason.decode!(done_frame)

      assert %{
               "type" => "response.completed",
               "response" => %{"output" => [^expected_item]}
             } = Jason.decode!(completed_frame)

      refute done_frame =~ @raw_sentinel
      refute completed_frame =~ @raw_sentinel
    end
  end

  test "V2 native collector terminal families fail once without retry or replay" do
    cases = [
      {"response.failed", response_failed(),
       {"context_length_exceeded", "response.failed", "input"}},
      {"response.incomplete", failure_coded_incomplete(),
       {"server_error", "response.incomplete", "input"}},
      {"error", top_level_error(), {"invalid_request", "error", "input"}},
      {"response.incomplete", ordinary_incomplete(),
       {"max_output_tokens", "response.incomplete", nil}}
    ]

    for {event_type, terminal, diagnostics} <- cases do
      mode =
        FakeUpstream.sse_stream(
          [native_compaction_item_event(), {event_type, terminal}],
          done: false
        )

      result = execute_failure(mode)

      assert result.error == %{
               status: 502,
               code: "invalid_compaction_response",
               message: "upstream compact stream was invalid"
             }

      assert_failure_contract(result, "invalid_compaction_response",
        diagnostics: diagnostics,
        health: :failed
      )
    end
  end

  test "V2 malformed native result fails once without retry or replay" do
    mode =
      FakeUpstream.sse_stream([
        {"response.output_item.done",
         %{
           "type" => "response.output_item.done",
           "item" => %{"type" => "compaction", "encrypted_content" => "   "}
         }},
        {"response.completed",
         %{
           "type" => "response.completed",
           "response" => %{"id" => "resp_malformed_compaction", "status" => "completed"}
         }}
      ])

    result = execute_failure(mode)

    assert result.error.code == "invalid_compaction_response"

    assert_failure_contract(result, "invalid_compaction_response",
      diagnostics: {nil, nil, nil},
      health: :failed
    )
  end

  test "V2 plain pre-terminal interruption stays health-neutral and never retries" do
    result = execute_failure(FakeUpstream.websocket_sse_then_close([]))

    assert result.error.code == "invalid_compaction_response"

    assert_failure_contract(result, "upstream_stream_error",
      diagnostics: {nil, nil, nil},
      health: :neutral
    )

    assert_transport_failure(result, "peer_close_frame", "upstream_close")
  end

  test "V2 upstream idle timeout records its exact health failure and never retries" do
    release_ref = make_ref()

    result =
      execute_failure(
        FakeUpstream.websocket_idle_timeout(notify: self(), release_ref: release_ref),
        receive_timeout: 100
      )

    assert_receive {:fake_upstream_timeout_barrier, :websocket_idle, upstream_pid, ^release_ref},
                   @detection_timeout_ms

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert result.error.code == "invalid_compaction_response"

    assert_failure_contract(result, "stream_idle_timeout",
      diagnostics: {nil, nil, nil},
      health: :failed
    )

    assert_transport_failure(result, "pooler_receive_timeout", "receive_timeout")
  end

  test "connection-bound compact suppresses retryable first-event replay" do
    anchor = "resp_connection_bound_retry_anchor"

    first_upstream =
      start_upstream(
        {:sequence,
         [
           completed_websocket_response(anchor),
           FakeUpstream.sse_stream(
             [
               {"error",
                %{
                  "type" => "error",
                  "status" => 400,
                  "code" => "websocket_connection_limit_reached",
                  "param" => "reasoning.effort",
                  "message" => @raw_sentinel
                }}
             ],
             done: false
           ),
           successful_compaction_response("retry_must_not_run")
         ]}
      )

    setup = gateway_setup(first_upstream, compact?: true)

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok,
            %{
              codex_session: session,
              upstream_websocket_session: upstream_websocket_session
            }} = Websocket.prepare_websocket_session(auth)

    request_options =
      Websocket.websocket_response_options(
        %{request_id: "connection-bound-retry-policy"},
        session,
        upstream_websocket_session,
        true
      )

    assert :ok =
             Service.execute_websocket_response(
               auth,
               ordinary_payload(setup, anchor),
               request_options,
               fn _frame -> :ok end
             )

    result =
      Service.execute_websocket_response(
        auth,
        compact_payload(setup, anchor),
        request_options,
        fn frame -> send(self(), {:unexpected_native_frame, frame}) end
      )

    assert FakeUpstream.count(first_upstream) == 2
    assert FakeUpstream.http_request_count(first_upstream) == 0
    assert FakeUpstream.websocket_connection_count(first_upstream) == 1

    compact_request =
      Repo.one!(
        from(request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.endpoint == "/backend-api/codex/responses/compact"
        )
      )

    assert compact_request.status == "failed"
    assert compact_request.retry_count == 0

    assert [compact_attempt] =
             Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_request.id))

    assert compact_attempt.status == "failed"
    refute compact_attempt.retryable

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^compact_request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert {:error, %{code: _code}} = result
    refute_received {:unexpected_native_frame, _frame}
  end

  test "connection-bound compact suppresses websocket auth refresh and reconnect" do
    anchor = "resp_connection_bound_auth_anchor"

    upstream =
      start_upstream(
        {:sequence,
         [
           completed_websocket_response(anchor),
           FakeUpstream.sse_stream(
             [
               {"response.failed",
                %{
                  "type" => "response.failed",
                  "response" => %{
                    "status" => "failed",
                    "error" => %{
                      "code" => "invalid_api_key",
                      "param" => "reasoning.effort",
                      "message" => @raw_sentinel
                    }
                  }
                }}
             ],
             done: false
           ),
           FakeUpstream.json_response(%{"access_token" => "refresh-must-not-run"}, 200),
           successful_compaction_response("auth_retry_must_not_run")
         ]}
      )

    setup = gateway_setup(upstream, compact?: true)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(setup.identity, %{
               secret_kind: "refresh_token",
               plaintext: "synthetic-compact-refresh-token"
             })

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok,
            %{
              codex_session: session,
              upstream_websocket_session: upstream_websocket_session
            }} = Websocket.prepare_websocket_session(auth)

    request_options =
      Websocket.websocket_response_options(
        %{request_id: "connection-bound-auth-policy"},
        session,
        upstream_websocket_session,
        true
      )

    assert :ok =
             Service.execute_websocket_response(
               auth,
               ordinary_payload(setup, anchor),
               request_options,
               fn _frame -> :ok end
             )

    result =
      Service.execute_websocket_response(
        auth,
        compact_payload(setup, anchor),
        request_options,
        fn frame -> send(self(), {:unexpected_native_frame, frame}) end
      )

    assert FakeUpstream.count(upstream) == 2
    refute Enum.any?(FakeUpstream.requests(upstream), &(&1.path == "/oauth/token"))
    assert FakeUpstream.http_request_count(upstream) == 0
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    compact_request =
      Repo.one!(
        from(request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.endpoint == "/backend-api/codex/responses/compact"
        )
      )

    assert compact_request.status == "failed"
    assert compact_request.retry_count == 0
    refute Map.has_key?(compact_request.request_metadata || %{}, "auth_refresh")

    assert [compact_attempt] =
             Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_request.id))

    assert compact_attempt.status == "failed"
    refute compact_attempt.retryable

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^compact_request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert {:error, %{code: _code}} = result
    refute_received {:unexpected_native_frame, _frame}
    refute inspect({compact_request, compact_attempt}) =~ @raw_sentinel
    refute inspect({compact_request, compact_attempt}) =~ "synthetic-compact-refresh-token"
  end

  test "connection-bound compact suppresses pre-visible close reconnect" do
    anchor = "resp_connection_bound_close_anchor"

    upstream =
      start_upstream(
        {:sequence,
         [
           completed_websocket_response(anchor),
           FakeUpstream.websocket_sse_then_close([]),
           FakeUpstream.json_response(%{
             "id" => "resp_close_retry_must_not_run",
             "object" => "response"
           })
         ]}
      )

    setup = gateway_setup(upstream, compact?: true)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok,
            %{
              codex_session: session,
              upstream_websocket_session: upstream_websocket_session
            }} = Websocket.prepare_websocket_session(auth)

    request_options =
      Websocket.websocket_response_options(
        %{request_id: "connection-bound-close-policy"},
        session,
        upstream_websocket_session,
        true
      )

    assert :ok =
             Service.execute_websocket_response(
               auth,
               ordinary_payload(setup, anchor),
               request_options,
               fn _frame -> :ok end
             )

    assert {:error, %{code: _code}} =
             Service.execute_websocket_response(
               auth,
               compact_payload(setup, anchor),
               request_options,
               fn frame -> send(self(), {:unexpected_native_frame, frame}) end
             )

    assert FakeUpstream.count(upstream) == 2
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
    refute_received {:unexpected_native_frame, _frame}

    compact_request =
      Repo.one!(
        from(request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.endpoint == "/backend-api/codex/responses/compact"
        )
      )

    assert compact_request.status == "failed"
    assert compact_request.retry_count == 0

    assert [compact_attempt] =
             Repo.all(from(attempt in Attempt, where: attempt.request_id == ^compact_request.id))

    assert compact_attempt.status == "failed"
    refute compact_attempt.retryable

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^compact_request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert_health(setup.assignment, compact_request, "upstream_stream_error", :failed)
  end

  defp execute_failure(first_mode, opts \\ []) do
    first_upstream = start_upstream(first_mode)

    second_upstream = start_upstream(first_mode)

    setup = gateway_setup(first_upstream, compact?: true)

    second =
      gateway_upstream(setup.pool, second_upstream, "upstream-token-second-candidate",
        compact?: true
      )

    prime_routing_quota!(second.identity)
    use_routing_strategy!(setup.pool, "bridge_ring", 2)

    model = put_model_source_assignments!(setup.model, [setup.assignment, second.assignment])
    setup = %{setup | model: model}
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Websocket.start_codex_session(auth, %{})

    request_options =
      native_options(session, compact_payload(setup), %{
        request_id:
          seed_preferring_assignment(
            [setup.assignment.id, second.assignment.id],
            setup.assignment.id
          ),
        receive_timeout: Keyword.get(opts, :receive_timeout, 5_000)
      })

    assert {:error, error} =
             Service.execute_websocket_response(
               auth,
               compact_payload(setup),
               request_options,
               fn frame -> send(self(), {:unexpected_native_frame, frame}) end
             )

    {selected_upstream, selected_assignment, unselected_upstream} =
      case {FakeUpstream.count(first_upstream), FakeUpstream.count(second_upstream)} do
        {1, 0} -> {first_upstream, setup.assignment, second_upstream}
        {0, 1} -> {second_upstream, second.assignment, first_upstream}
      end

    %{
      error: error,
      selected_assignment: selected_assignment,
      selected_upstream: selected_upstream,
      session: session,
      setup: setup,
      unselected_upstream: unselected_upstream
    }
  end

  defp assert_failure_contract(result, expected_code, opts) do
    diagnostics = Keyword.fetch!(opts, :diagnostics)
    health = Keyword.fetch!(opts, :health)

    refute_received {:unexpected_native_frame, _frame}
    assert FakeUpstream.count(result.selected_upstream) == 1
    assert FakeUpstream.count(result.unselected_upstream) == 0
    assert FakeUpstream.http_request_count(result.selected_upstream) == 0
    assert FakeUpstream.websocket_connection_count(result.selected_upstream) == 1

    assert [request] =
             Repo.all(from(request in Request, where: request.pool_id == ^result.setup.pool.id))

    assert request.status == "failed"
    assert request.last_error_code == expected_code
    assert request.retry_count == 0

    assert [attempt] =
             Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

    assert attempt.pool_upstream_assignment_id == result.selected_assignment.id
    assert attempt.status == "failed"
    assert attempt.network_error_code == expected_code
    refute attempt.retryable

    assert [turn] =
             Repo.all(
               from(turn in CodexTurn,
                 where:
                   turn.codex_session_id == ^result.session.id and turn.request_id == ^request.id
               )
             )

    assert turn.status == "failed"
    assert turn.error_code == expected_code
    assert turn.final_attempt_id == attempt.id

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert_diagnostics(attempt.response_metadata, diagnostics)
    assert_health(result.selected_assignment, request, expected_code, health)

    persisted = inspect({request, attempt, turn})
    refute persisted =~ @raw_sentinel
    refute persisted =~ "synthetic-native-encrypted"
    refute persisted =~ "malformed-optional-id"
    refute persisted =~ "malformed-optional-turn-id"
  end

  defp assert_diagnostics(metadata, {upstream_code, event_type, error_param}) do
    assert Map.get(metadata, "upstream_error_code") == upstream_code
    assert Map.get(metadata, "stream_terminal_type") == event_type
    assert Map.get(metadata, "upstream_error_param") == error_param
  end

  defp assert_transport_failure(result, source, phase) do
    attempt =
      Repo.one!(
        from(attempt in Attempt,
          where: attempt.pool_upstream_assignment_id == ^result.selected_assignment.id
        )
      )

    assert %{
             "termination_source" => ^source,
             "phase" => ^phase,
             "terminal_seen" => false
           } = attempt.response_metadata["transport_failure"]
  end

  defp assert_health(selected_assignment, request, expected_code, :failed) do
    assert get_in(request.request_metadata, ["routing", "demotion_reason"]) == expected_code

    assert [demotion] =
             Repo.all(
               from(demotion in BridgeDemotion,
                 where: demotion.pool_id == ^request.pool_id
               )
             )

    assert demotion.pool_upstream_assignment_id == selected_assignment.id
    assert demotion.reason_code == expected_code
    assert demotion.status == "active"
    assert demotion.metadata == %{"source" => "gateway_failure"}

    assert [circuit] =
             Repo.all(
               from(circuit in RoutingCircuitState,
                 where: circuit.pool_id == ^request.pool_id
               )
             )

    assert circuit.pool_upstream_assignment_id == selected_assignment.id
    assert circuit.reason_code == expected_code
    assert circuit.failure_count == 1
  end

  defp assert_health(_setup, request, _expected_code, :neutral) do
    refute get_in(request.request_metadata, ["routing", "demotion_reason"])

    assert Repo.all(from(demotion in BridgeDemotion, where: demotion.pool_id == ^request.pool_id)) ==
             []

    assert Repo.all(
             from(circuit in RoutingCircuitState, where: circuit.pool_id == ^request.pool_id)
           ) == []
  end

  defp compact_payload(setup) do
    compact_payload(setup, nil)
  end

  defp compact_payload(setup, anchor) do
    Jason.encode!(
      %{
        "type" => "response.create",
        "model" => setup.model.exposed_model_id,
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "synthetic compact input"},
          %{"type" => "compaction_trigger"}
        ],
        "stream" => true,
        "generate" => true,
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            Jason.encode!(%{
              "turn_id" => "native-compact-#{setup.pool.id}",
              "window_id" => "native-window-#{setup.pool.id}",
              "context_window_id" => setup.pool.id,
              "window_number" => 1,
              "request_kind" => "compaction",
              "compaction" => %{
                "trigger" => "auto",
                "reason" => "context_limit",
                "implementation" => "responses_compaction_v2",
                "phase" => "pre_turn",
                "strategy" => "memento"
              }
            })
        }
      }
      |> maybe_put_previous_response_id(anchor)
    )
  end

  defp native_options(session, payload, attrs \\ %{}) do
    assert {:ok, %NativeCodexTurnMetadata{request_kind: :compaction} = metadata} =
             NativeCodexTurnMetadata.parse(Jason.decode!(payload), session.id)

    for digest <- [
          metadata.semantic_turn_key,
          metadata.window_id_digest,
          metadata.context_window_id_digest
        ] do
      assert is_binary(digest) and byte_size(digest) == 32
    end

    owner = start_supervised!({UpstreamWebsocketSession, []}, id: make_ref())

    attrs
    |> Websocket.websocket_response_options(session, owner, true)
    |> RequestOptions.put_payload_context(native_codex_turn_metadata: metadata)
  end

  defp ordinary_payload(setup, response_id) do
    Jason.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [%{"type" => "message", "role" => "user", "content" => "synthetic lineage"}],
      "stream" => true,
      "generate" => true,
      "client_metadata" => %{"synthetic_response_id" => response_id}
    })
  end

  defp maybe_put_previous_response_id(payload, nil), do: payload

  defp maybe_put_previous_response_id(payload, anchor),
    do: Map.put(payload, "previous_response_id", anchor)

  defp completed_websocket_response(response_id) do
    FakeUpstream.sse_stream(
      [
        {"response.completed",
         %{
           "type" => "response.completed",
           "response" => %{"id" => response_id, "status" => "completed", "output" => []}
         }}
      ],
      done: false
    )
  end

  defp successful_compaction_response(suffix) do
    FakeUpstream.sse_stream(
      [
        native_compaction_item_event(%{
          "type" => "compaction",
          "encrypted_content" => "synthetic-native-encrypted-#{suffix}"
        }),
        {"response.completed",
         %{
           "type" => "response.completed",
           "response" => %{"id" => "resp_#{suffix}", "status" => "completed"}
         }}
      ],
      done: false
    )
  end

  defp native_compaction_item_event(item \\ nil)

  defp native_compaction_item_event(nil) do
    native_compaction_item_event(%{
      "type" => "compaction",
      "encrypted_content" => "synthetic-native-encrypted",
      "id" => "cmp_valid_native_id",
      "internal_chat_message_metadata_passthrough" => %{
        "turn_id" => "turn_valid_native_id",
        "ignored" => @raw_sentinel
      },
      "summary" => @raw_sentinel
    })
  end

  defp native_compaction_item_event(item) do
    {"response.output_item.done",
     %{
       "type" => "response.output_item.done",
       "item" => item
     }}
  end

  defp response_failed do
    %{
      "type" => "response.failed",
      "response" => %{
        "status" => "failed",
        "error" => %{
          "code" => "context_length_exceeded",
          "param" => "input",
          "message" => @raw_sentinel
        }
      }
    }
  end

  defp failure_coded_incomplete do
    %{
      "type" => "response.incomplete",
      "response" => %{
        "status" => "incomplete",
        "error" => %{
          "code" => "server_error",
          "param" => "input",
          "message" => @raw_sentinel
        }
      }
    }
  end

  defp top_level_error do
    %{
      "type" => "error",
      "error" => %{
        "code" => "invalid_request",
        "param" => "input",
        "message" => @raw_sentinel
      }
    }
  end

  defp ordinary_incomplete do
    %{
      "type" => "response.incomplete",
      "response" => %{
        "status" => "incomplete",
        "incomplete_details" => %{"reason" => "max_output_tokens"},
        "metadata" => %{"ignored" => @raw_sentinel}
      }
    }
  end
end
