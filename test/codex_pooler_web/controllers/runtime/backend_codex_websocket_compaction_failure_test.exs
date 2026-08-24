defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketCompactionFailureTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    CodexTurn,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Repo

  @raw_sentinel "synthetic-v2-terminal-private-message"

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
                 RequestOptions.for_websocket(%{codex_session: session}),
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
    result = execute_failure(FakeUpstream.abrupt_close_mid_stream([]))

    assert result.error.code == "invalid_compaction_response"

    assert_failure_contract(result, "upstream_stream_error",
      diagnostics: {nil, nil, nil},
      health: :neutral
    )
  end

  test "V2 upstream idle timeout records its exact health failure and never retries" do
    release_ref = make_ref()

    result =
      execute_failure(
        FakeUpstream.timeout_after_sse_headers(notify: self(), release_ref: release_ref),
        receive_timeout: 100
      )

    assert_receive {:fake_upstream_timeout_barrier, :after_sse_headers, upstream_pid,
                    ^release_ref},
                   1_000

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert result.error.code == "invalid_compaction_response"

    assert_failure_contract(result, "stream_idle_timeout",
      diagnostics: {nil, nil, nil},
      health: :failed
    )
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
      RequestOptions.for_websocket(%{
        codex_session: session,
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
    Jason.encode!(%{
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
          Jason.encode!(%{"compaction" => %{"implementation" => "responses_compaction_v2"}})
      }
    })
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
