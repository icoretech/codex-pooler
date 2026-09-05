defmodule CodexPooler.Gateway.Runtime.NativeCompactionPreflightTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.AccountingTestSupport
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{ClientRetry, RequestClientRetryLink}
  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Binding
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession, as: Owner

  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request,
    as: OwnerRequest

  alias CodexPooler.Repo

  test "validated native compaction stays outside exact original retry classification" do
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

    compact_metadata =
      Map.merge(metadata, %{
        "request_kind" => "compaction",
        "compaction" => %{
          "trigger" => "auto",
          "reason" => "context_limit",
          "implementation" => "responses_compaction_v2",
          "phase" => "mid_turn",
          "strategy" => "memento"
        }
      })

    continuation =
      continuation
      |> Map.put("stream", true)
      |> Map.update!("input", &(&1 ++ [%{"type" => "compaction_trigger"}]))
      |> put_in(["client_metadata", "x-codex-turn-metadata"], Jason.encode!(compact_metadata))

    first = prepare(original, session, setup)

    continuation = Map.put(continuation, "previous_response_id", "resp_compact_seed")
    next = prepare(continuation, session, setup)
    assert first.semantic_turn_key == next.semantic_turn_key
    refute first.replay_claim_digest == next.replay_claim_digest
    assert first.request_options.continuity.request_claim_key == first.turn_claim_key
    assert next.request_options.continuity.request_claim_key == first.turn_claim_key
    assert next.endpoint == "/backend-api/codex/responses/compact"
    assert next.request_options.payload_context.compaction_result_mode == :native_websocket

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
          status: "succeeded",
          completed_at: now,
          last_error_code: nil,
          usage_status: "usage_unknown"
        )
      )

    attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(request, setup.assignment, %{
        status: "succeeded",
        completed_at: now,
        network_error_code: nil,
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
      status: "succeeded",
      error_code: nil,
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

    assert {:ok, {:error, :authorization_changed}} =
             Repo.transaction(fn ->
               ClientRetry.preflight_snapshot(session, setup.api_key, setup.model, %{
                 input
                 | endpoint: next.endpoint
               })
             end)

    assert {:ok, {:error, :terminal_predecessor}} =
             Repo.transaction(fn ->
               ClientRetry.preflight_snapshot(session, setup.api_key, setup.model, %{
                 input
                 | replay_claim_digest: first.replay_claim_digest
               })
             end)

    {:ok, owner} =
      Owner.start_link([])

    frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_compact_seed", "status" => "completed"}
      })

    {:ok, upstream} =
      CodexPooler.FakeUpstream.start_link(CodexPooler.FakeUpstream.websocket_text_frames([frame]))

    try do
      owner_module = Owner

      {:ok, result} =
        owner_module.request(
          owner,
          %OwnerRequest{
            url: CodexPooler.FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
            headers: [],
            payload: Jason.encode!(original),
            request_id: request.id,
            attempt_id: attempt.id,
            effective_serving_mode: "full",
            writer: fn _ -> :ok end,
            timeouts: %{connect_timeout_ms: 5000, receive_timeout_ms: 5000},
            message_mapper: &StreamProtocol.canonicalize_native_codex_responses_json_message/1
          }
        )

      receipt = result.ordinary_success_result

      {:ok, parsed} =
        NativeCodexTurnMetadata.parse(original, session.id)

      binding = %Binding{
        semantic_turn_key: first.semantic_turn_key,
        window_digest: parsed.window_id_digest,
        context_digest: parsed.context_window_id_digest,
        window_number: parsed.window_number,
        previous_response_digest: receipt.response_digest,
        serving_mode: :full,
        topology: receipt.topology,
        lifecycle_id: receipt.lifecycle.lifecycle_id,
        generation: receipt.lifecycle.generation
      }

      assert :ok =
               owner_module.arm_compact(
                 owner,
                 binding,
                 System.system_time(:millisecond) + 30_000,
                 receipt
               )

      {:ok, capability} =
        owner_module.reserve_compaction(
          owner,
          :compact,
          binding,
          make_ref(),
          System.system_time(:millisecond)
        )

      {:ok, admission} =
        RequestOptions.NativeCompactionAdmission.new(
          capability,
          {:direct, owner},
          receipt.lifecycle
        )

      {:ok, authorized} = WebsocketCodec.attach_native_compaction_admission(next, admission)

      assert {:ok, %{intent: :fresh, lifecycle: nil}} =
               Service.prepare_replay_intent(setup.auth, authorized)

      assert {:error, %{code: "duplicate_turn"}} =
               Service.prepare_replay_intent(setup.auth, prepare(continuation, session, setup))

      full_history = prepare(Map.delete(continuation, "previous_response_id"), session, setup)

      assert {:ok, %{intent: :fresh, lifecycle: nil}} =
               Service.prepare_replay_intent(setup.auth, full_history)

      # Fresh preflight grants no ordinary duplicate-claim exemption.
      assert {:error, _} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, %{
                 endpoint: "/backend-api/codex/responses",
                 correlation_id: first.turn_claim_key
               })

      invalid_options =
        RequestOptions.put_payload_context(first.request_options,
          compaction_trigger_bridge?: true,
          compaction_result_mode: :native_websocket
        )

      assert {:error, %{code: "duplicate_turn"}} =
               Service.prepare_replay_intent(setup.auth, %{
                 first
                 | request_options: invalid_options
               })

      assert {:error, %{code: "duplicate_turn"}} =
               Service.prepare_replay_intent(setup.auth, first)

      {:ok, _} =
        Repo.update(
          Ecto.Changeset.change(setup.api_key,
            runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch + 1
          )
        )

      assert {:error, _} = Service.prepare_replay_intent(setup.auth, authorized)
    after
      GenServer.stop(owner)
      CodexPooler.FakeUpstream.stop(upstream)
    end

    assert Repo.aggregate(RequestClientRetryLink, :count) == 0
    assert Repo.aggregate(CodexTurn, :count) == 1
  end

  defp prepare(payload, session, setup) do
    options =
      RequestOptions.build(
        %{codex_session: session, transport: "websocket", upstream_websocket_session: self()},
        "/backend-api/codex/responses",
        payload
      )
      |> RequestOptions.put_model_serving_mode(%{
        configured_mode: "full",
        effective_mode: "full",
        source: "override"
      })
      |> RequestOptions.put_runtime_context(
        api_key_runtime_epoch: setup.api_key.runtime_revocation_epoch
      )

    {:ok, metadata} =
      NativeCodexTurnMetadata.parse(payload, session.id)

    options = RequestOptions.put_payload_context(options, native_codex_turn_metadata: metadata)

    {:ok, prepared} =
      WebsocketCodec.prepare_frame(Jason.encode!(payload), options, fn _ -> :ok end)

    prepared
  end
end
