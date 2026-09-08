defmodule CodexPooler.Accounting.CompactionRetryTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting

  alias CodexPooler.Accounting.{
    Attempt,
    ClientRetry,
    LedgerEntry,
    Request,
    RequestClientRetryLink
  }

  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport

  for terminal_status <- ["failed", "interrupted"] do
    test "selects the newest #{terminal_status} compaction when an older failure already has a successor" do
      {setup, older, opts} = predecessor!("client_disconnected", 0)

      assert {:ok, older_claim} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      completed_at = DateTime.utc_now()
      update!(older_claim.request, status: "succeeded", completed_at: completed_at)
      update!(older_claim.codex_turn, status: "succeeded", completed_at: completed_at)

      assert {:ok, %{request: newer}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, %{
                 endpoint: opts.endpoint,
                 correlation_id: Ecto.UUID.generate(),
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

      assert {:error, :successor_claimed} =
               Accounting.claim_client_retry_successor(setup.auth, setup.model, %{}, opts)

      assert {:ok, newer_claim} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

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
        "usage_not_included",
        "cyber_policy",
        "misalignment_policy_violation",
        "invalid_prompt",
        "bio_policy",
        "server_is_overloaded",
        "slow_down"
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

  for endpoint <- ["/backend-api/codex/responses", "/backend-api/codex/responses/compact"] do
    test "does not revive an older failed compact after a newer successful #{endpoint} turn" do
      {setup, predecessor, opts} = predecessor!("upstream_stream_error", 0)

      assert {:ok, %{request: newer}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, %{
                 endpoint: unquote(endpoint),
                 correlation_id: Ecto.UUID.generate()
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

      assert {:error, _reason} =
               Accounting.claim_compaction_retry_successor(setup.auth, setup.model, %{}, opts)

      assert row_counts() == counts

      refute Repo.exists?(
               from link in RequestClientRetryLink,
                 where: link.predecessor_request_id == ^predecessor.id
             )
    end
  end

  test "rejects expired, visible, mismatched and unauthorized predecessors without side effects" do
    for mutation <- [
          :expired,
          :visible,
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

          :visible ->
            update!(turn, first_visible_output_at: DateTime.utc_now())
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

  defp row_counts do
    Map.new(
      [Request, CodexTurn, LedgerEntry, RequestClientRetryLink],
      &{&1, Repo.aggregate(&1, :count)}
    )
  end

  defp predecessor!(error, age) do
    setup = accounting_setup(%{price_version: Ecto.UUID.generate()})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    completed_at = DateTime.add(now, -age, :second)
    digest = :crypto.strong_rand_bytes(32)
    semantic = :crypto.strong_rand_bytes(32)
    endpoint = "/backend-api/codex/responses/compact"
    witness = ClientRetry.original_witness!(digest, setup.api_key.runtime_revocation_epoch)

    assert {:ok, %{request: request}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, %{
               endpoint: endpoint,
               correlation_id: Ecto.UUID.generate(),
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
      replay_claim_digest: digest
    }

    {setup, request, opts}
  end

  defp update!(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()
end
