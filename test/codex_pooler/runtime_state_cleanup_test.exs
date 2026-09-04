defmodule CodexPooler.RuntimeStateCleanupTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.RuntimeCleanup

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    IdempotencyKey
  }

  alias CodexPooler.Jobs
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  alias CodexPooler.Gateway.Persistence.SessionContinuity

  test "cleanup marks expired file metadata without touching active rows" do
    now = ~U[2026-05-03 02:30:00Z]
    expired_at = DateTime.add(now, -1, :second)
    future_at = DateTime.add(now, 3600, :second)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()

    expired_file =
      file_record_fixture(pool, api_key, %{status: "uploaded", expires_at: expired_at})

    abandoned_file = file_record_fixture(pool, api_key, %{expires_at: expired_at})

    active_file =
      file_record_fixture(pool, api_key, %{expires_at: future_at})

    assert {:ok, summary} = Files.cleanup_expired(now)

    assert summary == %{abandoned_files: 1, expired_files: 1}
    assert Repo.get!(FileRecord, expired_file.id).status == "expired"
    assert Repo.get!(FileRecord, abandoned_file.id).status == "abandoned"
    assert Repo.get!(FileRecord, active_file.id).status == "pending_upload"
  end

  @tag :replay_clock
  test "cleanup expires bridge aliases owner leases and idempotency keys deterministically" do
    now = ~U[2026-05-03 02:45:00Z]
    expired_at = DateTime.add(now, -1, :second)
    future_at = DateTime.add(now, 3600, :second)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    session = session_fixture(pool, api_key, assignment, now)

    active_lease_session =
      session_fixture(pool, api_key, assignment, DateTime.add(now, 1, :second))

    expired_alias = alias_fixture(session, pool, api_key, expired_at)
    active_alias = alias_fixture(session, pool, api_key, future_at)
    expired_lease = lease_fixture(session, pool, api_key, assignment, expired_at, now)
    active_lease = lease_fixture(active_lease_session, pool, api_key, assignment, future_at, now)
    expired_key = idempotency_key_fixture(pool, api_key, expired_at)
    active_key = idempotency_key_fixture(pool, api_key, future_at)

    assert {:ok, summary} = RuntimeCleanup.cleanup_expired_runtime_state(now)

    assert summary == %{
             expired_aliases: 1,
             expired_idempotency_keys: 1,
             expired_owner_leases: 1,
             expired_owner_sessions_recovered: 0
           }

    assert Repo.get!(BridgeSessionAlias, expired_alias.id).status == "expired"
    assert Repo.get!(BridgeSessionAlias, active_alias.id).status == "active"
    assert Repo.get!(BridgeOwnerLease, expired_lease.id).status == "expired"
    assert Repo.get!(BridgeOwnerLease, active_lease.id).status == "active"
    assert Repo.get!(IdempotencyKey, expired_key.id).status == "expired"
    assert Repo.get!(IdempotencyKey, active_key.id).status == "in_progress"
  end

  @tag :replay_lock_order
  test "cleanup interrupts in-progress turns before expiring owner leases" do
    now = ~U[2026-05-03 03:15:00Z]
    expired_at = DateTime.add(now, -1, :second)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "gpt-cleanup"})
    session = session_fixture(pool, api_key, assignment, expired_at)
    expired_lease = lease_fixture(session, pool, api_key, assignment, expired_at, now)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        model_id: model.id,
        requested_model: model.exposed_model_id,
        transport: "websocket",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil,
        request_metadata: %{"codex_session_id" => session.id}
      })

    attempt =
      attempt_fixture(request, assignment, %{
        status: "in_progress",
        completed_at: nil,
        usage_status: "usage_pending",
        response_metadata: %{}
      })

    turn = turn_fixture(session, request, attempt, now)

    request
    |> ledger_entry_fixture(%{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      entry_kind: "reservation",
      amount_status: "recorded",
      usage_status: "usage_pending",
      transport: "websocket",
      output_tokens: 8,
      total_tokens: 12,
      details: %{"source" => "test_reservation"}
    })
    |> Ecto.Changeset.change(%{source_event_id: "request:#{request.id}:reservation"})
    |> Repo.update!()

    assert {:ok, summary} = RuntimeCleanup.cleanup_expired_runtime_state(now)
    assert summary.expired_owner_sessions_recovered == 1
    assert summary.expired_owner_leases == 1

    assert %Request{
             status: "failed",
             usage_status: "usage_unknown",
             response_status_code: 499,
             last_error_code: "owner_unavailable"
           } = Repo.reload!(request)

    assert %Attempt{
             status: "failed",
             usage_status: "usage_unknown",
             network_error_code: "owner_unavailable"
           } = Repo.reload!(attempt)

    assert %CodexTurn{status: "interrupted", error_code: "owner_unavailable"} =
             Repo.reload!(turn)

    assert Repo.reload!(expired_lease).status == "expired"

    assert Enum.map(ledger_entries_for_request(request.id), & &1.entry_kind) |> Enum.sort() == [
             "release",
             "reservation",
             "settlement"
           ]
  end

  @tag :replay_cleanup
  @tag :replay_lock_order
  test "expired owner cleanup does not interrupt a replacement owner after candidate selection" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expired_at = DateTime.add(now, -1, :second)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "gpt-cleanup-takeover"})
    session = session_fixture(pool, api_key, assignment, expired_at)
    old_token = session.owner_lease_token
    old_lease = lease_fixture(session, pool, api_key, assignment, expired_at, now)

    old_lease
    |> Ecto.Changeset.change(%{lease_token: old_token})
    |> Repo.update!()

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        model_id: model.id,
        requested_model: model.exposed_model_id,
        transport: "websocket",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil,
        request_metadata: %{"codex_session_id" => session.id}
      })

    attempt =
      attempt_fixture(request, assignment, %{
        status: "in_progress",
        completed_at: nil,
        usage_status: "usage_pending",
        response_metadata: %{}
      })

    turn = turn_fixture(session, request, attempt, now)

    request
    |> ledger_entry_fixture(%{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      entry_kind: "reservation",
      amount_status: "recorded",
      usage_status: "usage_pending",
      transport: "websocket",
      details: %{"source" => "test_reservation"}
    })
    |> Ecto.Changeset.change(%{source_event_id: "request:#{request.id}:reservation"})
    |> Repo.update!()

    barrier_ref = make_ref()
    parent = self()

    Application.put_env(
      :codex_pooler,
      :runtime_cleanup_owner_candidate_test_barrier,
      {parent, barrier_ref}
    )

    on_exit(fn ->
      Application.delete_env(:codex_pooler, :runtime_cleanup_owner_candidate_test_barrier)
    end)

    cleanup_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        RuntimeCleanup.cleanup_expired_runtime_state(now)
      end)

    assert_receive {:runtime_cleanup_owner_candidates_selected, cleanup_pid, ^barrier_ref,
                    [candidate]}

    assert candidate.session_id == session.id
    assert candidate.owner_instance_id == session.owner_instance_id
    assert candidate.owner_lease_token == old_token
    assert candidate.owner_lease_expires_at == session.owner_lease_expires_at

    replacement_opts =
      %{}
      |> RequestOptions.for_websocket()
      |> RequestOptions.put_continuity(
        owner_instance_id: "node-b",
        bridge_owner_lease_ttl_seconds: 120
      )

    assert {:ok, replacement} =
             SessionContinuity.replace_unavailable_owner_lease(session, replacement_opts)

    refute replacement.owner_lease_token == old_token
    released_old_lease = Repo.reload!(old_lease)
    assert released_old_lease.status == "released"

    replacement_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        model_id: model.id,
        requested_model: model.exposed_model_id,
        transport: "websocket",
        status: "in_progress",
        usage_status: "usage_pending",
        completed_at: nil,
        response_status_code: nil,
        request_metadata: %{"codex_session_id" => replacement.id}
      })

    replacement_attempt =
      attempt_fixture(replacement_request, assignment, %{
        status: "in_progress",
        completed_at: nil,
        usage_status: "usage_pending",
        response_metadata: %{}
      })

    replacement_turn =
      %CodexTurn{
        codex_session_id: replacement.id,
        request_id: replacement_request.id,
        turn_sequence: 2,
        transport_kind: replacement_request.transport,
        final_attempt_id: replacement_attempt.id,
        status: "in_progress",
        started_at: now,
        created_at: now,
        updated_at: now
      }
      |> Repo.insert!()

    replacement_request
    |> ledger_entry_fixture(%{
      attempt_id: replacement_attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      entry_kind: "reservation",
      amount_status: "recorded",
      usage_status: "usage_pending",
      transport: "websocket",
      details: %{"source" => "test_reservation"}
    })
    |> Ecto.Changeset.change(%{
      source_event_id: "request:#{replacement_request.id}:reservation"
    })
    |> Repo.update!()

    assert {:ok, :stale_owner} =
             CodexPooler.Accounting.close_request_replays_for_session(
               candidate.session_id,
               Map.take(candidate, [
                 :owner_instance_id,
                 :owner_lease_token,
                 :owner_lease_expires_at
               ]),
               :owner_shutdown
             )

    send(cleanup_pid, {:release_runtime_cleanup_owner_candidates, barrier_ref})

    assert {:ok, summary} = Task.await(cleanup_task, 15_000)
    assert summary.expired_owner_sessions_recovered == 0

    replacement_lease =
      Repo.one!(
        from lease in BridgeOwnerLease,
          where: lease.codex_session_id == ^session.id and lease.status == "active"
      )

    assert Repo.reload!(replacement).status == "active"
    assert Repo.reload!(old_lease) == released_old_lease
    assert replacement_lease.lease_token == replacement.owner_lease_token
    assert Repo.reload!(request).status == "in_progress"
    assert Repo.reload!(attempt).status == "in_progress"
    assert Repo.reload!(turn).status == "in_progress"
    assert Repo.reload!(replacement_request).status == "in_progress"
    assert Repo.reload!(replacement_attempt).status == "in_progress"
    assert Repo.reload!(replacement_turn).status == "in_progress"

    Application.delete_env(:codex_pooler, :runtime_cleanup_owner_candidate_test_barrier)

    assert {:ok, repeated} = RuntimeCleanup.cleanup_expired_runtime_state(now)
    assert repeated.expired_owner_sessions_recovered == 0
    assert Repo.reload!(replacement).status == "active"
    assert Repo.reload!(old_lease) == released_old_lease
    assert Repo.reload!(request).status == "in_progress"
    assert Repo.reload!(attempt).status == "in_progress"
    assert Repo.reload!(turn).status == "in_progress"
    assert Repo.reload!(replacement_request).status == "in_progress"
    assert Repo.reload!(replacement_attempt).status == "in_progress"
    assert Repo.reload!(replacement_turn).status == "in_progress"
  end

  test "jobs cleanup entrypoint combines file and gateway cleanup summaries" do
    now = ~U[2026-05-03 03:00:00Z]
    expired_at = DateTime.add(now, -1, :second)
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    session = session_fixture(pool, api_key, assignment, now)

    file_record_fixture(pool, api_key, %{status: "uploaded", expires_at: expired_at})
    alias_fixture(session, pool, api_key, expired_at)

    assert {:ok, summary} = Jobs.cleanup_runtime_state(now)

    assert summary.expired_files == 1
    assert summary.expired_aliases == 1
  end

  defp file_record_fixture(pool, api_key, attrs) do
    now = ~U[2026-05-03 01:00:00Z]
    expires_at = Map.get(attrs, :expires_at, DateTime.add(now, 7200, :second))

    %FileRecord{}
    |> FileRecord.changeset(%{
      pool_id: pool.id,
      api_key_id: api_key.id,
      file_id: Map.get(attrs, :file_id, "file-#{System.unique_integer([:positive])}"),
      purpose: "user_data",
      filename: "sample.txt",
      byte_size: Map.get(attrs, :byte_size, 12),
      status: Map.get(attrs, :status, "pending_upload"),
      finalize_status: Map.get(attrs, :finalize_status, "pending"),
      expires_at: expires_at,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp session_fixture(pool, api_key, assignment, now) do
    now = usec(now)

    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: "session-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: assignment.id,
      status: "active",
      owner_instance_id: "node-a",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, 45, :second),
      last_heartbeat_at: now,
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp alias_fixture(session, pool, api_key, expires_at) do
    now = usec(~U[2026-05-03 01:00:00Z])
    expires_at = usec(expires_at)

    %BridgeSessionAlias{}
    |> BridgeSessionAlias.changeset(%{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      alias_kind: "turn_state",
      alias_hash: :crypto.hash(:sha256, "alias-#{System.unique_integer([:positive])}"),
      status: "active",
      expires_at: expires_at,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp lease_fixture(session, pool, api_key, assignment, expires_at, now) do
    now = usec(now)
    expires_at = usec(expires_at)

    %BridgeOwnerLease{}
    |> BridgeOwnerLease.changeset(%{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      pool_upstream_assignment_id: assignment.id,
      owner_instance_id: "node-a",
      lease_token: session.owner_lease_token,
      status: "active",
      acquired_at: now,
      renewed_at: now,
      expires_at: expires_at,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp idempotency_key_fixture(pool, api_key, expires_at) do
    now = usec(~U[2026-05-03 01:00:00Z])
    expires_at = usec(expires_at)

    %IdempotencyKey{}
    |> IdempotencyKey.changeset(%{
      pool_id: pool.id,
      api_key_id: api_key.id,
      scope: "backend_file_create",
      key_hash: :crypto.hash(:sha256, "key-#{System.unique_integer([:positive])}"),
      status: "in_progress",
      expires_at: expires_at,
      response_metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp turn_fixture(session, request, attempt, now) do
    timestamp = now |> DateTime.add(-30, :second) |> usec()

    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: request.transport,
      final_attempt_id: attempt.id,
      status: "in_progress",
      started_at: timestamp,
      created_at: timestamp,
      updated_at: timestamp
    }
    |> Repo.insert!()
  end

  defp ledger_entries_for_request(request_id) do
    import Ecto.Query

    Repo.all(from entry in LedgerEntry, where: entry.request_id == ^request_id)
  end

  defp usec(%DateTime{} = timestamp) do
    %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}}
  end
end
