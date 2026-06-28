defmodule CodexPooler.Gateway.Persistence.RuntimeCleanupTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    IdempotencyKey,
    RuntimeCleanup
  }

  test "active_runtime_request?/2 detects in-progress turns with a live owner lease" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale_started_at = DateTime.add(now, -7, :hour)
    request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress"})
    _attempt = attempt_fixture(request, assignment, %{status: "in_progress", completed_at: nil})

    active_session =
      session_fixture(pool, api_key, assignment, stale_started_at,
        owner_instance_id: "runtime-cleanup-test",
        owner_lease_token: Ecto.UUID.generate(),
        owner_lease_expires_at: DateTime.add(now, 5, :minute),
        last_heartbeat_at: now
      )

    _turn =
      turn_fixture(active_session, request, stale_started_at,
        status: CodexTurn.in_progress_status()
      )

    expired_request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress"})
    _expired_attempt = attempt_fixture(expired_request, assignment, %{status: "in_progress"})
    expired_session = session_fixture(pool, api_key, assignment, stale_started_at)

    _expired_turn =
      turn_fixture(expired_session, expired_request, stale_started_at,
        status: CodexTurn.in_progress_status()
      )

    assert RuntimeCleanup.active_runtime_request?(request, now)
    refute RuntimeCleanup.active_runtime_request?(expired_request.id, now)
  end

  test "recover_stale_request_turn/3 interrupts only matching in-progress turns" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale_started_at = DateTime.add(now, -7, :hour)
    request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "failed"})
    attempt = attempt_fixture(request, assignment, %{status: "failed"})
    session = session_fixture(pool, api_key, assignment, stale_started_at)

    turn =
      turn_fixture(session, request, stale_started_at, status: CodexTurn.in_progress_status())

    done_request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "succeeded"})

    done_turn =
      turn_fixture(session, done_request, stale_started_at, status: CodexTurn.succeeded_status())

    assert :ok =
             RuntimeCleanup.recover_stale_request_turn(request, attempt,
               now: now,
               error_code: "stale_reservation_recovered"
             )

    assert %CodexTurn{
             status: "interrupted",
             error_code: "stale_reservation_recovered",
             final_attempt_id: final_attempt_id,
             completed_at: ^now
           } = Repo.reload!(turn)

    assert final_attempt_id == attempt.id
    assert Repo.reload!(done_turn).status == CodexTurn.succeeded_status()
  end

  test "expires only cleanup-eligible runtime records past their ttl" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    past = DateTime.add(now, -1, :second)
    future = DateTime.add(now, 60, :second)
    session = session_fixture(pool, api_key, assignment, now)

    expired_alias =
      alias_fixture(pool, api_key, session,
        status: BridgeSessionAlias.active_status(),
        expires_at: past,
        token: "expired-alias"
      )

    future_alias =
      alias_fixture(pool, api_key, session,
        status: BridgeSessionAlias.active_status(),
        expires_at: future,
        token: "future-alias"
      )

    expired_lease =
      lease_fixture(pool, api_key, assignment, session,
        status: BridgeOwnerLease.active_status(),
        expires_at: past,
        now: now
      )

    in_progress_key =
      idempotency_key_fixture(pool, api_key,
        status: IdempotencyKey.in_progress_status(),
        expires_at: past,
        token: "in-progress-key"
      )

    succeeded_key =
      idempotency_key_fixture(pool, api_key,
        status: IdempotencyKey.succeeded_status(),
        expires_at: past,
        token: "succeeded-key"
      )

    failed_key =
      idempotency_key_fixture(pool, api_key,
        status: IdempotencyKey.failed_status(),
        expires_at: past,
        token: "failed-key"
      )

    assert {:ok,
            %{
              expired_aliases: 1,
              expired_owner_leases: 1,
              expired_idempotency_keys: 2
            }} = RuntimeCleanup.cleanup_expired(now)

    assert Repo.reload!(expired_alias).status == BridgeSessionAlias.expired_status()
    assert Repo.reload!(future_alias).status == BridgeSessionAlias.active_status()
    assert Repo.reload!(expired_lease).status == BridgeOwnerLease.expired_status()
    assert Repo.reload!(in_progress_key).status == IdempotencyKey.expired_status()
    assert Repo.reload!(succeeded_key).status == IdempotencyKey.expired_status()
    assert Repo.reload!(failed_key).status == IdempotencyKey.failed_status()
  end

  defp session_fixture(pool, api_key, assignment, now, attrs \\ []) do
    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: "session-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: assignment.id,
      status: "active",
      owner_instance_id: Keyword.get(attrs, :owner_instance_id),
      owner_lease_token: Keyword.get(attrs, :owner_lease_token),
      owner_lease_expires_at: Keyword.get(attrs, :owner_lease_expires_at),
      last_heartbeat_at: Keyword.get(attrs, :last_heartbeat_at),
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp turn_fixture(session, request, now, attrs) do
    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: System.unique_integer([:positive]),
      transport_kind: "http_sse",
      status: Keyword.fetch!(attrs, :status),
      started_at: now,
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp alias_fixture(pool, api_key, session, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    token = Keyword.fetch!(attrs, :token)

    %BridgeSessionAlias{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      alias_kind: "session_header",
      alias_hash: hash_token(token),
      alias_preview: String.slice(token, 0, 8),
      status: Keyword.fetch!(attrs, :status),
      expires_at: Keyword.fetch!(attrs, :expires_at),
      metadata: %{},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp lease_fixture(pool, api_key, assignment, session, attrs) do
    now = Keyword.fetch!(attrs, :now)

    %BridgeOwnerLease{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      pool_upstream_assignment_id: assignment.id,
      owner_instance_id: "runtime-cleanup-test",
      lease_token: Ecto.UUID.generate(),
      status: Keyword.fetch!(attrs, :status),
      acquired_at: now,
      renewed_at: now,
      expires_at: Keyword.fetch!(attrs, :expires_at),
      metadata: %{},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp idempotency_key_fixture(pool, api_key, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    token = Keyword.fetch!(attrs, :token)

    %IdempotencyKey{
      pool_id: pool.id,
      api_key_id: api_key.id,
      scope: "runtime-cleanup-test",
      key_hash: hash_token(token),
      status: Keyword.fetch!(attrs, :status),
      expires_at: Keyword.fetch!(attrs, :expires_at),
      response_metadata: %{},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)
end
