defmodule CodexPooler.Gateway.Persistence.RuntimeCleanupTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.OperationalSettings

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    IdempotencyKey,
    RuntimeCleanup
  }

  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Platform.InstancePresence.Identity

  test "active_runtime_request?/3 detects in-progress turns with a live owner lease" do
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
      turn_fixture(active_session, request, stale_started_at, status: CodexTurn.in_progress_status())

    expired_request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress"})
    _expired_attempt = attempt_fixture(expired_request, assignment, %{status: "in_progress"})
    expired_session = session_fixture(pool, api_key, assignment, stale_started_at)

    _expired_turn =
      turn_fixture(expired_session, expired_request, stale_started_at, status: CodexTurn.in_progress_status())

    assert RuntimeCleanup.active_runtime_request?(request, now, [])
    refute RuntimeCleanup.active_runtime_request?(expired_request.id, now, [])
  end

  test "an active owner lease row holds the request after the session owner stamp has run out" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale_started_at = DateTime.add(now, -7, :hour)

    stamp_expired = fn ->
      [
        owner_instance_id: "runtime-cleanup-test",
        owner_lease_token: Ecto.UUID.generate(),
        owner_lease_expires_at: DateTime.add(now, -1, :second),
        last_heartbeat_at: stale_started_at
      ]
    end

    leased_request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress"})
    leased_attempt = attempt_fixture(leased_request, assignment, %{status: "in_progress", completed_at: nil})
    leased_session = session_fixture(pool, api_key, assignment, stale_started_at, stamp_expired.())
    _turn = turn_fixture(leased_session, leased_request, stale_started_at, status: CodexTurn.in_progress_status())

    lease_fixture(pool, api_key, assignment, leased_session, status: BridgeOwnerLease.active_status(), expires_at: DateTime.add(now, 60, :second), now: now)

    unleased_request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress"})
    unleased_attempt = attempt_fixture(unleased_request, assignment, %{status: "in_progress", completed_at: nil})
    unleased_session = session_fixture(pool, api_key, assignment, stale_started_at, stamp_expired.())
    _turn = turn_fixture(unleased_session, unleased_request, stale_started_at, status: CodexTurn.in_progress_status())

    # Only the lease row separates the two requests: both session stamps have
    # run out, so the lease branch alone decides.
    assert RuntimeCleanup.active_runtime_request?(leased_request, leased_attempt, now, [])
    assert RuntimeCleanup.active_runtime_request?(leased_request.id, now, [])
    refute RuntimeCleanup.active_runtime_request?(unleased_request, unleased_attempt, now, [])
    refute RuntimeCleanup.active_runtime_request?(unleased_request.id, now, [])
  end

  test "a disconnected successor incarnation proves the old runtime owner is gone" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = InstancePresence.database_now()
    stale = DateTime.add(now, -10, :minute)
    node_name = "codex_pooler@10.77.#{System.unique_integer([:positive])}.9"
    first = Identity.new(node_name, Ecto.UUID.generate())
    second = Identity.new(node_name, Ecto.UUID.generate())
    request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress"})
    _attempt = attempt_fixture(request, assignment, %{status: "in_progress", completed_at: nil})

    session =
      session_fixture(pool, api_key, assignment, stale,
        owner_instance_id: first.node_name,
        owner_instance_boot_id: first.boot_id,
        owner_lease_token: Ecto.UUID.generate(),
        owner_lease_expires_at: DateTime.add(now, 5, :minute),
        last_heartbeat_at: stale
      )

    _turn = turn_fixture(session, request, stale, status: CodexTurn.in_progress_status())

    assert {:ok, _} = InstancePresence.record_heartbeat(first, stale)
    assert {:ok, _} = InstancePresence.record_heartbeat(second, now)
    assert {:ok, _} = InstancePresence.record_heartbeat()
    assert InstancePresence.status(first) == :unknown
    assert InstancePresence.superseded?(first)

    refute RuntimeCleanup.active_runtime_request?(request, now, [])
  end

  test "an attempt whose incarnation is gone is not sheltered by the live owner of its session" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = InstancePresence.database_now()
    stale = DateTime.add(now, -10, :minute)
    node_name = "codex_pooler@10.77.#{System.unique_integer([:positive])}.9"
    crashed = Identity.new(node_name, Ecto.UUID.generate())
    successor = Identity.new(node_name, Ecto.UUID.generate())
    peer = Identity.new("codex_pooler@10.77.#{System.unique_integer([:positive])}.10", Ecto.UUID.generate())

    assert {:ok, _} = InstancePresence.record_heartbeat(crashed, stale)
    assert {:ok, _} = InstancePresence.record_heartbeat(successor, now)
    assert {:ok, _} = InstancePresence.record_heartbeat(peer, now)
    assert {:ok, _} = InstancePresence.record_heartbeat()

    request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress"})
    stranded = owned_attempt(request, assignment, crashed)
    legacy = owned_attempt(request, assignment, Identity.new(node_name, "unused"), boot_id: nil)

    # The live peer took the session over and renewed its lease, which is what
    # a released client's transport fallback produces on the same session row.
    session =
      session_fixture(pool, api_key, assignment, stale,
        owner_instance_id: peer.node_name,
        owner_instance_boot_id: peer.boot_id,
        owner_lease_token: Ecto.UUID.generate(),
        owner_lease_expires_at: DateTime.add(now, 45, :second),
        last_heartbeat_at: now
      )

    _turn = turn_fixture(session, request, stale, status: CodexTurn.in_progress_status())

    refute InstancePresence.absent?(peer, now)
    assert InstancePresence.superseded?(crashed)

    # The session is held, so the session-scoped question still answers "held"
    # for this request, and an attempt that names no incarnation keeps that
    # shelter. Only the attempt whose own incarnation is provably gone loses it.
    assert RuntimeCleanup.active_runtime_request?(request, now, [])
    assert RuntimeCleanup.active_runtime_request?(request, legacy, now, [])
    refute RuntimeCleanup.active_runtime_request?(request, stranded, now, [])
  end

  test "a live attempt owner still holds its request" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = InstancePresence.database_now()
    stale = DateTime.add(now, -10, :minute)
    owner = Identity.new("codex_pooler@10.77.#{System.unique_integer([:positive])}.11", Ecto.UUID.generate())

    assert {:ok, _} = InstancePresence.record_heartbeat(owner, now)
    assert {:ok, _} = InstancePresence.record_heartbeat()

    request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress"})
    attempt = owned_attempt(request, assignment, owner)

    session =
      session_fixture(pool, api_key, assignment, stale,
        owner_instance_id: owner.node_name,
        owner_instance_boot_id: owner.boot_id,
        owner_lease_token: Ecto.UUID.generate(),
        owner_lease_expires_at: DateTime.add(now, 45, :second),
        last_heartbeat_at: now
      )

    _turn = turn_fixture(session, request, stale, status: CodexTurn.in_progress_status())

    assert RuntimeCleanup.active_runtime_request?(request, attempt, now, [])

    # And the shelter needs live work, not merely a live owner: once the lease
    # and the stamp have run out, the same live owner shelters nothing.
    session
    |> Ecto.Changeset.change(owner_lease_expires_at: DateTime.add(now, -1, :second))
    |> Repo.update!()

    refute RuntimeCleanup.active_runtime_request?(request, attempt, now, [])
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

  # A session whose window is never used again stayed `active` forever once its
  # idle owner released the lease: only a later start of the same key and
  # session key closes an expired session, and that start is what carries the
  # findings#141 assignment preference. Past the expired-alias retention, with
  # every alias expired, no lease and no turn in progress, nothing can resume
  # the session and the provider context the preference points at is long gone,
  # so cleanup closes it; anything younger keeps the preference path intact
  # (findings#225, row 225-89).
  test "closes reconnectable sessions retired past the expired-alias retention and nothing else" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    retention = OperationalSettings.current().expired_alias_ttl_seconds
    retired_at = DateTime.add(now, -(retention + 60), :second)
    recent = DateTime.add(now, -(retention - 60), :second)

    retired = retired_session_fixture(pool, api_key, assignment, retired_at)
    retired_interrupted = retired_session_fixture(pool, api_key, assignment, retired_at, status: "interrupted")
    recent_expiry = retired_session_fixture(pool, api_key, assignment, recent)

    with_alias = retired_session_fixture(pool, api_key, assignment, retired_at)
    alias_fixture(pool, api_key, with_alias, status: BridgeSessionAlias.active_status(), expires_at: DateTime.add(now, 60, :second), token: "retained-alias")

    with_lease = retired_session_fixture(pool, api_key, assignment, retired_at)
    lease_fixture(pool, api_key, assignment, with_lease, status: BridgeOwnerLease.active_status(), expires_at: DateTime.add(now, 60, :second), now: now)

    with_turn = retired_session_fixture(pool, api_key, assignment, retired_at)
    request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "in_progress"})
    turn_fixture(with_turn, request, retired_at, status: CodexTurn.in_progress_status())

    assert {:ok, summary} = RuntimeCleanup.cleanup_expired(now)

    for session <- [retired, retired_interrupted] do
      assert %CodexSession{status: "closed", closed_at: ^now} = Repo.reload!(session)
    end

    assert summary.closed_retired_sessions == 2

    for session <- [recent_expiry, with_alias, with_lease] do
      assert Repo.reload!(session).status == "active"
    end

    assert Repo.reload!(with_turn).status == "active"
  end

  defp retired_session_fixture(pool, api_key, assignment, lease_expired_at, attrs \\ []) do
    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: "retired-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: assignment.id,
      status: Keyword.get(attrs, :status, "active"),
      owner_instance_id: "runtime-cleanup-test",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: lease_expired_at,
      last_heartbeat_at: lease_expired_at,
      created_at: lease_expired_at,
      updated_at: lease_expired_at
    }
    |> Repo.insert!()
  end

  defp owned_attempt(request, assignment, %Identity{} = owner, opts \\ []) do
    attempt_fixture(request, assignment, %{
      status: "in_progress",
      completed_at: nil,
      attempt_number: System.unique_integer([:positive])
    })
    |> Ecto.Changeset.change(
      owner_instance_id: owner.node_name,
      owner_instance_boot_id: Keyword.get(opts, :boot_id, owner.boot_id)
    )
    |> Repo.update!()
  end

  defp session_fixture(pool, api_key, assignment, now, attrs \\ []) do
    %CodexSession{
      pool_id: pool.id,
      api_key_id: api_key.id,
      session_key: "session-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: assignment.id,
      status: "active",
      owner_instance_id: Keyword.get(attrs, :owner_instance_id),
      owner_instance_boot_id: Keyword.get(attrs, :owner_instance_boot_id),
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
