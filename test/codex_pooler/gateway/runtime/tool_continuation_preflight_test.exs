defmodule CodexPooler.Gateway.Runtime.ToolContinuationPreflightTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.AccountingTestSupport
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{ClientRetry, RequestClientRetryLink}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Repo

  test "changed completed-tool continuation remains fresh before its distinct ordinary claim" do
    setup = accounting_setup()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session =
      Repo.insert!(%CodexSession{
        pool_id: setup.pool.id,
        api_key_id: setup.api_key.id,
        session_key: "diagnosis-#{System.unique_integer([:positive])}",
        pool_upstream_assignment_id: setup.assignment.id,
        status: "active",
        created_at: now,
        updated_at: now
      })

    metadata = %{
      "turn_id" => "synthetic-turn",
      "request_kind" => "turn",
      "window_id" => "synthetic-window",
      "window_number" => 1,
      "context_window_id" => Ecto.UUID.generate()
    }

    original = %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [%{"role" => "user", "content" => "synthetic"}],
      "client_metadata" => %{"x-codex-turn-metadata" => Jason.encode!(metadata)}
    }

    continuation =
      Map.update!(
        original,
        "input",
        &(&1 ++
            [
              %{
                "type" => "function_call",
                "call_id" => "call_synthetic",
                "name" => "synthetic",
                "arguments" => "{}"
              },
              %{
                "type" => "function_call_output",
                "call_id" => "call_synthetic",
                "output" => "synthetic-result"
              }
            ])
      )

    first = prepare(original, session, setup)
    next = prepare(continuation, session, setup)
    assert first.semantic_turn_key == next.semantic_turn_key
    refute first.replay_claim_digest == next.replay_claim_digest
    assert first.request_options.continuity.request_claim_key == first.turn_claim_key
    refute next.request_options.continuity.request_claim_key == first.turn_claim_key

    assert String.starts_with?(
             next.request_options.continuity.request_claim_key,
             "codex-request:"
           )

    witness =
      ClientRetry.original_witness!(
        first.replay_claim_digest,
        setup.api_key.runtime_revocation_epoch
      )

    {:ok, %{request: request}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: first.turn_claim_key,
        native_client_retry_witness: witness
      })

    request =
      Repo.update!(
        Ecto.Changeset.change(request,
          status: "failed",
          completed_at: now,
          last_error_code: "upstream_stream_error",
          usage_status: "usage_unknown"
        )
      )

    attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(request, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "upstream_stream_error",
        usage_status: "usage_unknown",
        transport: "websocket",
        replay_generation: 0,
        response_metadata: %{
          "transport_failure" => %{
            "phase" => "receive",
            "termination_source" => "peer_close_frame",
            "transport_signal" => "tcp_closed"
          },
          "native_client_retry_observation" => %{
            "version" => 1,
            "authority_complete" => true,
            "output_item_done_count" => 1,
            "output_item_done_count_saturated" => false,
            "partial_reasoning_seen" => false,
            "first_visible_at" => DateTime.to_iso8601(now),
            "terminal_seen" => false,
            "terminal_candidate_seen" => false
          }
        }
      })

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      status: "failed",
      error_code: "upstream_stream_error",
      semantic_turn_digest: first.semantic_turn_key,
      first_visible_output_at: now,
      final_attempt_id: attempt.id,
      completed_at: now,
      started_at: now,
      created_at: now,
      updated_at: now
    })

    input = %{
      endpoint: "/backend-api/codex/responses",
      requested_model: setup.model.exposed_model_id,
      runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
      semantic_turn_digest: next.semantic_turn_key,
      replay_claim_digest: next.replay_claim_digest,
      anchor_present?: false
    }

    assert {:ok, {:error, :payload_mismatch}} =
             Repo.transaction(fn ->
               ClientRetry.preflight_snapshot(session, setup.api_key, setup.model, input)
             end)

    assert {:ok, {:error, :unsafe_completed_output}} =
             Repo.transaction(fn ->
               ClientRetry.preflight_snapshot(session, setup.api_key, setup.model, %{
                 input
                 | replay_claim_digest: first.replay_claim_digest
               })
             end)

    assert {:ok, %{intent: :fresh, lifecycle: nil}} =
             Service.prepare_replay_intent(setup.auth, next)

    assert {:error, %{code: "duplicate_turn"}} = Service.prepare_replay_intent(setup.auth, first)

    forged_options =
      RequestOptions.put_continuity(first.request_options,
        request_claim_key: next.request_options.continuity.request_claim_key
      )

    assert {:error, %{code: "invalid_request"}} =
             Service.prepare_replay_intent(setup.auth, %{first | request_options: forged_options})

    assert Repo.aggregate(RequestClientRetryLink, :count) == 0
    assert Repo.aggregate(CodexTurn, :count) == 1
    # The already-derived ordinary request claim itself remains available.
    assert {:ok, %{request: ordinary}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, %{
               endpoint: "/backend-api/codex/responses",
               correlation_id: next.request_options.continuity.request_claim_key
             })

    refute ordinary.id == request.id
    assert Repo.aggregate(RequestClientRetryLink, :count) == 0

    assert {:error, _} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, %{
               endpoint: "/backend-api/codex/responses",
               correlation_id: next.request_options.continuity.request_claim_key
             })
  end

  defp prepare(payload, session, setup) do
    options =
      RequestOptions.build(
        %{codex_session: session, transport: "websocket"},
        "/backend-api/codex/responses",
        payload
      )
      |> RequestOptions.put_runtime_context(
        api_key_runtime_epoch: setup.api_key.runtime_revocation_epoch
      )

    {:ok, prepared} =
      WebsocketCodec.prepare_frame(Jason.encode!(payload), options, fn _ -> :ok end)

    prepared
  end
end
