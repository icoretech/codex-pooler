defmodule CodexPooler.Accounting.DeadExecutionResendRecoveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting

  alias CodexPooler.Accounting.{
    Attempt,
    ClientRetry,
    LedgerEntry,
    Request,
    RequestClientRetryLink
  }

  alias CodexPooler.Accounting.RequestLifecycle
  alias CodexPooler.Gateway.Payloads.{NativeMailboxContinuation, RequestOptions, WebsocketTurnIdentity}
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn, SessionContinuity}
  alias CodexPooler.Gateway.Runtime.Finalization.{AttemptSettlement, Interruption}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Persistence, as: OwnerPersistence
  alias CodexPooler.Gateway.Websocket.{DeliveryReceipt, OwnerCleanup}
  alias CodexPooler.Platform.ExecutionTerminalProofs
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Platform.InstancePresence.Identity
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"
  @retry_prefix "codex-request-retry:"
  @detection_timeout_ms 15_000

  test "a dead mailbox continuation requires the exact proof, output receipt, epoch and session" do
    fixture = dead_mailbox_fixture!()
    %{setup: setup, request: request, attempt: attempt, turn: turn, options: options} = fixture
    assert {:ok, :recovered} = RequestLifecycle.recover_dead_execution(request, attempt, db_now())

    attempt = Repo.reload!(attempt)
    assert %{"outcome" => "aborted", "terminal_class" => "none", "completed_items" => 1, "completed_item_digests" => [_digest]} = attempt.response_metadata["downstream_delivery"]
    altered = attempt |> Ecto.Changeset.change(owner_process_id: "<0.999999.0>") |> Repo.update!()
    assert_dead_mailbox_refused!(fixture, options, :settlement)
    altered |> Ecto.Changeset.change(owner_process_id: attempt.owner_process_id) |> Repo.update!()

    for receipt <- [nil, %{}, %{"completed_items" => 1, "completed_item_digests" => []}] do
      changed_metadata = Map.put(attempt.response_metadata, "downstream_delivery", receipt)
      attempt |> Ecto.Changeset.change(response_metadata: changed_metadata) |> Repo.update!()
      assert_dead_mailbox_refused!(fixture, options, :output_prefix)
    end

    restored_attempt = attempt |> Repo.reload!() |> Ecto.Changeset.change(response_metadata: attempt.response_metadata) |> Repo.update!()
    assert restored_attempt.response_metadata == attempt.response_metadata
    assert ClientRetry.mailbox_check(Repo.reload!(turn), Repo.reload!(request), restored_attempt, options.native_client_retry_witness, nil, :same_session).stage == :verified
    changed_epoch = %{options.native_client_retry_witness | auth_epoch: setup.api_key.runtime_revocation_epoch + 1}
    assert_dead_mailbox_refused!(fixture, %{options | native_client_retry_witness: changed_epoch}, :authorization)
    assert_dead_mailbox_refused!(fixture, %{options | codex_session: insert_session!(setup)}, :session)

    assert {:ok, %{request: successor, client_resend: %{predecessor_shape: :mailbox_continuation}}} = Accounting.claim_websocket_turn(setup.auth, setup.model, options)
    assert Repo.get_by!(RequestClientRetryLink, predecessor_request_id: request.id).successor_request_id == successor.id
    assert {:error, %{code: :duplicate_request}} = Accounting.claim_websocket_turn(setup.auth, setup.model, options)
    assert_recovered!(request, attempt, turn)
    assert ledger_kinds(request.id) == ["release", "reservation", "settlement"]
  end

  defp assert_dead_mailbox_refused!(fixture, options, stage) do
    assert {:error, %{code: :duplicate_request, mailbox_check: ^stage}} = Accounting.claim_websocket_turn(fixture.setup.auth, fixture.setup.model, options)
    assert Repo.aggregate(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^fixture.request.id), :count) == 0
    assert Repo.aggregate(from(request in Request, where: request.pool_id == ^fixture.setup.pool.id), :count) == 1
  end

  defp dead_mailbox_fixture! do
    fixture = active_dead_execution_fixture!()
    semantic = fixture.turn.semantic_turn_digest
    output = %{"type" => "reasoning", "id" => "rs_dead_mailbox", "summary" => [], "encrypted_content" => "synthetic dead mailbox reasoning"}
    mail = %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic update"}]}
    payload = %{"model" => fixture.setup.model.exposed_model_id, "input" => [%{"type" => "message", "role" => "user", "content" => "synthetic question"}], "client_metadata" => %{"x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"request_kind" => "turn", "agent_name" => "/root"})}}
    {:ok, digest} = WebsocketTurnIdentity.replay_claim_digest(semantic, payload)
    request = fixture.request |> Ecto.Changeset.change(native_client_retry_digest: digest) |> Repo.update!()
    turn = fixture.turn |> Ecto.Changeset.change(first_visible_output_at: db_now()) |> Repo.update!()
    {:ok, output_digest} = WebsocketTurnIdentity.completed_item_digest(output)
    receipt = DeliveryReceipt.build(%{outcome: "aborted", terminal_class: nil, highest_frame_class: "item_done", frames_after_visible: 1, completed_items: 1, completed_item_digests: [output_digest]})
    :ok = DeliveryReceipt.persist(fixture.attempt.id, receipt)
    CodexPooler.ExecutionProofSupport.publish_terminal!(fixture.attempt)
    candidate = Map.update!(payload, "input", &(&1 ++ [output, mail]))
    {:ok, current_digest} = WebsocketTurnIdentity.replay_claim_digest(semantic, candidate)
    witness = ClientRetry.original_witness!(current_digest, fixture.setup.api_key.runtime_revocation_epoch) |> NativeMailboxContinuation.attach(semantic, candidate, RequestOptions.build(%{}, @endpoint, %{}))
    assert witness.mailbox != []
    options = %{endpoint: @endpoint, correlation_id: request.correlation_id, codex_session: fixture.session, semantic_turn_digest: semantic, native_client_retry_witness: witness}
    Map.merge(fixture, %{request: request, turn: turn, options: options})
  end

  test "a recovered successor can die and be retried once again after session rotation" do
    fixture = active_dead_execution_fixture!()
    %{setup: setup, request: request, attempt: attempt, turn: turn} = fixture
    CodexPooler.ExecutionProofSupport.publish_terminal!(attempt)
    witness = ClientRetry.original_witness!(fixture.replay_claim_digest, setup.api_key.runtime_revocation_epoch)
    opts = %{endpoint: @endpoint, correlation_id: request.correlation_id, codex_session: insert_session!(setup), semantic_turn_digest: turn.semantic_turn_digest, native_client_retry_witness: witness}
    assert {:ok, %{request: first_successor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    assert {:ok, %{request: first_successor}} = Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id, "input" => []}, %{endpoint: @endpoint, transport: "websocket", correlation_id: first_successor.correlation_id, turn_claim: first_successor})
    successor_attempt = create_dead_attempt!(setup, first_successor)
    successor_turn = insert_turn!(opts.codex_session, first_successor, successor_attempt)
    successor_turn |> Ecto.Changeset.change(semantic_turn_digest: turn.semantic_turn_digest) |> Repo.update!()
    CodexPooler.ExecutionProofSupport.publish_terminal!(successor_attempt)
    opts = %{opts | codex_session: insert_session!(setup)}

    assert {:ok, %{request: second_successor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    assert second_successor.id != first_successor.id
    assert %Request{status: "failed", last_error_code: "dead_execution_recovered"} = Repo.reload!(first_successor)
    assert ledger_kinds(first_successor.id) == ["release", "reservation", "settlement"]
    assert Repo.get_by!(RequestClientRetryLink, predecessor_request_id: first_successor.id).successor_request_id == second_successor.id
    assert {:error, %{code: :duplicate_request}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
  end

  for recovered_before_resend <- [false, true] do
    @tag recovered_before_resend: recovered_before_resend
    test "a proven replaced instance permits one exact resend in a new session, cleanup first=#{recovered_before_resend}", %{recovered_before_resend: recovered_before_resend} do
      fixture = active_dead_execution_fixture!()
      %{setup: setup, request: request, attempt: attempt, turn: turn} = fixture
      now = db_now()
      old = Identity.new("replaced-#{System.unique_integer([:positive])}@example", "old-boot")
      newer = Identity.new(old.node_name, "new-boot")
      stale = DateTime.add(now, -180, :second)
      {:ok, _} = InstancePresence.record_heartbeat(old, stale)
      {:ok, _} = InstancePresence.record_heartbeat(newer, now)
      {:ok, _} = InstancePresence.record_heartbeat()

      attempt = attempt |> Ecto.Changeset.change(owner_instance_id: old.node_name, owner_instance_boot_id: old.boot_id) |> Repo.update!()
      turn = turn |> Ecto.Changeset.change(first_visible_output_at: now) |> Repo.update!()
      new_session = insert_session!(setup)

      if recovered_before_resend do
        assert {:ok, :recovered} = RequestLifecycle.recover_absent_execution(request, attempt, now, [])
      end

      witness = ClientRetry.original_witness!(fixture.replay_claim_digest, setup.api_key.runtime_revocation_epoch)
      opts = %{endpoint: @endpoint, correlation_id: request.correlation_id, codex_session: new_session, native_client_retry_witness: witness}

      wrong_witness = ClientRetry.original_witness!(:crypto.strong_rand_bytes(32), setup.api_key.runtime_revocation_epoch)
      assert {:error, %{code: :duplicate_request}} = Accounting.claim_websocket_turn(setup.auth, setup.model, %{opts | native_client_retry_witness: wrong_witness})

      unless recovered_before_resend do
        assert Repo.reload!(request).status == "in_progress"
        assert Repo.reload!(attempt).status == "in_progress"
        assert Repo.reload!(turn).status == "in_progress"
        assert ledger_kinds(request.id) == ["reservation"]
      end

      assert {:ok, %{request: successor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
      assert successor.id != request.id
      assert %Request{status: "failed", last_error_code: "absent_instance_recovered"} = Repo.reload!(request)
      assert %Attempt{status: "failed", network_error_code: "absent_instance_recovered"} = Repo.reload!(attempt)
      assert %CodexTurn{status: "interrupted", error_code: "absent_instance_recovered"} = Repo.reload!(turn)
      assert ledger_kinds(request.id) == ["release", "reservation", "settlement"]
      assert {:error, %{code: :duplicate_request}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
      assert Repo.aggregate(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^request.id), :count) == 1
    end
  end

  test "an exact terminal proof recovers the live predecessor inside the released-client resend" do
    setup = accounting_setup()
    session = insert_session!(setup)

    witness =
      ClientRetry.original_witness!(
        :crypto.strong_rand_bytes(32),
        setup.api_key.runtime_revocation_epoch
      )

    claim = "codex-turn:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    opts = %{
      endpoint: @endpoint,
      correlation_id: claim,
      codex_session: session,
      native_client_retry_witness: witness
    }

    assert {:ok, %{request: claimed}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

    assert {:ok, %{request: request}} =
             Accounting.reserve(
               setup.auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => []},
               %{
                 endpoint: @endpoint,
                 transport: "websocket",
                 correlation_id: claim,
                 turn_claim: claimed
               }
             )

    attempt = create_dead_attempt!(setup, request)
    turn = insert_turn!(session, request, attempt)
    CodexPooler.ExecutionProofSupport.publish_terminal!(attempt)

    wrong_witness =
      ClientRetry.original_witness!(
        :crypto.strong_rand_bytes(32),
        setup.api_key.runtime_revocation_epoch
      )

    assert {:error, %{code: :duplicate_request, resend_disposition: :terminal_predecessor}} =
             Accounting.claim_websocket_turn(
               setup.auth,
               setup.model,
               %{opts | native_client_retry_witness: wrong_witness}
             )

    assert %Request{status: "in_progress", completed_at: nil} = Repo.reload!(request)
    assert %Attempt{status: "in_progress", completed_at: nil} = Repo.reload!(attempt)
    assert %CodexTurn{status: "in_progress", completed_at: nil} = Repo.reload!(turn)
    assert ledger_kinds(request.id) == ["reservation"]

    attach_outcome_handler!()

    assert {:ok,
            %{
              request: successor,
              client_resend: %{
                predecessor_request_id: predecessor_id,
                predecessor_shape: :task_exception
              }
            }} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

    assert predecessor_id == request.id
    assert String.starts_with?(successor.correlation_id, @retry_prefix)

    assert_receive {:dead_resend_outcome,
                    %{
                      outcome: "interrupted",
                      downstream_transport: "websocket",
                      upstream_transport: "websocket"
                    }, false}

    assert_recovered!(request, attempt, turn)
    assert ledger_kinds(request.id) == ["release", "reservation", "settlement"]

    assert Repo.aggregate(
             from(link in RequestClientRetryLink,
               where: link.predecessor_request_id == ^request.id
             ),
             :count
           ) == 1

    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 2
  end

  test "direct disconnect cleanup preserves exact dead-execution attribution" do
    setup = accounting_setup()
    session = insert_session!(setup)
    claim = "codex-turn:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    witness =
      ClientRetry.original_witness!(
        :crypto.strong_rand_bytes(32),
        setup.api_key.runtime_revocation_epoch
      )

    assert {:ok, %{request: claimed}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, %{
               endpoint: @endpoint,
               correlation_id: claim,
               codex_session: session,
               native_client_retry_witness: witness
             })

    assert {:ok, %{request: request}} =
             Accounting.reserve(
               setup.auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => []},
               %{
                 endpoint: @endpoint,
                 transport: "websocket",
                 correlation_id: claim,
                 turn_claim: claimed
               }
             )

    attempt = create_dead_attempt!(setup, request)
    turn = insert_turn!(session, request, attempt)
    CodexPooler.ExecutionProofSupport.publish_terminal!(attempt)
    attach_outcome_handler!()

    assert :ok =
             Interruption.interrupt_direct_request(
               %{
                 session_id: session.id,
                 request_id: request.id,
                 correlation_id: request.correlation_id,
                 api_key_id: request.api_key_id,
                 attempt_id: attempt.id,
                 replay_generation: attempt.replay_generation
               },
               "client_disconnected"
             )

    assert_receive {:dead_resend_outcome,
                    %{
                      outcome: "interrupted",
                      downstream_transport: "websocket",
                      upstream_transport: "websocket"
                    }, false}

    assert_recovered!(request, attempt, turn)
    assert ledger_kinds(request.id) == ["release", "reservation", "settlement"]
  end

  test "owner crash interruption preserves exact dead-execution attribution" do
    fixture = active_dead_execution_fixture!()
    CodexPooler.ExecutionProofSupport.publish_terminal!(fixture.attempt)
    attach_outcome_handler!()

    assert {:ok, %{interrupted_turn_count: 1}} =
             Interruption.interrupt_codex_turn(
               fixture.session,
               RequestOptions.for_websocket(%{
                 request_id: fixture.request.correlation_id,
                 interrupt_reason: "owner_crashed",
                 reconnect_window_seconds: 300
               })
             )

    assert_receive {:dead_resend_outcome,
                    %{
                      outcome: "interrupted",
                      downstream_transport: "websocket",
                      upstream_transport: "websocket"
                    }, false}

    assert_recovered!(fixture.request, fixture.attempt, fixture.turn)
  end

  # The owner's own interruption of its active turn, as its exit or its drain
  # cut writes it through its persistence, over an executor whose end is
  # proven (findings#270 row 270-362). A drain cut settles the turn for its
  # own reason; an owner crash says nothing about the executor, so the proof
  # keeps the lost-executor recovery (rows 207 and 217).
  test "an owner's drain cut of its active turn keeps owner_drained over the executor's proven end" do
    fixture = owned_dead_execution_fixture!()
    CodexPooler.ExecutionProofSupport.publish_terminal!(fixture.attempt)

    assert :ok = OwnerPersistence.interrupt_codex_session(owner_state(fixture), :owner_drained)

    assert %Request{status: "failed", response_status_code: 499, last_error_code: "owner_drained"} = Repo.reload!(fixture.request)
    assert %Attempt{status: "failed", network_error_code: "owner_drained"} = Repo.reload!(fixture.attempt)
    assert %CodexTurn{status: "interrupted", error_code: "owner_drained"} = Repo.reload!(fixture.turn)
  end

  test "an owner crash's interruption of its active turn keeps the executor's proven death" do
    fixture = owned_dead_execution_fixture!()
    CodexPooler.ExecutionProofSupport.publish_terminal!(fixture.attempt)

    assert :ok = OwnerPersistence.interrupt_codex_session(owner_state(fixture), :owner_crashed)

    assert_recovered!(fixture.request, fixture.attempt, fixture.turn)
  end

  test "owner crash interruption keeps owner_crashed without a terminal proof" do
    fixture = active_dead_execution_fixture!()

    assert {:ok, %{interrupted_turn_count: 1}} =
             Interruption.interrupt_codex_turn(
               fixture.session,
               RequestOptions.for_websocket(%{
                 request_id: fixture.request.correlation_id,
                 interrupt_reason: "owner_crashed",
                 reconnect_window_seconds: 300
               })
             )

    assert %Request{status: "failed", last_error_code: "owner_crashed"} =
             Repo.reload!(fixture.request)

    assert %Attempt{status: "failed", network_error_code: "owner_crashed"} =
             Repo.reload!(fixture.attempt)

    assert %CodexTurn{status: "interrupted", error_code: "owner_crashed"} =
             Repo.reload!(fixture.turn)
  end

  test "released-client retry admits an owner crash once exact death proof arrives" do
    fixture = active_dead_execution_fixture!()

    assert {:ok, %{interrupted_turn_count: 1}} =
             Interruption.interrupt_codex_turn(
               fixture.session,
               RequestOptions.for_websocket(%{
                 request_id: fixture.request.correlation_id,
                 interrupt_reason: "owner_crashed",
                 reconnect_window_seconds: 300
               })
             )

    input = retry_input(fixture)

    assert {:error, :terminal_predecessor} =
             Accounting.client_retry_preflight_snapshot(
               fixture.session,
               fixture.setup.api_key,
               fixture.setup.model,
               input
             )

    CodexPooler.ExecutionProofSupport.publish_terminal!(fixture.attempt)

    assert {:ok,
            %{
              replay_generation: 0,
              client_retry_predecessor_request_id: predecessor_id
            }} =
             Accounting.client_retry_preflight_snapshot(
               fixture.session,
               fixture.setup.api_key,
               fixture.setup.model,
               input
             )

    assert predecessor_id == fixture.request.id

    assert {:ok, %ClientRetry.SuccessorClaim{} = successor} =
             Accounting.claim_client_retry_successor(
               fixture.setup.auth,
               fixture.setup.model,
               %{"model" => fixture.setup.model.exposed_model_id, "input" => []},
               Map.merge(input, %{
                 codex_session: fixture.session,
                 owner_idle_validated?: true,
                 owner_lease_token: fixture.session.owner_lease_token,
                 owner_instance_id: fixture.session.owner_instance_id
               })
             )

    assert successor.predecessor_request_id == fixture.request.id
    assert ClientRetry.reserved_successor_claim?(successor.correlation_id)
  end

  for {code, status} <- [{"owner_crashed", 502}, {"owner_unavailable", 503}], turn_status <- ["interrupted", "failed"] do
    @tag :proven_owner_response_task
    test "proven #{code} response-task failure permits one successor with #{turn_status} turn" do
      fixture = response_task_owner_loss_fixture!(unquote(code), unquote(status), unquote(turn_status))
      input = retry_input(fixture)
      assert {:error, :terminal_predecessor} = owner_loss_preflight(fixture, input)
      CodexPooler.ExecutionProofSupport.publish_terminal!(fixture.attempt)
      assert ExecutionTerminalProofs.terminal?(fixture.attempt)
      assert {:ok, %{client_retry_predecessor_request_id: predecessor_id}} = owner_loss_preflight(fixture, input)
      assert predecessor_id == fixture.request.id

      assert {:ok, %ClientRetry.SuccessorClaim{} = successor} =
               Accounting.claim_client_retry_successor(
                 fixture.setup.auth,
                 fixture.setup.model,
                 %{"model" => fixture.setup.model.exposed_model_id, "input" => []},
                 Map.merge(input, %{
                   codex_session: fixture.session,
                   owner_idle_validated?: true,
                   owner_lease_token: fixture.session.owner_lease_token,
                   owner_instance_id: fixture.session.owner_instance_id
                 })
               )

      assert successor.predecessor_request_id == fixture.request.id
      assert ClientRetry.reserved_successor_claim?(successor.correlation_id)
      assert Repo.aggregate(Ecto.Query.from(l in RequestClientRetryLink, where: l.predecessor_request_id == ^fixture.request.id), :count) == 1
      assert {:error, _refusal} = owner_loss_preflight(fixture, input)
      assert Repo.reload!(fixture.request).usage_status == "usage_unknown"
      assert Repo.reload!(fixture.turn).status == unquote(turn_status)
    end
  end

  for {code, status} <- [{"owner_crashed", 502}, {"owner_unavailable", 503}], control <- [:wrong_boot, :wrong_generation, :wrong_epoch, :wrong_witness, :foreign_key, :foreign_pool, :known_usage] do
    @tag :proven_owner_response_task
    test "canonical #{code} response-task failure rejects #{control}" do
      fixture = response_task_owner_loss_fixture!(unquote(code), unquote(status), "interrupted", unquote(control))
      CodexPooler.ExecutionProofSupport.publish_terminal!(fixture.attempt)
      input = retry_input(fixture)
      {fixture, input} = owner_loss_control(fixture, input, unquote(control))
      assert {:error, _refusal} = owner_loss_preflight(fixture, input)
      assert Repo.aggregate(Ecto.Query.from(l in RequestClientRetryLink, where: l.predecessor_request_id == ^fixture.request.id), :count) == 0
    end
  end

  @tag :proven_owner_response_task
  test "a terminal execution proof does not make an arbitrary interrupted failure retryable" do
    fixture = active_dead_execution_fixture!()
    assert {:ok, _settled} = AttemptSettlement.finalize_partial_stream_failure(fixture.request, fixture.attempt, %{status: "usage_unknown"}, %{response_status_code: 502, last_error_code: "other_owner_failure"})
    assert Repo.reload!(fixture.turn).status == "failed"
    fixture.turn |> Ecto.Changeset.change(status: "interrupted") |> Repo.update!()
    CodexPooler.ExecutionProofSupport.publish_terminal!(fixture.attempt)
    assert {:error, :terminal_predecessor} = owner_loss_preflight(fixture, retry_input(fixture))
  end

  @tag :proven_owner_response_task
  test "a delivered measured success keeps its distinct identical-resend authority and recorded charge" do
    fixture = active_dead_execution_fixture!()
    assert :ok = SessionContinuity.mark_codex_turn_visible(fixture.request, fixture.attempt)
    receipt = DeliveryReceipt.build(%{outcome: "delivered", terminal_class: "response.completed", highest_frame_class: "terminal", frames_after_visible: 1})
    assert :ok = DeliveryReceipt.persist(fixture.attempt.id, receipt)
    assert {:ok, _settled} = AttemptSettlement.finalize_success(fixture.request, fixture.attempt, %{status: "usage_known", input_tokens: 2, output_tokens: 1, total_tokens: 3}, %{})
    CodexPooler.ExecutionProofSupport.publish_terminal!(fixture.attempt)
    refute ClientRetry.verified_owner_crash?(Repo.reload!(fixture.turn), Repo.reload!(fixture.request), Repo.reload!(fixture.attempt))
    assert {:ok, %{client_retry_predecessor_request_id: predecessor_id}} = owner_loss_preflight(fixture, retry_input(fixture))
    assert predecessor_id == fixture.request.id
    assert Repo.reload!(fixture.turn).status == "succeeded"
    assert Repo.reload!(fixture.turn).first_visible_output_at != nil
    assert Repo.reload!(fixture.attempt).response_metadata["downstream_delivery"] == receipt
    assert [%LedgerEntry{total_tokens: 3}] = Repo.all(Ecto.Query.from(e in LedgerEntry, where: e.request_id == ^fixture.request.id and e.entry_kind == "settlement" and e.amount_status == "recorded"))
  end

  defp response_task_owner_loss_fixture!(code, status, turn_status, control \\ :none) do
    fixture = active_dead_execution_fixture!()
    usage = if control == :known_usage, do: %{status: "usage_known", input_tokens: 2, output_tokens: 1, total_tokens: 3}, else: %{status: "usage_unknown"}
    assert {:ok, _settled} = AttemptSettlement.finalize_partial_stream_failure(fixture.request, fixture.attempt, usage, %{response_status_code: status, last_error_code: code})
    assert Repo.reload!(fixture.turn).status == "interrupted"
    turn = if turn_status == "failed", do: fixture.turn |> Ecto.Changeset.change(status: "failed") |> Repo.update!(), else: Repo.reload!(fixture.turn)
    %{fixture | request: Repo.reload!(fixture.request), attempt: Repo.reload!(fixture.attempt), turn: turn}
  end

  defp owner_loss_preflight(fixture, input), do: Accounting.client_retry_preflight_snapshot(fixture.session, fixture.setup.api_key, fixture.setup.model, input)

  defp owner_loss_control(fixture, input, :wrong_boot) do
    fixture.attempt |> Ecto.Changeset.change(owner_instance_boot_id: "other-test-boot") |> Repo.update!()
    {fixture, input}
  end

  defp owner_loss_control(fixture, input, :wrong_generation) do
    fixture.attempt |> Ecto.Changeset.change(replay_generation: 1) |> Repo.update!()
    {fixture, input}
  end

  defp owner_loss_control(fixture, input, :wrong_epoch), do: {fixture, Map.update!(input, :runtime_revocation_epoch, &(&1 + 1))}
  defp owner_loss_control(fixture, input, :wrong_witness), do: {fixture, %{input | replay_claim_digest: :crypto.strong_rand_bytes(32)}}

  defp owner_loss_control(fixture, input, :foreign_key) do
    %{api_key: key} = CodexPooler.PoolerFixtures.active_api_key_fixture(fixture.setup.pool)
    {%{fixture | setup: %{fixture.setup | api_key: key}}, input}
  end

  defp owner_loss_control(fixture, input, :foreign_pool) do
    foreign = accounting_setup()
    {%{fixture | setup: %{fixture.setup | api_key: foreign.api_key, model: foreign.model}}, input}
  end

  defp owner_loss_control(fixture, input, _control), do: {fixture, input}

  defp create_dead_attempt!(setup, request) do
    parent = self()

    owner_pid =
      spawn(fn ->
        assert {:ok, attempt} = Accounting.create_attempt(request, setup.assignment)
        send(parent, {:dead_resend_attempt, self(), attempt})

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill) end)
    assert_receive {:dead_resend_attempt, ^owner_pid, %Attempt{} = attempt}, @detection_timeout_ms
    monitor = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner_pid, :killed}, @detection_timeout_ms
    attempt
  end

  defp active_dead_execution_fixture! do
    setup = accounting_setup()
    now = db_now()

    session =
      setup
      |> insert_session!()
      |> Ecto.Changeset.change(
        owner_instance_id: "owner-node@example",
        owner_instance_boot_id: "owner-boot",
        owner_lease_token: Ecto.UUID.generate(),
        owner_lease_expires_at: DateTime.add(now, 300, :second),
        last_heartbeat_at: now
      )
      |> Repo.update!()

    Repo.insert!(%BridgeOwnerLease{
      codex_session_id: session.id,
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      pool_upstream_assignment_id: setup.assignment.id,
      owner_instance_id: session.owner_instance_id,
      owner_instance_boot_id: session.owner_instance_boot_id,
      lease_token: session.owner_lease_token,
      status: "active",
      acquired_at: now,
      renewed_at: now,
      expires_at: session.owner_lease_expires_at,
      metadata: %{},
      created_at: now,
      updated_at: now
    })

    claim = "codex-turn:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    witness =
      ClientRetry.original_witness!(
        :crypto.strong_rand_bytes(32),
        setup.api_key.runtime_revocation_epoch
      )

    assert {:ok, %{request: claimed}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, %{
               endpoint: @endpoint,
               correlation_id: claim,
               codex_session: session,
               native_client_retry_witness: witness
             })

    assert {:ok, %{request: request}} =
             Accounting.reserve(
               setup.auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "input" => []},
               %{
                 endpoint: @endpoint,
                 transport: "websocket",
                 correlation_id: claim,
                 turn_claim: claimed
               }
             )

    attempt = create_dead_attempt!(setup, request)

    %{
      setup: setup,
      request: request,
      attempt: attempt,
      turn: insert_turn!(session, request, attempt),
      session: session,
      replay_claim_digest: witness.digest
    }
  end

  # The active dead-execution fixture with the request forwarded to the
  # session's owner (the metadata the owner's cleanup witness is checked
  # against).
  defp owned_dead_execution_fixture! do
    fixture = active_dead_execution_fixture!()

    request =
      fixture.request
      |> Ecto.Changeset.change(request_metadata: Map.put(fixture.request.request_metadata || %{}, "websocket_owner_forwarding", %{"owner_instance_id" => fixture.session.owner_instance_id, "downstream_epoch" => 1}))
      |> Repo.update!()

    %{fixture | request: request}
  end

  # The owner state its persistence reads: the session, the lease it holds and
  # the cleanup witness of its active turn.
  defp owner_state(fixture) do
    witness =
      %OwnerCleanup{
        session_id: fixture.session.id,
        owner_instance_id: fixture.session.owner_instance_id,
        owner_lease_token: fixture.session.owner_lease_token,
        request_id: fixture.request.id,
        attempt_id: fixture.attempt.id,
        replay_generation: 0,
        downstream_epoch: 1
      }

    %{
      codex_session_id: fixture.session.id,
      owner_lease_token: fixture.session.owner_lease_token,
      active_turn: %{cleanup_witness: witness},
      suspended_replay: nil,
      termination_cleanup_witness: nil,
      persistence: %{interrupt_codex_session: &Interruption.interrupt_codex_session/2}
    }
  end

  defp retry_input(fixture) do
    %{
      endpoint: @endpoint,
      requested_model: fixture.setup.model.exposed_model_id,
      runtime_revocation_epoch: fixture.setup.api_key.runtime_revocation_epoch,
      semantic_turn_digest: fixture.turn.semantic_turn_digest,
      original_request_claim: fixture.request.correlation_id,
      replay_claim_digest: fixture.replay_claim_digest,
      anchor_present?: false,
      reservation_estimate: %{
        input_tokens: 0,
        cached_input_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        total_tokens: 0,
        estimated_cost_micros: Decimal.new(0),
        strategy: "exact"
      }
    }
  end

  defp insert_session!(setup) do
    now = db_now()

    Repo.insert!(%CodexSession{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      session_key: "dead-resend-#{System.unique_integer([:positive, :monotonic])}",
      pool_upstream_assignment_id: setup.assignment.id,
      status: "active",
      created_at: now,
      updated_at: now
    })
  end

  defp insert_turn!(session, request, attempt) do
    now = db_now()

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      semantic_turn_digest: :crypto.strong_rand_bytes(32),
      status: "in_progress",
      final_attempt_id: attempt.id,
      started_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp attach_outcome_handler! do
    id = "dead-resend-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach(
        id,
        [:codex_pooler, :gateway, :stream, :outcome],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:dead_resend_outcome, metadata, Repo.in_transaction?()})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp assert_recovered!(request, attempt, turn) do
    assert %Request{status: "failed", last_error_code: "dead_execution_recovered"} =
             Repo.reload!(request)

    assert %Attempt{
             status: "failed",
             network_error_code: "dead_execution_recovered",
             usage_status: "usage_unknown"
           } = Repo.reload!(attempt)

    assert %CodexTurn{status: "interrupted", error_code: "dead_execution_recovered"} =
             Repo.reload!(turn)
  end

  defp ledger_kinds(request_id) do
    Repo.all(
      from entry in LedgerEntry,
        where: entry.request_id == ^request_id,
        order_by: [asc: entry.entry_kind],
        select: entry.entry_kind
    )
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    now
  end
end
