defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.FinalizationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestReplay}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @tag :websocket_session_success
  test "websocket response dispatch persists a succeeded session turn" do
    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_ws_backend",
          "object" => "response",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "stable-ws-success"})

    result =
      execute_websocket_response(
        auth,
        CodexPooler.JSON.encode!(%{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("hello over ws")
        }),
        %{
          request_id: "ws-request-#{System.unique_integer([:positive])}",
          client_ip: "127.0.0.1",
          codex_session: session
        },
        fn frame -> send(self(), {:websocket_frame, frame}) end
      )

    assert result == :ok
    assert_received {:websocket_frame, frame}
    assert %{"id" => "resp_ws_backend"} = CodexPooler.JSON.decode!(frame)
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "websocket"
    assert request.status == "succeeded"
    assert request.request_metadata["codex_session_id"] == session.id

    assert [turn] = Repo.all(from(t in CodexTurn, where: t.codex_session_id == ^session.id))
    assert turn.request_id == request.id
    assert turn.status == "succeeded"
    assert turn.transport_kind == "websocket"
    assert turn.completed_at
    assert turn.first_visible_output_at

    session = Repo.get!(CodexSession, session.id)
    assert session.status == "active"
    assert session.pool_upstream_assignment_id == setup.assignment.id
  end

  test "websocket completion registers an early response identity after its body frame is evicted" do
    response_id = "ws-finalization-early-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.sse_stream([
          {"response.created",
           %{"type" => "response.created", "response" => %{"id" => response_id}}},
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => String.duplicate("x", 70_000)}},
          {"response.completed",
           %{"type" => "response.completed", "response" => %{"status" => "completed"}}}
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-finalization-early"})

    logs =
      capture_log(fn ->
        assert :ok =
                 execute_websocket_response(
                   auth,
                   CodexPooler.JSON.encode!(%{
                     "type" => "response.create",
                     "model" => setup.model.exposed_model_id,
                     "input" => [],
                     "stream" => true,
                     "generate" => true
                   }),
                   %{request_id: "ws-finalization-early", codex_session: session},
                   fn frame -> send(self(), {:websocket_frame, frame}) end
                 )
      end)

    frames = receive_websocket_frames_by_type(["response.created", "response.completed"], 5_000)
    assert get_in(frames, ["response.created", "response", "id"]) == response_id
    assert get_in(frames, ["response.completed", "response", "id"]) == nil

    assert [request] = await_succeeded_pool_requests!(setup.pool.id, 1)

    assert [attempt] =
             Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

    assert [turn] =
             Repo.all(from(turn in CodexTurn, where: turn.request_id == ^request.id))

    assert [settlement] =
             Repo.all(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               )
             )

    assert [alias_record] =
             Repo.all(
               from(alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^session.id and
                     alias_record.alias_kind == "previous_response_id" and
                     alias_record.status == "active"
               )
             )

    assert request.status == "succeeded"
    assert attempt.status == "succeeded"
    assert turn.status == "succeeded"
    assert settlement.attempt_id == attempt.id
    assert alias_record.alias_hash == :crypto.hash(:sha256, response_id)

    persisted =
      inspect({
        request.request_metadata,
        attempt.response_metadata,
        settlement.details,
        turn,
        alias_record,
        Accounting.list_request_logs(setup.pool, filters: %{request_id: request.id})
      })

    refute persisted =~ response_id
    refute logs =~ response_id
  end

  test "websocket response.done completion registers its response identity alias" do
    response_id = "ws-finalization-done-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{
            "type" => "response.done",
            "response" => %{"id" => response_id, "status" => "completed"}
          })
        ])
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-finalization-done"})

    assert :ok =
             execute_websocket_response(
               auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => setup.model.exposed_model_id,
                 "input" => [],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-finalization-done", codex_session: session},
               fn frame -> send(self(), {:websocket_frame, frame}) end
             )

    assert_received {:websocket_frame, frame}
    assert get_in(CodexPooler.JSON.decode!(frame), ["response", "id"]) == response_id
    assert [request] = await_succeeded_pool_requests!(setup.pool.id, 1)

    assert [alias_record] =
             Repo.all(
               from(alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^session.id and
                     alias_record.alias_kind == "previous_response_id" and
                     alias_record.status == "active"
               )
             )

    assert alias_record.alias_hash == :crypto.hash(:sha256, response_id)

    persisted =
      inspect({
        request.request_metadata,
        alias_record,
        Accounting.list_request_logs(setup.pool, filters: %{request_id: request.id})
      })

    refute persisted =~ response_id
  end

  test "websocket completed finalization falls back to its body identity and re-entry stays exactly once" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-finalization-fallback"})

    body_response_id = "ws-finalization-body-#{System.unique_integer([:positive])}"

    {context, finalization} =
      completed_websocket_finalization_context!(
        setup,
        auth,
        session,
        CodexPooler.JSON.encode!(%{
          "id" => body_response_id,
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    capture_native_stream_telemetry(fn ->
      assert {:ok, %{status: 200, websocket_messages: []}} =
               Finalization.finalize_completed_websocket_response(context, finalization)

      assert_receive {:stream_finalization,
                      %{
                        usage_status: "usage_known",
                        usage_source: "upstream_usage",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      assert_receive {:stream_outcome,
                      %{
                        outcome: "succeeded",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      refute_received {:stream_finalization, _metadata}
      refute_received {:stream_outcome, _metadata}

      assert {:ok, %{status: 200, websocket_messages: []}} =
               Finalization.finalize_completed_websocket_response(context, finalization)

      assert_receive {:stream_finalization,
                      %{
                        usage_status: "usage_known",
                        usage_source: "upstream_usage",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      refute_received {:stream_finalization, _metadata}
      refute_received {:stream_outcome, _metadata}
    end)

    assert [request] =
             Repo.all(from(request in Request, where: request.id == ^context.reserved.request.id))

    assert [attempt] =
             Repo.all(from(attempt in Attempt, where: attempt.id == ^context.attempt.id))

    assert [turn] = Repo.all(from(turn in CodexTurn, where: turn.request_id == ^request.id))

    assert [settlement] =
             Repo.all(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               )
             )

    assert [alias_record] =
             Repo.all(
               from(alias_record in BridgeSessionAlias,
                 where:
                   alias_record.codex_session_id == ^session.id and
                     alias_record.alias_kind == "previous_response_id" and
                     alias_record.status == "active"
               )
             )

    assert request.status == "succeeded"
    assert attempt.status == "succeeded"
    assert turn.status == "succeeded"
    assert settlement.attempt_id == attempt.id
    assert alias_record.alias_hash == :crypto.hash(:sha256, body_response_id)

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(alias_record in BridgeSessionAlias,
               where:
                 alias_record.codex_session_id == ^session.id and
                   alias_record.alias_kind == "previous_response_id" and
                   alias_record.status == "active"
             ),
             :count
           ) == 1

    persisted =
      inspect({
        request.request_metadata,
        attempt.response_metadata,
        settlement.details,
        turn,
        alias_record,
        Accounting.list_request_logs(setup.pool, filters: %{request_id: request.id})
      })

    refute persisted =~ body_response_id
  end

  test "public connection-bound compact finalization skips native acknowledgement" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-public-compact-finalization"})

    item = %{
      "type" => "compaction_summary",
      "id" => nil,
      "encrypted_content" => "synthetic-public-compact-content"
    }

    {context, finalization} =
      completed_websocket_finalization_context!(
        setup,
        auth,
        session,
        compact_websocket_body("resp_public_compact_finalization", item)
      )

    request_options =
      context.request_options
      |> RequestOptions.put_transport(websocket_delivery_mode: :collect_compaction)
      |> RequestOptions.put_payload_context(
        compaction_trigger_bridge?: true,
        compaction_result_mode: :public_websocket
      )
      |> put_incremental_compaction_input_mode()
      |> RequestOptions.put_openai_compatibility(source_endpoint: "/v1/responses")

    context = %{context | request_options: request_options}

    assert {:ok, %{status: 200, raw_body: raw_body}} =
             Finalization.finalize_completed_websocket_response(context, finalization)

    assert %{
             "status" => "completed",
             "output" => [
               %{
                 "type" => "compaction",
                 "id" => nil,
                 "encrypted_content" => "synthetic-public-compact-content"
               }
             ]
           } = CodexPooler.JSON.decode!(raw_body)

    assert Repo.reload!(context.reserved.request).status == "succeeded"
    assert Repo.reload!(context.attempt).status == "succeeded"
  end

  test "native connection-bound compact finalization still requires native acknowledgement" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-native-compact-finalization"})

    item = %{
      "type" => "compaction",
      "encrypted_content" => "synthetic-native-compact-content"
    }

    {context, finalization} =
      completed_websocket_finalization_context!(
        setup,
        auth,
        session,
        compact_websocket_body("resp_native_compact_finalization", item)
      )

    request_options =
      context.request_options
      |> RequestOptions.put_transport(websocket_delivery_mode: :collect_compaction)
      |> RequestOptions.put_payload_context(
        compaction_trigger_bridge?: true,
        compaction_result_mode: :native_websocket
      )
      |> put_incremental_compaction_input_mode()

    context = %{context | request_options: request_options}

    assert {:error, %{status: 502, code: "invalid_compaction_response"}} =
             Finalization.finalize_completed_websocket_response(context, finalization)

    assert Repo.reload!(context.reserved.request).status == "succeeded"
    assert Repo.reload!(context.attempt).status == "succeeded"
  end

  test "public connection-bound compact finalization keeps strict collection validation" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-public-invalid-compact"})

    invalid_item = %{"type" => "compaction_summary", "id" => nil}

    {context, finalization} =
      completed_websocket_finalization_context!(
        setup,
        auth,
        session,
        compact_websocket_body("resp_public_invalid_compact", invalid_item)
      )

    request_options =
      context.request_options
      |> RequestOptions.put_transport(websocket_delivery_mode: :collect_compaction)
      |> RequestOptions.put_payload_context(
        compaction_trigger_bridge?: true,
        compaction_result_mode: :public_websocket
      )
      |> put_incremental_compaction_input_mode()
      |> RequestOptions.put_openai_compatibility(source_endpoint: "/v1/responses")

    context = %{context | request_options: request_options}

    assert {:error,
            %{
              status: 502,
              code: "invalid_compaction_response",
              public_compaction_error?: true
            }} = Finalization.finalize_completed_websocket_response(context, finalization)

    assert Repo.reload!(context.reserved.request).status == "failed"
    assert Repo.reload!(context.attempt).status == "failed"
  end

  @tag :replay_generation_race
  @tag :replay_race
  test "stale generation invalid websocket compaction finalization is a typed no-op" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-stale-invalid-compact"})

    invalid_item = %{"type" => "compaction_summary", "id" => nil}

    {context, finalization} =
      completed_websocket_finalization_context!(
        setup,
        auth,
        session,
        compact_websocket_body("resp_stale_invalid_compact", invalid_item)
      )

    stale_attempt = context.attempt
    stale_request = context.reserved.request

    turn = Repo.get_by!(CodexTurn, request_id: stale_request.id)
    semantic_digest = <<1::256>>

    turn
    |> Ecto.Changeset.change(%{semantic_turn_digest: semantic_digest})
    |> Repo.update!()

    assert {:ok, _armed} =
             RequestReplay.arm(%{
               api_key_id: auth.api_key.id,
               pool_id: auth.pool.id,
               codex_session_id: session.id,
               request_id: stale_request.id,
               codex_turn_id: turn.id,
               eligible_attempt_id: stale_attempt.id,
               api_key_runtime_epoch: auth.api_key.runtime_revocation_epoch,
               model_id: setup.model.id,
               model_identifier: setup.model.exposed_model_id,
               endpoint: stale_request.endpoint,
               semantic_turn_digest: semantic_digest,
               replay_claim_digest: <<2::256>>,
               owner_instance_id: session.owner_instance_id,
               owner_lease_token: session.owner_lease_token,
               predecessor_epoch: 1,
               failure_reason: :client_disconnected,
               pre_visible_output: true
             })

    request_options =
      context.request_options
      |> RequestOptions.put_transport(websocket_delivery_mode: :collect_compaction)
      |> RequestOptions.put_payload_context(
        compaction_trigger_bridge?: true,
        compaction_result_mode: :native_websocket
      )
      |> put_incremental_compaction_input_mode()

    context = %{context | request_options: request_options}

    assert {:ok, %{stale_generation?: true}} =
             Finalization.finalize_completed_websocket_response(context, finalization)

    assert Repo.reload!(stale_request).status == "in_progress"
    assert Repo.reload!(stale_attempt).status == "retryable_failed"
  end

  test "websocket completed settlement rollback emits one attempt-scoped failure outcome" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-finalization-rollback"})

    {context, finalization} =
      completed_websocket_finalization_context!(
        setup,
        auth,
        session,
        CodexPooler.JSON.encode!(%{
          "id" => "ws-finalization-rollback",
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    mismatched =
      gateway_upstream(
        setup.pool,
        start_upstream(FakeUpstream.json_response(%{"data" => []})),
        "upstream-token-settlement-mismatch",
        compact?: false
      )

    mismatched_attempt =
      context.attempt
      |> Ecto.Changeset.change(upstream_identity_id: mismatched.identity.id)
      |> Repo.update!()

    context = %{context | attempt: mismatched_attempt}

    capture_stream_outcome_telemetry(fn ->
      log =
        capture_log(fn ->
          assert {:error,
                  %{
                    status: 500,
                    code: "gateway_accounting_failed",
                    message: "gateway accounting finalization failed"
                  }} = Finalization.finalize_completed_websocket_response(context, finalization)
        end)

      assert log =~ "reason=upstream_reference_mismatch"

      assert_receive {:stream_outcome,
                      %{
                        outcome: "settlement_failed",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      refute_received {:stream_outcome, _metadata}
    end)

    assert Repo.reload!(context.reserved.request).status == "in_progress"
    assert Repo.reload!(mismatched_attempt).status == "in_progress"
  end

  test "websocket transport finalizer owns the first client disconnect outcome" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-finalizer-disconnect"})

    {context, finalization} =
      completed_websocket_finalization_context!(setup, auth, session, "")

    failed_finalization =
      finalization
      |> Map.drop([:callbacks, :status])
      |> Map.merge(%{reason: :client_disconnected, headers: []})

    capture_stream_outcome_telemetry(fn ->
      assert {:error, %{status: 499, code: "client_disconnected"}} =
               Finalization.finalize_failed_websocket_response(context, failed_finalization)

      assert_receive {:stream_outcome,
                      %{
                        outcome: "interrupted",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      assert {:error, %{status: 499, code: "client_disconnected"}} =
               Finalization.finalize_failed_websocket_response(context, failed_finalization)

      refute_received {:stream_outcome, _metadata}
    end)
  end

  test "websocket failed finalization stays silent for reused and usage-replaced settlements" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    for {suffix, initial_usage} <- [
          {"reused",
           %{status: "usage_known", input_tokens: 4, output_tokens: 3, total_tokens: 7}},
          {"replaced", %{status: "usage_unknown", source: "owner_drained"}}
        ] do
      {:ok, session} =
        Gateway.start_codex_session(auth, %{
          accepted_turn_state: "ws-failed-settlement-#{suffix}"
        })

      body =
        CodexPooler.JSON.encode!(%{
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })

      {context, finalization} =
        completed_websocket_finalization_context!(setup, auth, session, body)

      assert {:ok, _settled} =
               Accounting.finalize_failure_with_disposition(
                 context.reserved.request,
                 context.attempt,
                 %{
                   response_status_code: 502,
                   last_error_code: "upstream_request_failed",
                   usage: initial_usage
                 }
               )

      failed_finalization =
        finalization
        |> Map.drop([:callbacks, :status])
        |> Map.merge(%{reason: :upstream_stream_interrupted, headers: []})

      capture_stream_outcome_telemetry(fn ->
        assert {:error, %{status: 502, code: "upstream_request_failed"}} =
                 Finalization.finalize_failed_websocket_response(context, failed_finalization)

        refute_received {:stream_outcome, _metadata}
      end)

      assert Repo.reload!(context.reserved.request).status == "failed"
      assert Repo.reload!(context.attempt).status == "failed"
    end
  end

  test "native retry boundaries keep both already-finalized lifecycle errors uncounted" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    for lifecycle <- [:request, :attempt] do
      {:ok, session} =
        Gateway.start_codex_session(auth, %{
          accepted_turn_state: "ws-native-#{lifecycle}-already-finalized"
        })

      {context, finalization} =
        completed_websocket_finalization_context!(setup, auth, session, "")

      context = %{context | allow_retry?: true}

      expected_code =
        case lifecycle do
          :request ->
            assert {:ok, _settled} =
                     Accounting.finalize_failure(
                       context.reserved.request,
                       context.attempt,
                       %{
                         response_status_code: 502,
                         last_error_code: "upstream_request_failed",
                         usage_status: "usage_unknown"
                       }
                     )

            "request_already_finalized"

          :attempt ->
            assert {:ok, %Attempt{status: "retryable_failed"}} =
                     Accounting.record_retryable_attempt_failure(context.attempt, %{
                       response_status_code: 502,
                       last_error_code: "upstream_request_timeout"
                     })

            "attempt_already_finalized"
        end

      failed_finalization =
        finalization
        |> Map.drop([:callbacks, :status])
        |> Map.merge(%{reason: :upstream_request_timeout, headers: []})

      capture_stream_outcome_telemetry(fn ->
        assert {:error, %{status: 499, code: ^expected_code}} =
                 Finalization.finalize_failed_websocket_response(context, failed_finalization)

        refute_received {:stream_outcome, _metadata}
      end)
    end
  end

  test "concurrent native settlement rollbacks each emit an attempt-scoped failure" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-concurrent-settlement-failure"})

    {context, finalization} =
      completed_websocket_finalization_context!(
        setup,
        auth,
        session,
        CodexPooler.JSON.encode!(%{
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
        })
      )

    mismatched =
      gateway_upstream(
        setup.pool,
        start_upstream(FakeUpstream.json_response(%{"data" => []})),
        "upstream-token-concurrent-settlement-mismatch",
        compact?: false
      )

    mismatched_attempt =
      context.attempt
      |> Ecto.Changeset.change(upstream_identity_id: mismatched.identity.id)
      |> Repo.update!()

    context = %{context | attempt: mismatched_attempt}
    parent = self()
    release_ref = make_ref()

    capture_stream_outcome_telemetry(fn ->
      tasks =
        for label <- [:first, :second] do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())
            send(parent, {:native_settlement_failure_ready, label, self(), release_ref})

            receive do
              {:release_native_settlement_failure, ^release_ref} -> :ok
            after
              5_000 -> flunk("native settlement failure task #{label} was not released")
            end

            {result, _log} =
              with_log(fn ->
                Finalization.finalize_completed_websocket_response(context, finalization)
              end)

            result
          end)
        end

      task_pids =
        for _label <- [:first, :second] do
          assert_receive {:native_settlement_failure_ready, _label, pid, ^release_ref}, 5_000
          pid
        end

      Enum.each(task_pids, &send(&1, {:release_native_settlement_failure, release_ref}))

      assert [
               {:error, %{code: "gateway_accounting_failed"}},
               {:error, %{code: "gateway_accounting_failed"}}
             ] = Task.await_many(tasks, 10_000)

      assert_receive {:stream_outcome,
                      %{
                        outcome: "settlement_failed",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      assert_receive {:stream_outcome,
                      %{
                        outcome: "settlement_failed",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      refute_received {:stream_outcome, _metadata}
    end)

    assert Repo.reload!(context.reserved.request).status == "in_progress"
    assert Repo.reload!(mismatched_attempt).status == "in_progress"
  end

  test "interruption-first settlement makes the native transport finalizer silent" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{accepted_turn_state: "ws-interruption-first"})

    {context, finalization} =
      completed_websocket_finalization_context!(setup, auth, session, "")

    failed_finalization =
      finalization
      |> Map.drop([:callbacks, :status])
      |> Map.merge(%{reason: :client_disconnected, headers: []})

    capture_stream_outcome_telemetry(fn ->
      assert {:ok, %{interrupted_turn_count: 1}} =
               Gateway.interrupt_codex_turn(session, %{
                 request_id: context.request_options.request_metadata.request_id,
                 reason: "client_disconnected",
                 reconnect_window_seconds: 300
               })

      assert_receive {:stream_outcome,
                      %{
                        outcome: "interrupted",
                        downstream_transport: "websocket",
                        upstream_transport: "websocket"
                      }}

      assert {:error, %{status: 499, code: "client_disconnected"}} =
               Finalization.finalize_failed_websocket_response(context, failed_finalization)

      refute_received {:stream_outcome, _metadata}
    end)

    assert Repo.reload!(context.reserved.request).status == "failed"
    assert Repo.reload!(context.attempt).status == "failed"
  end

  test "id-less and failed websocket terminals do not register response aliases" do
    idless_upstream =
      start_upstream(
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{
            "type" => "response.completed",
            "response" => %{"status" => "completed"}
          })
        ])
      )

    idless_setup = gateway_setup(idless_upstream)
    {:ok, idless_auth} = Access.authenticate_authorization_header(idless_setup.authorization)

    {:ok, idless_session} =
      Gateway.start_codex_session(idless_auth, %{accepted_turn_state: "ws-finalization-idless"})

    assert :ok =
             execute_websocket_response(
               idless_auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => idless_setup.model.exposed_model_id,
                 "input" => [],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-finalization-idless", codex_session: idless_session},
               fn frame -> send(self(), {:idless_websocket_frame, frame}) end
             )

    assert_received {:idless_websocket_frame, _frame}
    assert [idless_request] = await_succeeded_pool_requests!(idless_setup.pool.id, 1)

    refute Repo.exists?(
             from(alias_record in BridgeSessionAlias,
               where:
                 alias_record.codex_session_id == ^idless_session.id and
                   alias_record.alias_kind == "previous_response_id" and
                   alias_record.status == "active"
             )
           )

    failed_upstream =
      start_upstream(
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{
            "type" => "response.failed",
            "response" => %{
              "id" => "ws-finalization-failed-#{System.unique_integer([:positive])}",
              "status" => "failed",
              "error" => %{"code" => "server_error"}
            }
          })
        ])
      )

    failed_setup = gateway_setup(failed_upstream)
    {:ok, failed_auth} = Access.authenticate_authorization_header(failed_setup.authorization)

    {:ok, failed_session} =
      Gateway.start_codex_session(failed_auth, %{accepted_turn_state: "ws-finalization-failed"})

    assert :ok =
             execute_websocket_response(
               failed_auth,
               CodexPooler.JSON.encode!(%{
                 "type" => "response.create",
                 "model" => failed_setup.model.exposed_model_id,
                 "input" => [],
                 "stream" => true,
                 "generate" => true
               }),
               %{request_id: "ws-finalization-failed", codex_session: failed_session},
               fn frame -> send(self(), {:failed_websocket_frame, frame}) end
             )

    assert_received {:failed_websocket_frame, _frame}

    assert [failed_request] =
             Repo.all(from(request in Request, where: request.pool_id == ^failed_setup.pool.id))

    assert failed_request.status == "failed"

    refute Repo.exists?(
             from(alias_record in BridgeSessionAlias,
               where:
                 alias_record.codex_session_id == ^failed_session.id and
                   alias_record.alias_kind == "previous_response_id" and
                   alias_record.status == "active"
             )
           )

    refute inspect({idless_request.request_metadata, failed_request.request_metadata}) =~
             "ws-finalization-failed-"
  end

  defp completed_websocket_finalization_context!(setup, auth, session, body) do
    payload = %{"model" => setup.model.exposed_model_id, "stream" => true}

    request_options =
      Gateway.websocket_response_options(
        %{request_id: "ws-finalization-#{System.unique_integer([:positive])}"},
        session,
        nil,
        false
      )

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: "/backend-api/codex/responses",
               transport: "websocket",
               correlation_id: request_options.request_metadata.request_id,
               request_metadata: %{"codex_session_id" => session.id}
             })

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    assert {:ok, _turn} = Gateway.start_codex_turn(session, reserved.request, request_options)

    context = %SelectedCandidateContext{
      auth: auth,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      model: setup.model,
      reserved: reserved,
      request_options: request_options,
      route_plan: %{
        affinity: %{
          enabled?: false,
          key_hash: nil,
          pool_id: auth.pool.id,
          api_key_id: auth.api_key.id,
          model_identifier: setup.model.exposed_model_id
        },
        demotions: %{}
      },
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      retry_count: 0,
      allow_retry?: false,
      routing_attempt_metadata: %{},
      route_class: "proxy_websocket",
      attempt: attempt,
      started: System.monotonic_time(:millisecond)
    }

    callbacks = %{
      register_continuity: fn request_options, payload, response_body ->
        Gateway.register_codex_session_continuity(
          session,
          payload,
          response_body,
          request_options
        )
      end
    }

    {context,
     %{
       body: body,
       status: 200,
       headers: [],
       started: System.monotonic_time(:millisecond),
       callbacks: callbacks
     }}
  end

  defp compact_websocket_body(response_id, item) do
    [
      {"response.output_item.done", %{"type" => "response.output_item.done", "item" => item}},
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => response_id,
           "status" => "completed",
           "output" => [item],
           "usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}
         }
       }}
    ]
    |> Enum.map_join(fn {event, data} ->
      "event: #{event}\ndata: #{CodexPooler.JSON.encode!(data)}\n\n"
    end)
  end

  defp put_incremental_compaction_input_mode(%RequestOptions{} = request_options) do
    %{
      request_options
      | payload_context: %{request_options.payload_context | compaction_input_mode: :incremental}
    }
  end

  defp capture_native_stream_telemetry(fun) do
    handler_id = "native-stream-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:codex_pooler, :gateway, :stream, :finalization],
          [:codex_pooler, :gateway, :stream, :outcome]
        ],
        fn
          [:codex_pooler, :gateway, :stream, :finalization], _measurements, metadata, _config ->
            send(parent, {:stream_finalization, metadata})

          [:codex_pooler, :gateway, :stream, :outcome], _measurements, metadata, _config ->
            send(parent, {:stream_outcome, metadata})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end
end
