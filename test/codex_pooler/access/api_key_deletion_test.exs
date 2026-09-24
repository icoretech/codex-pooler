defmodule CodexPooler.Access.APIKeyDeletionTest do
  # Deleting an API key detaches its requests and ledger entries (SET NULL) and deletes its
  # sessions and bridge rows. A key with a large history is revoked at once and deleted by a
  # background job in batches; the audit event is written with the delete (findings#206 row
  # 206-561).
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, BridgeSessionAlias, CodexSession}
  alias CodexPooler.Jobs.APIKeyDeletionWorker
  alias CodexPooler.Repo
  alias CodexPooler.TestAppEnv

  setup do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => "key-deletion-owner@example.com"})
    scope = Scope.for_user(owner, ["instance_owner"])
    pool = pool_fixture()
    %{owner: owner, scope: scope, pool: pool}
  end

  test "a key with little history is deleted at once, its history detached, with one audit event", %{owner: owner, scope: scope, pool: pool} do
    %{api_key: api_key} = active_api_key_fixture(pool, %{scope: scope})
    history = key_history!(pool, api_key)
    %{api_key: other_key} = active_api_key_fixture(pool, %{scope: scope})
    other_history = key_history!(pool, other_key)

    assert {:ok, %APIKey{id: deleted_id}} = Access.delete_api_key(scope, api_key)
    assert deleted_id == api_key.id

    refute Repo.get(APIKey, api_key.id)
    assert history_counts(history, api_key.id) == detached_counts()
    assert history_counts(other_history, other_key.id) == attached_counts()
    assert [%AuditEvent{actor_user_id: actor_id}] = key_delete_audit_events(api_key)
    assert actor_id == owner.id
    refute_enqueued(worker: APIKeyDeletionWorker, args: %{"api_key_id" => api_key.id})
  end

  test "the immediate delete runs under its own statement timeout", %{scope: scope, pool: pool} do
    Repo.query!("CREATE TEMPORARY TABLE api_key_delete_statement_timeouts (setting text) ON COMMIT DROP")

    Repo.query!("""
    CREATE FUNCTION pg_temp.record_api_key_delete_statement_timeout() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO api_key_delete_statement_timeouts VALUES (current_setting('statement_timeout'));
      RETURN OLD;
    END $$
    """)

    Repo.query!("CREATE TRIGGER record_api_key_delete_statement_timeout BEFORE DELETE ON api_keys FOR EACH ROW EXECUTE FUNCTION pg_temp.record_api_key_delete_statement_timeout()")

    %{api_key: api_key} = active_api_key_fixture(pool, %{scope: scope})

    assert {:ok, _deleted} = Access.delete_api_key(scope, api_key)
    assert Repo.query!("SELECT setting FROM api_key_delete_statement_timeouts").rows == [["10s"]]
  end

  test "a cancelled delete writes no delete audit event, revokes the key and hands it to the deletion job", %{scope: scope, pool: pool} do
    Repo.query!("""
    CREATE FUNCTION pg_temp.cancel_api_key_delete() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'canceling statement due to user request' USING ERRCODE = 'query_canceled';
    END $$
    """)

    Repo.query!("CREATE TRIGGER cancel_api_key_delete BEFORE DELETE ON api_keys FOR EACH ROW EXECUTE FUNCTION pg_temp.cancel_api_key_delete()")

    %{api_key: api_key} = active_api_key_fixture(pool, %{scope: scope})
    history = key_history!(pool, api_key)

    assert {:deleting, %APIKey{status: "revoked"}} = Access.delete_api_key(scope, api_key)

    assert Repo.get!(APIKey, api_key.id).status == "revoked"
    assert history_counts(history, api_key.id) == attached_counts()
    assert key_delete_audit_events(api_key) == []
    assert_enqueued(worker: APIKeyDeletionWorker, args: %{"api_key_id" => api_key.id})
  end

  test "a key with a large history is revoked at once and deleted by the job in batches, and only then audited", %{owner: owner, scope: scope, pool: pool} do
    TestAppEnv.restore_on_exit(:api_key_deletion_immediate_request_limit)
    Application.put_env(:codex_pooler, :api_key_deletion_immediate_request_limit, 2)

    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture(pool, %{scope: scope})
    history = key_history!(pool, api_key)
    %{api_key: other_key} = active_api_key_fixture(pool, %{scope: scope})
    other_history = key_history!(pool, other_key)

    assert {:deleting, %APIKey{status: "revoked"}} = Access.delete_api_key(scope, api_key)
    assert {:error, _revoked} = Access.authenticate_api_key(raw_key)
    assert Access.api_key_deletion_states([api_key.id, other_key.id]) == %{api_key.id => :in_progress}
    assert {:deleting, %APIKey{}} = Access.delete_api_key(scope, api_key)
    assert [%Oban.Job{args: args}] = all_enqueued(worker: APIKeyDeletionWorker, args: %{"api_key_id" => api_key.id})
    assert args == %{"api_key_id" => api_key.id, "requested_by_user_id" => owner.id}
    assert key_delete_audit_events(api_key) == []

    assert Access.continue_api_key_deletion(api_key.id, owner.id, System.monotonic_time(:millisecond) - 1) == :more
    assert history_counts(history, api_key.id) == attached_counts()

    assert :ok = perform_job(APIKeyDeletionWorker, args)

    refute Repo.get(APIKey, api_key.id)
    assert history_counts(history, api_key.id) == detached_counts()
    assert history_counts(other_history, other_key.id) == attached_counts()
    assert [%AuditEvent{actor_user_id: actor_id}] = key_delete_audit_events(api_key)
    assert actor_id == owner.id

    assert :ok = perform_job(APIKeyDeletionWorker, args)
    assert length(key_delete_audit_events(api_key)) == 1
  end

  test "the job leaves a key that is not revoked alone and a discarded job reads as failed", %{scope: scope, pool: pool} do
    %{api_key: api_key} = active_api_key_fixture(pool, %{scope: scope})
    history = key_history!(pool, api_key)

    assert {:cancel, :api_key_not_revoked} = perform_job(APIKeyDeletionWorker, %{"api_key_id" => api_key.id})
    assert history_counts(history, api_key.id) == attached_counts()

    %{"api_key_id" => api_key.id}
    |> APIKeyDeletionWorker.new()
    |> Oban.insert!()
    |> Ecto.Changeset.change(state: "discarded")
    |> Repo.update!()

    assert Access.api_key_deletion_states([api_key.id]) == %{api_key.id => :failed}
  end

  defp key_history!(pool, api_key) do
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    request_ids =
      for _index <- 1..3 do
        request = request_fixture(%{pool: pool, api_key: api_key})
        attempt_fixture(request, assignment)
        ledger_entry_fixture(request)
        request.id
      end

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session =
      Repo.insert!(%CodexSession{
        pool_id: pool.id,
        api_key_id: api_key.id,
        session_key: "key-deletion-session-#{System.unique_integer([:positive])}",
        pool_upstream_assignment_id: assignment.id,
        status: "active",
        created_at: now,
        updated_at: now
      })

    %BridgeSessionAlias{}
    |> BridgeSessionAlias.changeset(%{
      codex_session_id: session.id,
      pool_id: pool.id,
      api_key_id: api_key.id,
      alias_kind: "turn_state",
      alias_hash: :crypto.hash(:sha256, "key-deletion-alias-#{System.unique_integer([:positive])}"),
      status: "active",
      expires_at: DateTime.add(now, 3_600, :second),
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()

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
      expires_at: DateTime.add(now, 45, :second),
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()

    %{request_ids: request_ids}
  end

  # The key's requests and ledger entries survive with or without the key; its sessions and
  # bridge rows go with it.
  defp history_counts(%{request_ids: request_ids}, api_key_id) do
    request_ids = Enum.map(request_ids, &Ecto.UUID.dump!/1)
    api_key_id = Ecto.UUID.dump!(api_key_id)

    [row] =
      Repo.query!(
        """
        SELECT (SELECT count(*) FROM requests WHERE id = ANY($1)),
               (SELECT count(*) FROM requests WHERE id = ANY($1) AND api_key_id = $2),
               (SELECT count(*) FROM ledger_entries WHERE request_id = ANY($1)),
               (SELECT count(*) FROM ledger_entries WHERE request_id = ANY($1) AND api_key_id = $2),
               (SELECT count(*) FROM codex_sessions WHERE api_key_id = $2),
               (SELECT count(*) FROM bridge_session_aliases WHERE api_key_id = $2),
               (SELECT count(*) FROM bridge_owner_leases WHERE api_key_id = $2)
        """,
        [request_ids, api_key_id]
      ).rows

    Enum.zip(~w(requests requests_on_key ledger_entries ledger_on_key codex_sessions bridge_session_aliases bridge_owner_leases)a, row)
    |> Map.new()
  end

  defp attached_counts,
    do: %{requests: 3, requests_on_key: 3, ledger_entries: 3, ledger_on_key: 3, codex_sessions: 1, bridge_session_aliases: 1, bridge_owner_leases: 1}

  defp detached_counts,
    do: %{requests: 3, requests_on_key: 0, ledger_entries: 3, ledger_on_key: 0, codex_sessions: 0, bridge_session_aliases: 0, bridge_owner_leases: 0}

  defp key_delete_audit_events(api_key) do
    Repo.all(from event in AuditEvent, where: event.action == "api_key.delete" and event.target_id == ^api_key.id)
  end
end
