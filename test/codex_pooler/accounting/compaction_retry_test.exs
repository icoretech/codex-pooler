defmodule CodexPooler.Accounting.CompactionRetryTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting

  alias CodexPooler.Accounting.{
    Attempt,
    ClientRetry,
    LedgerEntry,
    Request,
    RequestClientRetryLink,
    RequestLifecycle,
    RequestReplayEntitlement
  }

  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.Platform.ExecutionIdentity
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport

  # What the attempt records for the Codex backend's websocket refusal of an
  # anchor its connection cannot resolve (findings#232 row 232-277).
  @provider_refusal_rejection %{
    "rejection_upstream_status" => 400,
    "rejection_error_type" => "invalid_request_error",
    "rejection_message_class" => "invalid_previous_response_id",
    "rejection_message_present" => true,
    "rejection_message_bytes" => 31
  }

  test "compact successor preserves capacity denial until a different reservation releases" do
    {setup, _predecessor, opts} = local_failure_predecessor!(:task_exception)
    update!(setup.api_key, max_active_requests: 1)

    assert {:ok, occupied} =
             Accounting.reserve(
               setup.auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id},
               %{
                 correlation_id: Ecto.UUID.generate()
               }
             )

    before = row_counts()

    assert {:error, %{code: :api_key_concurrency_limit_exceeded}} =
             Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

    assert row_counts() == before

    assert {:ok, _} =
             Accounting.finalize_reservation_failure(
               occupied.request,
               %{last_error_code: "dispatch_unavailable"}
             )

    assert {:ok, _} =
             Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
  end

  for failure <- [:dead_execution, :task_exception] do
    test "claims exactly one compact successor after verified #{failure}" do
      {setup, predecessor, opts} = local_failure_predecessor!(unquote(failure))

      assert {:ok, claim} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      assert claim.predecessor_request_id == predecessor.id
      assert claim.request.id != predecessor.id
      assert claim.codex_turn.turn_sequence == 2
      assert Repo.aggregate(RequestClientRetryLink, :count) == 1

      assert {:error, :successor_claimed} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
    end

    for mutation <- [
          :visible,
          :request_endpoint,
          :input_endpoint,
          :generation,
          :request_status,
          :attempt_status,
          :request_usage,
          :attempt_usage,
          :response_status,
          :attempt_identity,
          :epoch,
          :model,
          :anchor,
          :entitlement
        ] do
      test "rejects altered compact #{failure} #{mutation} evidence without a successor" do
        {setup, predecessor, opts} = local_failure_predecessor!(unquote(failure))
        turn = Repo.get_by!(CodexTurn, request_id: predecessor.id)
        attempt = Repo.get!(Attempt, turn.final_attempt_id)
        opts = alter_local_failure!(unquote(mutation), setup, predecessor, turn, attempt, opts)
        before = row_counts()

        if unquote(failure) == :dead_execution and unquote(mutation) == :visible do
          assert {:ok, claim} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
          assert claim.predecessor_request_id == predecessor.id
        else
          assert {:error, _} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
          assert row_counts() == before
        end
      end
    end
  end

  # A rollout drain (`owner_drained`), an executor proven dead
  # (`dead_execution_recovered`) or the provider's stream
  # (`upstream_stream_error`) cut a compaction the Pooler had started
  # collecting. A native compaction reaches the client only with its terminal,
  # so a receipt with only the cut's error, or nothing, proves the client got
  # none of it and resends it (findings#270 rows 270-352 and 270-365).
  for code <- ["owner_drained", "dead_execution_recovered", "upstream_stream_error"], terminal_class <- ["error", "none"] do
    test "claims one successor for a compaction cut after the Pooler began collecting it: #{code}, client written #{terminal_class}" do
      {setup, predecessor, opts} = collected_cut_predecessor!(unquote(code), unquote(terminal_class))
      assert compaction_resend_shape(predecessor) == {:ok, :unreceived_compaction}

      assert {:ok, claim} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
      assert claim.predecessor_request_id == predecessor.id
      assert Repo.aggregate(RequestClientRetryLink, :count) == 1
    end
  end

  for code <- ["owner_drained", "dead_execution_recovered", "upstream_stream_error"], receipt <- ["response.completed", :absent] do
    test "chains a compaction resend independently of server receipt: #{code}, receipt #{receipt}" do
      {setup, predecessor, opts} = collected_cut_predecessor!(unquote(code), unquote(receipt))
      assert compaction_resend_shape(predecessor) == {:ok, :unreceived_compaction}
      assert {:ok, claim} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
      assert claim.predecessor_request_id == predecessor.id
      assert Repo.aggregate(RequestClientRetryLink, :count) == 1
    end
  end

  test "rejects recovered compact evidence without its execution identity" do
    for field <- [
          :owner_instance_id,
          :owner_instance_boot_id,
          :owner_process_id,
          :owner_execution_id
        ] do
      {setup, predecessor, opts} = local_failure_predecessor!(:dead_execution)
      attempt = Repo.get_by!(Attempt, request_id: predecessor.id)
      update!(attempt, [{field, nil}])
      before = row_counts()

      assert {:error, :terminal_predecessor} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      assert row_counts() == before
    end
  end

  # The turn's next compaction runs one window later under a claim of its own
  # (findings#270 rows 270-351 and 270-357): its resend meets it, never the
  # older compaction's chain, and the older one's resend after it is refused,
  # since the client completed that one and went on.
  for terminal_status <- ["failed", "interrupted"] do
    test "selects the turn's newer #{terminal_status} compaction by its own claim when an older failure already has a successor" do
      {setup, older, opts} = predecessor!("client_disconnected", 0)

      assert {:ok, older_claim} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      completed_at = DateTime.utc_now()
      update!(older_claim.request, status: "succeeded", completed_at: completed_at)
      update!(older_claim.codex_turn, status: "succeeded", completed_at: completed_at)
      newer_claim_key = compaction_claim()

      assert {:ok, %{request: newer}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, %{
                 endpoint: opts.endpoint,
                 correlation_id: newer_claim_key,
                 native_client_retry_witness:
                   ClientRetry.original_witness!(
                     opts.replay_claim_digest,
                     setup.api_key.runtime_revocation_epoch
                   )
               })

      newer =
        update!(newer,
          status: "failed",
          completed_at: completed_at,
          last_error_code: "client_disconnected"
        )

      attempt =
        CodexPooler.PoolerFixtures.attempt_fixture(newer, setup.assignment, %{
          status: "failed",
          completed_at: completed_at,
          network_error_code: "client_disconnected",
          transport: "websocket",
          replay_generation: 0
        })

      Repo.insert!(%CodexTurn{
        codex_session_id: opts.codex_session.id,
        request_id: newer.id,
        turn_sequence: 3,
        transport_kind: "websocket",
        semantic_turn_digest: opts.semantic_turn_digest,
        status: unquote(terminal_status),
        error_code: "client_disconnected",
        final_attempt_id: attempt.id,
        completed_at: completed_at,
        started_at: completed_at,
        created_at: completed_at,
        updated_at: completed_at
      })

      # The client retry policy judges the newest original turn of the digest,
      # a client disconnect outside its admissible vocabulary, rather than the
      # older linked failure it used to lock first; either way it stays fenced.
      assert {:error, :terminal_predecessor} =
               Accounting.claim_client_retry_successor(setup.auth, setup.model, %{}, opts)

      counts = row_counts()

      assert {:error, :terminal_predecessor} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      assert row_counts() == counts

      assert {:ok, newer_claim} =
               Accounting.claim_compaction_retry_successor(
                 setup.auth,
                 setup.model,
                 %{},
                 Map.put(opts, :original_request_claim, newer_claim_key)
               )

      assert newer_claim.predecessor_request_id == newer.id
      assert newer_claim.link.predecessor_request_id == newer.id
      assert newer_claim.codex_turn.turn_sequence == 4
      assert older_claim.link.predecessor_request_id == older.id
      assert Repo.get!(RequestClientRetryLink, older_claim.link.id) == older_claim.link
      assert Repo.aggregate(RequestClientRetryLink, :count) == 2
    end
  end

  test "selects the failed compaction after an ordinary turn with the same semantic digest" do
    {setup, predecessor, opts} = predecessor!("upstream_stream_error", 0)
    compact_turn = Repo.get_by!(CodexTurn, request_id: predecessor.id)
    update!(compact_turn, turn_sequence: 2)

    assert {:ok, %{request: ordinary}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, %{
               endpoint: "/backend-api/codex/responses",
               correlation_id: Ecto.UUID.generate()
             })

    completed_at = DateTime.utc_now()
    update!(ordinary, status: "succeeded", completed_at: completed_at)

    ordinary_attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(ordinary, setup.assignment, %{
        status: "succeeded",
        completed_at: completed_at,
        transport: "websocket",
        replay_generation: 0
      })

    Repo.insert!(%CodexTurn{
      codex_session_id: opts.codex_session.id,
      request_id: ordinary.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      semantic_turn_digest: opts.semantic_turn_digest,
      status: "succeeded",
      final_attempt_id: ordinary_attempt.id,
      completed_at: completed_at,
      started_at: completed_at,
      created_at: completed_at,
      updated_at: completed_at
    })

    assert {:ok, claim} =
             Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

    assert claim.predecessor_request_id == predecessor.id
    assert claim.link.predecessor_request_id == predecessor.id
    assert claim.codex_turn.turn_sequence == 3
    assert Repo.get!(Request, ordinary.id).status == "succeeded"

    assert {:error, :successor_claimed} =
             Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

    assert Repo.aggregate(RequestClientRetryLink, :count) == 1
  end

  for error <- ["upstream_stream_error", "client_disconnected", "owner_drained"] do
    test "claims one distinct successor after the watchdog for #{error}" do
      {setup, predecessor, opts} = predecessor!(unquote(error), 305)
      payload = %{"model" => setup.model.exposed_model_id}

      assert {:error, :terminal_predecessor} =
               Accounting.claim_client_retry_successor(setup.auth, setup.model, payload, opts)

      assert {:ok, claim} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, payload, opts)

      assert claim.request.id != predecessor.id
      assert claim.correlation_id != predecessor.correlation_id
      assert claim.reservation.request_id == claim.request.id
      assert claim.codex_turn.request_id == claim.request.id
      assert claim.codex_turn.codex_session_id == opts.codex_session.id
      assert claim.codex_turn.turn_sequence == 2
      refute ClientRetry.original_witness_eligible?(claim.request)

      assert {:ok, claim.correlation_id} ==
               ClientRetry.deterministic_compaction_successor_claim(
                 predecessor,
                 Repo.get_by!(CodexTurn, request_id: predecessor.id),
                 opts.replay_claim_digest
               )

      assert :ok ==
               ClientRetry.validate_dispatch_authority(claim.request, claim.dispatch_authority)

      assert {:error, :successor_claimed} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, payload, opts)

      assert Repo.aggregate(RequestClientRetryLink, :count) == 1
    end
  end

  for {event_type, error} <- [
        {"response.failed", "server_error"},
        {"response.failed", "rate_limit_exceeded"},
        {"response.failed", "slow_down"},
        {"response.incomplete", "max_output_tokens"}
      ] do
    test "claims one successor for Codex-retryable #{event_type} #{error}" do
      {setup, predecessor, opts} = predecessor!(unquote(error), 0)
      attempt = Repo.get_by!(Attempt, request_id: predecessor.id)

      update!(attempt, response_metadata: %{"stream_terminal_type" => unquote(event_type)})

      assert {:ok, claim} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      assert claim.predecessor_request_id == predecessor.id
      assert Repo.aggregate(RequestClientRetryLink, :count) == 1

      assert {:error, :successor_claimed} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
    end
  end

  for error <- [
        "context_length_exceeded",
        "insufficient_quota",
        "credit_balance_exhausted",
        "organization_spend_limit_exceeded",
        "project_spend_limit_exceeded",
        "usage_not_included",
        "cyber_policy",
        "misalignment_policy_violation",
        "invalid_prompt",
        "bio_policy",
        "server_is_overloaded"
      ] do
    test "rejects Codex-terminal response.failed #{error} without side effects" do
      {setup, predecessor, opts} = predecessor!(unquote(error), 0)
      attempt = Repo.get_by!(Attempt, request_id: predecessor.id)
      update!(attempt, response_metadata: %{"stream_terminal_type" => "response.failed"})
      counts = row_counts()

      assert {:error, :terminal_predecessor} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      assert row_counts() == counts

      refute Repo.exists?(
               from link in RequestClientRetryLink,
                 where: link.predecessor_request_id == ^predecessor.id
             )
    end
  end

  test "a verified session budget terminal cannot create a compaction successor" do
    {setup, predecessor, opts} = predecessor!("budget_reached", 0)
    attempt = Repo.get_by!(Attempt, request_id: predecessor.id)
    update!(attempt, response_metadata: %{"stream_terminal_type" => "response.failed", "session_budget_terminal" => true})
    counts = row_counts()

    assert {:error, :terminal_predecessor} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
    assert row_counts() == counts
  end

  for code <- ~w(inference_hook_denied content_policy_violation invalid_access_program unsupported_access_program access_program_not_enabled) do
    test "verified #{code} cannot create a native compaction successor" do
      {setup, predecessor, opts} = predecessor!(unquote(code), 0)
      attempt = Repo.get_by!(Attempt, request_id: predecessor.id)
      update!(attempt, response_metadata: %{"stream_terminal_type" => "response.failed", "request_policy_terminal" => true})
      counts = row_counts()
      assert {:error, :terminal_predecessor} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
      assert row_counts() == counts
    end
  end

  test "a budget code without the verified terminal carrier keeps the prior retry policy" do
    {setup, predecessor, opts} = predecessor!("budget_reached", 0)
    attempt = Repo.get_by!(Attempt, request_id: predecessor.id)
    update!(attempt, response_metadata: %{"stream_terminal_type" => "response.failed", "rejection_upstream_status" => 401})

    assert {:ok, _claim} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
  end

  # The connection-bound guard refused an anchored compaction before sending
  # it, and its client got `previous_response_not_found`, which the released
  # client retries as the full request without the anchor. With owner
  # forwarding on, that resend met `terminal_predecessor` here (findings#278).
  # The provider's own refusal of an anchor gets the same event when its shape
  # proves it preceded any execution: the codeless wrapped `error` event,
  # status 400 `invalid_request_error`, with the fixed `Invalid
  # previous_response_id` message class (findings#270 row 270-238).
  for refusal <- [:guard_refusal, :provider_refusal] do
    test "claims one successor for a compaction whose anchor was refused before any execution: #{refusal}" do
      {setup, predecessor, opts} = guard_refused_predecessor!(unquote(refusal))

      assert {:ok, claim} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      assert claim.predecessor_request_id == predecessor.id
      assert Repo.aggregate(RequestClientRetryLink, :count) == 1
      assert {:ok, :anchor_refusal} = compaction_resend_shape(predecessor)
    end
  end

  # A refusal with neither the guard's metadata nor the provider's proven
  # shape, a refusal recorded as sent upstream (not the guard's), and a
  # provider 400 of another message class keep the fence: their client gets
  # the collected compaction's 400, which it does not retry.
  for mutation <- [:unproven_refusal, :upstream_committed, :other_refusal_class] do
    test "keeps the fence for a compaction anchor refusal: #{mutation}" do
      {setup, predecessor, opts} = guard_refused_predecessor!(unquote(mutation))
      counts = row_counts()

      assert {:error, :terminal_predecessor} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      assert row_counts() == counts

      refute Repo.exists?(
               from link in RequestClientRetryLink,
                 where: link.predecessor_request_id == ^predecessor.id
             )
    end
  end

  for endpoint <- ["/backend-api/codex/responses", "/backend-api/codex/responses/compact"] do
    test "does not revive an older failed compact after a newer successful #{endpoint} turn" do
      {setup, predecessor, opts} = predecessor!("upstream_stream_error", 0)
      newer_claim_key = if(unquote(endpoint) == "/backend-api/codex/responses/compact", do: compaction_claim(), else: Ecto.UUID.generate())

      assert {:ok, %{request: newer}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, %{
                 endpoint: unquote(endpoint),
                 correlation_id: newer_claim_key
               })

      completed_at = DateTime.utc_now()
      update!(newer, status: "succeeded", completed_at: completed_at)

      attempt =
        CodexPooler.PoolerFixtures.attempt_fixture(newer, setup.assignment, %{
          status: "succeeded",
          completed_at: completed_at,
          transport: "websocket",
          replay_generation: 0
        })

      Repo.insert!(%CodexTurn{
        codex_session_id: opts.codex_session.id,
        request_id: newer.id,
        turn_sequence: 2,
        transport_kind: "websocket",
        semantic_turn_digest: opts.semantic_turn_digest,
        status: "succeeded",
        final_attempt_id: attempt.id,
        completed_at: completed_at,
        started_at: completed_at,
        created_at: completed_at,
        updated_at: completed_at
      })

      counts = row_counts()

      # A request of the turn newer than the compaction's chain means the
      # client completed that compaction and went on: the resume after it, or
      # the turn's next compaction, one window later under a claim of its own.
      # The client resends only a compaction it did not complete, so the older
      # one's resend is refused and nothing revives it (findings#270 rows
      # 270-354 and 270-357). Before, the newest request of the turn was the
      # predecessor whatever its claim: a newer compaction took the older
      # one's resend, and a newer resume refused every full-history send of
      # the turn's next compaction `authorization_changed`.
      assert {:error, :terminal_predecessor} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      refute Repo.exists?(
               from link in RequestClientRetryLink,
                 where: link.predecessor_request_id == ^predecessor.id
             )

      assert row_counts() == counts

      # The newer compaction's own resend, under the claim it holds, is chained
      # onto it: the client resends a compaction only when it did not read its
      # reply (findings#206 row 206-330).
      if unquote(endpoint) == "/backend-api/codex/responses/compact" do
        assert {:ok, %{predecessor_request_id: predecessor_request_id}} =
                 Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, Map.put(opts, :original_request_claim, newer_claim_key))

        assert predecessor_request_id == newer.id
      end
    end
  end

  # A resend whose claim no compaction of the turn holds repeats nothing
  # recorded: the owner's preflight answers `:none`, the frame is served as a
  # new compaction, and a successor claim is refused. The turn's second
  # compaction sent first as full history (its socket closed during the tool
  # round before it) was chained to the first one (findings#270 row 270-357).
  test "a compaction resend whose claim no compaction of the turn holds is new, not a resend of the turn's compaction" do
    {setup, predecessor, opts} = predecessor!("client_disconnected", 0)
    opts = Map.put(opts, :original_request_claim, compaction_claim())
    counts = row_counts()

    assert :none =
             ClientRetry.preflight_snapshot(opts.codex_session, setup.api_key, setup.model, Map.put(opts, :retry_policy, :native_compaction))

    assert {:error, :terminal_predecessor} =
             Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

    assert row_counts() == counts
    refute Repo.exists?(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^predecessor.id))
  end

  test "rejects expired, visible, mismatched and unauthorized predecessors without side effects" do
    for mutation <- [
          :expired,
          :full_history,
          :bridge,
          :anchor,
          :missing_anchor,
          :semantic,
          :epoch,
          :endpoint,
          :error,
          :session,
          :model,
          :active
        ] do
      {setup, predecessor, opts} = predecessor!("upstream_stream_error", 0)
      turn = Repo.get_by!(CodexTurn, request_id: predecessor.id)

      opts =
        case mutation do
          :expired ->
            update!(predecessor, completed_at: DateTime.add(DateTime.utc_now(), -331, :second))
            opts

          :full_history ->
            Map.put(opts, :full_history?, false)

          :bridge ->
            Map.put(opts, :compaction_trigger_bridge?, false)

          :anchor ->
            Map.put(opts, :anchor_present?, true)

          :missing_anchor ->
            Map.delete(opts, :anchor_present?)

          :semantic ->
            Map.put(opts, :semantic_turn_digest, <<9::256>>)

          :epoch ->
            Map.update!(opts, :runtime_revocation_epoch, &(&1 + 1))

          :endpoint ->
            Map.put(opts, :endpoint, "/backend-api/codex/responses")

          :error ->
            update!(predecessor, last_error_code: "other_error")
            opts

          :model ->
            Map.put(opts, :requested_model, "other-model")

          :active ->
            update!(turn, status: "in_progress", completed_at: nil)
            opts

          :session ->
            session = opts.codex_session

            other =
              Repo.insert!(%CodexSession{
                pool_id: session.pool_id,
                api_key_id: session.api_key_id,
                session_key: Ecto.UUID.generate(),
                status: "active",
                created_at: DateTime.utc_now(),
                updated_at: DateTime.utc_now()
              })

            Map.put(opts, :codex_session, other)
        end

      before = Repo.aggregate(Request, :count)

      assert {:error, _reason} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      assert Repo.aggregate(Request, :count) == before
      assert Repo.aggregate(RequestClientRetryLink, :count) == 0
    end
  end

  test "rolls back the entire successor if link storage fails" do
    {setup, predecessor, opts} = predecessor!("upstream_stream_error", 0)
    before = Repo.aggregate(Request, :count)

    assert {:error, :storage_failure} =
             Accounting.claim_compaction_retry_successor(
               setup.auth,
               setup.model,
               %{},
               Map.put(opts, :force_client_retry_storage_failure, true)
             )

    assert Repo.aggregate(Request, :count) == before
    assert Repo.aggregate(CodexTurn, :count) == 1
    assert Repo.aggregate(RequestClientRetryLink, :count) == 0
    assert Repo.get!(Request, predecessor.id).status == "failed"
  end

  test "claims legacy interrupted client disconnect without an original retry witness" do
    {setup, predecessor, opts} = predecessor!("client_disconnected", 305)

    predecessor =
      update!(predecessor,
        native_client_retry_digest: nil,
        native_client_retry_version: nil,
        native_client_retry_auth_epoch: nil
      )

    Repo.get_by!(CodexTurn, request_id: predecessor.id) |> update!(status: "interrupted")

    assert {:error, :missing_witness} =
             Accounting.claim_client_retry_successor(setup.auth, setup.model, %{}, opts)

    assert {:ok, claim} =
             Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

    refute ClientRetry.original_witness_eligible?(claim.request)
    assert :ok = ClientRetry.validate_dispatch_authority(claim.request, claim.dispatch_authority)

    assert {:error, :successor_claimed} =
             Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
  end

  test "reclaims the same unattempted successor and fences the previous downstream cleanup" do
    {setup, _predecessor, opts} = predecessor!("client_disconnected", 0)
    update!(setup.api_key, max_active_requests: 1)
    opts = live_owner!(setup, opts)
    first_opts = forwarding_opts(opts, 1)

    assert {:ok, first} =
             Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, first_opts)

    counts = row_counts()
    parent = self()

    second_opts =
      opts
      |> forwarding_opts(2)
      |> Map.put(:direct_cleanup_bind, fn request ->
        send(parent, {:cleanup_bound, request.id, request.request_metadata})
        :ok
      end)

    assert {:ok, second} =
             Accounting.claim_compaction_retry_successor(
               setup.auth,
               setup.model,
               %{},
               second_opts
             )

    assert second.request.id == first.request.id
    assert second.codex_turn.id == first.codex_turn.id
    assert second.reservation == first.reservation
    assert second.link == first.link
    refute second.dispatch_authority == first.dispatch_authority
    assert second.pricing_snapshot == first.pricing_snapshot
    assert second.pricing_status == first.pricing_status
    assert second.pricing_service_tier == first.pricing_service_tier
    assert second.estimate == first.estimate
    assert row_counts() == counts
    assert second.request.request_metadata["pricing"] == first.request.request_metadata["pricing"]

    assert second.request.request_metadata["request_id"] ==
             second_opts.request_metadata["request_id"]

    assert_receive {:cleanup_bound, request_id, metadata}
    assert request_id == first.request.id
    assert metadata["websocket_owner_forwarding"]["downstream_epoch"] == 2

    stale_receipt = %{
      session_id: opts.codex_session.id,
      request_id: first.request.id,
      correlation_id: first.correlation_id,
      api_key_id: setup.api_key.id,
      owner_binding: %{
        owner_instance_id: opts.owner_instance_id,
        owner_lease_token: opts.owner_lease_token,
        downstream_epoch: 1
      }
    }

    assert :ok = DirectCleanup.interrupt(stale_receipt, "client_disconnected")
    assert Repo.get!(Request, first.request.id).status == "in_progress"
    assert Repo.get!(CodexTurn, first.codex_turn.id).status == "in_progress"
    assert row_counts() == counts

    current_receipt = put_in(stale_receipt.owner_binding.downstream_epoch, 2)
    assert :ok = DirectCleanup.interrupt(current_receipt, "client_disconnected")
    assert Repo.get!(Request, first.request.id).status == "failed"
  end

  test "image allowance survives successor creation and reclaim without accepting a new estimate" do
    {setup, _predecessor, opts} = predecessor!("client_disconnected", 0)
    opts = live_owner!(setup, opts)
    payload = %{"input" => [%{"role" => "user", "content" => [%{"type" => "input_image", "image_url" => "https://example.com/image.png"}]}]}
    assert {:ok, first} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, payload, forwarding_opts(opts, 1))
    assert first.estimate.image_estimate.image_count == 1
    assert first.estimate.image_estimate.image_tokens == 1_600
    assert first.request.request_metadata["reservation"]["image_estimate"] == first.reservation.details["image_estimate"]
    counts = row_counts()
    incoming = opts |> forwarding_opts(2) |> Map.put(:reservation_estimate, %{input_tokens: 99, output_tokens: 99})
    assert {:ok, reclaimed} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, incoming)
    assert reclaimed.estimate == first.estimate
    assert reclaimed.reservation == first.reservation
    assert reclaimed.request.request_metadata["reservation"] == first.request.request_metadata["reservation"]
    assert row_counts() == counts
  end

  test "reclaimed authority fences an old worker before its first attempt" do
    {setup, _predecessor, opts} = predecessor!("client_disconnected", 0)
    opts = live_owner!(setup, opts)

    assert {:ok, first} =
             Accounting.claim_compaction_retry_successor(
               setup.auth,
               setup.model,
               %{},
               forwarding_opts(opts, 1)
             )

    counts = row_counts()

    assert {:ok, second} =
             Accounting.claim_compaction_retry_successor(
               setup.auth,
               setup.model,
               %{},
               forwarding_opts(opts, 2)
             )

    assert second.request.id == first.request.id
    assert second.link == first.link
    assert second.reservation == first.reservation
    assert row_counts() == counts
    assert first.dispatch_authority.compaction_owner.downstream_epoch == 1
    assert second.dispatch_authority.compaction_owner.downstream_epoch == 2

    assert {:error, %{code: :invalid_client_retry_dispatch_authority}} =
             Accounting.create_client_retry_dispatch_attempt(
               first.request,
               setup.assignment,
               first.dispatch_authority,
               %{transport: "websocket"}
             )

    refute Repo.exists?(from attempt in Attempt, where: attempt.request_id == ^first.request.id)

    assert {:ok, attempt} =
             Accounting.create_client_retry_dispatch_attempt(
               second.request,
               setup.assignment,
               second.dispatch_authority,
               %{transport: "websocket"}
             )

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^second.request.id), :count) ==
             1

    assert :ok =
             ClientRetry.validate_dispatch_attempt(
               second.request.id,
               attempt.id,
               second.dispatch_authority
             )

    assert {:error, :stale_owner} =
             ClientRetry.validate_dispatch_attempt(
               second.request.id,
               attempt.id,
               first.dispatch_authority
             )
  end

  test "rejects attempted, finalized, released, mismatched or unfenced successor reclaim" do
    for mutation <- [
          :attempt,
          :finalized,
          :visible,
          :released,
          :voided,
          :digest,
          :same_epoch,
          :ownerless,
          :expired_lease
        ] do
      {setup, _predecessor, opts} = predecessor!("client_disconnected", 0)
      opts = live_owner!(setup, opts)

      assert {:ok, first} =
               Accounting.claim_compaction_retry_successor(
                 setup.auth,
                 setup.model,
                 %{},
                 forwarding_opts(opts, 1)
               )

      retry_opts = forwarding_opts(opts, 2)

      retry_opts =
        case mutation do
          :attempt ->
            CodexPooler.PoolerFixtures.attempt_fixture(first.request, setup.assignment)
            retry_opts

          :finalized ->
            update!(first.request, status: "failed", completed_at: DateTime.utc_now())
            retry_opts

          :visible ->
            update!(first.codex_turn, first_visible_output_at: DateTime.utc_now())
            retry_opts

          :released ->
            attrs =
              first.reservation
              |> Map.from_struct()
              |> Map.drop([:__meta__, :id])
              |> Map.merge(%{entry_kind: "release", source_event_id: Ecto.UUID.generate()})

            Repo.insert!(struct(LedgerEntry, attrs))
            retry_opts

          :voided ->
            update!(first.reservation, amount_status: "voided")
            retry_opts

          :digest ->
            Map.put(retry_opts, :replay_claim_digest, :crypto.strong_rand_bytes(32))

          :same_epoch ->
            forwarding_opts(opts, 1)

          :ownerless ->
            Map.put(retry_opts, :request_metadata, %{})

          :expired_lease ->
            Repo.get_by!(BridgeOwnerLease, codex_session_id: opts.codex_session.id)
            |> update!(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))

            retry_opts
        end

      counts = row_counts()

      assert {:error, :successor_claimed} =
               Accounting.claim_compaction_retry_successor(
                 setup.auth,
                 setup.model,
                 %{},
                 retry_opts
               )

      assert row_counts() == counts

      assert Repo.get!(Request, first.request.id).request_metadata ==
               first.request.request_metadata
    end
  end

  # The released client resends a remote compaction whose reply it did not
  # read up to twice, so a successor whose own reply was lost is the next
  # resend's predecessor, as with owner forwarding off
  # (findings#270 row 270-237 (a)).
  describe "a compaction's resend chain" do
    test "chains the next resend onto a settled successor, under the claim derived from it" do
      {setup, original, opts} = predecessor!("client_disconnected", 0)
      assert {:ok, first} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
      assert first.predecessor_request_id == original.id
      settle_successor!(setup, first, :disconnected)

      assert {:ok, second} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
      assert second.predecessor_request_id == first.request.id
      refute second.request.id in [original.id, first.request.id]
      assert second.codex_turn.turn_sequence == 3

      assert {:ok, derived} = ClientRetry.deterministic_compaction_successor_claim(Repo.get!(Request, first.request.id), second.codex_turn, opts.replay_claim_digest)
      assert second.request.correlation_id == derived

      assert Enum.sort(Repo.all(from(link in RequestClientRetryLink, select: {link.predecessor_request_id, link.successor_request_id}))) ==
               Enum.sort([{original.id, first.request.id}, {first.request.id, second.request.id}])
    end

    test "refuses a settled successor this policy did not derive for the resend" do
      {setup, _original, opts} = predecessor!("client_disconnected", 0)
      assert {:ok, first} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
      settle_successor!(setup, first, :disconnected)
      update!(Repo.get!(Request, first.request.id), correlation_id: "client-retry-v1:compaction:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false))
      counts = row_counts()

      assert {:error, :retry_exhausted} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)
      assert row_counts() == counts
    end

    test "reclaims an unattempted successor of a settled successor" do
      {setup, _original, opts} = predecessor!("client_disconnected", 0)
      opts = live_owner!(setup, opts)
      assert {:ok, first} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, forwarding_opts(opts, 1))
      settle_successor!(setup, first, :disconnected)
      assert {:ok, second} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, forwarding_opts(opts, 2))
      counts = row_counts()

      assert {:ok, reclaimed} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, forwarding_opts(opts, 3))
      assert reclaimed.request.id == second.request.id
      assert reclaimed.codex_turn.id == second.codex_turn.id
      assert reclaimed.link == second.link
      assert reclaimed.predecessor_request_id == first.request.id
      assert row_counts() == counts
    end

    test "keeps a running successor of a settled successor, and chains onto it once it was served and its reply lost" do
      {setup, _original, opts} = predecessor!("client_disconnected", 0)
      opts = live_owner!(setup, opts)
      assert {:ok, first} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, forwarding_opts(opts, 1))
      settle_successor!(setup, first, :disconnected)
      assert {:ok, second} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, forwarding_opts(opts, 2))
      attempt = CodexPooler.PoolerFixtures.attempt_fixture(second.request, setup.assignment, %{transport: "websocket", replay_generation: 0})
      counts = row_counts()

      assert {:error, :successor_claimed} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, forwarding_opts(opts, 3))
      assert row_counts() == counts

      settle_successor!(setup, second, :served, attempt)
      assert {:ok, third} = Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, forwarding_opts(opts, 4))
      assert third.predecessor_request_id == second.request.id
      refute third.request.id == second.request.id
    end
  end

  # A claimed successor as its settlement leaves it once it ran: its client left
  # before the reply (`client_disconnected` everywhere), or the provider served
  # it and its reply was lost (`succeeded`).
  defp settle_successor!(setup, claim, outcome, attempt \\ nil) do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    attempt = attempt || CodexPooler.PoolerFixtures.attempt_fixture(claim.request, setup.assignment, %{transport: "websocket", replay_generation: 0})

    {request_attrs, turn_attrs, attempt_attrs} =
      case outcome do
        :disconnected ->
          {[status: "failed", last_error_code: "client_disconnected"], [status: "interrupted", error_code: "client_disconnected"], [status: "failed", network_error_code: "client_disconnected"]}

        :served ->
          {[status: "succeeded"], [status: "succeeded"], [status: "succeeded"]}
      end

    update!(Repo.get!(Attempt, attempt.id), attempt_attrs ++ [completed_at: now])
    update!(Repo.get!(Request, claim.request.id), request_attrs ++ [completed_at: now])
    update!(Repo.get!(CodexTurn, claim.codex_turn.id), turn_attrs ++ [final_attempt_id: attempt.id, completed_at: now])
    :ok
  end

  defp live_owner!(setup, opts) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, 60, :second)
    token = Ecto.UUID.generate()

    Repo.insert!(%BridgeOwnerLease{
      codex_session_id: opts.codex_session.id,
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      pool_upstream_assignment_id: setup.assignment.id,
      owner_instance_id: "owner-a",
      lease_token: token,
      status: "active",
      acquired_at: now,
      renewed_at: now,
      expires_at: expires_at,
      metadata: %{},
      created_at: now,
      updated_at: now
    })

    session =
      update!(opts.codex_session,
        owner_instance_id: "owner-a",
        owner_lease_token: token,
        owner_lease_expires_at: expires_at,
        last_heartbeat_at: now
      )

    Map.merge(opts, %{
      codex_session: session,
      owner_idle_validated?: true,
      owner_instance_id: "owner-a",
      owner_lease_token: token
    })
  end

  defp forwarding_opts(opts, epoch) do
    Map.put(opts, :request_metadata, %{
      "request_id" => Ecto.UUID.generate(),
      "websocket_owner_forwarding" => %{
        "owner_instance_id" => opts.owner_instance_id,
        "downstream_epoch" => epoch
      }
    })
  end

  defp local_failure_predecessor!(failure) do
    setup = accounting_setup(%{price_version: Ecto.UUID.generate()})
    now = DateTime.utc_now()
    semantic = :crypto.strong_rand_bytes(32)
    digest = :crypto.strong_rand_bytes(32)
    endpoint = "/backend-api/codex/responses/compact"
    claim = compaction_claim()
    parent = self()

    child =
      start_supervised!(
        {Task,
         fn ->
           {:ok, reserved} =
             Accounting.reserve(
               setup.auth,
               setup.model,
               %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
               %{
                 endpoint: endpoint,
                 transport: "websocket",
                 correlation_id: claim
               }
             )

           {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
           send(parent, {:compact_execution, reserved.request, attempt})

           receive do
             :finish -> :ok
           end
         end},
        id: make_ref()
      )

    monitor = Process.monitor(child)
    assert_receive {:compact_execution, request, attempt}, 15_000
    assert ExecutionIdentity.status(attempt) == :alive

    session =
      Repo.insert!(%CodexSession{
        pool_id: setup.pool.id,
        api_key_id: setup.api_key.id,
        session_key: Ecto.UUID.generate(),
        status: "active",
        created_at: now,
        updated_at: now
      })

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      semantic_turn_digest: semantic,
      status: "in_progress",
      started_at: now,
      created_at: now,
      updated_at: now
    })

    send(child, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^child, :normal}, 15_000
    assert ExecutionIdentity.status(attempt) == :dead
    CodexPooler.ExecutionProofSupport.publish_terminal!(attempt)

    case failure do
      :dead_execution ->
        assert {:ok, :recovered} =
                 RequestLifecycle.recover_dead_execution(request, attempt, DateTime.utc_now())

      :task_exception ->
        assert :ok =
                 Interruption.finalize_task_exception_request(
                   %{
                     session_id: session.id,
                     request_id: request.id,
                     correlation_id: request.correlation_id,
                     api_key_id: setup.api_key.id,
                     owner_binding: nil,
                     attempt_id: attempt.id,
                     replay_generation: attempt.replay_generation
                   },
                   "owner_task_exception"
                 )
    end

    predecessor = Repo.reload!(request)

    assert predecessor.last_error_code ==
             if(failure == :dead_execution,
               do: "dead_execution_recovered",
               else: "owner_task_exception"
             )

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1

    {setup, predecessor,
     %{
       full_history?: true,
       compaction_trigger_bridge?: true,
       anchor_present?: false,
       endpoint: endpoint,
       requested_model: setup.model.exposed_model_id,
       runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
       codex_session: session,
       semantic_turn_digest: semantic,
       original_request_claim: claim,
       replay_claim_digest: digest
     }}
  end

  # The cut request as the drain, the dead-execution recovery or the stream
  # cut settles it: the turn interrupted (failed for the stream cut) and
  # stamped visible when the collection started, the request and its attempt
  # failed with the same code, and the socket's delivery receipt naming the
  # terminal class the client was written.
  defp collected_cut_predecessor!(code, receipt) do
    {setup, predecessor, opts} =
      case code do
        "dead_execution_recovered" -> local_failure_predecessor!(:dead_execution)
        code -> predecessor!(code, 0)
      end

    turn = Repo.get_by!(CodexTurn, request_id: predecessor.id)
    update!(turn, status: if(code == "upstream_stream_error", do: "failed", else: "interrupted"), first_visible_output_at: turn.completed_at)
    attempt = Repo.get!(Attempt, turn.final_attempt_id)

    case receipt do
      :absent -> :ok
      terminal_class -> update!(attempt, response_metadata: Map.put(attempt.response_metadata || %{}, "downstream_delivery", %{"outcome" => "aborted", "terminal_class" => terminal_class, "highest_frame_class" => "terminal", "frames_after_visible" => 0, "transport" => "websocket"}))
    end

    {setup, Repo.reload!(predecessor), opts}
  end

  defp alter_local_failure!(:entitlement, setup, request, turn, attempt, opts) do
    insert_local_entitlement!(setup, request, turn, attempt, opts)
    opts
  end

  defp alter_local_failure!(mutation, _setup, request, turn, attempt, opts) do
    row_mutations = %{
      visible: {turn, [first_visible_output_at: DateTime.utc_now()]},
      request_endpoint: {request, [endpoint: "/backend-api/codex/responses"]},
      generation: {attempt, [replay_generation: 1]},
      request_status: {request, [status: "cancelled"]},
      attempt_status: {attempt, [status: "succeeded"]},
      request_usage: {request, [usage_status: "usage_known"]},
      attempt_usage: {attempt, [usage_status: "usage_known"]},
      response_status: {request, [response_status_code: 502]},
      attempt_identity: {turn, [final_attempt_id: nil]}
    }

    if change = row_mutations[mutation] do
      {row, attrs} = change
      update!(row, attrs)
    end

    case mutation do
      :input_endpoint -> Map.put(opts, :endpoint, "/backend-api/codex/responses")
      :epoch -> Map.update!(opts, :runtime_revocation_epoch, &(&1 + 1))
      :model -> Map.put(opts, :requested_model, "other-model")
      :anchor -> Map.put(opts, :anchor_present?, true)
      _ -> opts
    end
  end

  defp insert_local_entitlement!(setup, request, turn, attempt, opts) do
    now = DateTime.utc_now()

    %RequestReplayEntitlement{}
    |> RequestReplayEntitlement.changeset(%{
      request_id: request.id,
      codex_turn_id: turn.id,
      eligible_attempt_id: attempt.id,
      api_key_id: setup.api_key.id,
      api_key_runtime_epoch: setup.api_key.runtime_revocation_epoch,
      pool_id: setup.pool.id,
      model_id: setup.model.id,
      model_identifier: setup.model.exposed_model_id,
      semantic_turn_digest: opts.semantic_turn_digest,
      replay_claim_digest: opts.replay_claim_digest,
      replay_generation: 1,
      owner_lease_digest: <<1::256>>,
      owner_lease_key_version: "test-v1",
      predecessor_epoch: 1,
      status: "armed",
      armed_at: now,
      expires_at: DateTime.add(now, 30)
    })
    |> Repo.insert!()
  end

  defp row_counts do
    Map.new(
      [Request, CodexTurn, LedgerEntry, RequestClientRetryLink],
      &{&1, Repo.aggregate(&1, :count)}
    )
  end

  defp predecessor!(error, age) do
    setup = accounting_setup(%{price_version: Ecto.UUID.generate()})
    # Retry age is checked against PostgreSQL time; an age-zero fixture must use that clock too.
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    completed_at = DateTime.add(now, -age, :second)
    digest = :crypto.strong_rand_bytes(32)
    semantic = :crypto.strong_rand_bytes(32)
    endpoint = "/backend-api/codex/responses/compact"
    witness = ClientRetry.original_witness!(digest, setup.api_key.runtime_revocation_epoch)
    claim = compaction_claim()

    assert {:ok, %{request: request}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, %{
               endpoint: endpoint,
               correlation_id: claim,
               native_client_retry_witness: witness
             })

    request =
      update!(request, status: "failed", completed_at: completed_at, last_error_code: error)

    session =
      Repo.insert!(%CodexSession{
        pool_id: setup.pool.id,
        api_key_id: setup.api_key.id,
        session_key: Ecto.UUID.generate(),
        status: "active",
        created_at: now,
        updated_at: now
      })

    attempt =
      CodexPooler.PoolerFixtures.attempt_fixture(request, setup.assignment, %{
        status: "failed",
        completed_at: completed_at,
        network_error_code: error,
        transport: "websocket",
        replay_generation: 0
      })

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "websocket",
      semantic_turn_digest: semantic,
      status: "failed",
      error_code: error,
      final_attempt_id: attempt.id,
      completed_at: completed_at,
      started_at: completed_at,
      created_at: now,
      updated_at: now
    })

    opts = %{
      full_history?: true,
      compaction_trigger_bridge?: true,
      anchor_present?: false,
      endpoint: endpoint,
      requested_model: setup.model.exposed_model_id,
      runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
      codex_session: session,
      semantic_turn_digest: semantic,
      original_request_claim: claim,
      replay_claim_digest: digest
    }

    {setup, request, opts}
  end

  # A compaction claim in its wire form (`WebsocketTurnIdentity.remote_compaction_claim_key/3`):
  # the resend policy meets the compaction holding the claim the resend derives.
  defp compaction_claim, do: "codex-request:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # The refused compaction as the guard's refusal settles it: `stream_incomplete`
  # everywhere, a turn stamped visible when collection started, and one
  # terminal error frame pushed (findings#278).
  defp guard_refused_predecessor!(mutation) do
    {setup, predecessor, opts} = predecessor!("stream_incomplete", 0)
    turn = Repo.get_by!(CodexTurn, request_id: predecessor.id)
    update!(turn, first_visible_output_at: turn.started_at)
    attempt = Repo.get_by!(Attempt, request_id: predecessor.id)
    update!(attempt, response_metadata: guard_refusal_metadata(mutation))
    {setup, predecessor, opts}
  end

  defp guard_refusal_metadata(mutation) do
    metadata = %{
      "stream_terminal_type" => "error",
      "upstream_error_code" => "previous_response_not_found",
      "transport_failure" => TransportFailureReason.continuation_generation_guard_metadata(:fresh),
      "downstream_delivery" => %{"outcome" => "delivered", "terminal_class" => "error", "highest_frame_class" => "terminal", "frames_after_visible" => 1, "transport" => "websocket"}
    }

    case mutation do
      :guard_refusal -> metadata
      :provider_refusal -> metadata |> Map.delete("transport_failure") |> Map.merge(@provider_refusal_rejection)
      :unproven_refusal -> Map.delete(metadata, "transport_failure")
      :upstream_committed -> put_in(metadata, ["transport_failure", "upstream_committed"], true)
      :other_refusal_class -> metadata |> Map.delete("transport_failure") |> Map.merge(@provider_refusal_rejection) |> Map.delete("rejection_message_class")
    end
  end

  defp compaction_resend_shape(%Request{} = request) do
    turn = Repo.get_by!(CodexTurn, request_id: request.id)
    attempt = Repo.get!(Attempt, turn.final_attempt_id)
    ClientRetry.compaction_resend_shape(turn, Repo.get!(Request, request.id), attempt)
  end

  defp update!(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()
end
