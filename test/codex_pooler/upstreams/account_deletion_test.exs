defmodule CodexPooler.Upstreams.AccountDeletionTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, DailyRollup, HourlyModelUsageRollup, LedgerEntry, Request, RequestLogFact, RequestReplayEntitlement}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Jobs.UpstreamDeletionWorker
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, Windows}
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}

  import CodexPooler.AccountingTestSupport
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(Upstreams)
    CodexPooler.TestAppEnv.restore_on_exit(:upstream_deletion_immediate_row_limit)

    Application.put_env(:codex_pooler, Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "account-deletion-test-key")),
      upstream_secret_key_version: "test-v1"
    )

    Application.put_env(:codex_pooler, :upstream_deletion_immediate_row_limit, 2_000)
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{owner: owner, scope: Scope.for_user(owner)}
  end

  test "a usage response allocated before deletion cannot reactivate the account", %{scope: scope} do
    alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
    Application.put_env(:codex_pooler, :upstream_deletion_immediate_row_limit, 0)
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(pool_fixture())
    {:ok, _identity, fence} = CredentialFencing.allocate_usage_probe(identity)
    remove_from_pool(assignment)
    assert {:deleting, _receipt} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert {:ok, :superseded, current, nil} = CredentialFencing.apply_usage_success(identity, fence, fn _ -> flunk("obsolete poll must not persist evidence") end)
    assert current.status == "deleted"
    assert current.metadata["permanent_deletion_requested_at"]
    assert :ok = perform_job(UpstreamDeletionWorker, %{upstream_identity_id: identity.id, requested_by_user_id: scope.user.id})
    refute Repo.get(UpstreamIdentity, identity.id)
  end

  test "a stale definitive rejection cannot revive a permanently deleting account", %{scope: scope} do
    alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
    Application.put_env(:codex_pooler, :upstream_deletion_immediate_row_limit, 0)
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(pool_fixture())
    {:ok, _identity, fence} = CredentialFencing.allocate_usage_probe(identity)
    remove_from_pool(assignment)

    assert {:deleting, _receipt} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert {:ok, :superseded, current} = CredentialFencing.mark_definitive_rejection(identity, fence)
    assert current.status == "deleted"
    assert current.metadata["permanent_deletion_requested_at"]
    assert Repo.get!(UpstreamIdentity, identity.id).status == "deleted"
    assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "deleted"
  end

  test "failed deletion enqueue returns a bounded error and rolls back the marker", %{scope: scope} do
    identity = active_upstream_identity_fixture()
    Repo.query!("CREATE FUNCTION pg_temp.reject_upstream_deletion() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.worker = 'CodexPooler.Jobs.UpstreamDeletionWorker' THEN RAISE EXCEPTION 'sample insert failure' USING ERRCODE = 'object_not_in_prerequisite_state'; END IF; RETURN NEW; END $$")
    Repo.query!("CREATE TRIGGER reject_upstream_deletion BEFORE INSERT ON oban_jobs FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_upstream_deletion()")
    assert {:error, %{code: :upstream_deletion_unavailable}} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert Repo.get!(UpstreamIdentity, identity.id).status == identity.status
    refute Repo.get!(UpstreamIdentity, identity.id).metadata["permanent_deletion_requested_at"]
    assert deletion_jobs(identity.id) == []
  end

  test "deletion worker cancels an unmarked target and rejects missing target args" do
    identity = active_upstream_identity_fixture()
    assert {:cancel, :upstream_account_not_deleting} = perform_job(UpstreamDeletionWorker, %{upstream_identity_id: identity.id})
    assert {:cancel, :upstream_deletion_target_invalid} = perform_job(UpstreamDeletionWorker, %{})
    assert Repo.get!(UpstreamIdentity, identity.id) == identity
  end

  test "database cancellations remain scheduled beyond the retry ceiling and complete after recovery", %{scope: scope} do
    Application.put_env(:codex_pooler, :upstream_deletion_immediate_row_limit, 0)
    identity = active_upstream_identity_fixture()
    assert {:deleting, _} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert [job] = deletion_jobs(identity.id)
    queue = "upstream_deletion_#{System.unique_integer([:positive])}"
    job |> change(queue: queue) |> Repo.update!()
    Repo.query!("CREATE FUNCTION pg_temp.cancel_upstream_detach() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'sample cancellation' USING ERRCODE = 'query_canceled'; END $$")
    Repo.query!("CREATE TRIGGER cancel_upstream_detach BEFORE UPDATE ON ledger_entries FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.cancel_upstream_detach()")

    for snoozes <- 1..(job.max_attempts + 1) do
      {result, log} = ExUnit.CaptureLog.with_log(fn -> Oban.drain_queue(queue: queue, with_scheduled: true) end)
      assert %{failure: 0, snoozed: 1, success: 0} = result
      assert log =~ "upstream deletion deferred job_id=#{job.id} reason=upstream_deletion_busy retry_in_seconds=30"
      pending = Repo.get!(Oban.Job, job.id)
      assert pending.state == "scheduled"
      assert pending.attempt == 0
      assert pending.max_attempts == job.max_attempts
      assert pending.meta["snoozed"] == snoozes
      assert pending.errors == []
      assert Upstreams.account_deletion_states([identity.id]) == %{identity.id => :in_progress}
      assert Repo.get!(UpstreamIdentity, identity.id).metadata["permanent_deletion_requested_at"]
      assert Repo.get!(UpstreamIdentity, identity.id).status == "deleted"
    end

    Repo.query!("DROP TRIGGER cancel_upstream_detach ON ledger_entries")
    assert %{failure: 0, snoozed: 0, success: 1} = Oban.drain_queue(queue: queue, with_scheduled: true)
    assert Repo.get!(Oban.Job, job.id).state == "completed"
    refute Repo.get(UpstreamIdentity, identity.id)
  end

  test "unexpected database faults still consume a retry and remain visible", %{scope: scope} do
    Application.put_env(:codex_pooler, :upstream_deletion_immediate_row_limit, 0)
    identity = active_upstream_identity_fixture()
    assert {:deleting, _} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert [job] = deletion_jobs(identity.id)
    queue = "upstream_deletion_#{System.unique_integer([:positive])}"
    job |> change(queue: queue) |> Repo.update!()
    Repo.query!("CREATE FUNCTION pg_temp.reject_upstream_detach() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'sample database fault' USING ERRCODE = 'object_not_in_prerequisite_state'; END $$")
    Repo.query!("CREATE TRIGGER reject_upstream_detach BEFORE UPDATE ON ledger_entries FOR EACH STATEMENT EXECUTE FUNCTION pg_temp.reject_upstream_detach()")

    {result, log} = ExUnit.CaptureLog.with_log(fn -> Oban.drain_queue(queue: queue) end)
    assert %{failure: 1, snoozed: 0, success: 0} = result
    assert log =~ "oban job failed"
    pending = Repo.get!(Oban.Job, job.id)
    assert pending.state == "retryable"
    assert pending.attempt == 1
    assert length(pending.errors) == 1
    assert Repo.get!(UpstreamIdentity, identity.id).metadata["permanent_deletion_requested_at"]
  end

  for status <- ["active", "deleted"] do
    @status status
    test "permanently removes an #{@status} account and its encrypted credentials", %{scope: scope} do
      %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture()

      assert {:ok, [quota]} = Windows.upsert_quota_windows(identity, [%{window_kind: "primary", window_minutes: 300, used_percent: Decimal.new("12"), source: "codex_usage_api", freshness_state: "fresh"}])

      if @status == "deleted" do
        identity |> change(status: "deleted") |> Repo.update!()
        assignment |> change(status: "deleted", eligibility_status: "ineligible") |> Repo.update!()
      else
        remove_from_pool(assignment)
      end

      assert Repo.exists?(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id)
      assert {:ok, %{status: :deleted, secret_status: :missing}} = Upstreams.delete_account_for_scope(scope, identity.id)
      assert_account_absent(identity.id, assignment.id)
      refute Repo.get(AccountQuotaWindow, quota.id)
      assert :gone = Upstreams.continue_account_deletion(identity.id, scope.user.id, deadline())
    end
  end

  test "retains request, attempt, ledger, session, turn and non-account rollup amounts", %{scope: scope} do
    fixture = accounting_setup()

    assert {:ok, reserved} =
             Accounting.reserve(fixture.auth, fixture.model, %{"model" => fixture.model.exposed_model_id, "max_output_tokens" => 5}, %{correlation_id: "delete-account-#{System.unique_integer([:positive])}"})

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, fixture.assignment)
    assert {:ok, settled} = Accounting.finalize_success(reserved.request, attempt, %{status: "usage_known", input_tokens: 7, output_tokens: 3, total_tokens: 10}, %{response_status_code: 200})
    {session, turn} = session_and_turn(fixture, settled.request, attempt)
    entitlement = retained_entitlement(fixture, settled.request, attempt, turn)
    entries = Repo.all(from entry in LedgerEntry, where: entry.request_id == ^settled.request.id, order_by: entry.id)
    amounts = Enum.map(entries, &Map.take(&1, [:id, :request_id, :attempt_id, :entry_kind, :total_tokens, :estimated_cost_micros, :settled_cost_micros]))
    rollups = non_account_rollups(fixture.pool.id)
    hourly = Repo.all(from row in HourlyModelUsageRollup, where: row.pool_id == ^fixture.pool.id)
    assert length(rollups) == 3
    assert hourly != []
    assert Repo.exists?(from row in DailyRollup, where: row.upstream_identity_id == ^fixture.identity.id)
    remove_from_pool(fixture.assignment)

    assert {:ok, %{status: :deleted}} = Upstreams.delete_account_for_scope(scope, fixture.identity.id)
    assert_account_absent(fixture.identity.id, fixture.assignment.id)
    retained_attempt = Repo.get!(Attempt, attempt.id)
    assert retained_attempt.request_id == settled.request.id
    assert retained_attempt.pool_upstream_assignment_id == nil
    assert retained_attempt.upstream_identity_id == nil
    assert Repo.get!(Request, settled.request.id).status == "succeeded"
    assert Repo.get!(CodexSession, session.id).pool_upstream_assignment_id == nil
    assert Repo.get!(CodexTurn, turn.id).final_attempt_id == attempt.id
    assert Repo.get!(RequestReplayEntitlement, entitlement.id) == entitlement
    assert Repo.get_by!(RequestLogFact, request_id: settled.request.id).latest_attempt_id == attempt.id

    retained_entries = Repo.all(from entry in LedgerEntry, where: entry.request_id == ^settled.request.id, order_by: entry.id)
    assert Enum.map(retained_entries, &Map.take(&1, [:id, :request_id, :attempt_id, :entry_kind, :total_tokens, :estimated_cost_micros, :settled_cost_micros])) == amounts
    assert Enum.all?(retained_entries, &is_nil(&1.upstream_identity_id))
    assert Enum.all?(retained_entries, &is_nil(&1.pool_upstream_assignment_id))
    assert non_account_rollups(fixture.pool.id) == rollups
    assert Repo.all(from row in HourlyModelUsageRollup, where: row.pool_id == ^fixture.pool.id) == hourly
    refute Repo.exists?(from row in DailyRollup, where: row.upstream_identity_id == ^fixture.identity.id or row.pool_upstream_assignment_id == ^fixture.assignment.id)
  end

  test "an admin must operate every retained Pool, including deleted assignments", %{owner: owner} do
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    first_pool = pool_fixture()
    second_pool = pool_fixture()
    %{identity: identity, assignment: first_assignment} = active_upstream_assignment_fixture(first_pool)
    {:ok, second_assignment} = PoolAssignments.create_pool_assignment(second_pool, identity)
    second_assignment |> change(status: "deleted", eligibility_status: "ineligible") |> Repo.update!()
    first_assignment = remove_from_pool(first_assignment)
    identity = identity |> change(status: "deleted") |> Repo.update!()
    operator_pool_assignment_fixture(admin, first_pool)
    scope = Scope.for_user(admin)
    secrets = Repo.all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id)

    assert {:error, %{code: :capability_denied}} = Upstreams.authorize_account_deletion(scope, identity.id)
    assert {:error, %{code: :capability_denied}} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert Repo.get!(UpstreamIdentity, identity.id) == identity
    assert Repo.get!(PoolUpstreamAssignment, first_assignment.id) == first_assignment
    assert Repo.all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id) == secrets
    assert deletion_jobs(identity.id) == []

    operator_pool_assignment_fixture(admin, second_pool)
    assert {:ok, %{status: :deleted}} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert_account_absent(identity.id, first_assignment.id)
    refute Repo.get(PoolUpstreamAssignment, second_assignment.id)
  end

  test "only the instance owner can delete an orphan account", %{owner: owner, scope: owner_scope} do
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    identity = active_upstream_identity_fixture()
    assert {:error, %{code: :capability_denied}} = Upstreams.delete_account_for_scope(Scope.for_user(admin), identity.id)
    assert Repo.get!(UpstreamIdentity, identity.id) == identity
    assert {:ok, %{status: :deleted}} = Upstreams.delete_account_for_scope(owner_scope, identity.id)
    refute Repo.get(UpstreamIdentity, identity.id)
  end

  test "batched permissions match full-identity authorization and reject missing ids", %{owner: owner, scope: owner_scope} do
    %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
    pool = pool_fixture()
    operator_pool_assignment_fixture(admin, pool)
    %{identity: allowed} = upstream_assignment_fixture(pool, %{identity_status: "deleted", assignment_status: "deleted"})
    %{identity: shared} = upstream_assignment_fixture(pool)
    {:ok, _} = PoolAssignments.create_pool_assignment(pool_fixture(), shared)
    orphan = active_upstream_identity_fixture()
    missing = Ecto.UUID.generate()
    ids = [allowed.id, shared.id, orphan.id, missing]

    assert Upstreams.account_deletion_permissions(Scope.for_user(admin), ids) == %{allowed.id => true, shared.id => false, orphan.id => false, missing => false}
    assert Upstreams.account_deletion_permissions(owner_scope, ids) == %{allowed.id => true, shared.id => false, orphan.id => true, missing => false}
  end

  test "confirmation checks the freshly stored label before any deletion write", %{scope: scope} do
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture()
    assignment = remove_from_pool(assignment)
    updated = identity |> change(account_label: "Renamed account") |> Repo.update!()
    secrets = Repo.all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id)
    assert {:error, %{code: :confirmation_mismatch}} = Upstreams.delete_account_for_scope(scope, identity.id, %{confirmation_label: identity.account_label})
    assert Repo.get!(UpstreamIdentity, identity.id) == updated
    assert Repo.get!(PoolUpstreamAssignment, assignment.id) == assignment
    assert Repo.all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id) == secrets
    assert deletion_jobs(identity.id) == []
    assert {:ok, %{status: :deleted}} = Upstreams.delete_account_for_scope(scope, identity.id, %{confirmation_label: "Renamed account"})
  end

  for {request_status, attempt_status} <- [{"accepted", "succeeded"}, {"in_progress", "succeeded"}, {"succeeded", "queued"}, {"succeeded", "in_progress"}] do
    @request_status request_status
    @attempt_status attempt_status
    test "waits for request #{@request_status} / attempt #{@attempt_status} before removing attribution", %{scope: scope} do
      %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture()
      pool = CodexPooler.Pools.get_pool(assignment.pool_id)
      key = api_key_fixture(pool)
      request = request_fixture(key, %{status: @request_status})
      attempt = attempt_fixture(request, assignment, %{status: @attempt_status})
      remove_from_pool(assignment)

      assert {:deleting, _} = Upstreams.delete_account_for_scope(scope, identity.id)
      pending = Repo.get!(UpstreamIdentity, identity.id)
      assert pending.status == "deleted"
      assert is_binary(pending.metadata["permanent_deletion_requested_at"])
      assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "deleted"
      assert Repo.get!(PoolUpstreamAssignment, assignment.id).eligibility_status == "ineligible"
      refute Repo.exists?(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id and secret.status == "active")
      assert Upstreams.account_deletion_states([identity.id]) == %{identity.id => :in_progress}
      assert :more = Upstreams.continue_account_deletion(identity.id, scope.user.id, deadline())
      assert {:snooze, 1} = perform_job(UpstreamDeletionWorker, %{upstream_identity_id: identity.id})
      assert Repo.get!(Attempt, attempt.id).pool_upstream_assignment_id == assignment.id
      request |> change(status: "succeeded") |> Repo.update!()
      attempt |> change(status: "succeeded") |> Repo.update!()

      assert :deleted = Upstreams.continue_account_deletion(identity.id, scope.user.id, deadline())
      assert_account_absent(identity.id, assignment.id)
      assert Repo.get!(Attempt, attempt.id).pool_upstream_assignment_id == nil
    end
  end

  test "repeated requests share a job and its worker resumes deferred deletion", %{scope: scope} do
    Application.put_env(:codex_pooler, :upstream_deletion_immediate_row_limit, 0)
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture()
    remove_from_pool(assignment)
    assert {:deleting, _} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert {:deleting, _} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert [job] = deletion_jobs(identity.id)
    assert Repo.get!(UpstreamIdentity, identity.id).status == "deleted"
    assert :ok = perform_job(UpstreamDeletionWorker, job.args)
    assert_account_absent(identity.id, assignment.id)
    assert :ok = perform_job(UpstreamDeletionWorker, job.args)
  end

  test "an admitted request settles through real accounting before its upstream is removed", %{scope: scope} do
    fixture = accounting_setup()
    assert {:ok, reserved} = Accounting.reserve(fixture.auth, fixture.model, %{"model" => fixture.model.exposed_model_id, "max_output_tokens" => 5}, %{correlation_id: "delete-drain-#{System.unique_integer([:positive])}"})
    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, fixture.assignment)
    remove_from_pool(fixture.assignment)

    assert {:deleting, _} = Upstreams.delete_account_for_scope(scope, fixture.identity.id)
    assert :more = Upstreams.continue_account_deletion(fixture.identity.id, scope.user.id, deadline())
    assert {:ok, settled} = Accounting.finalize_success(reserved.request, attempt, %{status: "usage_known", input_tokens: 7, output_tokens: 3, total_tokens: 10}, %{response_status_code: 200})
    assert :deleted = Upstreams.continue_account_deletion(fixture.identity.id, scope.user.id, deadline())
    assert_account_absent(fixture.identity.id, fixture.assignment.id)
    assert Repo.get!(Request, settled.request.id).status == "succeeded"
    assert [%LedgerEntry{total_tokens: 10} = settlement] = Repo.all(from entry in LedgerEntry, where: entry.request_id == ^settled.request.id and entry.entry_kind == "settlement")
    assert Decimal.positive?(settlement.settled_cost_micros)
    assert settlement.upstream_identity_id == nil
    assert settlement.pool_upstream_assignment_id == nil
  end

  test "an expired cleanup deadline retains the graph for the next worker pass", %{scope: scope} do
    Application.put_env(:codex_pooler, :upstream_deletion_immediate_row_limit, 0)
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture()
    remove_from_pool(assignment)
    assert {:deleting, _} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert :more = Upstreams.continue_account_deletion(identity.id, scope.user.id, System.monotonic_time(:millisecond) - 1)
    assert Repo.get(UpstreamIdentity, identity.id)
    assert :deleted = Upstreams.continue_account_deletion(identity.id, scope.user.id, deadline())
    assert_account_absent(identity.id, assignment.id)
  end

  test "discarded and cancelled jobs expose failed deletion state for retry", %{scope: scope} do
    Application.put_env(:codex_pooler, :upstream_deletion_immediate_row_limit, 0)

    for state <- ["discarded", "cancelled"] do
      %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture()
      remove_from_pool(assignment)
      assert {:deleting, _} = Upstreams.delete_account_for_scope(scope, identity.id)
      assert [job] = deletion_jobs(identity.id)
      job |> change(state: state) |> Repo.update!()
      assert Upstreams.account_deletion_states([identity.id]) == %{identity.id => :failed}
      assert {:deleting, _} = Upstreams.delete_account_for_scope(scope, identity.id)
      assert Upstreams.account_deletion_states([identity.id]) == %{identity.id => :in_progress}
    end
  end

  test "assigned accounts cannot be deleted even by the instance owner", %{scope: scope} do
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture()
    secrets = Repo.all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id)
    assert {:error, %{code: :upstream_account_assigned}} = Upstreams.delete_account_for_scope(scope, identity.id)
    assert Repo.get!(UpstreamIdentity, identity.id) == identity
    assert Repo.get!(PoolUpstreamAssignment, assignment.id) == assignment
    assert Repo.all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id) == secrets
    assert deletion_jobs(identity.id) == []
  end

  defp remove_from_pool(assignment) do
    assert {:ok, %{assignment: deleted}} = PoolAssignments.delete_pool_assignment(assignment.pool_id, assignment.id)
    deleted
  end

  defp assert_account_absent(identity_id, assignment_id) do
    refute Repo.get(UpstreamIdentity, identity_id)
    refute Repo.get(PoolUpstreamAssignment, assignment_id)
    refute Repo.exists?(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity_id)
  end

  defp deletion_jobs(identity_id) do
    Repo.all(from job in Oban.Job, where: job.worker == "CodexPooler.Jobs.UpstreamDeletionWorker" and fragment("?->>'upstream_identity_id'", job.args) == ^identity_id)
  end

  defp non_account_rollups(pool_id) do
    Repo.all(from row in DailyRollup, where: row.pool_id == ^pool_id and row.dimension_kind in ["pool", "api_key", "model"], order_by: row.id)
  end

  defp session_and_turn(fixture, request, attempt) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session =
      Repo.insert!(%CodexSession{pool_id: fixture.pool.id, api_key_id: fixture.api_key.id, session_key: "delete-session-#{System.unique_integer([:positive])}", pool_upstream_assignment_id: fixture.assignment.id, status: "closed", created_at: now, updated_at: now, closed_at: now})

    turn =
      Repo.insert!(%CodexTurn{codex_session_id: session.id, request_id: request.id, turn_sequence: 1, transport_kind: "http_sse", status: "succeeded", semantic_turn_digest: <<1::256>>, final_attempt_id: attempt.id, started_at: now, completed_at: now, created_at: now, updated_at: now})

    {session, turn}
  end

  defp retained_entitlement(fixture, request, attempt, turn) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RequestReplayEntitlement{}
    |> RequestReplayEntitlement.changeset(%{
      request_id: request.id,
      codex_turn_id: turn.id,
      eligible_attempt_id: attempt.id,
      api_key_id: fixture.api_key.id,
      api_key_runtime_epoch: fixture.api_key.runtime_revocation_epoch,
      pool_id: fixture.pool.id,
      model_id: fixture.model.id,
      model_identifier: fixture.model.exposed_model_id,
      semantic_turn_digest: turn.semantic_turn_digest,
      replay_claim_digest: <<2::256>>,
      owner_lease_digest: <<3::256>>,
      owner_lease_key_version: "test-v1",
      predecessor_epoch: 1,
      status: "revoked",
      armed_at: now,
      expires_at: DateTime.add(now, 30, :second),
      terminal_at: now,
      closed_at: DateTime.add(now, 1, :microsecond)
    })
    |> Repo.insert!()
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 30_000
end
