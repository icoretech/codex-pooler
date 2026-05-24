defmodule CodexPooler.RuntimeStateCleanupTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    IdempotencyKey
  }

  alias CodexPooler.Jobs
  alias CodexPooler.Repo

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

    assert {:ok, summary} = Gateway.cleanup_expired_runtime_state(now)

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

    assert {:ok, summary} = Gateway.cleanup_expired_runtime_state(now)
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
      lease_token: Ecto.UUID.generate(),
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
