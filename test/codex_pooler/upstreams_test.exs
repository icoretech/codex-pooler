defmodule CodexPooler.UpstreamsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Secrets, as: Secrets

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.MCP.Tools.QuotaMetadata
  alias CodexPooler.Pools
  alias CodexPooler.Quotas
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Auth.{CodexAuth, CodexAuthJson, TokenRefresh}
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.TokenLinking

  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Charts.Measurements
  alias CodexPooler.Upstreams.Quota.ReadModel, as: QuotaReadModel
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe

  alias CodexPooler.Upstreams.Schemas.{
    EncryptedSecret,
    PoolUpstreamAssignment,
    UpstreamIdentity
  }

  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      monthly_only_account_primary_quota_payload: 1,
      monthly_only_account_primary_quota_window_attrs: 1
    ]

  describe "upstream identity lifecycle" do
    test "creates, activates, updates, and reuses upstream account identities" do
      assert {:ok, identity} =
               IdentityLifecycle.create_upstream_identity(%{
                 chatgpt_account_id: "acct_123",
                 account_label: " Primary account ",
                 onboarding_method: "import"
               })

      assert identity.account_label == "Primary account"
      assert identity.status == "pending"

      assert {:ok, active_identity} =
               IdentityLifecycle.activate_upstream_identity_with_plan(
                 identity,
                 %{
                   plan_family: "team-plan",
                   plan_label: "Team"
                 }
               )

      assert active_identity.status == "active"
      assert active_identity.plan_family == "team-plan"
      assert %DateTime{} = active_identity.auth_verified_at

      assert {:ok, updated_identity} =
               IdentityLifecycle.upsert_upstream_identity(%{
                 chatgpt_account_id: "acct_123",
                 account_label: "Renamed account",
                 onboarding_method: "import",
                 status: "active"
               })

      assert updated_identity.id == identity.id
      assert updated_identity.account_label == "Renamed account"
      assert Repo.get!(UpstreamIdentity, identity.id).plan_label == "Team"
    end

    test "allows one legacy null workspace slot per ChatGPT account" do
      account_id = "acct_legacy_slot_#{System.unique_integer([:positive])}"

      assert {:ok, _identity} =
               IdentityLifecycle.create_upstream_identity(%{
                 chatgpt_account_id: account_id,
                 account_label: "Legacy slot",
                 onboarding_method: "import"
               })

      assert {:error, changeset} =
               IdentityLifecycle.create_upstream_identity(%{
                 chatgpt_account_id: account_id,
                 account_label: "Duplicate legacy slot",
                 onboarding_method: "import"
               })

      assert %{chatgpt_account_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows legacy and concrete workspace slots for the same ChatGPT account" do
      %{legacy: legacy, alpha: alpha, beta: beta} = workspace_slot_identities_fixture()

      assert legacy.chatgpt_account_id == "acct_123"
      assert legacy.workspace_id == nil
      assert alpha.chatgpt_account_id == "acct_123"
      assert alpha.workspace_id == "ws_alpha"
      assert beta.chatgpt_account_id == "acct_123"
      assert beta.workspace_id == "ws_beta"
      assert alpha.id != beta.id
      assert legacy.id != alpha.id
      assert legacy.id != beta.id
    end

    test "normalizes blank workspace ids to the legacy null slot" do
      account_id = "acct_blank_workspace_#{System.unique_integer([:positive])}"

      assert {:ok, identity} =
               IdentityLifecycle.create_upstream_identity(%{
                 chatgpt_account_id: account_id,
                 workspace_id: "   ",
                 workspace_label: " Workspace label ",
                 seat_type: " team ",
                 account_label: "Blank workspace",
                 onboarding_method: "import"
               })

      assert identity.workspace_id == nil
      assert identity.workspace_label == "Workspace label"
      assert identity.seat_type == "team"

      assert {:error, changeset} =
               IdentityLifecycle.create_upstream_identity(%{
                 chatgpt_account_id: account_id,
                 workspace_id: nil,
                 account_label: "Duplicate blank workspace",
                 onboarding_method: "import"
               })

      assert %{chatgpt_account_id: ["has already been taken"]} = errors_on(changeset)
    end

    @tag :subject_identity_schema
    test "stores identities without a subject as nullable legacy rows" do
      account_id = "acct_subjectless_#{System.unique_integer([:positive])}"

      assert {:ok, identity} =
               IdentityLifecycle.create_upstream_identity(subject_identity_attrs(account_id))

      assert identity.chatgpt_user_id == nil
      assert Repo.get!(UpstreamIdentity, identity.id).chatgpt_user_id == nil
    end

    @tag :subject_identity_schema
    test "normalizes blank subject ids to nil before persistence" do
      account_id = "acct_blank_subject_#{System.unique_integer([:positive])}"

      assert {:ok, identity} =
               IdentityLifecycle.create_upstream_identity(
                 subject_identity_attrs(account_id, %{chatgpt_user_id: "   "})
               )

      assert identity.chatgpt_user_id == nil
      assert Repo.get!(UpstreamIdentity, identity.id).chatgpt_user_id == nil
    end

    @tag :subject_identity_schema
    test "rejects duplicate subjectless legacy rows for the same account" do
      account_id = "acct_duplicate_subjectless_#{System.unique_integer([:positive])}"

      assert {:ok, _identity} =
               IdentityLifecycle.create_upstream_identity(subject_identity_attrs(account_id))

      assert {:error, changeset} =
               IdentityLifecycle.create_upstream_identity(
                 subject_identity_attrs(account_id, %{
                   account_label: "Duplicate legacy subjectless"
                 })
               )

      assert %{chatgpt_account_id: ["has already been taken"]} = errors_on(changeset)
    end

    @tag :subject_identity_schema
    test "rejects duplicate subject-bearing legacy rows for the same account and subject" do
      account_id = "acct_duplicate_user_legacy_#{System.unique_integer([:positive])}"

      assert {:ok, _identity} =
               IdentityLifecycle.create_upstream_identity(
                 subject_identity_attrs(account_id, %{chatgpt_user_id: "user_123"})
               )

      assert {:error, changeset} =
               IdentityLifecycle.create_upstream_identity(
                 subject_identity_attrs(account_id, %{
                   account_label: "Duplicate subject legacy",
                   chatgpt_user_id: "user_123"
                 })
               )

      assert %{chatgpt_user_id: ["has already been taken"]} = errors_on(changeset)
    end

    @tag :subject_identity_schema
    test "rejects duplicate subject-bearing workspace rows for the same account workspace and subject" do
      account_id = "acct_duplicate_user_workspace_#{System.unique_integer([:positive])}"

      assert {:ok, _identity} =
               IdentityLifecycle.create_upstream_identity(
                 subject_identity_attrs(account_id, %{
                   chatgpt_user_id: "user_123",
                   workspace_id: "workspace_alpha"
                 })
               )

      assert {:error, changeset} =
               IdentityLifecycle.create_upstream_identity(
                 subject_identity_attrs(account_id, %{
                   account_label: "Duplicate subject workspace",
                   chatgpt_user_id: "user_123",
                   workspace_id: "workspace_alpha"
                 })
               )

      assert %{chatgpt_user_id: ["has already been taken"]} = errors_on(changeset)
    end

    @tag :subject_identity_schema
    test "allows different subjects in the same account legacy slot" do
      account_id = "acct_distinct_user_legacy_#{System.unique_integer([:positive])}"

      assert {:ok, first_identity} =
               IdentityLifecycle.create_upstream_identity(
                 subject_identity_attrs(account_id, %{chatgpt_user_id: "user_123"})
               )

      assert {:ok, second_identity} =
               IdentityLifecycle.create_upstream_identity(
                 subject_identity_attrs(account_id, %{
                   account_label: "Second subject legacy",
                   chatgpt_user_id: "user_456"
                 })
               )

      assert first_identity.id != second_identity.id
      assert first_identity.chatgpt_user_id == "user_123"
      assert second_identity.chatgpt_user_id == "user_456"
    end

    @tag :subject_identity_schema
    test "allows different subjects in the same account workspace slot" do
      account_id = "acct_distinct_user_workspace_#{System.unique_integer([:positive])}"

      assert {:ok, first_identity} =
               IdentityLifecycle.create_upstream_identity(
                 subject_identity_attrs(account_id, %{
                   chatgpt_user_id: "user_123",
                   workspace_id: "workspace_alpha"
                 })
               )

      assert {:ok, second_identity} =
               IdentityLifecycle.create_upstream_identity(
                 subject_identity_attrs(account_id, %{
                   account_label: "Second subject workspace",
                   chatgpt_user_id: "user_456",
                   workspace_id: "workspace_alpha"
                 })
               )

      assert first_identity.id != second_identity.id
      assert first_identity.chatgpt_user_id == "user_123"
      assert second_identity.chatgpt_user_id == "user_456"
      assert first_identity.workspace_id == second_identity.workspace_id
    end

    test "generic operator updates cannot set reported plan metadata" do
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_operator_plan_denied"})

      assert {:ok, updated_identity} =
               IdentityLifecycle.update_upstream_identity(identity, %{
                 account_label: "Operator renamed account",
                 plan_label: "Operator Chosen Plan",
                 plan_family: "operator"
               })

      assert updated_identity.account_label == "Operator renamed account"

      reloaded = Repo.get!(UpstreamIdentity, identity.id)
      assert reloaded.plan_label == nil
      assert reloaded.plan_family == nil
    end
  end

  describe "pool assignment lifecycle" do
    test "counts visible pool assignments by pool id and excludes deleted rows" do
      pool = pool_fixture()
      other_pool = pool_fixture()

      upstream_assignment_fixture(pool, %{assignment_status: "active"})
      upstream_assignment_fixture(pool, %{assignment_status: "paused"})
      upstream_assignment_fixture(pool, %{assignment_status: "deleted"})
      upstream_assignment_fixture(pool, %{identity_status: "deleted"})
      upstream_assignment_fixture(other_pool, %{assignment_status: "deleted"})

      pool_id = pool.id
      other_pool_id = other_pool.id
      missing_pool_id = Ecto.UUID.generate()

      assert %{
               ^pool_id => 2,
               ^other_pool_id => 0,
               ^missing_pool_id => 0
             } =
               Upstreams.count_pool_assignments_by_pool_ids([
                 pool_id,
                 other_pool_id,
                 missing_pool_id
               ])
    end

    test "lists only upstream identities assigned through visible active pools" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      scope = Scope.for_user(owner, ["instance_owner"])
      visible_pool = pool_fixture(%{status: "active"})
      disabled_pool = pool_fixture(%{status: "disabled"})

      %{identity: visible_identity} =
        upstream_assignment_fixture(visible_pool, %{account_label: "Visible upstream"})

      %{identity: disabled_pool_identity} =
        upstream_assignment_fixture(disabled_pool, %{account_label: "Disabled pool upstream"})

      %{identity: deleted_identity} =
        upstream_assignment_fixture(visible_pool, %{
          account_label: "Deleted identity upstream",
          identity_status: "deleted"
        })

      %{identity: deleted_assignment_identity} =
        upstream_assignment_fixture(visible_pool, %{
          account_label: "Deleted assignment upstream",
          assignment_status: "deleted"
        })

      visible_identity_ids =
        scope
        |> Upstreams.list_visible_upstream_identities()
        |> Enum.map(& &1.id)

      assert visible_identity.id in visible_identity_ids
      refute disabled_pool_identity.id in visible_identity_ids
      refute deleted_identity.id in visible_identity_ids
      refute deleted_assignment_identity.id in visible_identity_ids
    end

    test "enforces one assignment per pool identity and returns active eligible routing data" do
      pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_assignable"})

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{
                 assignment_label: "Primary"
               })

      assert assignment.status == "pending"
      assert assignment.health_status == "unknown"
      assert assignment.eligibility_status == "eligible"

      assert {:error, changeset} =
               PoolAssignments.create_pool_assignment(pool, identity)

      assert %{upstream_identity_id: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, active_assignment} =
               PoolAssignments.activate_pool_assignment(assignment)

      assert [selected] = Upstreams.list_eligible_pool_assignments(pool)
      assert selected.id == active_assignment.id

      cooldown_until = DateTime.add(DateTime.utc_now(), 300, :second)

      assert {:ok, _cooldown_assignment} =
               Upstreams.put_assignment_cooldown(active_assignment, cooldown_until)

      assert Upstreams.list_eligible_pool_assignments(pool) == []
    end

    test "admin assignment creates an active row and restores existing rows" do
      pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_admin_assign"})

      assert Upstreams.list_pool_assignments_for_identity(identity) == []

      assert {:ok, active_assignment} =
               PoolAssignments.assign_pool_assignment(pool, identity)

      assert active_assignment.status == "active"
      assert active_assignment.health_status == "active"
      assert active_assignment.eligibility_status == "eligible"

      assert {:ok, same_assignment} =
               PoolAssignments.assign_pool_assignment(pool, identity)

      assert same_assignment.id == active_assignment.id

      assert {:ok, %{status: :assignment_deleted}} =
               PoolAssignments.delete_pool_assignment(pool, active_assignment)

      assert {:ok, restored_assignment} =
               PoolAssignments.assign_pool_assignment(pool, identity)

      assert restored_assignment.id == active_assignment.id
      assert restored_assignment.status == "active"
      assert restored_assignment.health_status == "active"
      assert restored_assignment.eligibility_status == "eligible"
      assert is_nil(restored_assignment.disabled_at)

      pending_identity =
        active_identity_fixture(%{chatgpt_account_id: "acct_admin_assign_pending"})

      assert {:ok, pending_assignment} =
               PoolAssignments.create_pool_assignment(pool, pending_identity)

      assert {:ok, promoted_assignment} =
               PoolAssignments.assign_pool_assignment(pool, pending_identity)

      assert promoted_assignment.id == pending_assignment.id
      assert promoted_assignment.status == "active"

      deleted_identity =
        active_identity_fixture(%{chatgpt_account_id: "acct_admin_assign_deleted"})

      assert {:ok, deleted_identity} =
               IdentityLifecycle.update_upstream_identity(deleted_identity, %{status: "deleted"})

      assert {:error, %{code: :upstream_identity_not_assignable}} =
               PoolAssignments.assign_pool_assignment(pool, deleted_identity)
    end

    test "assignment list APIs return empty results for invalid pool refs" do
      assert Upstreams.list_active_pool_assignments(nil) == []
      assert Upstreams.list_active_pool_assignments(:invalid_pool) == []

      assert Upstreams.list_eligible_pool_assignments(nil) == []
      assert Upstreams.list_eligible_pool_assignments(:invalid_pool) == []
    end

    test "deleting the only pool assignment preserves the upstream identity and private data for future attachment" do
      pool = pool_fixture()
      other_pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_delete_single"})
      configure_upstream_secret_key!()
      token = generated_secret("single")

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: token
               })

      assert {:ok, [quota_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("12"),
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      assert {:ok,
              %{
                status: :assignment_deleted,
                assignment: deleted_assignment,
                identity: kept_identity,
                identity_deleted?: false,
                remaining_assignment_count: 0
              }} = PoolAssignments.delete_pool_assignment(pool, assignment)

      assert deleted_assignment.id == assignment.id
      assert kept_identity.id == identity.id
      assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "deleted"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "active"
      assert Repo.get!(EncryptedSecret, secret.id).upstream_identity_id == identity.id

      assert Repo.get!(Quota.AccountQuotaWindow, quota_window.id).upstream_identity_id ==
               identity.id

      assert {:ok, reattached_assignment} =
               PoolAssignments.create_pool_assignment(other_pool, identity, %{})

      assert reattached_assignment.upstream_identity_id == identity.id
    end

    test "deleting one of multiple pool assignments keeps the shared upstream identity" do
      first_pool = pool_fixture()
      second_pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_delete_shared"})
      configure_upstream_secret_key!()
      token = generated_secret("shared")

      assert {:ok, first_assignment} =
               PoolAssignments.create_pool_assignment(
                 first_pool,
                 identity,
                 %{}
               )

      assert {:ok, second_assignment} =
               PoolAssignments.create_pool_assignment(
                 second_pool,
                 identity,
                 %{}
               )

      assert {:ok, secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: token
               })

      assert {:ok,
              %{
                status: :assignment_deleted,
                assignment: deleted_assignment,
                identity: kept_identity,
                identity_deleted?: false,
                remaining_assignment_count: 1
              }} =
               PoolAssignments.delete_pool_assignment(
                 first_pool,
                 first_assignment
               )

      assert deleted_assignment.id == first_assignment.id
      assert kept_identity.id == identity.id
      assert Repo.get!(PoolUpstreamAssignment, first_assignment.id).status == "deleted"
      assert Repo.get!(PoolUpstreamAssignment, second_assignment.id).pool_id == second_pool.id
      assert Repo.get!(UpstreamIdentity, identity.id).id == identity.id
      assert Repo.get!(EncryptedSecret, secret.id).upstream_identity_id == identity.id
    end

    test "deleting a missing or already-deleted pool assignment is a safe no-op" do
      pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_delete_missing"})

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, %{status: :assignment_deleted, identity_deleted?: false}} =
               PoolAssignments.delete_pool_assignment(pool, assignment)

      assert {:ok,
              %{
                status: :already_deleted,
                assignment: nil,
                identity: nil,
                identity_deleted?: false,
                remaining_assignment_count: 0
              }} = PoolAssignments.delete_pool_assignment(pool, assignment)

      assert {:ok, %{status: :already_deleted}} =
               PoolAssignments.delete_pool_assignment(
                 pool,
                 Ecto.UUID.generate()
               )

      assert {:error, %{code: :pool_not_found}} =
               PoolAssignments.delete_pool_assignment(nil, assignment)

      assert {:error, %{code: :pool_upstream_assignment_not_found}} =
               PoolAssignments.delete_pool_assignment(pool, nil)
    end

    test "identity-based pool edit sync adds and removes target-pool rows without touching other pools" do
      pool = pool_fixture()
      other_pool = pool_fixture(%{slug: "assignment-sync-other", name: "Assignment Sync Other"})
      first_identity = active_identity_fixture(%{chatgpt_account_id: "acct_sync_first"})
      second_identity = active_identity_fixture(%{chatgpt_account_id: "acct_sync_second"})

      assert {:ok, preserved_assignment} =
               PoolAssignments.create_pool_assignment(other_pool, first_identity, %{})

      assert {:ok, _preserved_assignment} =
               PoolAssignments.activate_pool_assignment(preserved_assignment)

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [first_identity.id, second_identity.id],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      assignments_by_identity =
        pool
        |> Upstreams.list_pool_assignments()
        |> Map.new(&{&1.upstream_identity_id, &1})

      first_assignment = Map.fetch!(assignments_by_identity, first_identity.id)
      second_assignment = Map.fetch!(assignments_by_identity, second_identity.id)

      assert Enum.all?([first_assignment, second_assignment], &(&1.status == "active"))
      assert Repo.get!(PoolUpstreamAssignment, preserved_assignment.id).status == "active"

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [second_identity.id],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      assert Repo.get!(PoolUpstreamAssignment, first_assignment.id).status == "deleted"
      assert Repo.get!(PoolUpstreamAssignment, second_assignment.id).status == "active"
      assert Repo.get!(PoolUpstreamAssignment, preserved_assignment.id).status == "active"
      assert Repo.get!(UpstreamIdentity, first_identity.id).status == "active"
    end

    test "identity-based pool edit sync reactivates a deleted target-pool row instead of inserting a duplicate" do
      pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_sync_reactivate"})

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [identity.id],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      [assignment] = Upstreams.list_pool_assignments(pool)

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "deleted"

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [identity.id],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      [reactivated_assignment] = Upstreams.list_pool_assignments(pool)

      assert reactivated_assignment.id == assignment.id
      assert reactivated_assignment.status == "active"
    end

    test "identity-based pool edit sync detaches the last target-pool assignment without deleting the identity" do
      pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_sync_last_detach"})
      configure_upstream_secret_key!()

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: generated_secret("last-detach")
               })

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [identity.id],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      [assignment] = Upstreams.list_pool_assignments(pool)

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "deleted"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "active"
      assert {:ok, _token} = Secrets.decrypt_active_secret(identity, "access_token")
    end

    test "moving an identity between pools is an explicit attach-then-remove sequence" do
      source_pool =
        pool_fixture(%{slug: "assignment-move-source", name: "Assignment Move Source"})

      target_pool =
        pool_fixture(%{slug: "assignment-move-target", name: "Assignment Move Target"})

      identity = active_identity_fixture(%{chatgpt_account_id: "acct_sync_move"})

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 source_pool,
                 [identity.id],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      [source_assignment] = Upstreams.list_pool_assignments(source_pool)

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 target_pool,
                 [identity.id],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      [target_assignment] = Upstreams.list_pool_assignments(target_pool)

      assert target_assignment.upstream_identity_id == identity.id
      assert target_assignment.id != source_assignment.id
      assert Repo.get!(PoolUpstreamAssignment, source_assignment.id).status == "active"

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 source_pool,
                 [],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      assert Repo.get!(PoolUpstreamAssignment, source_assignment.id).status == "deleted"
      assert Repo.get!(PoolUpstreamAssignment, target_assignment.id).status == "active"
      assert Repo.get!(UpstreamIdentity, identity.id).status == "active"
    end

    test "assignment-id sync still validates pool-local selections" do
      pool = pool_fixture()

      other_pool =
        pool_fixture(%{slug: "assignment-sync-other-ids", name: "Assignment Sync Other Ids"})

      first_identity =
        active_identity_fixture(%{chatgpt_account_id: "acct_sync_assignment_first"})

      second_identity =
        active_identity_fixture(%{chatgpt_account_id: "acct_sync_assignment_second"})

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [first_identity.id, second_identity.id],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               )

      assignments_by_identity =
        pool
        |> Upstreams.list_pool_assignments()
        |> Map.new(&{&1.upstream_identity_id, &1})

      first_assignment = Map.fetch!(assignments_by_identity, first_identity.id)
      second_assignment = Map.fetch!(assignments_by_identity, second_identity.id)

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [second_assignment.id],
                 select_by: :assignment_id,
                 skip_quota_priming: true
               )

      assert Repo.get!(PoolUpstreamAssignment, first_assignment.id).status == "deleted"
      assert Repo.get!(PoolUpstreamAssignment, second_assignment.id).status == "active"

      assert :ok =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [first_assignment.id, second_assignment.id],
                 select_by: :assignment_id,
                 skip_quota_priming: true
               )

      assert Repo.get!(PoolUpstreamAssignment, first_assignment.id).status == "active"

      %{assignment: foreign_assignment} = upstream_assignment_fixture(other_pool)

      assert {:error, %{code: :invalid_assignment_selection}} =
               Upstreams.sync_pool_assignments_for_pool_edit(
                 pool,
                 [foreign_assignment.id],
                 select_by: :assignment_id
               )
    end
  end

  describe "Codex auth.json import" do
    test "requires pool operate capability before writing upstream rows" do
      owner_scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(owner_scope, %{slug: "import-denied", name: "Import Denied"})

      denied_user =
        %User{}
        |> User.operator_create_changeset(%{
          "email" => unique_user_email(),
          "display_name" => "Denied Operator",
          "password" => valid_user_password()
        })
        |> Repo.insert!()

      denied_scope = Scope.for_user(denied_user, [])

      assert {:error, %{code: :capability_denied}} =
               Upstreams.import_codex_auth_json(
                 denied_scope,
                 pool,
                 auth_json_fixture(
                   account_id: "acct_denied_import",
                   id_token:
                     jwt_token(%{
                       "email" => "auth-denied@example.com",
                       "https://api.openai.com/auth" => %{
                         "chatgpt_account_id" => "acct_denied_import",
                         "chatgpt_user_id" => "user_denied_import"
                       }
                     })
                 )
               )

      assert Upstreams.get_upstream_identity_by_chatgpt_account("acct_denied_import") == nil
    end

    test "imports Codex auth.json and stores access and refresh tokens encrypted" do
      scope = fixture_owner_scope()
      {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-json", name: "auth.json"})
      access_token = jwt_token(%{"exp" => future_unix()})
      refresh_token = runtime_secret("auth-json-refresh")
      auth_json = auth_json_fixture(access_token: access_token, refresh_token: refresh_token)

      assert {:ok,
              %{
                status: :created,
                identity: identity,
                assignment: assignment,
                secret_status: :present
              } = result} = Upstreams.import_codex_auth_json(scope, pool, auth_json)

      assert identity.chatgpt_account_id == "acct_fixture_auth_json"
      assert identity.account_email == "fixture-user@example.com"
      assert identity.account_label == "fixture-user@example.com"
      assert identity.onboarding_method == "import"
      assert identity.plan_label == "pro"
      assert identity.auth_verified_at
      assert identity.auth_fresh_at
      assert identity.metadata["account_email"] == "fixture-user@example.com"
      assert identity.metadata["auth_json_imported"] == true
      assert identity.metadata["access_token_expires_at"]
      assert assignment.pool_id == pool.id
      assert assignment.assignment_label == identity.account_label
      assert assignment.status == "active"
      assert assignment.health_status == "active"
      assert assignment.eligibility_status == "eligible"
      assert assignment.metadata["onboarding_method"] == "import"

      assert {:ok, ^access_token} =
               Secrets.decrypt_active_secret(identity, "access_token")

      assert {:ok, ^refresh_token} =
               Secrets.decrypt_active_secret(identity, "refresh_token")

      assert active_secret_count("access_token") == 1
      assert active_secret_count("refresh_token") == 1
      refute inspect(identity.metadata) =~ access_token
      refute inspect(identity.metadata) =~ refresh_token
      refute inspect(identity.metadata) =~ auth_json
      refute inspect(result) =~ access_token
      refute inspect(result) =~ refresh_token
      refute inspect(result) =~ auth_json

      assert [event] = audit_events("upstream_account.import", identity.id)
      assert event.actor_user_id == scope.user.id
      assert event.pool_id == pool.id
      assert event.target_type == "upstream_identity"
      assert event.details["upstream_identity_id"] == identity.id
      assert event.details["pool_assignment_ids"] == [assignment.id]
      assert event.details["result_status"] == "created"
      assert event.details["credential_status"] == "present"
      refute inspect(event) =~ access_token
      refute inspect(event) =~ refresh_token
      refute inspect(event) =~ auth_json
    end

    @tag :subject_plumbing
    test "imports auth.json subject claims onto upstream identities outside metadata" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "auth-json-subject", name: "auth.json Subject"})

      id_token =
        jwt_token(%{
          "email" => "subject-import@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => "acct_subject_import",
            "chatgpt_user_id" => "user_subject_import",
            "chatgpt_plan_type" => "pro"
          }
        })

      auth_json = auth_json_fixture(account_id: "acct_subject_import", id_token: id_token)

      assert {:ok, attrs} = CodexAuthJson.parse(auth_json)
      assert Map.get(attrs, :chatgpt_user_id) == "user_subject_import"
      refute Map.has_key?(attrs.import_metadata, "chatgpt_user_id")

      assert {:ok, %{identity: identity}} =
               Upstreams.import_codex_auth_json(scope, pool, auth_json)

      assert identity.chatgpt_account_id == "acct_subject_import"
      assert identity.chatgpt_user_id == "user_subject_import"
      refute Map.has_key?(identity.metadata, "chatgpt_user_id")
      assert Repo.get!(UpstreamIdentity, identity.id).chatgpt_user_id == "user_subject_import"
    end

    @tag :subject_identity_upsert
    test "auth.json imports create distinct identities for different subjects in the same workspace slot" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "subject-slot-distinct", name: "Subject Slot Distinct"})

      account_id = "acct_subject_slot_#{System.unique_integer([:positive])}"
      workspace_id = "ws_subject_slot"
      first_access = jwt_token(%{"exp" => future_unix(), "nonce" => "subject-first"})
      second_access = jwt_token(%{"exp" => future_unix(), "nonce" => "subject-second"})

      first_id_token =
        jwt_token(%{
          "email" => "subject-slot@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "chatgpt_user_id" => "user_subject_slot_first",
            "workspace_id" => workspace_id,
            "workspace_label" => "Subject Slot",
            "entitlement_type" => "team-seat"
          }
        })

      second_id_token =
        jwt_token(%{
          "email" => "subject-slot@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "chatgpt_user_id" => "user_subject_slot_second",
            "workspace_id" => workspace_id,
            "workspace_label" => "Subject Slot",
            "entitlement_type" => "team-seat"
          }
        })

      assert {:ok, %{status: :created, identity: first_identity, assignment: first_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: first_access,
                   id_token: first_id_token
                 )
               )

      assert {:ok, %{status: :created, identity: second_identity, assignment: second_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: second_access,
                   id_token: second_id_token
                 )
               )

      assert first_identity.id != second_identity.id
      assert first_assignment.id != second_assignment.id
      assert first_assignment.upstream_identity_id == first_identity.id
      assert second_assignment.upstream_identity_id == second_identity.id
      assert first_identity.chatgpt_user_id == "user_subject_slot_first"
      assert second_identity.chatgpt_user_id == "user_subject_slot_second"
      assert Repo.aggregate(UpstreamIdentity, :count) == 2
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 2
      assert active_secret_count("access_token", first_identity) == 1
      assert active_secret_count("access_token", second_identity) == 1

      assert {:ok, ^first_access} = Secrets.decrypt_active_secret(first_identity, "access_token")

      assert {:ok, ^second_access} =
               Secrets.decrypt_active_secret(second_identity, "access_token")
    end

    @tag :subject_identity_upsert
    test "auth.json reimport updates the same subject identity and preserves sibling secrets" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "subject-slot-reimport", name: "Subject Slot Reimport"})

      account_id = "acct_subject_reimport_#{System.unique_integer([:positive])}"
      workspace_id = "ws_subject_reimport"
      first_access = jwt_token(%{"exp" => future_unix(), "nonce" => "subject-reimport-first"})
      second_access = jwt_token(%{"exp" => future_unix(), "nonce" => "subject-reimport-second"})
      sibling_access = jwt_token(%{"exp" => future_unix(), "nonce" => "subject-reimport-sibling"})

      first_id_token =
        jwt_token(%{
          "email" => "subject-reimport@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "chatgpt_user_id" => "user_subject_reimport",
            "workspace_id" => workspace_id
          }
        })

      sibling_id_token =
        jwt_token(%{
          "email" => "subject-reimport@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "chatgpt_user_id" => "user_subject_sibling",
            "workspace_id" => workspace_id
          }
        })

      assert {:ok, %{status: :created, identity: first_identity, assignment: first_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: first_access,
                   id_token: first_id_token
                 )
               )

      assert {:ok, %{status: :created, identity: sibling_identity}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: sibling_access,
                   id_token: sibling_id_token
                 )
               )

      assert {:ok, %{status: :existing, identity: reimported, assignment: reimported_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: second_access,
                   id_token: first_id_token
                 )
               )

      assert reimported.id == first_identity.id
      assert reimported_assignment.id == first_assignment.id
      assert Repo.aggregate(UpstreamIdentity, :count) == 2
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 2
      assert active_secret_count("access_token", reimported) == 1
      assert active_secret_count("access_token", sibling_identity) == 1

      assert {:ok, ^second_access} = Secrets.decrypt_active_secret(reimported, "access_token")

      assert {:ok, ^sibling_access} =
               Secrets.decrypt_active_secret(sibling_identity, "access_token")
    end

    @tag :subject_identity_upsert
    test "auth.json subject import claims one unambiguous legacy subjectless workspace row" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "subject-legacy-claim", name: "Subject Legacy Claim"})

      account_id = "acct_subject_claim_#{System.unique_integer([:positive])}"
      workspace_id = "ws_subject_claim"
      legacy_access = jwt_token(%{"exp" => future_unix(), "nonce" => "subject-legacy"})
      subject_access = jwt_token(%{"exp" => future_unix(), "nonce" => "subject-claim"})

      legacy_id_token =
        jwt_token(%{
          "email" => "subject-claim@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "workspace_id" => workspace_id,
            "workspace_label" => "Subject Claim"
          }
        })

      subject_id_token =
        jwt_token(%{
          "email" => "subject-claim@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "chatgpt_user_id" => "user_subject_claim",
            "workspace_id" => workspace_id,
            "workspace_label" => "Subject Claim"
          }
        })

      assert {:ok, %{status: :created, identity: legacy_identity, assignment: legacy_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: legacy_access,
                   id_token: legacy_id_token
                 )
               )

      assert legacy_identity.chatgpt_user_id == nil

      assert {:ok, %{status: :existing, identity: claimed, assignment: claimed_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: subject_access,
                   id_token: subject_id_token
                 )
               )

      assert claimed.id == legacy_identity.id
      assert claimed_assignment.id == legacy_assignment.id
      assert claimed.chatgpt_user_id == "user_subject_claim"
      assert claimed.workspace_id == workspace_id
      assert Repo.aggregate(UpstreamIdentity, :count) == 1
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1
      assert active_secret_count("access_token", claimed) == 1
      assert {:ok, ^subject_access} = Secrets.decrypt_active_secret(claimed, "access_token")
    end

    @tag :subject_identity_upsert
    test "subjectless auth.json import conflicts with subject-bound workspace siblings" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "subjectless-conflict", name: "Subjectless Conflict"})

      account_id = "acct_subjectless_conflict_#{System.unique_integer([:positive])}"
      workspace_id = "ws_subjectless_conflict"
      subject_access = jwt_token(%{"exp" => future_unix(), "nonce" => "subject-bound"})
      subjectless_access = jwt_token(%{"exp" => future_unix(), "nonce" => "subjectless"})

      subject_id_token =
        jwt_token(%{
          "email" => "subjectless-conflict@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "chatgpt_user_id" => "user_subject_bound",
            "workspace_id" => workspace_id,
            "workspace_label" => "Subjectless Conflict"
          }
        })

      subjectless_id_token =
        jwt_token(%{
          "email" => "subjectless-conflict@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "workspace_id" => workspace_id,
            "workspace_label" => "Subjectless Conflict"
          }
        })

      assert {:ok, %{identity: subject_identity, assignment: assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: subject_access,
                   id_token: subject_id_token
                 )
               )

      assert {:error,
              {:identity_conflict, :workspace_identity_mismatch,
               %{
                 path: "upstream_identity.reconciliation",
                 incoming_workspace_ref: incoming_workspace_ref
               } = conflict}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: subjectless_access,
                   id_token: subjectless_id_token
                 )
               )

      assert String.starts_with?(incoming_workspace_ref, "ws:")
      assert Repo.aggregate(UpstreamIdentity, :count) == 1
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1
      assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "active"

      assert Repo.get!(UpstreamIdentity, subject_identity.id).chatgpt_user_id ==
               "user_subject_bound"

      assert active_secret_count("access_token", subject_identity) == 1

      assert {:ok, ^subject_access} =
               Secrets.decrypt_active_secret(subject_identity, "access_token")

      conflict_text = inspect(conflict)
      refute conflict_text =~ account_id
      refute conflict_text =~ workspace_id
      refute conflict_text =~ "user_subject_bound"
      refute conflict_text =~ subjectless_access
    end

    test "shared token linking boundary preserves import semantics for normalized attrs" do
      Repo.delete_all(Oban.Job)

      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{
          slug: "token-linking-import",
          name: "Token Linking Import"
        })

      access_token = runtime_secret("token-linking-access")
      refresh_token = runtime_secret("token-linking-refresh")

      attrs = %{
        chatgpt_account_id: "acct_token_linking_import",
        account_identifier: "acct_token_linking_import",
        account_email: "token-linking@example.com",
        account_label: "token-linking@example.com",
        workspace_id: "ws_token_linking",
        workspace_label: "Token Linking Workspace",
        seat_type: "team-seat",
        plan_label: "team",
        token: access_token,
        refresh_token: refresh_token,
        access_token_expires_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond),
        import_metadata: %{
          "account_email" => "token-linking@example.com",
          "auth_json_imported" => true
        }
      }

      assert {:ok,
              %{
                status: :created,
                identity: identity,
                assignment: assignment,
                secret_status: :present
              } = result} =
               TokenLinking.link_tokens(scope, pool, attrs,
                 onboarding_method: "import",
                 audit_action: "upstream_account.import",
                 broadcast_reason: "upstream_account_imported",
                 quota_trigger_kind: "account_link",
                 token_refresh_trigger_kind: "auth_json_import"
               )

      assert identity.chatgpt_account_id == "acct_token_linking_import"
      assert identity.account_email == "token-linking@example.com"
      assert identity.workspace_id == "ws_token_linking"
      assert identity.workspace_label == "Token Linking Workspace"
      assert identity.seat_type == "team-seat"
      assert identity.onboarding_method == "import"
      assert identity.plan_label == "team"
      assert identity.metadata["auth_json_imported"] == true
      assert identity.metadata["credential_epoch"] == 1
      assert identity.metadata["usage_probe_sequence"] == 0
      assert identity.metadata["usage_probe_applied_sequence"] == 0
      assert identity.metadata["token_refresh"]["status"] == "imported"
      assert identity.metadata["token_refresh"]["trigger_kind"] == "auth_json_import"

      assert assignment.pool_id == pool.id
      assert assignment.upstream_identity_id == identity.id
      assert assignment.status == "active"
      assert assignment.health_status == "active"
      assert assignment.eligibility_status == "eligible"
      assert assignment.metadata["onboarding_method"] == "import"

      assert {:ok, ^access_token} = Secrets.decrypt_active_secret(identity, "access_token")
      assert {:ok, ^refresh_token} = Secrets.decrypt_active_secret(identity, "refresh_token")
      assert active_secret_count("access_token") == 1
      assert active_secret_count("refresh_token") == 1

      assert [event] = audit_events("upstream_account.import", identity.id)
      assert event.actor_user_id == scope.user.id
      assert event.pool_id == pool.id
      assert event.details["pool_assignment_ids"] == [assignment.id]
      assert event.details["result_status"] == "created"
      assert event.details["credential_status"] == "present"

      assert [job] = all_enqueued(worker: AccountReconciliationWorker)
      assert job.args["pool_id"] == pool.id
      assert job.args["pool_upstream_assignment_id"] == assignment.id
      assert job.args["trigger_kind"] == "account_link"

      refute inspect(result) =~ access_token
      refute inspect(result) =~ refresh_token
      refute inspect(result) =~ "id_token"
    end

    test "reimporting an existing account preserves the operator label" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "auth-json-reimport", name: "auth.json Reimport"})

      access_token = jwt_token(%{"exp" => future_unix()})
      account_id = "acct_reimport_label_#{System.unique_integer([:positive])}"
      account_email = "reimport-label-#{System.unique_integer([:positive])}@example.com"

      id_token =
        jwt_token(%{
          "email" => account_email,
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "chatgpt_user_id" => "user_reimport_label",
            "chatgpt_plan_type" => "pro"
          }
        })

      auth_json =
        auth_json_fixture(account_id: account_id, access_token: access_token, id_token: id_token)

      assert {:ok, %{status: :created, identity: identity, assignment: assignment}} =
               Upstreams.import_codex_auth_json(scope, pool, auth_json)

      assert identity.account_label == account_email
      initial_epoch = identity.metadata["credential_epoch"]

      assert {:ok, renamed_identity} =
               IdentityLifecycle.update_upstream_identity(identity, %{account_label: "codex01"})

      assert renamed_identity.account_label == "codex01"

      assert {:ok,
              %{
                status: :existing,
                identity: reimported_identity,
                assignment: reimported_assignment
              }} =
               Upstreams.import_codex_auth_json(scope, pool, auth_json)

      assert reimported_identity.id == identity.id
      assert reimported_identity.metadata["credential_epoch"] == initial_epoch + 1
      assert reimported_identity.account_label == "codex01"
      assert reimported_identity.account_email == account_email
      assert reimported_identity.metadata["account_email"] == account_email
      assert reimported_assignment.id == assignment.id
      assert reimported_assignment.assignment_label == "codex01"

      assert Repo.get!(UpstreamIdentity, identity.id).account_label == "codex01"
    end

    test "auth parsers prefer nested workspace claims over conflicting top-level claims" do
      id_token =
        jwt_token(%{
          "email" => "workspace-nested@example.com",
          "workspace_id" => "ws_top",
          "workspace_label" => "Top Workspace",
          "seat_type" => "top-seat",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => "acct_workspace_nested",
            "organization_id" => "ws_nested",
            "organization_name" => "Nested Workspace",
            "entitlement_type" => "nested-seat"
          }
        })

      assert {:ok,
              %{
                workspace_id: "ws_nested",
                workspace_label: "Nested Workspace",
                seat_type: "nested-seat"
              }} = CodexAuth.token_info(id_token)

      assert {:ok, attrs} =
               CodexAuthJson.parse(
                 auth_json_fixture(account_id: "acct_workspace_nested", id_token: id_token)
               )

      assert attrs.workspace_id == "ws_nested"
      assert attrs.workspace_label == "Nested Workspace"
      assert attrs.seat_type == "nested-seat"
    end

    test "auth.json parser falls back to accepted top-level workspace claim aliases" do
      cases = [
        {"workspace_id", "workspace_label", "seat_type"},
        {"chatgpt_workspace_id", "workspace_name", "chatgpt_seat_type"},
        {"organization_id", "organization_name", "entitlement_type"},
        {"org_id", "org_name", "seat_type"},
        {"tenant_id", "tenant_name", "seat_type"}
      ]

      for {id_key, label_key, seat_key} <- cases do
        unique = System.unique_integer([:positive])

        id_token =
          jwt_token(%{
            "email" => "workspace-alias-#{unique}@example.com",
            "https://api.openai.com/auth" => %{
              "chatgpt_account_id" => "acct_workspace_alias_#{unique}"
            },
            id_key => "ws_alias_#{unique}",
            label_key => "Alias Workspace #{unique}",
            seat_key => "alias-seat-#{unique}"
          })

        assert {:ok, attrs} =
                 CodexAuthJson.parse(
                   auth_json_fixture(
                     account_id: "acct_workspace_alias_#{unique}",
                     id_token: id_token
                   )
                 )

        assert attrs.workspace_id == "ws_alias_#{unique}"
        assert attrs.workspace_label == "Alias Workspace #{unique}"
        assert attrs.seat_type == "alias-seat-#{unique}"
      end
    end

    test "auth.json import stores workspace claim metadata on upstream identities" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "auth-json-workspace", name: "auth.json Workspace"})

      id_token =
        jwt_token(%{
          "email" => "workspace-import@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => "acct_workspace_import",
            "workspace_id" => "ws_import",
            "workspace_label" => "Imported Workspace",
            "seat_type" => "team-seat",
            "chatgpt_plan_type" => "team"
          }
        })

      assert {:ok, %{identity: identity}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(account_id: "acct_workspace_import", id_token: id_token)
               )

      assert identity.chatgpt_account_id == "acct_workspace_import"
      assert identity.workspace_id == "ws_import"
      assert identity.workspace_label == "Imported Workspace"
      assert identity.seat_type == "team-seat"
      assert identity.plan_label == "team"
    end

    test "auth.json import normalizes blank workspace claims and does not key on label alone" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "auth-json-workspace-label", name: "auth.json Label"})

      id_token =
        jwt_token(%{
          "email" => "workspace-label@example.com",
          "workspace_id" => "   ",
          "workspace_label" => " Display Only Workspace ",
          "seat_type" => "   ",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => "acct_workspace_label_only"
          }
        })

      auth_json =
        auth_json_fixture(account_id: "acct_workspace_label_only", id_token: id_token)
        |> Jason.decode!()
        |> Map.merge(%{
          "workspace_id" => "untrusted_payload_workspace",
          "workspace_label" => "Untrusted Payload Workspace",
          "seat_type" => "untrusted-seat"
        })
        |> Jason.encode!()

      assert {:ok, %{identity: identity}} =
               Upstreams.import_codex_auth_json(scope, pool, auth_json)

      assert identity.workspace_id == nil
      assert identity.workspace_label == "Display Only Workspace"
      assert identity.seat_type == nil
      assert Repo.aggregate(UpstreamIdentity, :count) == 1
    end

    test "auth.json import updates the exact account workspace slot" do
      scope = fixture_owner_scope()
      {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-json-slot", name: "auth.json Slot"})
      account_id = "acct_workspace_exact_#{System.unique_integer([:positive])}"
      first_access = jwt_token(%{"exp" => future_unix(), "nonce" => "slot-first"})
      second_access = jwt_token(%{"exp" => future_unix(), "nonce" => "slot-second"})

      first_id_token =
        jwt_token(%{
          "email" => "slot-exact@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "workspace_id" => "ws_exact",
            "workspace_label" => "Exact Workspace",
            "entitlement_type" => "team-seat"
          }
        })

      second_id_token =
        jwt_token(%{
          "email" => "slot-exact@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "workspace_id" => "ws_exact",
            "workspace_label" => "Exact Workspace Renamed",
            "entitlement_type" => "enterprise-seat"
          }
        })

      assert {:ok, %{status: :created, identity: first_identity, assignment: first_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: first_access,
                   id_token: first_id_token
                 )
               )

      assert {:ok, %{status: :existing, identity: second_identity, assignment: second_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: second_access,
                   id_token: second_id_token
                 )
               )

      assert second_identity.id == first_identity.id
      assert second_assignment.id == first_assignment.id
      assert second_identity.workspace_id == "ws_exact"
      assert second_identity.workspace_label == "Exact Workspace Renamed"
      assert second_identity.seat_type == "enterprise-seat"
      assert Repo.aggregate(UpstreamIdentity, :count) == 1
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1

      assert {:ok, ^second_access} =
               Secrets.decrypt_active_secret(second_identity, "access_token")
    end

    test "auth.json import upgrades a unique legacy slot to the incoming workspace" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "auth-json-legacy-slot", name: "auth.json Legacy Slot"})

      account_id = "acct_workspace_upgrade_#{System.unique_integer([:positive])}"

      legacy_id_token =
        jwt_token(%{
          "email" => "legacy-upgrade@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id
          }
        })

      assert {:ok, %{identity: legacy_identity, assignment: legacy_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(account_id: account_id, id_token: legacy_id_token)
               )

      assert legacy_identity.workspace_id == nil
      assert legacy_identity.chatgpt_user_id == nil

      workspace_id_token =
        jwt_token(%{
          "email" => "legacy-upgrade@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "workspace_id" => "ws_promoted",
            "workspace_label" => "Promoted Workspace",
            "entitlement_type" => "team-seat"
          }
        })

      assert {:ok, %{status: :existing, identity: promoted, assignment: promoted_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(account_id: account_id, id_token: workspace_id_token)
               )

      assert promoted.id == legacy_identity.id
      assert promoted_assignment.id == legacy_assignment.id
      assert promoted.workspace_id == "ws_promoted"
      assert promoted.workspace_label == "Promoted Workspace"
      assert promoted.seat_type == "team-seat"
      assert Repo.aggregate(UpstreamIdentity, :count) == 1
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1
    end

    test "auth.json import keeps a legacy slot distinct when concrete siblings exist" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "auth-json-sibling-slot", name: "auth.json Sibling Slot"})

      account_id = "acct_workspace_sibling_#{System.unique_integer([:positive])}"

      assert {:ok, %{identity: legacy_identity}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(account_id: account_id)
               )

      concrete_sibling =
        active_identity_fixture(%{
          chatgpt_account_id: account_id,
          account_email: "sibling-slot@example.com",
          account_label: "Existing concrete slot",
          workspace_id: "ws_existing"
        })

      incoming_id_token =
        jwt_token(%{
          "email" => "sibling-slot@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => account_id,
            "workspace_id" => "ws_new",
            "workspace_label" => "New Workspace",
            "entitlement_type" => "team-seat"
          }
        })

      assert {:ok, %{status: :created, identity: new_identity}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(account_id: account_id, id_token: incoming_id_token)
               )

      assert new_identity.id != legacy_identity.id
      assert new_identity.id != concrete_sibling.id
      assert new_identity.workspace_id == "ws_new"
      assert Repo.get!(UpstreamIdentity, legacy_identity.id).workspace_id == nil
      assert Repo.get!(UpstreamIdentity, legacy_identity.id).status == "active"
      assert Repo.get!(UpstreamIdentity, concrete_sibling.id).workspace_id == "ws_existing"
      assert Repo.get!(UpstreamIdentity, concrete_sibling.id).status == "active"
      assert Repo.aggregate(UpstreamIdentity, :count) == 3
    end

    test "email workspace fallback updates only a single unambiguous candidate" do
      email = "fallback-single-#{System.unique_integer([:positive])}@example.com"

      identity =
        active_identity_fixture(%{
          chatgpt_account_id: "acct_fallback_single_#{System.unique_integer([:positive])}",
          account_email: email,
          account_label: "Fallback original",
          workspace_id: "ws_fallback"
        })

      assert {:ok, updated_identity} =
               IdentityLifecycle.upsert_upstream_identity(%{
                 account_email: email,
                 account_label: "Fallback updated",
                 workspace_id: "ws_fallback",
                 onboarding_method: "import",
                 status: "active"
               })

      assert updated_identity.id == identity.id
      assert updated_identity.chatgpt_account_id == identity.chatgpt_account_id
      assert updated_identity.account_label == "Fallback updated"
      assert Repo.aggregate(UpstreamIdentity, :count) == 1
    end

    test "email workspace fallback refuses zero candidates without creating an identity" do
      email = "fallback-missing-#{System.unique_integer([:positive])}@example.com"
      workspace_id = "ws_missing_fallback"

      assert {:error,
              {:identity_conflict, :workspace_identity_mismatch,
               %{
                 path: "upstream_identity.reconciliation",
                 stored_workspace_ref: "legacy",
                 incoming_workspace_ref: incoming_workspace_ref,
                 stored_plan_family: nil,
                 incoming_plan_family: "team",
                 stored_seat_type: nil,
                 incoming_seat_type: "enterprise-seat"
               } = conflict}} =
               IdentityLifecycle.upsert_upstream_identity(%{
                 account_email: email,
                 account_label: "Fallback missing",
                 workspace_id: workspace_id,
                 onboarding_method: "import",
                 plan_family: "team",
                 seat_type: "enterprise-seat",
                 status: "active"
               })

      assert String.starts_with?(incoming_workspace_ref, "ws:")

      assert Map.keys(conflict) |> Enum.sort() ==
               [
                 :incoming_plan_family,
                 :incoming_seat_type,
                 :incoming_workspace_ref,
                 :path,
                 :stored_plan_family,
                 :stored_seat_type,
                 :stored_workspace_ref
               ]

      assert Repo.aggregate(UpstreamIdentity, :count) == 0
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0
      assert Repo.aggregate(EncryptedSecret, :count) == 0
      refute inspect(conflict) =~ email
      refute inspect(conflict) =~ workspace_id
    end

    test "email legacy fallback refuses concrete sibling ambiguity without mutations" do
      pool = pool_fixture()
      email = "fallback-conflict-#{System.unique_integer([:positive])}@example.com"
      account_id = "acct_fallback_conflict_#{System.unique_integer([:positive])}"
      configure_upstream_secret_key!()
      access_token = generated_secret("fallback-conflict")

      legacy_identity =
        active_identity_fixture(%{
          chatgpt_account_id: account_id,
          account_email: email,
          account_label: "Fallback legacy",
          plan_family: "pro"
        })

      concrete_identity =
        active_identity_fixture(%{
          chatgpt_account_id: account_id,
          account_email: email,
          account_label: "Fallback concrete",
          workspace_id: "ws_conflict",
          seat_type: "team-seat"
        })

      assert {:ok, assignment} = PoolAssignments.create_pool_assignment(pool, legacy_identity)
      assert {:ok, assignment} = PoolAssignments.activate_pool_assignment(assignment)

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(legacy_identity, %{
                 secret_kind: "access_token",
                 plaintext: access_token
               })

      assert {:error,
              {:identity_conflict, :workspace_identity_mismatch,
               %{
                 path: "upstream_identity.reconciliation",
                 stored_workspace_ref: stored_workspace_ref,
                 incoming_workspace_ref: "legacy",
                 stored_plan_family: nil,
                 incoming_plan_family: "team",
                 stored_seat_type: "team-seat",
                 incoming_seat_type: "enterprise-seat"
               } = conflict}} =
               IdentityLifecycle.upsert_upstream_identity(%{
                 account_email: email,
                 account_label: "Fallback incoming",
                 onboarding_method: "import",
                 plan_family: "team",
                 seat_type: "enterprise-seat",
                 status: "active"
               })

      assert String.starts_with?(stored_workspace_ref, "ws:")

      assert Map.keys(conflict) |> Enum.sort() ==
               [
                 :incoming_plan_family,
                 :incoming_seat_type,
                 :incoming_workspace_ref,
                 :path,
                 :stored_plan_family,
                 :stored_seat_type,
                 :stored_workspace_ref
               ]

      assert Repo.aggregate(UpstreamIdentity, :count) == 2
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1
      assert Repo.get!(UpstreamIdentity, legacy_identity.id).account_label == "Fallback legacy"
      assert Repo.get!(UpstreamIdentity, legacy_identity.id).workspace_id == nil
      assert Repo.get!(UpstreamIdentity, concrete_identity.id).workspace_id == "ws_conflict"

      assert Repo.get!(PoolUpstreamAssignment, assignment.id).upstream_identity_id ==
               legacy_identity.id

      assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "active"
      assert {:ok, ^access_token} = Secrets.decrypt_active_secret(legacy_identity, "access_token")
      refute inspect(conflict) =~ email
      refute inspect(conflict) =~ account_id
      refute inspect(conflict) =~ "ws_conflict"
    end

    test "auth.json import primes quota through the canonical assignment job path" do
      Repo.delete_all(Oban.Job)

      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "auth-json-prime", name: "auth.json Prime"})

      access_token = jwt_token(%{"exp" => future_unix(), "nonce" => "prime"})
      refresh_token = runtime_secret("auth-json-prime")

      assert {:ok, %{identity: identity, assignment: assignment} = result} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: "acct_auth_json_prime",
                   access_token: access_token,
                   refresh_token: refresh_token
                 )
               )

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      priming = assignment.metadata["quota_priming"]

      assert priming["status"] == "unknown"
      assert priming["trigger_kind"] == "account_link"
      assert {:ok, _enqueued_at, 0} = DateTime.from_iso8601(priming["enqueued_at"])
      refute Quota.PrimingState.candidate?(assignment)

      assert [job] = all_enqueued(worker: AccountReconciliationWorker)
      assert job.args["pool_id"] == pool.id
      assert job.args["pool_upstream_assignment_id"] == assignment.id
      assert job.args["trigger_kind"] == "account_link"

      refute inspect(result) =~ access_token
      refute inspect(result) =~ refresh_token
      assert identity.chatgpt_account_id == "acct_auth_json_prime"
    end

    test "auth.json import records duplicate priming conflicts as blocked metadata" do
      Repo.delete_all(Oban.Job)

      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{
          slug: "auth-json-prime-conflict",
          name: "auth.json Prime Conflict"
        })

      auth_json =
        auth_json_fixture(
          account_id: "acct_auth_json_prime_conflict",
          access_token: jwt_token(%{"exp" => future_unix(), "nonce" => "first"}),
          refresh_token: runtime_secret("auth-json-prime-conflict-first")
        )

      assert {:ok, %{assignment: first_assignment}} =
               Upstreams.import_codex_auth_json(scope, pool, auth_json)

      assert {:ok, %{assignment: second_assignment}} =
               Upstreams.import_codex_auth_json(scope, pool, auth_json)

      assert second_assignment.id == first_assignment.id
      assert [job] = all_enqueued(worker: AccountReconciliationWorker)
      refute job.conflict?

      assignment = Repo.get!(PoolUpstreamAssignment, first_assignment.id)
      priming = assignment.metadata["quota_priming"]

      assert priming["status"] == "blocked"
      assert priming["trigger_kind"] == "account_link"
      assert priming["reason"]["code"] == "oban_unique_conflict"
      assert priming["reason"]["message"] == "account reconciliation is already queued"
      assert {:ok, _blocked_at, 0} = DateTime.from_iso8601(priming["blocked_at"])
      refute Quota.PrimingState.candidate?(assignment)
    end

    test "reimporting Codex auth.json reuses account, assignment, and active secret rows" do
      scope = fixture_owner_scope()
      {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-json-reuse", name: "auth.json Reuse"})
      first_access = jwt_token(%{"exp" => future_unix(), "nonce" => "first"})
      second_access = jwt_token(%{"exp" => future_unix(), "nonce" => "second"})
      first_refresh = runtime_secret("auth-json-first-refresh")
      second_refresh = runtime_secret("auth-json-second-refresh")

      assert {:ok, %{status: :created, identity: first_identity, assignment: first_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(access_token: first_access, refresh_token: first_refresh)
               )

      assert {:ok, %{status: :existing, identity: second_identity, assignment: second_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(access_token: second_access, refresh_token: second_refresh)
               )

      assert second_identity.id == first_identity.id
      assert second_assignment.id == first_assignment.id
      assert Repo.aggregate(UpstreamIdentity, :count) == 1
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1
      assert active_secret_count("access_token") == 1
      assert active_secret_count("refresh_token") == 1

      assert {:ok, ^second_access} =
               Secrets.decrypt_active_secret(
                 second_identity,
                 "access_token"
               )

      assert {:ok, ^second_refresh} =
               Secrets.decrypt_active_secret(
                 second_identity,
                 "refresh_token"
               )
    end

    test "fresh auth.json reimport clears stale token refresh remediation and bumps generation" do
      scope = fixture_owner_scope()
      {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-json-fence", name: "auth.json Fence"})
      first_access = jwt_token(%{"exp" => future_unix(), "nonce" => "fence-first"})
      second_access = jwt_token(%{"exp" => future_unix(), "nonce" => "fence-second"})
      first_refresh = runtime_secret("auth-json-fence-first-refresh")
      second_refresh = runtime_secret("auth-json-fence-second-refresh")
      account_id = "acct_auth_json_generation_fence"

      assert {:ok, %{identity: identity, assignment: assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: first_access,
                   refresh_token: first_refresh
                 )
               )

      stale_metadata = %{
        "auth_json_imported" => true,
        "safe_unrelated" => "preserved",
        "token_refresh" => %{
          "status" => "reauth_required",
          "attempt_id" => Ecto.UUID.generate(),
          "generation" => 7,
          "finished_at" => "2026-05-22T10:00:00Z",
          "trigger_kind" => "worker",
          "reason" => %{
            "code" => "refresh_token_revoked",
            "message" => "refresh token was revoked"
          }
        }
      }

      disabled_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      Repo.get!(UpstreamIdentity, identity.id)
      |> UpstreamIdentity.changeset(%{
        status: "reauth_required",
        disabled_at: disabled_at,
        metadata: stale_metadata
      })
      |> Repo.update!()

      Repo.get!(PoolUpstreamAssignment, assignment.id)
      |> PoolUpstreamAssignment.changeset(%{
        health_status: "disabled",
        eligibility_status: "ineligible",
        disabled_at: disabled_at
      })
      |> Repo.update!()

      second_auth_json =
        auth_json_fixture(
          account_id: account_id,
          access_token: second_access,
          refresh_token: second_refresh
        )

      assert {:ok,
              %{status: :existing, identity: imported, assignment: imported_assignment} = result} =
               Upstreams.import_codex_auth_json(scope, pool, second_auth_json)

      assert imported.id == identity.id
      assert imported.status == "active"
      assert imported.disabled_at == nil
      assert imported.metadata["safe_unrelated"] == "preserved"
      assert imported.metadata["auth_json_imported"] == true

      token_refresh = imported.metadata["token_refresh"]
      assert token_refresh["status"] == "imported"
      assert token_refresh["generation"] == 8
      assert token_refresh["trigger_kind"] == "auth_json_import"
      assert {:ok, _imported_at, 0} = DateTime.from_iso8601(token_refresh["imported_at"])
      refute Map.has_key?(token_refresh, "reason")

      assert imported_assignment.status == "active"
      assert imported_assignment.health_status == "active"
      assert imported_assignment.eligibility_status == "ineligible"
      assert imported_assignment.disabled_at == nil

      assert {:ok, ^second_access} = Secrets.decrypt_active_secret(imported, "access_token")
      assert {:ok, ^second_refresh} = Secrets.decrypt_active_secret(imported, "refresh_token")
      assert active_secret_count("access_token") == 1
      assert active_secret_count("refresh_token") == 1

      metadata_text = inspect(imported.metadata)
      refute metadata_text =~ first_access
      refute metadata_text =~ second_access
      refute metadata_text =~ first_refresh
      refute metadata_text =~ second_refresh
      refute inspect(result) =~ second_auth_json
    end

    test "fresh auth.json reimport fences stale in-flight refresh finalization" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "auth-json-flight", name: "auth.json Flight"})

      account_id = "acct_auth_json_in_flight_fence"
      original_access = jwt_token(%{"exp" => future_unix(), "nonce" => "flight-original"})
      original_refresh = runtime_secret("auth-json-flight-original-refresh")
      stale_provider_access = runtime_secret("auth-json-flight-stale-access")
      stale_provider_refresh = runtime_secret("auth-json-flight-stale-refresh")
      imported_access = jwt_token(%{"exp" => future_unix(), "nonce" => "flight-imported"})
      imported_refresh = runtime_secret("auth-json-flight-imported-refresh")
      release_ref = make_ref()

      {:ok, upstream} =
        FakeUpstream.start_link(
          FakeUpstream.barrier_json_response(
            %{
              "access_token" => stale_provider_access,
              "refresh_token" => stale_provider_refresh,
              "expires_in" => 3600
            },
            notify: self(),
            release_ref: release_ref
          )
        )

      on_exit(fn -> FakeUpstream.stop(upstream) end)

      assert {:ok, %{identity: identity}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(
                   account_id: account_id,
                   access_token: original_access,
                   refresh_token: original_refresh
                 )
               )

      identity = Repo.get!(UpstreamIdentity, identity.id)

      identity
      |> UpstreamIdentity.changeset(%{
        metadata: Map.put(identity.metadata, "base_url", FakeUpstream.url(upstream))
      })
      |> Repo.update!()

      parent = self()

      refresh_task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          TokenRefresh.refresh_access_token(identity, trigger_kind: "stale_import_race")
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                      ^release_ref},
                     1_000

      refreshing = Repo.get!(UpstreamIdentity, identity.id)
      claimed_generation = refreshing.metadata["token_refresh"]["generation"]
      assert refreshing.status == "refreshing"

      fresh_auth_json =
        auth_json_fixture(
          account_id: account_id,
          access_token: imported_access,
          refresh_token: imported_refresh
        )

      assert {:ok, %{identity: imported} = import_result} =
               Upstreams.import_codex_auth_json(scope, pool, fresh_auth_json)

      assert imported.status == "active"
      assert imported.metadata["token_refresh"]["status"] == "imported"
      assert imported.metadata["token_refresh"]["generation"] == claimed_generation + 1

      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

      assert {:ok, %{status: :noop, retryable?: false}} = Task.await(refresh_task, 1_000)

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "active"
      assert persisted.metadata["token_refresh"] == imported.metadata["token_refresh"]
      assert {:ok, ^imported_access} = Secrets.decrypt_active_secret(identity, "access_token")
      assert {:ok, ^imported_refresh} = Secrets.decrypt_active_secret(identity, "refresh_token")
      refute inspect(persisted.metadata) =~ stale_provider_access
      refute inspect(persisted.metadata) =~ stale_provider_refresh
      refute inspect(import_result) =~ fresh_auth_json
    end

    test "importing an existing Codex auth.json into another Pool reuses the identity and creates a new Pool assignment" do
      scope = fixture_owner_scope()

      {:ok, source_pool} =
        Pools.create_pool(scope, %{slug: "auth-json-source", name: "auth.json Source"})

      {:ok, target_pool} =
        Pools.create_pool(scope, %{slug: "auth-json-target", name: "auth.json Target"})

      first_access = jwt_token(%{"exp" => future_unix(), "nonce" => "source"})
      second_access = jwt_token(%{"exp" => future_unix(), "nonce" => "target"})
      first_refresh = runtime_secret("auth-json-cross-pool-first-refresh")
      second_refresh = runtime_secret("auth-json-cross-pool-second-refresh")

      assert {:ok, %{status: :created, identity: first_identity, assignment: source_assignment}} =
               Upstreams.import_codex_auth_json(
                 scope,
                 source_pool,
                 auth_json_fixture(access_token: first_access, refresh_token: first_refresh)
               )

      second_auth_json =
        auth_json_fixture(access_token: second_access, refresh_token: second_refresh)

      assert {:ok,
              %{status: :existing, identity: second_identity, assignment: target_assignment} =
                result} =
               Upstreams.import_codex_auth_json(scope, target_pool, second_auth_json)

      assert second_identity.id == first_identity.id
      assert source_assignment.id != target_assignment.id
      assert source_assignment.pool_id == source_pool.id
      assert target_assignment.pool_id == target_pool.id
      assert target_assignment.upstream_identity_id == first_identity.id

      assignments_by_pool =
        first_identity
        |> Upstreams.list_pool_assignments_for_identity()
        |> Map.new(&{&1.pool_id, &1})

      assert Map.fetch!(assignments_by_pool, source_pool.id).id == source_assignment.id
      assert Map.fetch!(assignments_by_pool, target_pool.id).id == target_assignment.id
      assert Repo.aggregate(UpstreamIdentity, :count) == 1
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 2
      assert active_secret_count("access_token") == 1
      assert active_secret_count("refresh_token") == 1

      assert {:ok, ^second_access} =
               Secrets.decrypt_active_secret(
                 second_identity,
                 "access_token"
               )

      assert {:ok, ^second_refresh} =
               Secrets.decrypt_active_secret(
                 second_identity,
                 "refresh_token"
               )

      refute inspect(result) =~ first_access
      refute inspect(result) =~ second_access
      refute inspect(result) =~ first_refresh
      refute inspect(result) =~ second_refresh
      refute inspect(result) =~ second_auth_json
      refute inspect(result) =~ "cookie"
      refute inspect(result) =~ "/Users/"
    end

    test "rejects malformed unsupported expired and missing-token Codex auth.json safely" do
      scope = fixture_owner_scope()
      {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-json-invalid", name: "Invalid JSON"})
      sensitive_token = runtime_secret("auth-json-invalid")

      invalid_cases = [
        {"not-json", "Codex auth.json is malformed"},
        {Jason.encode!(%{"OPENAI_API_KEY" => sensitive_token}),
         "Codex API-key auth.json is not supported"},
        {auth_json_fixture(access_token: jwt_token(%{"exp" => past_unix()})),
         "Codex auth.json access token is expired"},
        {auth_json_fixture(tokens: %{"id_token" => id_token_fixture()}),
         "Codex auth.json is missing access_token"},
        {auth_json_fixture(tokens: %{"access_token" => jwt_token(%{"exp" => future_unix()})}),
         "Codex auth.json is missing id_token"},
        {auth_json_fixture(
           tokens: %{
             "id_token" => id_token_fixture(),
             "access_token" => jwt_token(%{"exp" => future_unix()})
           }
         ), "Codex auth.json is missing refresh_token"}
      ]

      for {payload, message} <- invalid_cases do
        assert {:error, changeset} = Upstreams.import_codex_auth_json(scope, pool, payload)
        assert %{content: [^message]} = errors_on(changeset)
        refute inspect(changeset) =~ sensitive_token
        refute inspect(changeset) =~ payload
      end

      assert Repo.aggregate(UpstreamIdentity, :count) == 0
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0
      assert Repo.aggregate(EncryptedSecret, :count) == 0
    end

    test "rejects personal access token auth.json without storing or exposing the token" do
      scope = fixture_owner_scope()
      {:ok, pool} = Pools.create_pool(scope, %{slug: "auth-json-pat", name: "PAT JSON"})
      personal_access_token = "at-auth-json-pat-do-not-leak-#{System.unique_integer([:positive])}"
      unsupported_message = "Codex personal access token auth.json is not supported in this cycle"

      payloads = [
        Jason.encode!(%{
          "auth_mode" => "personalAccessToken",
          "personalAccessToken" => personal_access_token
        }),
        Jason.encode!(%{"personalAccessToken" => personal_access_token}),
        Jason.encode!(%{
          "tokens" => %{
            "access_token" => personal_access_token,
            "id_token" => id_token_fixture(),
            "refresh_token" => runtime_secret("auth-json-pat-refresh"),
            "account_id" => "acct_pat_unsupported"
          }
        })
      ]

      baseline_import_events =
        Repo.aggregate(
          from(event in AuditEvent, where: event.action == "upstream_account.import"),
          :count
        )

      for payload <- payloads do
        assert {:error, %{code: :unsupported_auth_json, message: ^unsupported_message}} =
                 CodexAuthJson.parse(payload)

        assert {:error, changeset} = Upstreams.import_codex_auth_json(scope, pool, payload)
        assert %{content: [^unsupported_message]} = errors_on(changeset)
        refute inspect(changeset) =~ personal_access_token
        refute inspect(changeset) =~ payload
      end

      assert Repo.aggregate(UpstreamIdentity, :count) == 0
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0
      assert Repo.aggregate(EncryptedSecret, :count) == 0

      assert Repo.aggregate(
               from(event in AuditEvent, where: event.action == "upstream_account.import"),
               :count
             ) == baseline_import_events
    end

    test "invalid upstream secret key rolls back auth.json import without partial rows" do
      scope = fixture_owner_scope()

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: "auth-json-invalid-key", name: "Invalid Key"})

      invalid_key = "too-short"

      configure_upstream_secret_key!(invalid_key)

      assert {:error,
              %{
                code: :upstream_secret_key_invalid,
                message:
                  "CODEX_POOLER_UPSTREAM_SECRET_KEY must be 32 raw bytes or base64-encoded 32 bytes"
              } = error} =
               Upstreams.import_codex_auth_json(
                 scope,
                 pool,
                 auth_json_fixture(account_id: "acct_invalid_key_import")
               )

      refute inspect(error) =~ invalid_key
      assert Upstreams.get_upstream_identity_by_chatgpt_account("acct_invalid_key_import") == nil
      assert Repo.aggregate(UpstreamIdentity, :count) == 0
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0
      assert Repo.aggregate(EncryptedSecret, :count) == 0
    end
  end

  describe "account lifecycle states" do
    test "scoped lifecycle entry points require an operable pool assignment" do
      %{user: owner} = bootstrap_owner_fixture()
      owner_scope = Scope.for_user(owner, ["instance_owner"])
      %{user: admin} = operator_fixture(owner, %{"email" => "upstream-admin@example.com"})
      pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_scoped_lifecycle"})

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, _assignment} =
               PoolAssignments.activate_pool_assignment(assignment)

      operator_pool_assignment_fixture(admin, pool, created_by_user_id: owner.id)
      admin_scope = Scope.for_user(admin)

      assert {:ok, result} =
               Upstreams.pause_account_for_scope(admin_scope, identity.id, %{
                 reason: "operator_pause"
               })

      assert result.status == :paused
      assert result.identity.status == "paused"

      unassigned_identity =
        active_identity_fixture(%{chatgpt_account_id: "acct_unassigned_lifecycle"})

      assert {:error, %{code: :pool_assignment_not_found}} =
               Upstreams.pause_account_for_scope(owner_scope, unassigned_identity.id, %{})
    end

    test "assigned-pool admin cannot mutate a shared identity with hidden assignments" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
      visible_pool = pool_fixture(%{name: "Visible Pool"})
      hidden_pool = pool_fixture(%{name: "Hidden Pool"})
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_shared_hidden_lifecycle"})

      assert {:ok, visible_assignment} =
               PoolAssignments.create_pool_assignment(visible_pool, identity)

      assert {:ok, visible_assignment} =
               PoolAssignments.activate_pool_assignment(visible_assignment)

      assert {:ok, hidden_assignment} =
               PoolAssignments.create_pool_assignment(hidden_pool, identity)

      assert {:ok, hidden_assignment} =
               PoolAssignments.activate_pool_assignment(hidden_assignment)

      operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)
      admin_scope = Scope.for_user(admin)

      assert {:error, %{code: :capability_denied}} =
               Upstreams.pause_account_for_scope(admin_scope, identity.id, %{
                 reason: "scoped_pause"
               })

      assert {:error, %{code: :capability_denied}} =
               Upstreams.soft_delete_account_for_scope(admin_scope, identity.id, %{
                 reason: "scoped_delete"
               })

      assert Repo.get!(UpstreamIdentity, identity.id).status == "active"
      assert Repo.get!(PoolUpstreamAssignment, visible_assignment.id).status == "active"
      assert Repo.get!(PoolUpstreamAssignment, hidden_assignment.id).status == "active"
      assert audit_events("upstream_account.pause", identity.id) == []
      assert audit_events("upstream_account.delete", identity.id) == []
    end

    test "assigned-pool admin cannot import an existing account into an unassigned target pool" do
      configure_upstream_secret_key!()
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      owner_scope = Scope.for_user(owner)
      %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
      source_pool = pool_fixture(%{name: "Source Pool"})
      target_pool = pool_fixture(%{name: "Target Pool"})
      account_id = "acct_import_unassigned_target"

      operator_pool_assignment_fixture(admin, source_pool, created_by_user_id: owner.id)
      admin_scope = Scope.for_user(admin)

      assert {:ok, %{identity: identity, assignment: source_assignment}} =
               Upstreams.import_codex_auth_json(
                 owner_scope,
                 source_pool,
                 auth_json_fixture(account_id: account_id)
               )

      assert {:error, %{code: :capability_denied}} =
               Upstreams.import_codex_auth_json(
                 admin_scope,
                 target_pool,
                 auth_json_fixture(account_id: account_id)
               )

      assert Repo.aggregate(UpstreamIdentity, :count) == 1
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1
      assert Repo.get!(PoolUpstreamAssignment, source_assignment.id).pool_id == source_pool.id
      assert Upstreams.get_upstream_identity(identity.id).status == "active"
    end

    test "assigned-pool admin can import an existing account into an assigned target pool" do
      configure_upstream_secret_key!()
      %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
      owner_scope = Scope.for_user(owner)
      %{user: admin} = operator_fixture(owner, %{"email" => unique_user_email()})
      source_pool = pool_fixture(%{name: "Source Pool"})
      target_pool = pool_fixture(%{name: "Target Pool"})
      account_id = "acct_import_assigned_target"

      operator_pool_assignment_fixture(admin, source_pool, created_by_user_id: owner.id)
      operator_pool_assignment_fixture(admin, target_pool, created_by_user_id: owner.id)
      admin_scope = Scope.for_user(admin)

      assert {:ok, %{identity: identity}} =
               Upstreams.import_codex_auth_json(
                 owner_scope,
                 source_pool,
                 auth_json_fixture(account_id: account_id)
               )

      assert {:ok, %{status: :existing, identity: imported, assignment: target_assignment}} =
               Upstreams.import_codex_auth_json(
                 admin_scope,
                 target_pool,
                 auth_json_fixture(account_id: account_id)
               )

      assert imported.id == identity.id
      assert target_assignment.pool_id == target_pool.id
      assert Repo.aggregate(UpstreamIdentity, :count) == 1
      assert Repo.aggregate(PoolUpstreamAssignment, :count) == 2
    end

    test "scoped lifecycle entry points record sanitized user audit events" do
      scope = fixture_owner_scope()
      pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_lifecycle_audit"})
      configure_upstream_secret_key!()
      token = generated_secret("lifecycle-audit")

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, _assignment} =
               PoolAssignments.activate_pool_assignment(assignment)

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: token
               })

      assert {:ok, %{status: :paused}} =
               Upstreams.pause_account_for_scope(scope, identity.id, %{reason: "audit_pause"})

      assert {:ok, %{status: :active}} =
               Upstreams.reactivate_account_for_scope(scope, identity.id, %{})

      assert {:ok, %{status: :deleted}} =
               Upstreams.soft_delete_account_for_scope(scope, identity.id, %{
                 reason: "audit_delete"
               })

      for {action, status, previous_status} <- [
            {"upstream_account.pause", "paused", "active"},
            {"upstream_account.reactivate", "active", "paused"},
            {"upstream_account.delete", "deleted", "active"}
          ] do
        assert [event] = audit_events(action, identity.id)
        assert event.actor_user_id == scope.user.id
        assert event.pool_id == pool.id
        assert event.target_type == "upstream_identity"
        assert event.details["upstream_identity_id"] == identity.id
        assert event.details["pool_assignment_ids"] == [assignment.id]
        assert event.details["status"] == status
        assert event.details["previous_status"] == previous_status
        refute inspect(event) =~ token
        refute inspect(event) =~ identity.chatgpt_account_id
      end
    end

    @tag :lifecycle_pause_reactivate
    test "pause preserves secrets and history, removes routing, and reactivates after local checks" do
      pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_pause_reactivate"})
      configure_upstream_secret_key!()
      token = generated_secret("pause")

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, assignment} =
               PoolAssignments.activate_pool_assignment(assignment)

      assert {:ok, secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: token
               })

      assert [eligible] = Upstreams.list_eligible_pool_assignments(pool)
      assert eligible.id == assignment.id

      scope = fixture_owner_scope()

      assert {:ok, result} =
               Upstreams.pause_account_for_scope(scope, identity, %{reason: "operator_pause"})

      assert result.status == :paused
      assert result.identity.status == "paused"
      assert result.secret_status == :present

      assert [%PoolUpstreamAssignment{status: "paused", eligibility_status: "ineligible"}] =
               result.assignments

      refute inspect(result) =~ token

      assert Repo.get!(EncryptedSecret, secret.id).status == "active"
      assert Upstreams.list_eligible_pool_assignments(pool) == []

      assert {:ok, result} = Upstreams.reactivate_account_for_scope(scope, identity, %{})
      assert result.status == :active
      assert result.identity.status == "active"
      assert result.secret_status == :present

      assert [eligible] = Upstreams.list_eligible_pool_assignments(pool)
      assert eligible.id == assignment.id

      assert {:ok, decrypted} =
               Secrets.decrypt_active_secret(identity, "access_token")

      assert decrypted == token
    end

    test "reactivation promotes a newly attached pending assignment" do
      source_pool = pool_fixture(%{name: "Reactivation Source"})
      target_pool = pool_fixture(%{name: "Reactivation Target"})
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_pending_reactivation"})
      configure_upstream_secret_key!()

      assert {:ok, source_assignment} =
               PoolAssignments.create_pool_assignment(source_pool, identity)

      assert {:ok, source_assignment} =
               PoolAssignments.activate_pool_assignment(source_assignment)

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: generated_secret("pending-reactivation")
               })

      scope = fixture_owner_scope()

      assert {:ok, %{status: :paused}} =
               Upstreams.pause_account_for_scope(scope, identity, %{})

      assert {:ok, %{status: :assignment_deleted}} =
               PoolAssignments.delete_pool_assignment(source_pool, source_assignment)

      assert {:ok, pending_assignment} =
               PoolAssignments.create_pool_assignment(target_pool, identity)

      assert pending_assignment.status == "pending"

      assert {:ok, %{status: :active}} =
               Upstreams.reactivate_account_for_scope(scope, identity, %{})

      assert %PoolUpstreamAssignment{
               status: "active",
               health_status: "active",
               eligibility_status: "eligible"
             } = Repo.get!(PoolUpstreamAssignment, pending_assignment.id)

      assert Repo.get!(PoolUpstreamAssignment, source_assignment.id).status == "deleted"
    end

    test "reactivation fails when the account has no active routing secret" do
      pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_pause_missing_secret"})

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, _assignment} =
               PoolAssignments.activate_pool_assignment(assignment)

      scope = fixture_owner_scope()

      assert {:ok, _paused} = Upstreams.pause_account_for_scope(scope, identity, %{})

      assert {:error, %{code: :upstream_secret_not_routable, message: message}} =
               Upstreams.reactivate_account_for_scope(scope, identity, %{})

      assert message == "upstream access token is missing"
      assert Upstreams.list_eligible_pool_assignments(pool) == []
    end

    @tag :lifecycle_soft_delete
    test "soft delete revokes active routing secrets while preserving historical rows" do
      pool = pool_fixture()
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_soft_delete"})
      configure_upstream_secret_key!()
      token = generated_secret("soft-delete")

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, _assignment} =
               PoolAssignments.activate_pool_assignment(assignment)

      assert {:ok, secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: token
               })

      scope = fixture_owner_scope()

      assert {:ok, result} =
               Upstreams.soft_delete_account_for_scope(scope, identity, %{
                 reason: "operator_delete"
               })

      assert result.status == :deleted
      assert result.identity.status == "deleted"
      assert result.secret_status == :missing

      assert [%PoolUpstreamAssignment{status: "deleted", eligibility_status: "ineligible"}] =
               result.assignments

      refute inspect(result) =~ token

      assert Repo.get!(UpstreamIdentity, identity.id).status == "deleted"
      assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "deleted"
      assert Repo.get!(EncryptedSecret, secret.id).status == "revoked"

      assert {:error, %{code: :upstream_secret_not_found}} =
               Secrets.decrypt_active_secret(identity, "access_token")

      assert Upstreams.list_eligible_pool_assignments(pool) == []

      assert {:error, %{code: :pool_assignment_not_found}} =
               Upstreams.reactivate_account_for_scope(scope, identity, %{})
    end

    test "secret status returns only safe lifecycle labels" do
      identity = active_identity_fixture(%{chatgpt_account_id: "acct_secret_status"})
      configure_upstream_secret_key!()
      token = generated_secret("status")

      assert Secrets.secret_status(identity) == :missing

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: token
               })

      assert Secrets.secret_status(identity) == :present

      assert {:ok, expired} =
               IdentityLifecycle.update_upstream_identity(identity, %{
                 metadata: %{"access_token_expires_at" => "2020-01-01T00:00:00Z"}
               })

      assert Secrets.secret_status(expired) == :expired

      assert {:ok, reauth} =
               IdentityLifecycle.update_upstream_identity(identity, %{
                 status: "reauth_required"
               })

      assert Secrets.secret_status(reauth) == :reauth_required
      refute inspect(Secrets.secret_status(reauth)) =~ token
    end
  end

  describe "encrypted secrets" do
    test "validates upstream secret key boot values without exposing invalid input" do
      raw_key = String.duplicate("r", 32)
      base64_key = Base.encode64(String.duplicate("b", 32))
      non_utf8_raw_key = :binary.copy(<<255>>, 32)

      assert :ok = Secrets.validate_upstream_secret_key!(raw_key)
      assert :ok = Secrets.validate_upstream_secret_key!(base64_key)
      assert :ok = Secrets.validate_upstream_secret_key!(non_utf8_raw_key)

      invalid_cases = [
        nil,
        "not-base64!!!!",
        Base.encode64("too-short"),
        <<255, 254, 253>>
      ]

      for invalid_key <- invalid_cases do
        error =
          assert_raise RuntimeError, fn ->
            Secrets.validate_upstream_secret_key!(invalid_key)
          end

        assert Exception.message(error) ==
                 "CODEX_POOLER_UPSTREAM_SECRET_KEY must be 32 raw bytes or base64-encoded 32 bytes"

        if is_binary(invalid_key) do
          refute Exception.message(error) =~ invalid_key
        end
      end
    end

    test "stores and decrypts secrets with raw base64 and non-UTF8 raw upstream keys" do
      key_cases = [
        String.duplicate("r", 32),
        Base.encode64(String.duplicate("b", 32)),
        :binary.copy(<<255>>, 32)
      ]

      for key <- key_cases do
        identity = active_identity_fixture()
        plaintext = generated_secret("key-shape")
        configure_upstream_secret_key!(key)

        assert {:ok, _secret} =
                 Upstreams.store_encrypted_secret(identity, %{
                   secret_kind: "access_token",
                   plaintext: plaintext
                 })

        assert {:ok, ^plaintext} = Secrets.decrypt_active_secret(identity, "access_token")
      end
    end

    test "encrypts plaintext upstream secret input and decrypts only through explicit API" do
      identity = active_identity_fixture()
      plaintext = generated_secret("encrypt")
      configure_upstream_secret_key!()

      assert {:ok, secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: plaintext
               })

      persisted = Repo.get!(EncryptedSecret, secret.id)

      assert persisted.key_version == "test-v1"
      assert persisted.aad["algorithm"] == "AES-256-GCM"
      assert persisted.aad["key_env"] == "CODEX_POOLER_UPSTREAM_SECRET_KEY"
      assert persisted.aad["secret_kind"] == "access_token"
      assert persisted.aad["upstream_identity_id"] == identity.id
      assert byte_size(persisted.nonce) == 12
      refute persisted.ciphertext == plaintext
      refute persisted.ciphertext =~ plaintext

      assert {:ok, decrypted} =
               Secrets.decrypt_active_secret(identity, "access_token")

      assert decrypted == plaintext
    end

    test "encrypted plaintext storage preserves superseding behavior" do
      identity = active_identity_fixture()
      configure_upstream_secret_key!()
      first_token = generated_secret("first-refresh")
      second_token = generated_secret("second-refresh")

      assert {:ok, first_secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "refresh_token",
                 plaintext: first_token
               })

      assert {:ok, second_secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "refresh_token",
                 plaintext: second_token
               })

      assert Repo.get!(EncryptedSecret, first_secret.id).status == "superseded"
      assert Repo.get!(EncryptedSecret, second_secret.id).status == "active"

      assert {:ok, decrypted} =
               Secrets.decrypt_active_secret(identity, "refresh_token")

      assert decrypted == second_token
    end

    test "stores ciphertext metadata only and supersedes active secrets of the same kind" do
      identity = active_identity_fixture()

      assert {:ok, first_secret} =
               Upstreams.upsert_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 key_version: "v1",
                 ciphertext: <<1, 2, 3>>,
                 aad: %{"purpose" => "catalog"}
               })

      assert {:ok, second_secret} =
               Upstreams.upsert_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 key_version: "v2",
                 ciphertext: <<4, 5, 6>>,
                 aad: %{"purpose" => "catalog"}
               })

      assert [active_secret] =
               Secrets.list_active_encrypted_secrets(identity)

      assert active_secret.id == second_secret.id
      assert active_secret.ciphertext == <<4, 5, 6>>
      refute active_secret.ciphertext == generated_secret("ciphertext")

      assert Repo.get!(EncryptedSecret, first_secret.id).status == "superseded"
    end

    test "list_active_encrypted_secrets returns an empty list for invalid identity refs" do
      assert Secrets.list_active_encrypted_secrets(nil) == []
      assert Secrets.list_active_encrypted_secrets(%{}) == []
    end
  end

  describe "quota windows" do
    test "list_quota_windows returns an empty list for invalid identity refs" do
      assert QuotaWindows.list_quota_windows(nil) == []
      assert QuotaWindows.list_quota_windows(%{}) == []
    end

    test "list_quota_evidence returns an empty list for invalid identity refs" do
      assert QuotaWindows.list_evidence(nil) == []
      assert QuotaWindows.list_evidence(%{}) == []
    end

    test "builds deterministic pool quota remaining charts from account evidence" do
      now = ~U[2026-05-06 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)
      weekly_reset_at = DateTime.add(now, 604_800, :second)
      pool = pool_fixture(%{name: "Example Pool"})
      empty_pool = pool_fixture(%{name: "Example Empty Pool"})

      %{identity: team_identity, assignment: team_assignment} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-1",
          account_label: "Example Team Account",
          assignment_label: "Example Team Account"
        })

      %{identity: pro_identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-2",
          account_label: "Example Pro Account",
          assignment_label: "Example Pro Account"
        })

      %{identity: weekly_only_identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-weekly-only",
          account_label: "Example Weekly Account",
          assignment_label: "Example Weekly Account"
        })

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(team_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 500,
                   credits: 200,
                   used_percent: Decimal.new("95"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now,
                   metadata: %{"assignment_id" => team_assignment.id}
                 },
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   credits: 75,
                   reset_at: weekly_reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now,
                   metadata: %{"assignment_id" => team_assignment.id}
                 }
               ])

      assert {:ok, _model_window} =
               QuotaWindows.upsert_quota_windows(team_identity, [
                 %{
                   quota_key: "gpt_5_3_codex_spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 100,
                   credits: 90,
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert {:ok, _feature_window} =
               QuotaWindows.upsert_quota_windows(team_identity, [
                 %{
                   quota_key: "feature_limit",
                   window_kind: "primary",
                   window_minutes: 300,
                   credits: 90,
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   quota_scope: "feature",
                   quota_family: "feature_limit",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert {:ok, _upstream_model_window} =
               QuotaWindows.upsert_quota_windows(team_identity, [
                 %{
                   quota_key: "upstream_model_limit",
                   window_kind: "primary",
                   window_minutes: 300,
                   credits: 90,
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   quota_scope: "upstream_model",
                   quota_family: "codex_model",
                   upstream_model: "provider-gpt-5.3-codex-spark",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(pro_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 100,
                   used_percent: Decimal.new("25"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 },
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   active_limit: 1000,
                   credits: 900,
                   reset_at: weekly_reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert {:ok, _weekly_only} =
               QuotaWindows.upsert_quota_windows(weekly_only_identity, [
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   credits: 40,
                   used_percent: Decimal.new("20"),
                   reset_at: weekly_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      missing_pool_id = Ecto.UUID.generate()

      result =
        Quota.Charts.quota_remaining_charts_by_pool_ids(
          [pool.id, empty_pool.id, missing_pool_id, nil, pool.id],
          at: now
        )

      assert Map.keys(result) |> Enum.sort() ==
               [empty_pool.id, missing_pool_id, pool.id] |> Enum.sort()

      assert result[empty_pool.id].primary_5h.state == "empty"
      assert result[missing_pool_id].weekly.state == "empty"

      primary = result[pool.id].primary_5h
      weekly = result[pool.id].weekly

      assert primary.key == :primary_5h
      assert weekly.key == :weekly
      assert primary.title == "5h quota"
      assert weekly.title == "Weekly quota"

      assert Enum.map(primary.items, & &1.label) == [
               "Example Pro Account",
               "Example Team Account"
             ]

      refute Enum.any?(primary.items, &(&1.label == "Example Weekly Account"))

      team_primary = Enum.find(primary.items, &(&1.label == "Example Team Account"))
      assert_decimal_equal(team_primary.remaining, "75")
      assert_decimal_equal(team_primary.capacity, "500")
      assert_decimal_equal(team_primary.used, "425")
      assert_decimal_equal(team_primary.remaining_percent, "15")

      pro_primary = Enum.find(primary.items, &(&1.label == "Example Pro Account"))
      assert_decimal_equal(pro_primary.remaining, "75")
      assert_decimal_equal(pro_primary.capacity, "100")
      assert_decimal_equal(pro_primary.used, "25")
      assert_decimal_equal(pro_primary.remaining_percent, "75")

      assert_decimal_equal(primary.remaining_total, "150")
      assert_decimal_equal(primary.capacity_total, "600")
      assert_decimal_equal(primary.used_total, "450")
      assert_decimal_equal(primary.used_percent, "75")

      assert Enum.map(weekly.items, & &1.label) == [
               "Example Pro Account",
               "Example Team Account",
               "Example Weekly Account"
             ]

      weekly_only = Enum.find(weekly.items, &(&1.label == "Example Weekly Account"))
      assert_decimal_equal(weekly_only.remaining, "40")
      assert_decimal_equal(weekly_only.capacity, "50")
      assert_decimal_equal(weekly_only.remaining_percent, "80")
    end

    test "quota remaining chart items sort by remaining descending before label" do
      now = ~U[2026-05-06 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)
      pool = pool_fixture(%{name: "Example Pool"})

      %{identity: alpha_identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-alpha-sort",
          account_label: "Example Alpha Account",
          assignment_label: "Example Alpha Account"
        })

      %{identity: zulu_identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-zulu-sort",
          account_label: "Example Zulu Account",
          assignment_label: "Example Zulu Account"
        })

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(alpha_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   credits: 10,
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(zulu_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   credits: 90,
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      chart =
        Quota.Charts.quota_remaining_charts_by_pool_ids([pool.id], at: now)[pool.id].primary_5h

      assert Enum.map(chart.items, & &1.label) == [
               "Example Zulu Account",
               "Example Alpha Account"
             ]
    end

    test "quota remaining charts report excluded evidence and unknown capacity safely" do
      now = ~U[2026-05-06 12:00:00Z]
      future_reset = DateTime.add(now, 900, :second)
      stale_observed_at = DateTime.add(now, -Quotas.Evidence.freshness_ttl_seconds() - 1, :second)
      pool = pool_fixture(%{name: "Example Pool"})

      excluded_cases = [
        {"Example Resetless Account", %{observed_at: now}},
        {"Example Stale Account", %{reset_at: future_reset, observed_at: stale_observed_at}},
        {"Example Expired Account",
         %{reset_at: DateTime.add(now, -60, :second), observed_at: now}},
        {"Example Exhausted Account",
         %{reset_at: future_reset, used_percent: Decimal.new("100"), observed_at: now}}
      ]

      for {label, attrs} <- excluded_cases do
        %{identity: identity} =
          upstream_assignment_fixture(pool, %{
            chatgpt_account_id: "acct-#{System.unique_integer([:positive])}",
            account_label: label,
            assignment_label: label
          })

        window =
          Map.merge(
            %{
              window_kind: "primary",
              window_minutes: 300,
              active_limit: 100,
              used_percent: Decimal.new("20"),
              source: "codex_response_headers",
              source_precision: "observed",
              freshness_state: "fresh"
            },
            attrs
          )

        assert {:ok, [_window]} =
                 QuotaWindows.upsert_quota_windows(identity, [window])
      end

      %{identity: unknown_capacity_identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-unknown-capacity",
          account_label: "Example Unknown Capacity Account",
          assignment_label: "Example Unknown Capacity Account"
        })

      %{identity: known_capacity_identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-known-capacity",
          account_label: "Example Known Capacity Account",
          assignment_label: "Example Known Capacity Account"
        })

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(
                 unknown_capacity_identity,
                 [
                   %{
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     credits: 13,
                     reset_at: DateTime.add(now, 604_800, :second),
                     source: "codex_response_headers",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     observed_at: now
                   }
                 ]
               )

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(known_capacity_identity, [
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   active_limit: 100,
                   credits: 90,
                   reset_at: DateTime.add(now, 604_800, :second),
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      charts = Quota.Charts.quota_remaining_charts_by_pool_ids([pool.id], at: now)[pool.id]

      assert charts.primary_5h.items == []
      assert charts.primary_5h.excluded_count == 4
      assert charts.primary_5h.state == "blocked"
      assert charts.primary_5h.excluded_reasons["reset_missing"] == 1
      assert charts.primary_5h.excluded_reasons["not_fresh"] >= 1
      assert charts.primary_5h.excluded_reasons["expired"] == 1
      assert charts.primary_5h.excluded_reasons["exhausted"] == 1

      assert Enum.map(charts.weekly.items, & &1.label) == [
               "Example Known Capacity Account",
               "Example Unknown Capacity Account"
             ]

      unknown_capacity =
        Enum.find(charts.weekly.items, &(&1.label == "Example Unknown Capacity Account"))

      assert unknown_capacity.label == "Example Unknown Capacity Account"
      assert_decimal_equal(unknown_capacity.remaining, "13")
      assert unknown_capacity.capacity == nil
      assert unknown_capacity.remaining_percent == nil
      assert_decimal_equal(charts.weekly.remaining_total, "103")
      assert charts.weekly.capacity_total == nil
      assert charts.weekly.used_total == nil
      assert charts.weekly.used_percent == nil
    end

    test "quota remaining charts keep active-limit-only usage unknown" do
      now = ~U[2026-05-06 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)
      pool = pool_fixture(%{name: "Example Active Limit Only Pool"})

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-active-limit-only",
          account_label: "Example Active Limit Only Account",
          assignment_label: "Example Active Limit Only Account"
        })

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 100,
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      chart =
        Quota.Charts.quota_remaining_charts_by_pool_ids([pool.id], at: now)[pool.id].primary_5h

      assert chart.state == "usable"
      assert [item] = chart.items
      assert item.label == "Example Active Limit Only Account"
      assert item.remaining == nil
      assert_decimal_equal(item.capacity, "100")
      assert item.used == nil
      assert item.remaining_percent == nil
      assert chart.remaining_total == nil
      assert_decimal_equal(chart.capacity_total, "100")
      assert chart.used_total == nil
      assert chart.used_percent == nil
    end

    test "bulk account summaries evaluate the effective windows at the caller's as_of" do
      as_of = DateTime.utc_now() |> DateTime.add(-2 * 3600, :second) |> DateTime.truncate(:second)
      pool = pool_fixture(%{name: "Example As Of Pool"})

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-as-of",
          account_label: "Example As Of Account",
          assignment_label: "Example As Of Account"
        })

      # fresh 5h at as_of; by wall-clock now it is stale and out-synced by the
      # weekly sibling, so only an as_of-aware effective view still sees it
      assert {:ok, _primary} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("20"),
                   reset_at: DateTime.add(as_of, 10_800, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: as_of
                 }
               ])

      assert {:ok, _weekly} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("1"),
                   reset_at: DateTime.add(as_of, 6, :day),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: DateTime.add(as_of, 2 * 3600, :second)
                 }
               ])

      assert [summary] = Quota.ReadModel.account_summaries_for_pool_ids([pool.id], as_of)
      assert summary.state == :available
      assert summary.primary_5h != nil
      assert summary.primary_5h.window_minutes == 300
    end

    test "frozen 5h evidence superseded by fresh weekly stays out of charts and capacity summaries" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      frozen_observed_at = DateTime.add(now, -2 * 3600, :second)
      pool = pool_fixture(%{name: "Example Superseded Chart Pool"})

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-superseded-chart",
          account_label: "Example Superseded Chart Account",
          assignment_label: "Example Superseded Chart Account"
        })

      assert {:ok, _frozen} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("58"),
                   reset_at: DateTime.add(frozen_observed_at, 10_800, :second),
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   last_sync_at: frozen_observed_at,
                   observed_at: frozen_observed_at
                 }
               ])

      assert {:ok, _weekly} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("1"),
                   reset_at: DateTime.add(now, 6, :day),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      charts = Quota.Charts.quota_remaining_charts_by_pool_ids([pool.id], at: now)[pool.id]

      assert charts.primary_5h.evidence_count == 0
      assert charts.primary_5h.excluded_count == 0
      assert charts.primary_5h.items == []
      refute charts.primary_5h.state == "blocked"

      assert charts.weekly.usable_count == 1
      assert charts.weekly.excluded_count == 0

      capacity = Quota.Charts.quota_capacity_summary_by_pool_ids([pool.id])[pool.id]
      assert capacity.window_count == 1
      assert capacity.fresh_window_count == 1
    end

    test "quota remaining charts expose token-backed remaining and preserve exhausted zero" do
      now = ~U[2026-05-06 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)
      pool = pool_fixture(%{name: "Example Token Backed Pool"})

      %{identity: known_identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-token-known",
          account_label: "Example Token Known Account",
          assignment_label: "Example Token Known Account"
        })

      %{identity: exhausted_identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-token-exhausted",
          account_label: "Example Token Exhausted Account",
          assignment_label: "Example Token Exhausted Account"
        })

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(known_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 1000,
                   credits: 250,
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(exhausted_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 1000,
                   credits: 0,
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      chart =
        Quota.Charts.quota_remaining_charts_by_pool_ids([pool.id], at: now)[pool.id].primary_5h

      known_item = Enum.find(chart.items, &(&1.label == "Example Token Known Account"))
      [exhausted_window] = QuotaWindows.list_quota_windows(exhausted_identity)
      exhausted_measurements = Measurements.for_window(exhausted_window)

      assert_decimal_equal(known_item.remaining, "250")
      assert_decimal_equal(known_item.capacity, "1000")
      assert_decimal_equal(exhausted_measurements.remaining, "0")
      assert_decimal_equal(exhausted_measurements.capacity, "1000")
      assert_decimal_equal(chart.remaining_total, "250")
      assert_decimal_equal(chart.capacity_total, "1000")
      assert chart.excluded_count == 1
    end

    test "quota remaining charts keep percent-only partial evidence out of absolute totals" do
      now = ~U[2026-05-06 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)
      pool = pool_fixture(%{name: "Example Percent Only Pool"})

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-percent-only",
          account_label: "Example Percent Only Account",
          assignment_label: "Example Percent Only Account"
        })

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("42"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      chart =
        Quota.Charts.quota_remaining_charts_by_pool_ids([pool.id], at: now)[pool.id].primary_5h

      assert chart.state == "usable"
      assert [item] = chart.items
      assert item.label == "Example Percent Only Account"
      assert item.remaining == nil
      assert item.capacity == nil
      assert item.used == nil
      assert_decimal_equal(item.used_percent, "42")
      assert_decimal_equal(item.remaining_percent, "58")
      assert chart.remaining_total == nil
      assert chart.capacity_total == nil
      assert chart.used_total == nil
      assert chart.used_percent == nil
    end

    test "quota remaining charts treat zero absolute capacity with partial usage as percent-only evidence" do
      now = ~U[2026-05-06 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)
      pool = pool_fixture(%{name: "Example Zero Capacity Percent Pool"})

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-zero-capacity-percent",
          account_label: "Example Zero Capacity Percent Account",
          assignment_label: "Example Zero Capacity Percent Account"
        })

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("9"),
                   reset_at: reset_at,
                   source: "codex_usage",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      chart =
        Quota.Charts.quota_remaining_charts_by_pool_ids([pool.id], at: now)[pool.id].primary_5h

      assert chart.state == "usable"
      assert [item] = chart.items
      assert item.label == "Example Zero Capacity Percent Account"
      assert item.remaining == nil
      assert item.capacity == nil
      assert item.used == nil
      assert_decimal_equal(item.used_percent, "9")
      assert_decimal_equal(item.remaining_percent, "91")
      assert chart.remaining_total == nil
      assert chart.capacity_total == nil
      assert chart.used_total == nil
      assert chart.used_percent == nil
    end

    test "quota remaining charts keep zero percent-only evidence from looking fully available" do
      now = ~U[2026-05-06 12:00:00Z]
      weekly_reset_at = DateTime.add(now, 604_800, :second)
      pool = pool_fixture(%{name: "Example Zero Percent Only Pool"})

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-zero-percent-only",
          account_label: "Example Zero Percent Only Account",
          assignment_label: "Example Zero Percent Only Account"
        })

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("0"),
                   reset_at: weekly_reset_at,
                   source: "codex_rate_limit_event",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      chart = Quota.Charts.quota_remaining_charts_by_pool_ids([pool.id], at: now)[pool.id].weekly

      assert chart.state == "usable"
      assert [item] = chart.items
      assert item.label == "Example Zero Percent Only Account"
      assert item.remaining == nil
      assert item.capacity == nil
      assert item.used == nil
      assert_decimal_equal(item.used_percent, "0")
      assert item.remaining_percent == nil
      assert chart.lowest_remaining_percent == nil
      assert chart.remaining_total == nil
      assert chart.capacity_total == nil
      assert chart.used_total == nil
      assert chart.used_percent == nil
    end

    test "quota remaining charts do not infer capacity from known plan for percent-only evidence" do
      now = ~U[2026-05-06 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)
      weekly_reset_at = DateTime.add(now, 604_800, :second)
      pool = pool_fixture(%{name: "Example Plan Capacity Pool"})

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          plan_family: "pro",
          account_label: "Example Pro Percent Account",
          assignment_label: "Example Pro Percent Account"
        })

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("16"),
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 },
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("61"),
                   reset_at: weekly_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      charts = Quota.Charts.quota_remaining_charts_by_pool_ids([pool.id], at: now)[pool.id]

      assert [primary_item] = charts.primary_5h.items
      assert primary_item.remaining == nil
      assert primary_item.capacity == nil
      assert primary_item.used == nil
      assert_decimal_equal(primary_item.remaining_percent, "84")
      assert_decimal_equal(charts.primary_5h.lowest_remaining_percent, "84")
      assert charts.primary_5h.remaining_total == nil
      assert charts.primary_5h.capacity_total == nil

      assert [weekly_item] = charts.weekly.items
      assert weekly_item.remaining == nil
      assert weekly_item.capacity == nil
      assert weekly_item.used == nil
      assert_decimal_equal(weekly_item.remaining_percent, "39")
      assert_decimal_equal(charts.weekly.lowest_remaining_percent, "39")
      assert charts.weekly.remaining_total == nil
      assert charts.weekly.capacity_total == nil
    end

    test "quota remaining primary chart ignores unusable weekly caps" do
      now = ~U[2026-05-06 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)
      weekly_reset_at = DateTime.add(now, 604_800, :second)
      stale_observed_at = DateTime.add(now, -Quotas.Evidence.freshness_ttl_seconds() - 1, :second)
      pool = pool_fixture(%{name: "Example Pool"})

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          chatgpt_account_id: "acct-example-stale-weekly-cap",
          account_label: "Example Stale Weekly Account",
          assignment_label: "Example Stale Weekly Account"
        })

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 100,
                   credits: 80,
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 },
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   active_limit: 100,
                   credits: 20,
                   reset_at: weekly_reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: stale_observed_at
                 }
               ])

      charts = Quota.Charts.quota_remaining_charts_by_pool_ids([pool.id], at: now)[pool.id]

      assert [primary_item] = charts.primary_5h.items
      assert_decimal_equal(primary_item.remaining, "80")
      assert charts.weekly.items == []
      assert charts.weekly.excluded_count == 1
      assert charts.weekly.excluded_reasons["not_fresh"] == 1
    end

    test "replaces authoritative windows and derives usable selection data" do
      identity = active_identity_fixture()
      future_reset = DateTime.add(DateTime.utc_now(), 300, :second)

      assert {:ok, windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 1,
                   credits: 5,
                   reset_at: future_reset,
                   used_percent: Decimal.new("42.5"),
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 },
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   active_limit: 10,
                   credits: 50,
                   reset_at: future_reset,
                   used_percent: Decimal.new("10"),
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      assert Enum.map(windows, & &1.window_kind) == ["primary", "secondary"]
      assert Enum.map(windows, & &1.quota_key) == ["account", "account"]
      selection = QuotaWindows.quota_window_selection_data(identity)
      assert selection.usable?
      assert selection.primary.window_minutes == 300
      assert Enum.map(selection.fresh_windows, & &1.window_kind) == ["primary", "secondary"]

      assert {:ok, [secondary]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   active_limit: 0,
                   credits: 50,
                   reset_at: future_reset,
                   used_percent: Decimal.new("10"),
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      assert secondary.window_kind == "secondary"

      assert Enum.map(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               & &1.window_kind
             ) == [
               "primary",
               "secondary"
             ]

      assert QuotaWindows.quota_window_selection_data(identity).usable?
    end

    test "stores monthly-only account primary quota without synthetic secondary window" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 13:00:00Z]
      reset_at = DateTime.add(observed_at, 30, :day)

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 monthly_only_account_primary_quota_window_attrs(%{
                   observed_at: observed_at,
                   reset_at: reset_at
                 })
               ])

      assert window.quota_key == "account"
      assert window.quota_scope == "account"
      assert window.quota_family == "account"
      assert window.window_kind == "primary"
      assert window.window_minutes == 43_200
      assert Decimal.equal?(window.used_percent, Decimal.new("42.5"))
      assert window.source == "codex_usage_api"
      assert window.source_precision == "observed"
      assert window.freshness_state == "fresh"
      assert DateTime.compare(window.reset_at, reset_at) == :eq

      assert Enum.map(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               &{&1.quota_key, &1.window_kind, &1.window_minutes}
             ) == [{"account", "primary", 43_200}]
    end

    test "persists monthly-only usage payload as raw account primary evidence" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 13:00:00Z]
      reset_at = DateTime.add(observed_at, 30, :day)

      payload =
        monthly_only_account_primary_quota_payload(%{})
        |> put_in(["rate_limit", "primary_window", "reset_at"], DateTime.to_iso8601(reset_at))

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload,
                 observed_at
               )

      assert window.quota_key == "account"
      assert window.quota_scope == "account"
      assert window.quota_family == "account"
      assert window.window_kind == "primary"
      assert window.window_minutes == 43_200
      assert Decimal.equal?(window.used_percent, Decimal.new("42.5"))
      assert window.source == "codex_usage_api"
      assert window.source_precision == "observed"
      assert window.freshness_state == "fresh"
      assert DateTime.compare(window.reset_at, reset_at) == :eq
      assert DateTime.compare(window.observed_at, observed_at) == :eq
      assert DateTime.compare(window.last_sync_at, observed_at) == :eq
      assert window.active_limit == nil
      assert window.credits == nil
      assert window.metadata["limit_window_seconds"] == 2_592_000

      assert Enum.map(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               &{&1.quota_key, &1.window_kind, &1.window_minutes}
             ) == [{"account", "primary", 43_200}]
    end

    test "preserves unknown long primary usage windows without remapping them" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 13:00:00Z]
      unknown_window_seconds = 1_209_600
      unknown_window_minutes = 20_160
      reset_after_seconds = 1_800

      payload =
        monthly_only_account_primary_quota_payload(%{})
        |> put_in(["rate_limit", "primary_window", "used_percent"], 37.25)
        |> put_in(
          ["rate_limit", "primary_window", "limit_window_seconds"],
          unknown_window_seconds
        )
        |> put_in(
          ["rate_limit", "primary_window", "reset_after_seconds"],
          reset_after_seconds
        )

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload,
                 observed_at
               )

      assert window.quota_key == "account"
      assert window.quota_scope == "account"
      assert window.quota_family == "account"
      assert window.window_kind == "primary"
      assert window.window_minutes == unknown_window_minutes
      refute window.window_minutes in [300, 10_080, 43_200]
      assert Decimal.equal?(window.used_percent, Decimal.from_float(37.25))
      assert window.source == "codex_usage_api"
      assert window.source_precision == "inferred"
      assert window.freshness_state == "fresh"
      assert window.metadata["limit_window_seconds"] == unknown_window_seconds
      assert window.metadata["reset_after_seconds"] == reset_after_seconds

      assert DateTime.compare(
               window.reset_at,
               DateTime.add(observed_at, reset_after_seconds, :second)
             ) == :eq

      assert Enum.map(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               &{&1.quota_key, &1.window_kind, &1.window_minutes}
             ) == [{"account", "primary", unknown_window_minutes}]
    end

    test "stores additional model quota windows alongside account windows" do
      identity = active_identity_fixture()

      assert {:ok, windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("40"),
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 },
                 %{
                   quota_key: "codex_spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("55"),
                   display_label: "GPT-5.3-Codex-Spark",
                   limit_name: "codex_other",
                   metered_feature: "codex_bengalfox",
                   source: "codex_usage_api",
                   freshness_state: "fresh",
                   metadata: %{"limit_window_seconds" => 18_000}
                 }
               ])

      assert Enum.map(windows, &{&1.quota_key, &1.window_kind}) == [
               {"account", "primary"},
               {"codex_spark", "primary"}
             ]

      assert [account, spark] = QuotaWindows.list_quota_windows(identity)
      assert account.quota_key == "account"
      assert spark.quota_key == "codex_spark"
      assert spark.display_label == "GPT-5.3-Codex-Spark"
      assert spark.limit_name == "codex_other"
      assert spark.metered_feature == "codex_bengalfox"
    end

    test "canonical Codex Spark evidence updates historical alias rows instead of duplicating" do
      identity = active_identity_fixture()

      assert {:ok, [historical_alias]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "gpt_5_3_codex_spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("72"),
                   display_label: "GPT-5.3-Codex-Spark",
                   limit_name: "GPT-5.3-Codex-Spark",
                   metered_feature: "codex_bengalfox",
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      assert {:ok, windows} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{"used_percent" => 12, "limit_window_seconds" => 18_000}
                   },
                   "additional_rate_limits" => [
                     %{
                       "limit_name" => "GPT-5.3-Codex-Spark",
                       "metered_feature" => "codex_bengalfox",
                       "rate_limit" => %{
                         "primary_window" => %{
                           "used_percent" => 44,
                           "limit_window_seconds" => 18_000,
                           "reset_after_seconds" => 1_200
                         }
                       }
                     }
                   ]
                 }
               )

      spark = Enum.find(windows, &(&1.quota_key == "codex_spark"))
      refute spark.id == historical_alias.id
      assert Decimal.equal?(spark.used_percent, Decimal.new("44"))

      assert Enum.map(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               &{&1.quota_key, &1.window_kind}
             ) ==
               [
                 {"account", "primary"},
                 {"codex_spark", "primary"},
                 {"codex_spark", "primary"}
               ]
    end

    test "parses Codex usage payload with generic additional model limits" do
      synced_at = ~U[2026-04-27 10:00:00Z]

      assert {:ok, windows} =
               QuotaWindows.codex_usage_quota_windows_from_payload(
                 %{
                   "plan_type" => "free",
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 67,
                       "limit_window_seconds" => 18_000,
                       "reset_after_seconds" => 900
                     },
                     "secondary_window" => %{
                       "used_percent" => 21,
                       "limit_window_seconds" => 604_800,
                       "reset_after_seconds" => 86_400
                     }
                   },
                   "additional_rate_limits" => [
                     %{
                       "limit_name" => "codex_other",
                       "metered_feature" => "codex_bengalfox",
                       "rate_limit" => %{
                         "primary_window" => %{
                           "used_percent" => 55,
                           "limit_window_seconds" => 18_000
                         }
                       }
                     },
                     %{
                       "limit_name" => "GPT-5.3-Codex-Spark",
                       "metered_feature" => "codex_bengalfox",
                       "rate_limit" => %{
                         "primary_window" => %{
                           "used_percent" => 61,
                           "limit_window_seconds" => 18_000
                         }
                       }
                     }
                   ]
                 },
                 synced_at
               )

      assert Enum.map(windows, &{&1.quota_key, &1.window_kind, &1.used_percent}) == [
               {"account", "primary", Decimal.from_float(67.0)},
               {"account", "secondary", Decimal.from_float(21.0)},
               {"codex_spark", "primary", Decimal.from_float(61.0)}
             ]

      account_primary =
        Enum.find(windows, &(&1.quota_key == "account" and &1.window_kind == "primary"))

      assert account_primary.source == "codex_usage_api"
      assert account_primary.source_precision == "inferred"
      assert account_primary.quota_scope == "account"
      assert account_primary.quota_family == "account"
      assert account_primary.observed_at == synced_at
      assert account_primary.active_limit == nil
      assert account_primary.credits == nil

      assert DateTime.compare(account_primary.reset_at, DateTime.add(synced_at, 900, :second)) ==
               :eq

      spark = Enum.find(windows, &(&1.quota_key == "codex_spark"))
      assert spark.display_label == "GPT-5.3-Codex-Spark"
      assert spark.limit_name == "GPT-5.3-Codex-Spark"
      assert spark.metered_feature == "codex_bengalfox"
      assert spark.quota_scope == "model"
      assert spark.quota_family == "codex_model"
      assert spark.model == "gpt-5.3-codex-spark"
      assert spark.raw_limit_id == "codex_bengalfox"
      assert spark.raw_limit_name == "GPT-5.3-Codex-Spark"
      assert spark.raw_metered_feature == "codex_bengalfox"
      assert spark.reset_at == nil
    end

    test "preserves explicit zero credit balances when usage percent still leaves capacity" do
      synced_at = ~U[2026-04-27 10:00:00Z]

      for balance <- ["0", "0.0", 0, 0.0] do
        assert {:ok, windows} =
                 QuotaWindows.codex_usage_quota_windows_from_payload(
                   %{
                     "credits" => %{"balance" => balance},
                     "rate_limit" => %{
                       "primary_window" => %{
                         "used_percent" => 10,
                         "limit_window_seconds" => 18_000,
                         "reset_after_seconds" => 900
                       }
                     }
                   },
                   synced_at
                 )

        assert [account_primary] = windows
        assert account_primary.quota_key == "account"
        assert account_primary.window_kind == "primary"
        assert account_primary.used_percent == Decimal.from_float(10.0)
        assert account_primary.active_limit == 0
        assert account_primary.credits == 0
      end
    end

    test "leaves missing and malformed credit balances unknown" do
      synced_at = ~U[2026-04-27 10:00:00Z]

      for credits <- [
            nil,
            %{},
            %{"balance" => ""},
            %{"balance" => "bad"},
            %{"balance" => -1},
            %{"balance" => -1.0},
            %{"balance" => "-1"},
            %{"balance" => "-0.5"}
          ] do
        payload =
          %{
            "rate_limit" => %{
              "primary_window" => %{
                "used_percent" => 10,
                "limit_window_seconds" => 18_000,
                "reset_after_seconds" => 900
              }
            }
          }
          |> then(fn payload ->
            if is_nil(credits), do: payload, else: Map.put(payload, "credits", credits)
          end)

        assert {:ok, [account_primary]} =
                 QuotaWindows.codex_usage_quota_windows_from_payload(payload, synced_at)

        assert account_primary.active_limit == nil
        assert account_primary.credits == nil
      end
    end

    test "normalizes weekly-only usage as secondary display evidence only" do
      assert {:ok, windows} =
               QuotaWindows.codex_usage_quota_windows_from_payload(%{
                 "rate_limit" => %{
                   "primary_window" => %{
                     "used_percent" => 67,
                     "limit_window_seconds" => 604_800,
                     "reset_after_seconds" => 300
                   }
                 },
                 "additional_rate_limits" => [
                   %{
                     "limit_name" => "codex_other",
                     "rate_limit" => %{
                       "primary_window" => %{
                         "used_percent" => 72,
                         "limit_window_seconds" => 604_800,
                         "reset_after_seconds" => 300
                       }
                     }
                   }
                 ]
               })

      assert Enum.map(windows, &{&1.quota_key, &1.window_kind, &1.window_minutes}) == [
               {"account", "secondary", 10_080},
               {"codex_spark", "secondary", 10_080}
             ]

      assert Enum.all?(windows, &(&1.source_precision == "inferred"))
      assert Enum.all?(windows, &is_nil(&1.reset_at))
      refute Enum.any?(windows, &CodexPooler.Quotas.Evidence.reset_bearing?/1)
      refute Enum.any?(windows, &(&1.window_kind == "primary"))
    end

    test "persists weekly-only usage without inferred 5h rows" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 13:00:00Z]

      assert {:ok, windows} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 weekly_only_payload(%{
                   "additional_rate_limits" => [
                     %{
                       "limit_name" => "GPT-5.3-Codex-Spark",
                       "metered_feature" => "codex_bengalfox",
                       "rate_limit" => %{
                         "primary_window" => %{
                           "used_percent" => 88,
                           "limit_window_seconds" => 604_800,
                           "reset_after_seconds" => 600
                         }
                       }
                     }
                   ]
                 }),
                 observed_at
               )

      weekly = Enum.find(windows, &(&1.quota_key == "account"))
      assert weekly.quota_key == "account"
      assert weekly.window_kind == "secondary"
      assert weekly.window_minutes == 10_080
      assert weekly.source == "codex_usage_api"
      assert weekly.source_precision == "inferred"
      assert weekly.quota_scope == "account"
      assert weekly.quota_family == "account"
      assert weekly.reset_at == nil
      assert DateTime.compare(weekly.observed_at, observed_at) == :eq
      refute QuotaWindows.usable_window?(weekly, observed_at)

      additional_weekly = Enum.find(windows, &(&1.quota_key == "codex_spark"))
      assert additional_weekly.window_kind == "secondary"
      assert additional_weekly.window_minutes == 10_080
      assert additional_weekly.source == "codex_usage_api"
      assert additional_weekly.quota_scope == "model"
      assert additional_weekly.quota_family == "codex_model"
      assert additional_weekly.model == "gpt-5.3-codex-spark"
      assert additional_weekly.raw_limit_id == "codex_bengalfox"
      assert additional_weekly.raw_limit_name == "GPT-5.3-Codex-Spark"
      assert additional_weekly.raw_metered_feature == "codex_bengalfox"

      refute Enum.any?(windows, &(&1.window_kind == "primary"))

      assert Enum.map(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               &{&1.quota_key, &1.window_kind}
             ) ==
               [
                 {"account", "secondary"},
                 {"codex_spark", "secondary"}
               ]
    end

    @tag :quota_reversible_provider_shape
    test "provider 5h weekly-only and restored 5h evidence remains unique and reversible" do
      identity = active_identity_fixture()

      restored_at = DateTime.utc_now() |> DateTime.truncate(:second)
      weekly_at = DateTime.add(restored_at, -60, :second)
      initial_at = DateTime.add(weekly_at, -3_600, :second)

      assert {:ok, initial_windows} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 provider_shape_window_attrs(initial_at, :full)
               )

      assert quota_window_shape(initial_windows) == [
               {"account", "primary", 300},
               {"account", "secondary", 10_080},
               {"codex_spark", "primary", 300},
               {"codex_spark", "secondary", 10_080}
             ]

      assert {:ok, weekly_windows} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 provider_shape_window_attrs(weekly_at, :weekly_only)
               )

      assert quota_window_shape(weekly_windows) == [
               {"account", "secondary", 10_080},
               {"codex_spark", "secondary", 10_080}
             ]

      assert %{routing_state: :weekly_only_probe, selection: weekly_selection} =
               QuotaWindows.routing_quota_eligibility(identity,
                 at: weekly_at,
                 model: "gpt-5.3-codex-spark",
                 requested_model: "gpt-5.3-codex-spark"
               )

      assert quota_window_shape(weekly_selection.routing_windows) == [
               {"account", "secondary", 10_080},
               {"codex_spark", "secondary", 10_080}
             ]

      assert {:ok, _restored_primary_windows} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 provider_shape_window_attrs(restored_at, :primary_only, used_percent: "13")
               )

      restored_windows = QuotaWindows.list_quota_windows(identity)

      assert quota_window_shape(restored_windows) == quota_window_shape(initial_windows)

      assert %{routing_state: :precise, selection: restored_selection} =
               QuotaWindows.routing_quota_eligibility(identity,
                 at: restored_at,
                 model: "gpt-5.3-codex-spark",
                 requested_model: "gpt-5.3-codex-spark"
               )

      assert quota_window_shape(restored_selection.routing_windows) ==
               quota_window_shape(initial_windows)
    end

    test "classifies reset-bearing weekly-only account evidence as probe-routable" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 13:00:00Z]

      reset_at = DateTime.add(observed_at, 600, :second)

      assert {:ok, [_weekly]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 weekly_only_payload(%{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 67,
                       "limit_window_seconds" => 604_800,
                       "reset_at" => DateTime.to_iso8601(reset_at)
                     }
                   }
                 }),
                 observed_at
               )

      assert %{
               eligible?: true,
               routing_state: :weekly_only_probe,
               warnings: [%{code: "quota_account_primary_unknown"}],
               exclusions: []
             } =
               QuotaWindows.routing_quota_eligibility(identity,
                 at: observed_at
               )

      refute Enum.any?(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               &(&1.window_kind == "primary")
             )
    end

    test "honors explicit weekly usage reset_at while ignoring full-window reset_after refreshes" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      explicit_reset_at = DateTime.add(observed_at, 3 * 24 * 60 * 60, :second)

      assert {:ok, [weekly]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 weekly_only_payload(%{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 67,
                       "limit_window_seconds" => 604_800,
                       "reset_after_seconds" => 3 * 24 * 60 * 60,
                       "reset_at" => DateTime.to_iso8601(explicit_reset_at)
                     }
                   }
                 }),
                 observed_at
               )

      assert weekly.window_kind == "secondary"
      assert weekly.window_minutes == 10_080
      assert weekly.source_precision == "observed"
      assert DateTime.compare(weekly.reset_at, explicit_reset_at) == :eq
      assert QuotaWindows.usable_window?(weekly, observed_at)

      refresh_observed_at = DateTime.add(observed_at, 3600, :second)

      assert {:ok, [refreshed]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 weekly_only_payload(%{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 68,
                       "limit_window_seconds" => 604_800,
                       "reset_after_seconds" => 604_800
                     }
                   }
                 }),
                 refresh_observed_at
               )

      assert DateTime.compare(refreshed.reset_at, explicit_reset_at) == :eq
      assert refreshed.source_precision == "observed"
      assert refreshed.used_percent == Decimal.new("67.000")

      assert [stored] = QuotaWindows.list_quota_windows(identity)
      assert DateTime.compare(stored.reset_at, explicit_reset_at) == :eq
      assert stored.source_precision == "observed"
      assert stored.used_percent == Decimal.new("67.000")
    end

    test "does not derive rolling reset_at from weekly usage reset_after_seconds" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 13:00:00Z]

      assert {:ok, [weekly]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 weekly_only_payload(%{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 67,
                       "limit_window_seconds" => 604_800,
                       "reset_after_seconds" => 604_800
                     }
                   }
                 }),
                 observed_at
               )

      assert weekly.window_kind == "secondary"
      assert weekly.window_minutes == 10_080
      assert weekly.source_precision == "inferred"
      assert weekly.reset_at == nil
      refute QuotaWindows.usable_window?(weekly, observed_at)

      refresh_observed_at = DateTime.add(observed_at, 3600, :second)

      assert {:ok, [refreshed]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 weekly_only_payload(%{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 68,
                       "limit_window_seconds" => 604_800,
                       "reset_after_seconds" => 604_800
                     }
                   }
                 }),
                 refresh_observed_at
               )

      assert refreshed.reset_at == nil
      assert refreshed.source_precision == "inferred"
      refute QuotaWindows.usable_window?(refreshed, refresh_observed_at)
    end

    test "preserves non-weekly usage reset_after_seconds as inferred countdowns" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 13:00:00Z]

      assert {:ok, [primary]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 12,
                       "limit_window_seconds" => 18_000,
                       "reset_after_seconds" => 900
                     }
                   }
                 },
                 observed_at
               )

      assert primary.window_kind == "primary"
      assert primary.window_minutes == 300
      assert primary.source_precision == "inferred"
      assert DateTime.compare(primary.reset_at, DateTime.add(observed_at, 900, :second)) == :eq
      assert QuotaWindows.usable_window?(primary, observed_at)
    end

    test "relative usage countdowns do not replace explicit usage reset timestamps" do
      identity = active_identity_fixture()

      observed_at =
        DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)

      explicit_reset_at = DateTime.add(observed_at, 3 * 60 * 60, :second)

      assert {:ok, [primary]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 96,
                       "limit_window_seconds" => 18_000,
                       "reset_at" => DateTime.to_iso8601(explicit_reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert primary.source_precision == "observed"
      assert DateTime.compare(primary.reset_at, explicit_reset_at) == :eq

      refresh_observed_at = DateTime.add(observed_at, 60, :second)

      assert {:ok, [refreshed]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 95,
                       "limit_window_seconds" => 18_000,
                       "reset_after_seconds" => 18_000
                     }
                   }
                 },
                 refresh_observed_at
               )

      assert refreshed.source_precision == "observed"
      assert Decimal.equal?(refreshed.used_percent, Decimal.new("96.000"))
      assert DateTime.compare(refreshed.reset_at, explicit_reset_at) == :eq

      assert [stored] = QuotaWindows.list_quota_windows(identity)
      assert stored.source_precision == "observed"
      assert Decimal.equal?(stored.used_percent, Decimal.new("96.000"))
      assert DateTime.compare(stored.reset_at, explicit_reset_at) == :eq
    end

    test "higher relative usage evidence raises percent without moving explicit reset" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      explicit_reset_at = DateTime.add(observed_at, 3 * 60 * 60, :second)

      assert {:ok, [_primary]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 95,
                       "limit_window_seconds" => 18_000,
                       "reset_at" => DateTime.to_iso8601(explicit_reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert {:ok, [refreshed]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 97,
                       "limit_window_seconds" => 18_000,
                       "reset_after_seconds" => 18_000
                     }
                   }
                 },
                 DateTime.add(observed_at, 60, :second)
               )

      assert refreshed.source_precision == "observed"
      assert Decimal.equal?(refreshed.used_percent, Decimal.new("97.000"))
      assert DateTime.compare(refreshed.reset_at, explicit_reset_at) == :eq
    end

    test "relative model usage reset refreshes do not keep sliding an existing 5h reset" do
      identity = active_identity_fixture()

      observed_at =
        DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)

      first_reset_at = DateTime.add(observed_at, 18_000, :second)

      payload = fn used_percent, reset_at ->
        %{
          "rate_limit" => %{},
          "additional_rate_limits" => [
            %{
              "limit_name" => "GPT-5.3-Codex-Spark",
              "metered_feature" => "codex_bengalfox",
              "rate_limit" => %{
                "primary_window" => %{
                  "used_percent" => used_percent,
                  "limit_window_seconds" => 18_000,
                  "reset_after_seconds" => 18_000,
                  "reset_at" => DateTime.to_iso8601(reset_at)
                }
              }
            }
          ]
        }
      end

      assert {:ok, [primary]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload.(0, first_reset_at),
                 observed_at
               )

      assert primary.quota_key == "codex_spark"
      assert primary.window_kind == "primary"
      assert primary.source_precision == "observed"
      assert DateTime.compare(primary.reset_at, first_reset_at) == :eq

      refresh_at = DateTime.add(observed_at, 60, :second)
      sliding_reset_at = DateTime.add(refresh_at, 18_000, :second)

      assert {:ok, [refreshed]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload.(0, sliding_reset_at),
                 refresh_at
               )

      assert refreshed.source_precision == "observed"
      assert Decimal.equal?(refreshed.used_percent, Decimal.new("0.000"))
      assert DateTime.compare(refreshed.reset_at, first_reset_at) == :eq

      higher_usage_at = DateTime.add(observed_at, 120, :second)
      later_sliding_reset_at = DateTime.add(higher_usage_at, 18_000, :second)

      assert {:ok, [raised]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload.(1, later_sliding_reset_at),
                 higher_usage_at
               )

      assert Decimal.equal?(raised.used_percent, Decimal.new("1.000"))
      assert DateTime.compare(raised.reset_at, first_reset_at) == :eq

      assert [stored] = QuotaWindows.list_quota_windows(identity)
      assert DateTime.compare(stored.reset_at, first_reset_at) == :eq
      assert Decimal.equal?(stored.used_percent, Decimal.new("1.000"))
    end

    test "explicit usage reset corrects older rows derived from relative countdowns" do
      identity = active_identity_fixture()

      observed_at =
        DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)

      bad_relative_reset_at = DateTime.add(observed_at, 5 * 60 * 60, :second)
      explicit_reset_at = DateTime.add(observed_at, 3 * 60 * 60, :second)

      assert {:ok, [_bad_primary]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     quota_scope: "account",
                     quota_family: "account",
                     window_kind: "primary",
                     window_minutes: 300,
                     used_percent: Decimal.new("95"),
                     reset_at: bad_relative_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     metadata: %{
                       "limit_window_seconds" => 18_000,
                       "reset_after_seconds" => 18_000
                     },
                     last_sync_at: observed_at,
                     observed_at: observed_at
                   }
                 ],
                 delete_missing?: false
               )

      assert {:ok, [corrected]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 96,
                       "limit_window_seconds" => 18_000,
                       "reset_at" => DateTime.to_iso8601(explicit_reset_at)
                     }
                   }
                 },
                 DateTime.add(observed_at, 60, :second)
               )

      assert corrected.source_precision == "observed"
      assert Decimal.equal?(corrected.used_percent, Decimal.new("96.000"))
      assert DateTime.compare(corrected.reset_at, explicit_reset_at) == :eq
      refute Map.has_key?(corrected.metadata, "reset_after_seconds")

      assert [stored] = QuotaWindows.list_quota_windows(identity)
      assert DateTime.compare(stored.reset_at, explicit_reset_at) == :eq
      refute Map.has_key?(stored.metadata, "reset_after_seconds")
    end

    test "explicit usage reset corrects capacity-bearing rows derived from relative countdowns" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      bad_relative_reset_at = DateTime.add(observed_at, 28, :day)
      explicit_reset_at = DateTime.add(observed_at, 12, :day)

      assert {:ok, [_bad_primary]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     quota_scope: "account",
                     quota_family: "account",
                     window_kind: "primary",
                     window_minutes: 43_200,
                     active_limit: 4_192,
                     credits: 3_521,
                     used_percent: Decimal.new("16.007"),
                     reset_at: bad_relative_reset_at,
                     source: "codex_usage_api",
                     source_precision: "inferred",
                     freshness_state: "fresh",
                     metadata: %{
                       "limit_window_seconds" => 2_592_000,
                       "reset_after_seconds" => 2_592_000
                     },
                     last_sync_at: observed_at,
                     observed_at: observed_at
                   }
                 ],
                 delete_missing?: false
               )

      assert {:ok, [corrected]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 100,
                       "limit_window_seconds" => 2_592_000,
                       "reset_at" => DateTime.to_iso8601(explicit_reset_at)
                     }
                   }
                 },
                 DateTime.add(observed_at, 60, :second)
               )

      assert corrected.active_limit == 4_192
      assert corrected.credits == 3_521
      assert corrected.source_precision == "observed"
      assert_in_delta Decimal.to_float(corrected.used_percent), 16.006_679, 0.000_001
      assert DateTime.compare(corrected.reset_at, explicit_reset_at) == :eq
      refute Map.has_key?(corrected.metadata, "reset_after_seconds")
    end

    test "weekly-duration account primary evidence folds to the weekly window instead of precise routing" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 13:00:00Z]

      assert {:ok, [_primary]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   window_kind: "primary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("12"),
                   reset_at: DateTime.add(observed_at, 600, :second),
                   source: "codex_response_headers",
                   source_precision: "observed",
                   quota_scope: "account",
                   quota_family: "account",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      selection =
        QuotaWindows.quota_window_selection_data(identity, at: observed_at)

      assert selection.primary == nil
      assert %{window_kind: "secondary", window_minutes: 10_080} = selection.secondary

      assert %{
               eligible?: true,
               routing_state: :weekly_only_probe,
               exclusions: [],
               warnings: [%{code: "quota_account_primary_unknown"}]
             } =
               QuotaWindows.routing_quota_eligibility(identity,
                 at: observed_at
               )
    end

    test "blocks unusable weekly-only evidence from probe routing" do
      observed_at = ~U[2026-04-27 13:00:00Z]
      fresh_reset_at = DateTime.add(observed_at, 600, :second)

      stale_observed_at =
        DateTime.add(observed_at, -Quotas.Evidence.freshness_ttl_seconds() - 1, :second)

      cases = [
        resetless: %{},
        stale: %{reset_at: fresh_reset_at, observed_at: stale_observed_at},
        expired: %{reset_at: DateTime.add(observed_at, -60, :second), observed_at: observed_at},
        exhausted: %{
          reset_at: fresh_reset_at,
          observed_at: observed_at,
          used_percent: Decimal.new("100")
        }
      ]

      Enum.each(cases, fn {_case_name, attrs} ->
        identity = active_identity_fixture()

        window =
          Map.merge(
            %{
              quota_key: "account",
              window_kind: "secondary",
              window_minutes: 10_080,
              used_percent: Decimal.new("12"),
              source: "codex_usage_api",
              source_precision: "inferred",
              quota_scope: "account",
              quota_family: "account",
              freshness_state: "fresh",
              observed_at: observed_at
            },
            attrs
          )

        assert {:ok, [_weekly]} =
                 QuotaWindows.upsert_quota_windows(identity, [window])

        assert %{eligible?: false, routing_state: :blocked} =
                 QuotaWindows.routing_quota_eligibility(identity,
                   at: observed_at
                 )
      end)
    end

    test "persists reset-bearing usage windows with precise evidence dimensions" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 14:00:00Z]
      reset_at = DateTime.add(observed_at, 900, :second)

      assert {:ok, windows} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 12,
                       "limit_window_seconds" => 18_000,
                       "reset_at" => DateTime.to_iso8601(reset_at)
                     },
                     "secondary_window" => %{
                       "used_percent" => 21,
                       "limit_window_seconds" => 604_800,
                       "reset_after_seconds" => 86_400
                     }
                   },
                   "additional_rate_limits" => [
                     %{
                       "limit_name" => "GPT-5.3-Codex-Spark",
                       "metered_feature" => "codex_bengalfox",
                       "rate_limit" => %{
                         "primary_window" => %{
                           "used_percent" => 44,
                           "limit_window_seconds" => 18_000,
                           "reset_after_seconds" => 1_200
                         }
                       }
                     },
                     %{
                       "limit_id" => "future-limit",
                       "rate_limit" => %{
                         "primary_window" => %{
                           "used_percent" => 55,
                           "limit_window_seconds" => 18_000
                         }
                       }
                     }
                   ]
                 },
                 observed_at
               )

      assert Enum.map(windows, &{&1.quota_key, &1.window_kind}) == [
               {"account", "primary"},
               {"account", "secondary"},
               {"codex_spark", "primary"},
               {"future_limit", "primary"}
             ]

      account_primary =
        Enum.find(windows, &(&1.quota_key == "account" and &1.window_kind == "primary"))

      assert account_primary.source == "codex_usage_api"
      assert account_primary.source_precision == "observed"
      assert account_primary.quota_scope == "account"
      assert account_primary.quota_family == "account"
      assert DateTime.compare(account_primary.observed_at, observed_at) == :eq
      assert DateTime.compare(account_primary.reset_at, reset_at) == :eq
      assert QuotaWindows.usable_window?(account_primary, observed_at)

      account_secondary =
        Enum.find(windows, &(&1.quota_key == "account" and &1.window_kind == "secondary"))

      assert account_secondary.window_minutes == 10_080
      assert account_secondary.source_precision == "inferred"
      assert account_secondary.reset_at == nil
      refute QuotaWindows.usable_window?(account_secondary, observed_at)

      model_window = Enum.find(windows, &(&1.quota_key == "codex_spark"))
      assert model_window.source == "codex_usage_api"
      assert model_window.source_precision == "inferred"
      assert model_window.quota_scope == "model"
      assert model_window.quota_family == "codex_model"
      assert model_window.model == "gpt-5.3-codex-spark"
      assert model_window.raw_limit_id == "codex_bengalfox"
      assert model_window.raw_limit_name == "GPT-5.3-Codex-Spark"
      assert model_window.raw_metered_feature == "codex_bengalfox"
      assert DateTime.compare(model_window.observed_at, observed_at) == :eq

      assert DateTime.compare(model_window.reset_at, DateTime.add(observed_at, 1_200, :second)) ==
               :eq

      assert QuotaWindows.usable_window?(model_window, observed_at)

      resetless_future = Enum.find(windows, &(&1.quota_key == "future_limit"))
      assert resetless_future.source_precision == "inferred"
      assert resetless_future.quota_scope == "feature"
      assert resetless_future.quota_family == "future_limit"
      assert resetless_future.raw_limit_id == "future-limit"
      assert resetless_future.reset_at == nil
      refute QuotaWindows.usable_window?(resetless_future, observed_at)
    end

    test "quota windows without reset timestamps are not usable for routing" do
      identity = active_identity_fixture()

      assert {:ok, [primary]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("12"),
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      assert QuotaWindows.fresh_window?(primary)
      refute QuotaWindows.usable_window?(primary)
      refute QuotaWindows.quota_window_selection_data(identity).usable?
    end

    test "continues past weekly-only wham responses to refresh 5h quota from backend Codex fallback" do
      primary_payload = %{
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => "12",
            "limit_window_seconds" => 18_000,
            "reset_after_seconds" => 900
          },
          "secondary_window" => %{"used_percent" => 34, "limit_window_seconds" => 604_800}
        }
      }

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {200, weekly_only_payload()},
          "/backend-api/codex/usage" => {200, primary_payload}
        })

      pool = pool_fixture()

      identity =
        active_identity_fixture(%{
          chatgpt_account_id: "acct_usage_paths",
          metadata: %{"base_url" => FakeUpstream.url(upstream)}
        })

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, assignment} =
               PoolAssignments.activate_pool_assignment(assignment)

      configure_upstream_secret_key!()

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: generated_secret("usage-path")
               })

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded

      assert Enum.map(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               &{&1.window_kind, &1.used_percent}
             ) ==
               [
                 {"primary", Decimal.new("12.000")},
                 {"secondary", Decimal.new("34.000")}
               ]

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    @tag :quota_probe_envelope
    test "default ChatGPT probing keeps wham first and falls back to Codex after a 404" do
      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {404, %{}},
          "/backend-api/codex/usage" => {200, reset_bearing_account_primary_payload()}
        })

      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)

      assert {:ok, %UsageProbe.Result{usage_path: "/backend-api/codex/usage"}} =
               UsageProbe.fetch_from_identity(
                 identity,
                 assignment,
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 []
               )

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    @tag :quota_probe_envelope
    test "configured Codex usage paths remain Codex first while retaining wham fallback" do
      upstream =
        start_path_upstream(%{
          "/backend-api/codex/usage" => {200, weekly_only_payload()},
          "/backend-api/wham/usage" => {200, reset_bearing_account_primary_payload()}
        })

      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)

      assert {:ok, assignment} =
               PoolAssignments.update_pool_assignment(assignment, %{
                 metadata: %{"usage_path" => "/backend-api/codex/usage"}
               })

      assert {:ok, %UsageProbe.Result{usage_path: "/backend-api/wham/usage"}} =
               UsageProbe.fetch_from_identity(
                 identity,
                 assignment,
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 []
               )

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/codex/usage",
               "/api/codex/usage",
               "/backend-api/wham/usage"
             ]
    end

    @tag :quota_probe_envelope
    test "malformed wham data continues to the Codex fallback" do
      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => FakeUpstream.malformed_json(),
          "/backend-api/codex/usage" => {200, reset_bearing_account_primary_payload()}
        })

      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)

      assert {:ok, %UsageProbe.Result{usage_path: "/backend-api/codex/usage"}} =
               UsageProbe.fetch_from_identity(
                 identity,
                 assignment,
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 []
               )

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "provider usage refresh updates reported plan metadata" do
      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {200,
             %{
               "plan_type" => "Team",
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 12,
                   "limit_window_seconds" => 18_000,
                   "reset_after_seconds" => 900
                 }
               }
             }}
        })

      pool = pool_fixture()

      identity =
        active_identity_fixture(%{
          chatgpt_account_id: "acct_plan_refresh",
          metadata: %{"base_url" => FakeUpstream.url(upstream)}
        })

      assert {:ok, identity} =
               IdentityLifecycle.activate_upstream_identity_with_plan(
                 identity,
                 %{
                   plan_label: "Free",
                   plan_family: "free"
                 }
               )

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, assignment} =
               PoolAssignments.activate_pool_assignment(assignment)

      configure_upstream_secret_key!()

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: generated_secret("plan-refresh")
               })

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

      reloaded = Repo.get!(UpstreamIdentity, identity.id)
      assert reloaded.plan_label == "Team"
      assert reloaded.plan_family == "team"
    end

    test "continues usage probing when an earlier 200 response is weekly-only" do
      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {200,
             weekly_only_payload(%{
               "additional_rate_limits" => [
                 %{
                   "limit_name" => "GPT-5.3-Codex-Spark",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 88,
                       "limit_window_seconds" => 604_800,
                       "reset_after_seconds" => 1_200
                     }
                   }
                 }
               ]
             })},
          "/backend-api/codex/usage" =>
            {200,
             %{
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 15,
                   "limit_window_seconds" => 18_000,
                   "reset_after_seconds" => 900
                 },
                 "secondary_window" => %{"used_percent" => 67, "limit_window_seconds" => 604_800}
               }
             }}
        })

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded

      windows = QuotaWindows.list_quota_windows(identity)

      account_primary =
        Enum.find(windows, &(&1.quota_key == "account" and &1.window_kind == "primary"))

      account_secondary =
        Enum.find(windows, &(&1.quota_key == "account" and &1.window_kind == "secondary"))

      assert account_primary.window_minutes == 300
      assert account_primary.used_percent == Decimal.new("15.000")
      assert account_primary.source_precision == "inferred"
      assert QuotaWindows.usable_window?(account_primary)

      assert account_secondary.window_minutes == 10_080
      assert account_secondary.used_percent == Decimal.new("67.000")

      additional_secondary =
        Enum.find(
          windows,
          &(&1.quota_key == "codex_spark" and &1.window_kind == "secondary")
        )

      assert additional_secondary.window_minutes == 10_080
      assert additional_secondary.used_percent == Decimal.new("88.000")
      assert additional_secondary.quota_scope == "model"
      assert additional_secondary.raw_limit_id == "codex_bengalfox"

      refute Enum.any?(
               windows,
               &(&1.quota_key == "codex_spark" and &1.window_kind == "primary")
             )

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "reconciliation clears stale additional 5h rows when current usage reports weekly-only" do
      stale_reset_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {200,
             weekly_only_payload(%{
               "additional_rate_limits" => [
                 %{
                   "limit_name" => "GPT-5.3-Codex-Spark",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 0,
                       "limit_window_seconds" => 604_800,
                       "reset_after_seconds" => 604_800
                     }
                   }
                 }
               ]
             })}
        })

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      assert {:ok, [_stale_primary]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "codex_spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("100"),
                   reset_at: stale_reset_at,
                   display_label: "GPT-5.3-Codex-Spark",
                   limit_name: "GPT-5.3-Codex-Spark",
                   metered_feature: "codex_bengalfox",
                   source: "codex_usage_api",
                   source_precision: "observed",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   raw_limit_id: "codex_bengalfox",
                   raw_limit_name: "GPT-5.3-Codex-Spark",
                   raw_metered_feature: "codex_bengalfox",
                   freshness_state: "fresh"
                 }
               ])

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded

      windows = QuotaWindows.list_quota_windows(identity)

      refute Enum.any?(
               windows,
               &(&1.quota_key == "codex_spark" and &1.window_kind == "primary")
             )

      assert %Quota.AccountQuotaWindow{} =
               Enum.find(
                 windows,
                 &(&1.quota_key == "codex_spark" and &1.window_kind == "secondary")
               )
    end

    @tag :quota_descriptor_coverage
    test "weekly-only coverage removes only the absent variant in its exact provider descriptor" do
      payload =
        weekly_only_payload(%{
          "additional_rate_limits" => [descriptor_weekly_limit("Provider limit alpha")]
        })

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {200, payload},
          "/backend-api/codex/usage" => {404, %{}}
        })

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      stale_at = DateTime.add(observed_at, -600, :second)

      alpha =
        persist_descriptor_primary!(identity, stale_at, "Provider limit alpha", "codex_usage_api",
          freshness_state: "stale",
          reset_at: DateTime.add(observed_at, -60, :second)
        )

      beta =
        persist_descriptor_primary!(
          identity,
          observed_at,
          "Provider limit alpha",
          "codex_usage_api",
          "omitted_meter"
        )

      runtime_rows =
        for source <- [
              "codex_response_headers",
              "codex_rate_limit_event",
              "codex_rate_limit_error"
            ] do
          persist_descriptor_primary!(identity, observed_at, "Provider limit alpha", source)
        end

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

      persisted = QuotaWindows.list_evidence(identity)
      refute Enum.any?(persisted, &(&1.id == alpha.id))
      assert Enum.any?(persisted, &(&1.id == beta.id))

      assert Enum.all?(runtime_rows, fn runtime ->
               Enum.any?(persisted, &(&1.id == runtime.id))
             end)

      assert Enum.all?(persisted, &(&1.upstream_identity_id == identity.id))
    end

    @tag :quota_descriptor_coverage
    test "a valid additional descriptor deletes its absent variant while a malformed sibling is preserved" do
      payload = %{
        "additional_rate_limits" => [
          descriptor_weekly_limit("Provider limit alpha"),
          %{
            "limit_name" => "Provider limit beta",
            "metered_feature" => "beta_meter",
            "rate_limit" => %{
              "primary_window" => %{
                "used_percent" => "malformed",
                "limit_window_seconds" => 18_000
              },
              "secondary_window" => %{
                "used_percent" => 34,
                "limit_window_seconds" => 604_800
              }
            }
          }
        ]
      }

      upstream = start_path_upstream(%{"/backend-api/wham/usage" => {200, payload}})

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      valid_primary =
        persist_descriptor_primary!(identity, observed_at, "Provider limit alpha")

      malformed_primary =
        persist_descriptor_primary!(
          identity,
          observed_at,
          "Provider limit beta",
          "codex_usage_api",
          "beta_meter"
        )

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

      persisted = QuotaWindows.list_evidence(identity)
      refute Enum.any?(persisted, &(&1.id == valid_primary.id))
      assert Enum.any?(persisted, &(&1.id == malformed_primary.id))
    end

    for {label, descriptor} <- [
          {:unknown_only, %{"future_window" => %{"value" => 1}}},
          {:empty, %{}},
          {:no_supported_fields, %{"status" => "available", "limit" => 10}}
        ] do
      @tag :quota_descriptor_coverage
      test "#{label} live descriptor contributes zero deletion coverage" do
        upstream =
          start_path_upstream(%{
            "/backend-api/wham/usage" =>
              {200,
               %{
                 "additional_rate_limits" => [
                   %{
                     "limit_name" => "Provider limit alpha",
                     "metered_feature" => "example_meter",
                     "rate_limit" => unquote(Macro.escape(descriptor))
                   }
                 ]
               }}
          })

        %{identity: identity, pool: pool, assignment: assignment} =
          usage_assignment_fixture(upstream)

        existing =
          persist_descriptor_primary!(
            identity,
            DateTime.utc_now() |> DateTime.truncate(:second),
            "Provider limit alpha"
          )

        assert {:ok, _result} = Upstreams.reconcile_pool_account(pool, assignment)
        assert Enum.any?(QuotaWindows.list_evidence(identity), &(&1.id == existing.id))
      end
    end

    @tag :quota_descriptor_coverage
    test "unknown future fields do not reduce otherwise valid supported descriptor coverage" do
      descriptor =
        descriptor_weekly_limit("Provider limit alpha")
        |> put_in(["rate_limit", "future_window"], %{"value" => 1})

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {200, weekly_only_payload(%{"additional_rate_limits" => [descriptor]})}
        })

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      existing =
        persist_descriptor_primary!(
          identity,
          DateTime.utc_now() |> DateTime.truncate(:second),
          "Provider limit alpha"
        )

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)
      refute Enum.any?(QuotaWindows.list_evidence(identity), &(&1.id == existing.id))
    end

    @tag :quota_descriptor_coverage
    test "metadata option auth and empty inputs carry zero affected descriptor coverage" do
      for mode <- [:metadata, :option, :auth, :empty] do
        upstream =
          start_path_upstream(%{
            "/backend-api/wham/usage" => {200, %{}},
            "/backend-api/codex/usage" => {200, %{}}
          })

        %{identity: identity, pool: pool, assignment: assignment} =
          usage_assignment_fixture(upstream)

        existing =
          persist_descriptor_primary!(
            identity,
            DateTime.utc_now() |> DateTime.truncate(:second),
            "Provider limit alpha"
          )

        {identity, assignment, opts} =
          configure_descriptor_zero_coverage_mode(mode, identity, assignment, existing)

        if mode == :auth do
          Repo.delete_all(
            from(secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id)
          )
        end

        assert {:ok, _result} = Upstreams.reconcile_pool_account(pool, assignment, opts)
        assert Enum.any?(QuotaWindows.list_evidence(identity), &(&1.id == existing.id))
      end
    end

    @tag :quota_descriptor_coverage
    test "a timed out live probe carries zero descriptor coverage" do
      release_ref = make_ref()

      {:ok, upstream} =
        FakeUpstream.start_link(
          {:sequence,
           [
             {:timeout_before_headers, self(), release_ref},
             FakeUpstream.json_response(%{"error" => "unavailable"}, 503)
           ]}
        )

      on_exit(fn -> FakeUpstream.stop(upstream) end)

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      existing =
        persist_descriptor_primary!(
          identity,
          DateTime.utc_now() |> DateTime.truncate(:second),
          "Provider limit alpha"
        )

      parent = self()

      task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Upstreams.reconcile_pool_account(pool, assignment, receive_timeout: 1)
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid, ^release_ref}
      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
      assert {:ok, _result} = Task.await(task)
      assert Enum.any?(QuotaWindows.list_evidence(identity), &(&1.id == existing.id))
    end

    @tag :quota_descriptor_coverage
    test "multi-path descriptor coverage is a union and omitted colliding descriptors survive" do
      alpha_payload =
        weekly_only_payload(%{
          "additional_rate_limits" => [descriptor_weekly_limit("Provider limit alpha")]
        })

      gamma_payload = %{
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 12,
            "limit_window_seconds" => 18_000,
            "reset_after_seconds" => 900
          }
        },
        "additional_rate_limits" => [descriptor_weekly_limit("Provider limit gamma")]
      }

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {200, alpha_payload},
          "/backend-api/codex/usage" => {200, gamma_payload}
        })

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      alpha = persist_descriptor_primary!(identity, observed_at, "Provider limit alpha")

      beta =
        persist_descriptor_primary!(
          identity,
          observed_at,
          "Provider limit alpha",
          "codex_usage_api",
          "omitted_meter"
        )

      gamma = persist_descriptor_primary!(identity, observed_at, "Provider limit gamma")

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

      persisted = QuotaWindows.list_evidence(identity)
      refute Enum.any?(persisted, &(&1.id in [alpha.id, gamma.id]))
      assert Enum.any?(persisted, &(&1.id == beta.id))

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    @tag :quota_probe_envelope
    test "usage probe merges rich windows and unions safe descriptor coverage across live paths" do
      alpha_payload =
        weekly_only_payload(%{
          "additional_rate_limits" => [descriptor_weekly_limit("Provider limit alpha")]
        })

      beta_payload =
        weekly_only_payload(%{
          "additional_rate_limits" => [descriptor_weekly_limit("Provider limit beta")]
        })

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {200, alpha_payload},
          "/backend-api/codex/usage" => {200, beta_payload}
        })

      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, probe} =
               UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

      assert %UsageProbe.Result{
               usage_path: "/backend-api/wham/usage",
               windows: windows,
               covered_descriptors: covered_descriptors
             } = probe

      assert Enum.map(windows, &Quotas.Evidence.identity_key/1) |> Enum.uniq() |> length() ==
               length(windows)

      assert Enum.count(windows, &(&1.window_kind == "secondary")) == 3
      assert MapSet.size(covered_descriptors) == 3

      assert Enum.all?(
               covered_descriptors,
               &match?({_, _, _, _, _, "codex_usage_api", _, _, _}, &1)
             )
    end

    @tag :quota_probe_envelope
    test "rich legacy collisions survive path merging by exact evidence identity" do
      first_payload =
        weekly_only_payload(%{
          "additional_rate_limits" => [descriptor_weekly_limit("Provider limit")]
        })

      second_payload = %{
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 12,
            "limit_window_seconds" => 18_000,
            "reset_after_seconds" => 900
          }
        },
        "additional_rate_limits" => [
          descriptor_weekly_limit("Provider limit")
          |> Map.put("metered_feature", "example_meter_beta")
        ]
      }

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {200, first_payload},
          "/backend-api/codex/usage" => {200, second_payload}
        })

      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)

      assert {:ok, %UsageProbe.Result{windows: windows}} =
               UsageProbe.fetch_from_identity(
                 identity,
                 assignment,
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 []
               )

      model_windows = Enum.filter(windows, &(&1.quota_scope == "model"))
      assert length(model_windows) == 2

      assert model_windows
             |> MapSet.new(&{&1.quota_key, &1.window_kind, &1.window_minutes})
             |> MapSet.size() == 1

      identity_keys_by_raw_limit =
        Map.new(model_windows, &{&1.raw_limit_id, Quotas.Evidence.identity_key(&1)})

      assert MapSet.new(Map.keys(identity_keys_by_raw_limit)) ==
               MapSet.new(["example_meter", "example_meter_beta"])

      assert MapSet.size(MapSet.new(Map.values(identity_keys_by_raw_limit))) == 2
      assert elem(identity_keys_by_raw_limit["example_meter"], 8) == "example_meter"
      assert elem(identity_keys_by_raw_limit["example_meter_beta"], 8) == "example_meter_beta"

      assert MapSet.new(model_windows, & &1.raw_limit_id) ==
               MapSet.new(["example_meter", "example_meter_beta"])

      assert Enum.all?(model_windows, &(&1.model == "Provider limit"))

      assert Enum.all?(model_windows, &(&1.window_kind == "secondary"))
      assert Enum.all?(model_windows, &(&1.window_minutes == 10_080))
    end

    @tag :quota_probe_envelope
    test "duplicate rich identities keep preferred endpoint payload path and window coherent" do
      previous_payload =
        weekly_only_payload(%{
          "rate_limit" => %{
            "secondary_window" => %{
              "used_percent" => 31,
              "limit_window_seconds" => 604_800,
              "reset_after_seconds" => 3_600
            }
          }
        })

      current_payload = %{
        "plan_type" => "preferred-plan",
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 12,
            "limit_window_seconds" => 18_000,
            "reset_after_seconds" => 900
          },
          "secondary_window" => %{
            "used_percent" => 47,
            "limit_window_seconds" => 604_800,
            "reset_after_seconds" => 3_600
          }
        }
      }

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {200, previous_payload},
          "/backend-api/codex/usage" => {200, current_payload}
        })

      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)

      assert {:ok,
              %UsageProbe.Result{
                payload: ^current_payload,
                usage_path: "/backend-api/codex/usage",
                windows: windows
              }} =
               UsageProbe.fetch_from_identity(
                 identity,
                 assignment,
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 []
               )

      assert %{used_percent: used_percent} =
               Enum.find(windows, &(&1.quota_key == "account" and &1.window_kind == "secondary"))

      assert Decimal.equal?(used_percent, Decimal.new("47"))
    end

    @tag :quota_probe_envelope
    test "metadata and explicit option windows bypass live probing" do
      for mode <- [:metadata, :option] do
        upstream = start_path_upstream(%{"/backend-api/wham/usage" => {500, %{}}})

        %{identity: identity, pool: pool, assignment: assignment} =
          usage_assignment_fixture(upstream)

        window =
          rich_identity_attrs(DateTime.utc_now() |> DateTime.truncate(:second), %{
            source: "local_reconciliation"
          })

        {identity, opts} =
          case mode do
            :metadata ->
              assert {:ok, updated_identity} =
                       IdentityLifecycle.update_upstream_identity(identity, %{
                         metadata: Map.put(identity.metadata, "quota_windows", [window])
                       })

              {updated_identity, []}

            :option ->
              {identity, [quota_windows: [window]]}
          end

        assert {:ok, %{quota: %{status: :succeeded}}} =
                 Upstreams.reconcile_pool_account(pool, assignment, opts)

        assert FakeUpstream.requests(upstream) == []
        assert Enum.all?(QuotaWindows.list_evidence(identity), &(&1.source != "codex_usage_api"))
      end
    end

    @tag :quota_probe_envelope
    test "usable account primary halts before later paths and covers only observed descriptors" do
      payload = %{
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 12,
            "limit_window_seconds" => 18_000,
            "reset_after_seconds" => 900
          }
        }
      }

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {200, payload},
          "/backend-api/codex/usage" =>
            {200,
             weekly_only_payload(%{
               "additional_rate_limits" => [descriptor_weekly_limit("Unobserved limit")]
             })}
        })

      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)

      assert {:ok, %UsageProbe.Result{covered_descriptors: covered}} =
               UsageProbe.fetch_from_identity(
                 identity,
                 assignment,
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 []
               )

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage"
             ]

      assert MapSet.size(covered) == 1
      assert Enum.all?(covered, fn descriptor -> elem(descriptor, 4) == "account" end)
    end

    @tag :quota_probe_envelope
    test "weekly-primary first path still falls through to a later path carrying the 5h window" do
      weekly_reset_at = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

      weekly_primary_payload = %{
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 42,
            "limit_window_seconds" => 604_800,
            "reset_at" => DateTime.to_unix(weekly_reset_at)
          }
        }
      }

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {200, weekly_primary_payload},
          "/backend-api/codex/usage" => {200, reset_bearing_account_primary_payload()}
        })

      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)

      assert {:ok, %UsageProbe.Result{windows: windows}} =
               UsageProbe.fetch_from_identity(
                 identity,
                 assignment,
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 []
               )

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]

      assert Enum.any?(
               windows,
               &(&1.quota_key == "account" and &1.window_kind == "primary" and
                   &1.window_minutes == 300 and match?(%DateTime{}, &1.reset_at))
             )

      assert Enum.any?(
               windows,
               &(&1.quota_key == "account" and &1.window_kind == "secondary" and
                   &1.window_minutes == 10_080)
             )
    end

    @tag :quota_probe_envelope
    test "weekly-primary reconciliation deletes the vanished usage-sourced 5h primary row" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(observed_at, 3, :day)

      payload = %{
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 42,
            "limit_window_seconds" => 604_800,
            "reset_at" => DateTime.to_unix(reset_at)
          }
        }
      }

      upstream = start_path_upstream(%{"/backend-api/wham/usage" => {200, payload}})

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      stale_observed_at = DateTime.add(observed_at, -2 * 3600, :second)

      assert {:ok, [_stale_primary]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("55"),
                   reset_at: DateTime.add(stale_observed_at, -900, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   quota_scope: "account",
                   quota_family: "account",
                   freshness_state: "fresh",
                   observed_at: stale_observed_at
                 }
               ])

      assert {:ok, %{quota: %{status: :succeeded}}} =
               Upstreams.reconcile_pool_account(pool, assignment, [])

      # assert on raw persistence: the read-side effective view would hide a
      # superseded 5h row whether or not delete-missing actually removed it
      raw_windows = QuotaWindows.list_evidence(identity)

      refute Enum.any?(
               raw_windows,
               &(&1.window_kind == "primary" and &1.window_minutes == 300 and
                   &1.source == "codex_usage_api")
             )

      assert Enum.any?(
               raw_windows,
               &(&1.quota_key == "account" and &1.window_kind == "secondary" and
                   &1.window_minutes == 10_080)
             )
    end

    @tag :quota_probe_envelope
    test "malformed present primary leaves a valid secondary descriptor uncovered" do
      payload = %{
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => "malformed",
            "limit_window_seconds" => 18_000
          },
          "secondary_window" => %{
            "used_percent" => 34,
            "limit_window_seconds" => 604_800,
            "reset_after_seconds" => 3_600
          }
        }
      }

      upstream = start_path_upstream(%{"/backend-api/wham/usage" => {200, payload}})
      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)

      assert {:ok, %UsageProbe.Result{windows: [window], covered_descriptors: covered}} =
               UsageProbe.fetch_from_identity(
                 identity,
                 assignment,
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 []
               )

      assert window.window_kind == "secondary"
      assert MapSet.size(covered) == 0
    end

    @tag :quota_probe_envelope
    test "unsupported live descriptors contribute no probe coverage" do
      payload =
        weekly_only_payload(%{
          "additional_rate_limits" => [
            %{
              "limit_name" => "Provider limit alpha",
              "metered_feature" => "alpha_meter",
              "rate_limit" => %{"future_window" => %{"value" => 1}}
            }
          ]
        })

      upstream = start_path_upstream(%{"/backend-api/wham/usage" => {200, payload}})
      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)

      assert {:ok, %UsageProbe.Result{covered_descriptors: covered_descriptors}} =
               UsageProbe.fetch_from_identity(
                 identity,
                 assignment,
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 []
               )

      assert MapSet.size(covered_descriptors) == 1
      assert Enum.all?(covered_descriptors, fn descriptor -> elem(descriptor, 4) == "account" end)
    end

    @tag :quota_probe_envelope
    test "failed probes preserve sanitized errors without exposing request credentials or bodies" do
      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {503, %{"private_payload" => "must-not-leak"}}
        })

      %{identity: identity, assignment: assignment} = usage_assignment_fixture(upstream)

      assert {:error, reason} =
               UsageProbe.fetch_from_identity(
                 identity,
                 assignment,
                 DateTime.utc_now() |> DateTime.truncate(:second),
                 []
               )

      inspected = inspect(reason)
      assert reason == {:upstream_status, 503}
      refute inspected =~ "must-not-leak"
      refute inspected =~ "authorization"
      refute inspected =~ "cookie"
    end

    @tag :quota_descriptor_coverage
    test "a successful live path contributes coverage while a failed sibling path contributes none" do
      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {200,
             weekly_only_payload(%{
               "additional_rate_limits" => [descriptor_weekly_limit("Provider limit alpha")]
             })},
          "/backend-api/codex/usage" => {503, %{"error" => "unavailable"}}
        })

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      covered = persist_descriptor_primary!(identity, observed_at, "Provider limit alpha")
      failed_path = persist_descriptor_primary!(identity, observed_at, "Provider limit beta")

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

      persisted = QuotaWindows.list_evidence(identity)
      refute Enum.any?(persisted, &(&1.id == covered.id))
      assert Enum.any?(persisted, &(&1.id == failed_path.id))

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "refreshes reset-bearing quota from backend Codex usage fallback" do
      observed_start = DateTime.utc_now() |> DateTime.truncate(:second)

      upstream =
        start_path_upstream(%{
          "/backend-api/codex/usage" =>
            {200,
             %{
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 15,
                   "limit_window_seconds" => 18_000,
                   "reset_after_seconds" => 900
                 }
               },
               "additional_rate_limits" => [
                 %{
                   "limit_name" => "GPT-5.3-Codex-Spark",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 45,
                       "limit_window_seconds" => 18_000,
                       "reset_after_seconds" => 1_200
                     }
                   }
                 }
               ]
             }}
        })

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded

      assert Enum.map(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               &{&1.quota_key, &1.window_kind}
             ) ==
               [
                 {"account", "primary"},
                 {"codex_spark", "primary"}
               ]

      [account_primary, model_primary] =
        QuotaWindows.list_quota_windows(identity)

      assert account_primary.source == "codex_usage_api"
      assert account_primary.source_precision == "inferred"
      assert account_primary.quota_scope == "account"
      assert account_primary.quota_family == "account"
      assert DateTime.compare(account_primary.reset_at, observed_start) == :gt
      assert QuotaWindows.usable_window?(account_primary)

      assert model_primary.quota_scope == "model"
      assert model_primary.quota_family == "codex_model"
      assert model_primary.model == "gpt-5.3-codex-spark"
      assert model_primary.raw_limit_id == "codex_bengalfox"
      assert model_primary.raw_limit_name == "GPT-5.3-Codex-Spark"
      assert model_primary.raw_metered_feature == "codex_bengalfox"
      assert DateTime.compare(model_primary.reset_at, observed_start) == :gt
      assert QuotaWindows.usable_window?(model_primary)

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "refreshes backend wham weekly-only usage without creating primary rows" do
      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {200,
             weekly_only_payload(%{
               "additional_rate_limits" => [
                 %{
                   "limit_name" => "GPT-5.3-Codex-Spark",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 45,
                       "limit_window_seconds" => 604_800,
                       "reset_after_seconds" => 1_200
                     }
                   }
                 }
               ]
             })}
        })

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded

      windows = QuotaWindows.list_quota_windows(identity)

      weekly = Enum.find(windows, &(&1.quota_key == "account"))
      assert weekly.quota_key == "account"
      assert weekly.window_kind == "secondary"
      assert weekly.window_minutes == 10_080
      assert weekly.source == "codex_usage_api"
      assert weekly.quota_scope == "account"
      assert weekly.quota_family == "account"
      refute QuotaWindows.usable_window?(weekly)

      additional_weekly = Enum.find(windows, &(&1.quota_key == "codex_spark"))
      assert additional_weekly.window_kind == "secondary"
      assert additional_weekly.window_minutes == 10_080
      assert additional_weekly.source == "codex_usage_api"
      assert additional_weekly.quota_scope == "model"
      assert additional_weekly.quota_family == "codex_model"
      assert additional_weekly.model == "gpt-5.3-codex-spark"
      assert additional_weekly.raw_limit_id == "codex_bengalfox"
      assert additional_weekly.raw_limit_name == "GPT-5.3-Codex-Spark"
      assert additional_weekly.raw_metered_feature == "codex_bengalfox"

      refute Enum.any?(windows, &(&1.window_kind == "primary"))

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "falls back to backend wham usage when Codex usage paths return HTML 403" do
      html_403 = "<!doctype html><html><body>Forbidden</body></html>"

      {:ok, upstream} =
        FakeUpstream.start_link(
          {:sequence,
           [
             FakeUpstream.raw_response(html_403,
               status: 403,
               headers: [{"content-type", "text/html; charset=utf-8"}]
             ),
             FakeUpstream.json_response(
               weekly_only_payload(%{
                 "additional_rate_limits" => [
                   %{
                     "limit_name" => "GPT-5.3-Codex-Spark",
                     "metered_feature" => "codex_bengalfox",
                     "rate_limit" => %{
                       "primary_window" => %{
                         "used_percent" => 45,
                         "limit_window_seconds" => 604_800,
                         "reset_after_seconds" => 1_200
                       }
                     }
                   }
                 ]
               })
             )
           ]}
        )

      on_exit(fn -> FakeUpstream.stop(upstream) end)

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded

      windows = QuotaWindows.list_quota_windows(identity)
      assert Enum.any?(windows, &(&1.quota_key == "account" and &1.window_kind == "secondary"))
      refute Enum.any?(windows, &(&1.window_kind == "primary"))

      assert Enum.map(FakeUpstream.requests(upstream), & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "does not reuse Cloudflare cookies from non-ChatGPT usage probe origins" do
      html_403 = "<!doctype html><html><body>Forbidden</body></html>"

      {:ok, upstream} =
        FakeUpstream.start_link(
          {:sequence,
           [
             FakeUpstream.raw_response(html_403,
               status: 403,
               headers: [
                 {"content-type", "text/html; charset=utf-8"},
                 {"set-cookie", "__cf_bm=cf-token; Path=/; HttpOnly; Secure"}
               ]
             ),
             FakeUpstream.json_response(%{
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 42,
                   "limit_window_seconds" => 18_000,
                   "reset_after_seconds" => 300
                 },
                 "secondary_window" => %{
                   "used_percent" => 51,
                   "limit_window_seconds" => 604_800,
                   "reset_after_seconds" => 3_600
                 }
               }
             })
           ]}
        )

      on_exit(fn -> FakeUpstream.stop(upstream) end)

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :succeeded

      windows = QuotaWindows.list_quota_windows(identity)
      assert Enum.any?(windows, &(&1.quota_key == "account" and &1.window_kind == "primary"))

      requests = FakeUpstream.requests(upstream)

      assert Enum.map(requests, & &1.path) == [
               "/backend-api/wham/usage",
               "/backend-api/codex/usage"
             ]

      [_first_request, second_request | _rest] = FakeUpstream.requests(upstream)
      second_headers = Map.new(second_request.headers)
      refute Map.has_key?(second_headers, "cookie")
    end

    test "stores 5h and weekly quota windows from Codex response headers" do
      identity = active_identity_fixture()
      reset_at = DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.truncate(:second)
      reset_unix = DateTime.to_unix(reset_at)

      assert {:ok, windows} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-primary-used-percent", ["12"]},
                   {"x-codex-primary-window-minutes", ["300"]},
                   {"x-codex-primary-reset-at", [DateTime.to_iso8601(reset_at)]},
                   {"x-codex-secondary-used-percent", ["67"]},
                   {"x-codex-secondary-window-minutes", ["10080"]},
                   {"x-codex-secondary-reset-at", [Integer.to_string(reset_unix)]},
                   {"x-codex-bengalfox-primary-used-percent", ["44"]},
                   {"x-codex-bengalfox-primary-window-minutes", ["300"]},
                   {"x-codex-bengalfox-primary-reset-at", [Integer.to_string(reset_unix)]},
                   {"x-codex-bengalfox-limit-name", ["gpt-5.3-codex-spark"]}
                 ]
               )

      assert Enum.map(
               windows,
               &{&1.quota_key, &1.window_kind, Decimal.to_integer(&1.used_percent),
                &1.display_label, &1.source}
             ) == [
               {"account", "primary", 12, "Account", "codex_response_headers"},
               {"account", "secondary", 67, "Account", "codex_response_headers"},
               {"codex_spark", "primary", 44, "GPT-5.3-Codex-Spark", "codex_response_headers"}
             ]

      assert Enum.all?(windows, &(DateTime.compare(&1.reset_at, reset_at) == :eq))

      spark = Enum.find(windows, &(&1.quota_key == "codex_spark"))
      assert spark.source_precision == "observed"
      assert spark.quota_scope == "model"
      assert spark.quota_family == "codex_model"
      assert spark.model == "gpt-5.3-codex-spark"
      assert spark.raw_limit_id == "codex_bengalfox"
      assert spark.raw_limit_name == "gpt-5.3-codex-spark"
      assert spark.raw_metered_feature == "codex_bengalfox"
      assert spark.observed_at
    end

    test "Cloudflare cookie jar stores only allowed cookie names per origin" do
      url =
        "https://cookie-test-#{System.unique_integer([:positive])}.chatgpt.com/backend-api/codex/usage"

      other_url =
        "https://cookie-other-#{System.unique_integer([:positive])}.chatgpt.com/backend-api/codex/usage"

      assert CloudflareCookies.store_from_response(url, %Req.Response{
               status: 403,
               headers: %{
                 "set-cookie" => [
                   "__cf_bm=cf-token; Path=/; HttpOnly; Secure",
                   "session=must-not-forward; Path=/; HttpOnly; Secure",
                   "cf_chl_test=challenge-token; Path=/; HttpOnly; Secure"
                 ]
               }
             })

      headers = CloudflareCookies.request_headers(url, [{"accept", "application/json"}])
      cookie = headers |> Map.new() |> Map.fetch!("cookie")

      assert cookie =~ "__cf_bm=cf-token"
      assert cookie =~ "cf_chl_test=challenge-token"
      refute cookie =~ "session=must-not-forward"

      refute CloudflareCookies.request_headers(other_url, [])
             |> Map.new()
             |> Map.has_key?("cookie")
    end

    test "Cloudflare cookie jar stores allowed cookies from raw response headers" do
      url =
        "https://cookie-headers-#{System.unique_integer([:positive])}.chatgpt.com/backend-api/codex/responses"

      assert CloudflareCookies.store_from_headers(url, [
               {"content-type", "text/html"},
               {"set-cookie", "__cf_bm=header-token; Path=/; HttpOnly; Secure"},
               {"set-cookie", "session=must-not-forward; Path=/; HttpOnly; Secure"}
             ])

      headers = CloudflareCookies.request_headers(url, [{"accept", "application/json"}])
      cookie = headers |> Map.new() |> Map.fetch!("cookie")

      assert cookie =~ "__cf_bm=header-token"
      refute cookie =~ "session=must-not-forward"
    end

    test "Cloudflare cookie jar ignores non-ChatGPT and plain HTTP origins" do
      assert CloudflareCookies.store_from_headers("https://example.com/backend-api/codex/usage", [
               {"set-cookie", "__cf_bm=ignored; Path=/; HttpOnly; Secure"}
             ]) == false

      refute CloudflareCookies.request_headers(
               "https://example.com/backend-api/codex/usage",
               []
             )
             |> Map.new()
             |> Map.has_key?("cookie")

      assert CloudflareCookies.store_from_headers("http://chatgpt.com/backend-api/codex/usage", [
               {"set-cookie", "__cf_bm=ignored; Path=/; HttpOnly"}
             ]) == false

      refute CloudflareCookies.request_headers(
               "http://chatgpt.com/backend-api/codex/usage",
               []
             )
             |> Map.new()
             |> Map.has_key?("cookie")
    end

    test "Cloudflare cookie jar honors max-age clears and expired dates" do
      url =
        "https://cookie-expiry-#{System.unique_integer([:positive])}.chatgpt.com/backend-api/codex/usage"

      assert CloudflareCookies.store_from_headers(url, [
               {"set-cookie", "__cf_bm=live; Max-Age=1800; Path=/; HttpOnly; Secure"}
             ])

      assert CloudflareCookies.request_headers(url, []) |> Map.new() |> Map.fetch!("cookie") =~
               "__cf_bm=live"

      refute CloudflareCookies.store_from_headers(url, [
               {"set-cookie", "__cf_bm=; Max-Age=0; Path=/; HttpOnly; Secure"}
             ])

      refute CloudflareCookies.request_headers(url, [])
             |> Map.new()
             |> Map.has_key?("cookie")

      refute CloudflareCookies.store_from_headers(url, [
               {"set-cookie",
                "__cf_bm=expired; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/; HttpOnly; Secure"}
             ])

      refute CloudflareCookies.request_headers(url, [])
             |> Map.new()
             |> Map.has_key?("cookie")
    end

    test "Cloudflare cookie jar is owned by the supervised process" do
      url =
        "https://cookie-owner-#{System.unique_integer([:positive])}.chatgpt.com/backend-api/codex/usage"

      task =
        Task.async(fn ->
          assert CloudflareCookies.store_from_response(url, %Req.Response{
                   status: 403,
                   headers: %{
                     "set-cookie" => [
                       "__cf_bm=cf-token; Path=/; HttpOnly; Secure"
                     ]
                   }
                 })

          :ets.info(CloudflareCookies, :owner)
        end)

      owner = Task.await(task)

      assert owner == Process.whereis(CloudflareCookies)
      assert Process.alive?(owner)

      headers = CloudflareCookies.request_headers(url, [{"accept", "application/json"}])
      assert headers |> Map.new() |> Map.fetch!("cookie") =~ "__cf_bm=cf-token"
    end

    test "stores reset-bearing 5h quota from Codex rate limit events" do
      identity = active_identity_fixture()
      reset_at = DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.truncate(:second)

      assert {:ok, windows} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "primary" => %{
                       "used_percent" => 12.5,
                       "window_minutes" => 300,
                       "reset_at" => DateTime.to_unix(reset_at)
                     },
                     "secondary" => %{
                       "used_percent" => 67,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(reset_at)
                     }
                   }
                 }
               )

      assert Enum.map(
               windows,
               &{&1.quota_key, &1.window_kind, Decimal.round(&1.used_percent, 1), &1.source}
             ) == [
               {"account", "primary", Decimal.new("12.5"), "codex_rate_limit_event"},
               {"account", "secondary", Decimal.new("67.0"), "codex_rate_limit_event"}
             ]

      assert Enum.all?(windows, &(DateTime.compare(&1.reset_at, reset_at) == :eq))
      assert Enum.all?(windows, &QuotaWindows.usable_window?/1)
    end

    test "runtime rate-limit events do not roll back fresh account usage API quota" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      usage_reset_at = DateTime.add(observed_at, 6 * 24 * 60 * 60, :second)
      runtime_reset_at = DateTime.add(observed_at, 7 * 24 * 60 * 60, :second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     quota_scope: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("19"),
                     reset_at: usage_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     last_sync_at: observed_at,
                     observed_at: observed_at
                   }
                 ],
                 delete_missing?: false
               )

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 1,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(runtime_reset_at)
                     }
                   }
                 },
                 DateTime.add(observed_at, 60, :second)
               )

      stored_weekly =
        identity
        |> QuotaWindows.quota_window_selection_data(at: DateTime.add(observed_at, 60, :second))
        |> Map.fetch!(:secondary)

      assert stored_weekly.source == "codex_usage_api"
      assert Decimal.equal?(stored_weekly.used_percent, Decimal.new("19"))
      assert DateTime.compare(stored_weekly.reset_at, usage_reset_at) == :eq
    end

    test "fresh account usage API quota corrects lower runtime rate-limit evidence" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      runtime_reset_at = DateTime.add(observed_at, 7 * 24 * 60 * 60, :second)
      usage_reset_at = DateTime.add(observed_at, 6 * 24 * 60 * 60, :second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 1,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(runtime_reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     quota_scope: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("19"),
                     reset_at: usage_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     last_sync_at: DateTime.add(observed_at, 60, :second),
                     observed_at: DateTime.add(observed_at, 60, :second)
                   }
                 ],
                 delete_missing?: false
               )

      stored_weekly =
        identity
        |> QuotaWindows.quota_window_selection_data(at: DateTime.add(observed_at, 60, :second))
        |> Map.fetch!(:secondary)

      assert stored_weekly.source == "codex_usage_api"
      assert Decimal.equal?(stored_weekly.used_percent, Decimal.new("19"))
      assert DateTime.compare(stored_weekly.reset_at, usage_reset_at) == :eq
    end

    test "runtime rate-limit events still raise account usage pressure" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      usage_reset_at = DateTime.add(observed_at, 6 * 24 * 60 * 60, :second)
      runtime_reset_at = DateTime.add(observed_at, 7 * 24 * 60 * 60, :second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     quota_scope: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("19"),
                     reset_at: usage_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     last_sync_at: observed_at,
                     observed_at: observed_at
                   }
                 ],
                 delete_missing?: false
               )

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 91,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(runtime_reset_at)
                     }
                   }
                 },
                 DateTime.add(observed_at, 60, :second)
               )

      stored_weekly =
        identity
        |> QuotaWindows.quota_window_selection_data(at: DateTime.add(observed_at, 60, :second))
        |> Map.fetch!(:secondary)

      assert stored_weekly.source == "codex_rate_limit_event"
      assert Decimal.equal?(stored_weekly.used_percent, Decimal.new("91.0"))
      assert DateTime.compare(stored_weekly.reset_at, runtime_reset_at) == :eq
    end

    @tag :weekly_account_snapshot_refresh
    test "successive lower runtime events cannot demote a fresh weekly account snapshot" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      stronger_reset_at = DateTime.add(observed_at, 4, :day)
      weaker_reset_at = DateTime.add(observed_at, 6, :day)

      assert {:ok, [stronger_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 22,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(stronger_reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert {:ok, [_weaker_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 6,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(weaker_reset_at)
                     }
                   }
                 },
                 DateTime.add(observed_at, 60, :second)
               )

      assert {:ok, [_usage_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     quota_scope: "account",
                     quota_family: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     active_limit: 0,
                     credits: 0,
                     used_percent: Decimal.new("6"),
                     reset_at: weaker_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     observed_at: DateTime.add(observed_at, 120, :second)
                   }
                 ],
                 delete_missing?: false
               )

      stored_weekly =
        identity
        |> QuotaWindows.quota_window_selection_data(at: DateTime.add(observed_at, 120, :second))
        |> Map.fetch!(:secondary)

      assert stored_weekly.id == stronger_window.id
      assert stored_weekly.source == "codex_rate_limit_event"
      assert Decimal.equal?(stored_weekly.used_percent, Decimal.new("22"))
      assert DateTime.compare(stored_weekly.reset_at, stronger_reset_at) == :eq
    end

    @tag :weekly_account_snapshot_refresh
    test "lower rate-limit errors cannot demote a fresh weekly usage snapshot" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      stronger_reset_at = DateTime.add(observed_at, 4, :day)
      weaker_reset_at = DateTime.add(observed_at, 6, :day)

      assert {:ok, [stronger_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     quota_scope: "account",
                     quota_family: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     active_limit: 0,
                     credits: 0,
                     used_percent: Decimal.new("22"),
                     reset_at: stronger_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     observed_at: observed_at
                   }
                 ],
                 delete_missing?: false
               )

      assert {:ok, [_error_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_error(
                 identity,
                 %{
                   "limit_id" => "codex",
                   "window_kind" => "secondary",
                   "window_minutes" => 10_080,
                   "used_percent" => 6,
                   "reset_at" => DateTime.to_unix(weaker_reset_at)
                 },
                 DateTime.add(observed_at, 60, :second)
               )

      assert {:ok, [_event_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 6,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(weaker_reset_at)
                     }
                   }
                 },
                 DateTime.add(observed_at, 120, :second)
               )

      assert {:ok, [_usage_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     quota_scope: "account",
                     quota_family: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     active_limit: 0,
                     credits: 0,
                     used_percent: Decimal.new("6"),
                     reset_at: weaker_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     observed_at: DateTime.add(observed_at, 180, :second)
                   }
                 ],
                 delete_missing?: false
               )

      stored_weekly =
        identity
        |> QuotaWindows.quota_window_selection_data(at: DateTime.add(observed_at, 180, :second))
        |> Map.fetch!(:secondary)

      assert stored_weekly.id == stronger_window.id
      assert stored_weekly.source == "codex_usage_api"
      assert Decimal.equal?(stored_weekly.used_percent, Decimal.new("22"))
      assert DateTime.compare(stored_weekly.reset_at, stronger_reset_at) == :eq
    end

    @tag :weekly_account_snapshot_refresh
    test "equal runtime evidence refreshes a fresh weekly snapshot without changing its reset" do
      identity = active_identity_fixture()

      observed_at =
        DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)

      refreshed_at = DateTime.add(observed_at, 60, :second)
      stronger_reset_at = DateTime.add(observed_at, 4, :day)
      weaker_reset_at = DateTime.add(observed_at, 6, :day)

      assert {:ok, [stronger_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 22,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(stronger_reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert {:ok, [_refreshed_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 22,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(weaker_reset_at)
                     }
                   }
                 },
                 refreshed_at
               )

      assert [stored_weekly] =
               identity
               |> QuotaWindows.list_quota_windows()
               |> Enum.filter(&(&1.quota_key == "account" and &1.window_kind == "secondary"))

      assert stored_weekly.id == stronger_window.id
      assert stored_weekly.source == "codex_rate_limit_event"
      assert Decimal.equal?(stored_weekly.used_percent, Decimal.new("22"))
      assert DateTime.compare(stored_weekly.reset_at, stronger_reset_at) == :eq
      assert DateTime.compare(stored_weekly.observed_at, refreshed_at) == :eq
      assert DateTime.compare(stored_weekly.last_sync_at, refreshed_at) == :eq
    end

    @tag :weekly_account_snapshot_refresh
    test "quota upserts serialize concurrent evidence writes for one identity" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 22,
                       "window_minutes" => 10_080,
                       "reset_at" => observed_at |> DateTime.add(4, :day) |> DateTime.to_unix()
                     }
                   }
                 },
                 observed_at
               )

      connection_options =
        Repo.config()
        |> Keyword.take([
          :hostname,
          :port,
          :username,
          :password,
          :database,
          :socket,
          :socket_dir,
          :ssl,
          :ssl_opts,
          :parameters,
          :connect_timeout
        ])

      connection = start_supervised!({Postgrex, connection_options})

      assert %Postgrex.Result{rows: [[false]]} =
               Postgrex.query!(
                 connection,
                 "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))",
                 [identity.id]
               )
    end

    @tag :weekly_account_snapshot_refresh
    test "lower runtime evidence starts a new weekly cycle after the stronger snapshot expires" do
      identity = active_identity_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      expired_observed_at = DateTime.add(now, -120, :second)
      expired_reset_at = DateTime.add(now, -60, :second)
      next_reset_at = DateTime.add(now, 6, :day)

      assert {:ok, [expired_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 22,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(expired_reset_at)
                     }
                   }
                 },
                 expired_observed_at
               )

      assert {:ok, [next_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 6,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(next_reset_at)
                     }
                   }
                 },
                 now
               )

      assert next_window.id == expired_window.id
      assert next_window.source == "codex_rate_limit_event"
      assert Decimal.equal?(next_window.used_percent, Decimal.new("6"))
      assert DateTime.compare(next_window.reset_at, next_reset_at) == :eq
      assert DateTime.compare(next_window.observed_at, now) == :eq
    end

    test "runtime rate-limit events do not roll back fresh Spark usage API quota" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      usage_reset_at = DateTime.add(observed_at, 5 * 60 * 60, :second)
      runtime_reset_at = DateTime.add(observed_at, 7 * 24 * 60 * 60, :second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "codex_spark",
                     quota_scope: "model",
                     quota_family: "codex_model",
                     model: "gpt-5.3-codex-spark",
                     display_label: "GPT-5.3-Codex-Spark",
                     raw_limit_id: "codex_bengalfox",
                     raw_limit_name: "GPT-5.3-Codex-Spark",
                     raw_metered_feature: "codex_bengalfox",
                     window_kind: "primary",
                     window_minutes: 300,
                     used_percent: Decimal.new("10"),
                     reset_at: usage_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     last_sync_at: observed_at,
                     observed_at: observed_at
                   }
                 ],
                 delete_missing?: false
               )

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limits" => %{
                     "primary" => %{
                       "used_percent" => 1,
                       "window_minutes" => 300,
                       "reset_at" => DateTime.to_unix(runtime_reset_at)
                     }
                   }
                 },
                 DateTime.add(observed_at, 60, :second)
               )

      stored_spark =
        identity
        |> QuotaWindows.quota_window_selection_data(
          at: DateTime.add(observed_at, 60, :second),
          model: "gpt-5.3-codex-spark"
        )
        |> Map.fetch!(:routing_windows)
        |> Enum.find(&(&1.quota_key == "codex_spark"))

      assert stored_spark.source == "codex_usage_api"
      assert Decimal.equal?(stored_spark.used_percent, Decimal.new("10"))
      assert DateTime.compare(stored_spark.reset_at, usage_reset_at) == :eq
    end

    test "fresh Spark usage API quota corrects lower runtime rate-limit evidence" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      runtime_reset_at = DateTime.add(observed_at, 7 * 24 * 60 * 60, :second)
      usage_reset_at = DateTime.add(observed_at, 5 * 60 * 60, :second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limits" => %{
                     "primary" => %{
                       "used_percent" => 1,
                       "window_minutes" => 300,
                       "reset_at" => DateTime.to_unix(runtime_reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "codex_spark",
                     quota_scope: "model",
                     quota_family: "codex_model",
                     model: "gpt-5.3-codex-spark",
                     display_label: "GPT-5.3-Codex-Spark",
                     raw_limit_id: "codex_bengalfox",
                     raw_limit_name: "GPT-5.3-Codex-Spark",
                     raw_metered_feature: "codex_bengalfox",
                     window_kind: "primary",
                     window_minutes: 300,
                     used_percent: Decimal.new("10"),
                     reset_at: usage_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     last_sync_at: DateTime.add(observed_at, 60, :second),
                     observed_at: DateTime.add(observed_at, 60, :second)
                   }
                 ],
                 delete_missing?: false
               )

      stored_spark =
        identity
        |> QuotaWindows.quota_window_selection_data(
          at: DateTime.add(observed_at, 60, :second),
          model: "gpt-5.3-codex-spark"
        )
        |> Map.fetch!(:routing_windows)
        |> Enum.find(&(&1.quota_key == "codex_spark"))

      assert stored_spark.source == "codex_usage_api"
      assert Decimal.equal?(stored_spark.used_percent, Decimal.new("10"))
      assert DateTime.compare(stored_spark.reset_at, usage_reset_at) == :eq
    end

    test "runtime rate-limit events still raise Spark usage pressure" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      usage_reset_at = DateTime.add(observed_at, 5 * 60 * 60, :second)
      runtime_reset_at = DateTime.add(observed_at, 7 * 24 * 60 * 60, :second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "codex_spark",
                     quota_scope: "model",
                     quota_family: "codex_model",
                     model: "gpt-5.3-codex-spark",
                     display_label: "GPT-5.3-Codex-Spark",
                     raw_limit_id: "codex_bengalfox",
                     raw_limit_name: "GPT-5.3-Codex-Spark",
                     raw_metered_feature: "codex_bengalfox",
                     window_kind: "primary",
                     window_minutes: 300,
                     used_percent: Decimal.new("10"),
                     reset_at: usage_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     freshness_state: "fresh",
                     last_sync_at: observed_at,
                     observed_at: observed_at
                   }
                 ],
                 delete_missing?: false
               )

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limits" => %{
                     "primary" => %{
                       "used_percent" => 91,
                       "window_minutes" => 300,
                       "reset_at" => DateTime.to_unix(runtime_reset_at)
                     }
                   }
                 },
                 DateTime.add(observed_at, 60, :second)
               )

      stored_spark =
        identity
        |> QuotaWindows.quota_window_selection_data(
          at: DateTime.add(observed_at, 60, :second),
          model: "gpt-5.3-codex-spark"
        )
        |> Map.fetch!(:routing_windows)
        |> Enum.find(&(&1.quota_key == "codex_spark"))

      assert stored_spark.source == "codex_rate_limit_event"
      assert Decimal.equal?(stored_spark.used_percent, Decimal.new("91.0"))
      assert DateTime.compare(stored_spark.reset_at, runtime_reset_at) == :eq
    end

    @tag :quota_confirmed_convergence
    test "characterizes direct reset-bearing usage evidence persistence" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(observed_at, 300, :second)
      attrs = confirmed_convergence_attrs(:account, "primary", "22.000", reset_at, observed_at)

      assert {:ok, stored} = QuotaWindows.record_evidence(identity, attrs, observed_at)
      assert stored.upstream_identity_id == identity.id
      assert stored.quota_scope == "account"
      assert stored.quota_family == "account"
      assert stored.quota_key == "account"
      assert stored.window_kind == "primary"
      assert stored.window_minutes == 300
      assert Decimal.equal?(stored.used_percent, Decimal.new("22.000"))
      assert DateTime.compare(stored.reset_at, reset_at) == :eq
      assert DateTime.compare(stored.observed_at, observed_at) == :eq
      assert DateTime.compare(stored.last_sync_at, observed_at) == :eq
      assert stored.freshness_state == "fresh"
      assert stored.source == "codex_usage_api"
      assert stored.source_precision == "observed"
      assert QuotaWindows.usable_window?(stored, observed_at)
    end

    for evidence_scope <- [:account, :model, :upstream_model, :feature],
        window_kind <- ["primary", "secondary"] do
      @tag :quota_confirmed_convergence
      test "confirms two newer equivalent lower #{evidence_scope} #{window_kind} snapshots" do
        identity = active_identity_fixture()
        canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
        candidate_at = DateTime.add(canonical_at, 10, :second)
        confirmation_at = DateTime.add(candidate_at, 10, :second)
        reset_at = DateTime.add(canonical_at, 2, :hour)
        lower_percent = confirmed_convergence_lower_percent(unquote(evidence_scope))

        canonical =
          record_confirmed_convergence!(
            identity,
            unquote(evidence_scope),
            unquote(window_kind),
            "22",
            reset_at,
            canonical_at
          )

        first =
          record_confirmed_convergence!(
            identity,
            unquote(evidence_scope),
            unquote(window_kind),
            lower_percent,
            DateTime.add(reset_at, 5, :second),
            candidate_at
          )

        assert first.id == canonical.id
        assert_canonical_snapshot(first, canonical)

        assert_confirmed_candidate(
          first,
          lower_percent,
          DateTime.add(reset_at, 5, :second),
          candidate_at
        )

        assert QuotaWindows.usable_window?(first, candidate_at)

        confirmed =
          record_confirmed_convergence!(
            identity,
            unquote(evidence_scope),
            unquote(window_kind),
            Decimal.new(lower_percent) |> Decimal.normalize() |> Decimal.to_string(),
            DateTime.add(reset_at, 1, :second),
            confirmation_at
          )

        assert confirmed.id == canonical.id
        assert Decimal.equal?(confirmed.used_percent, Decimal.new(lower_percent))
        assert DateTime.compare(confirmed.reset_at, DateTime.add(reset_at, 1, :second)) == :eq
        assert DateTime.compare(confirmed.observed_at, confirmation_at) == :eq
        assert DateTime.compare(confirmed.last_sync_at, confirmation_at) == :eq
        assert confirmed.freshness_state == "fresh"
        assert confirmed.source == "codex_usage_api"
        assert confirmed.source_precision == "observed"
        refute confirmed_candidate(confirmed)
        assert QuotaWindows.usable_window?(confirmed, confirmation_at)
      end
    end

    @tag :quota_confirmed_convergence
    test "anchored forward weekly restart converges after two matching observations" do
      identity = active_identity_fixture()

      canonical_at =
        DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)

      restart_at = DateTime.add(canonical_at, 60, :second)
      confirm_at = DateTime.add(canonical_at, 120, :second)
      canonical_reset = DateTime.add(canonical_at, 5, :day)
      anchored_reset = DateTime.add(restart_at, 604_800 - 2 * 3600, :second)

      canonical =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "35",
          canonical_reset,
          canonical_at
        )

      corroborate_weekly_restart!(identity, anchored_reset, restart_at)

      quarantined =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "0",
          anchored_reset,
          restart_at
        )

      assert quarantined.id == canonical.id
      assert Decimal.equal?(quarantined.used_percent, Decimal.new("35"))
      assert DateTime.compare(quarantined.reset_at, canonical_reset) == :eq

      confirmed =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "0",
          anchored_reset,
          confirm_at
        )

      assert confirmed.id == canonical.id
      assert Decimal.equal?(confirmed.used_percent, Decimal.new("0"))
      assert DateTime.compare(confirmed.reset_at, anchored_reset) == :eq
      assert DateTime.compare(confirmed.observed_at, confirm_at) == :eq
      assert confirmed.freshness_state == "fresh"
    end

    @tag :quota_confirmed_convergence
    test "idle-rolling zero weekly usage cannot demote the canonical weekly snapshot" do
      identity = active_identity_fixture()
      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      rolling_at = DateTime.add(canonical_at, 60, :second)
      canonical_reset = DateTime.add(canonical_at, 5, :day)
      rolling_reset = DateTime.add(rolling_at, 604_800, :second)

      canonical =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "35",
          canonical_reset,
          canonical_at
        )

      retained =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "0",
          rolling_reset,
          rolling_at
        )

      assert retained.id == canonical.id
      assert Decimal.equal?(retained.used_percent, Decimal.new("35"))
      assert DateTime.compare(retained.reset_at, canonical_reset) == :eq
    end

    @tag :quota_confirmed_convergence
    test "a single usage zero cannot re-enable an expired exhausted weekly without corroboration" do
      # adversarial P0 repro: canonical 100% with the reset already passed
      # used to take the expired fast path and accept a lone usage zero
      identity = active_identity_fixture()

      canonical_at =
        DateTime.utc_now() |> DateTime.add(-4_000, :second) |> DateTime.truncate(:second)

      expired_reset = DateTime.add(canonical_at, 600, :second)

      canonical =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "100",
          expired_reset,
          canonical_at
        )

      zero_at = DateTime.utc_now() |> DateTime.truncate(:second)
      rolling_zero_reset = DateTime.add(zero_at, 604_800 - 2 * 3600, :second)

      retained =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "0",
          rolling_zero_reset,
          zero_at
        )

      assert retained.id == canonical.id
      assert Decimal.equal?(retained.used_percent, Decimal.new("100"))
      assert DateTime.compare(retained.reset_at, expired_reset) == :eq

      assert %{eligible?: false} =
               QuotaWindows.routing_quota_eligibility(identity, at: zero_at)
    end

    @tag :quota_confirmed_convergence
    test "capacity-bearing usage zero cannot re-enable an exhausted weekly without corroboration" do
      # adversarial P0 repro: credit/capacity shapes exit the weak-capacity
      # quarantine as :continue and used to reach the generic merge
      identity = active_identity_fixture()

      canonical_at =
        DateTime.utc_now() |> DateTime.add(-4_000, :second) |> DateTime.truncate(:second)

      canonical_reset = DateTime.add(canonical_at, 5, :day)

      weekly = fn percent, reset, observed, extra ->
        Map.merge(
          %{
            quota_key: "account",
            quota_scope: "account",
            quota_family: "account",
            window_kind: "secondary",
            window_minutes: 10_080,
            used_percent: Decimal.new(percent),
            reset_at: reset,
            source: "codex_usage_api",
            source_precision: "observed",
            freshness_state: "fresh",
            last_sync_at: observed,
            observed_at: observed
          },
          extra
        )
      end

      assert {:ok, canonical} =
               QuotaWindows.record_evidence(
                 identity,
                 weekly.("100", canonical_reset, canonical_at, %{}),
                 canonical_at
               )

      zero_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, retained} =
               QuotaWindows.record_evidence(
                 identity,
                 weekly.("0", DateTime.add(zero_at, 604_800 - 2 * 3600, :second), zero_at, %{
                   credits: 500,
                   active_limit: 1_000
                 }),
                 zero_at
               )

      assert retained.id == canonical.id
      assert Decimal.equal?(retained.used_percent, Decimal.new("100"))
      assert DateTime.compare(retained.reset_at, canonical_reset) == :eq
    end

    @tag :quota_confirmed_convergence
    test "stale or exhausted runtime rows cannot corroborate a weekly restart" do
      # adversarial P1 repro: a runtime row observed long ago, one carrying an
      # exhausted percent, one persisted with an explicitly non-fresh state,
      # or one observed after the merge instant (even within the clock-skew
      # band) must not vouch for a usage zero
      scenarios = [
        # stale corroboration: runtime row observed well past the freshness TTL
        fn identity, anchored_reset, canonical_at ->
          corroborate_weekly_restart!(
            identity,
            anchored_reset,
            DateTime.add(canonical_at, -7_200, :second)
          )
        end,
        # contradictory corroboration: runtime row at 100 percent
        fn identity, anchored_reset, canonical_at ->
          assert {:ok, _window} =
                   QuotaWindows.record_evidence(
                     identity,
                     %{
                       quota_key: "account",
                       quota_scope: "account",
                       quota_family: "account",
                       window_kind: "secondary",
                       window_minutes: 10_080,
                       used_percent: Decimal.new("100"),
                       reset_at: anchored_reset,
                       source: "codex_response_headers",
                       source_precision: "observed",
                       freshness_state: "fresh",
                       last_sync_at: DateTime.add(canonical_at, 30, :second),
                       observed_at: DateTime.add(canonical_at, 30, :second)
                     },
                     DateTime.add(canonical_at, 30, :second)
                   )
        end,
        # explicitly non-fresh persisted state, even when recently observed
        fn identity, anchored_reset, canonical_at ->
          assert {:ok, _window} =
                   QuotaWindows.record_evidence(
                     identity,
                     %{
                       quota_key: "account",
                       quota_scope: "account",
                       quota_family: "account",
                       window_kind: "secondary",
                       window_minutes: 10_080,
                       used_percent: Decimal.new("0"),
                       reset_at: anchored_reset,
                       source: "codex_response_headers",
                       source_precision: "observed",
                       freshness_state: "stale",
                       last_sync_at: DateTime.add(canonical_at, 30, :second),
                       observed_at: DateTime.add(canonical_at, 30, :second)
                     },
                     DateTime.add(canonical_at, 30, :second)
                   )
        end,
        # future corroboration inside the clock-skew band: the store merges at
        # wall clock, so the row must be observed ahead of the real merge
        # instant (a skewed-ahead node) to exercise the strict ceiling
        fn identity, anchored_reset, _canonical_at ->
          corroborate_weekly_restart!(
            identity,
            anchored_reset,
            DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.truncate(:second)
          )
        end
      ]

      for {corroborate, scenario_index} <- Enum.with_index(scenarios) do
        identity = active_identity_fixture()

        canonical_at =
          DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

        canonical_reset = DateTime.add(canonical_at, 5, :day)
        restart_at = DateTime.add(canonical_at, 60, :second)
        anchored_reset = DateTime.add(restart_at, 604_800 - 2 * 3600, :second)

        canonical =
          record_confirmed_convergence!(
            identity,
            :account,
            "secondary",
            "100",
            canonical_reset,
            canonical_at
          )

        corroborate.(identity, anchored_reset, canonical_at)

        for observed_offset <- [60, 120] do
          retained =
            record_confirmed_convergence!(
              identity,
              :account,
              "secondary",
              "0",
              anchored_reset,
              DateTime.add(canonical_at, observed_offset, :second)
            )

          assert retained.id == canonical.id

          assert Decimal.equal?(retained.used_percent, Decimal.new("100")),
                 "scenario #{scenario_index} offset #{observed_offset}"
        end
      end
    end

    @tag :quota_confirmed_convergence
    test "anchored weekly restart without independent runtime corroboration stays quarantined" do
      identity = active_identity_fixture()

      canonical_at =
        DateTime.utc_now() |> DateTime.add(-4_000, :second) |> DateTime.truncate(:second)

      canonical_reset = DateTime.add(canonical_at, 5, :day)
      restart_at = DateTime.add(canonical_at, 60, :second)
      anchored_reset = DateTime.add(restart_at, 604_800 - 2 * 3600, :second)

      canonical =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "100",
          canonical_reset,
          canonical_at
        )

      # two coherent zero snapshots from the usage endpoint alone (for example
      # one cached response replayed) must never re-enable exhausted quota
      for observed_offset <- [60, 120] do
        retained =
          record_confirmed_convergence!(
            identity,
            :account,
            "secondary",
            "0",
            anchored_reset,
            DateTime.add(canonical_at, observed_offset, :second)
          )

        assert retained.id == canonical.id
        assert Decimal.equal?(retained.used_percent, Decimal.new("100"))
        assert DateTime.compare(retained.reset_at, canonical_reset) == :eq
      end
    end

    @tag :quota_confirmed_convergence
    test "cached rolling zero weekly usage stays rejected up to the one-hour anchor boundary" do
      identity = active_identity_fixture()

      canonical_at =
        DateTime.utc_now() |> DateTime.add(-4_000, :second) |> DateTime.truncate(:second)

      canonical_reset = DateTime.add(canonical_at, 5, :day)

      # a provider cache computed reset = observation + full window once, then
      # keeps serving that same value; later samples see it drift inside the
      # window and it must still not look like an anchored restart while the
      # cache is younger than the one-hour anchor margin (3599s boundary).
      # all observation instants stay in the past so freshness skew does not
      # interfere with the decision under test
      cache_at = DateTime.add(canonical_at, 60, :second)
      cached_rolling_reset = DateTime.add(cache_at, 604_800, :second)

      canonical =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "35",
          canonical_reset,
          canonical_at
        )

      for cache_age_seconds <- [5, 300, 1_800, 3_599] do
        retained =
          record_confirmed_convergence!(
            identity,
            :account,
            "secondary",
            "0",
            cached_rolling_reset,
            DateTime.add(cache_at, cache_age_seconds, :second)
          )

        assert retained.id == canonical.id

        assert Decimal.equal?(retained.used_percent, Decimal.new("35")),
               "age #{cache_age_seconds}"

        assert DateTime.compare(retained.reset_at, canonical_reset) == :eq
      end
    end

    @tag :quota_confirmed_convergence
    test "a fixed weekly reset older than one hour converges after two matching observations" do
      # intentional trust boundary: a zero-usage snapshot whose fixed reset sits
      # at least one hour (3600s) inside the window is indistinguishable from a
      # genuine restart, so two matching observations are allowed to accept it.
      # observation instants stay in the past so freshness skew does not
      # interfere with the decision under test
      identity = active_identity_fixture()

      canonical_at =
        DateTime.utc_now() |> DateTime.add(-4_000, :second) |> DateTime.truncate(:second)

      canonical_reset = DateTime.add(canonical_at, 5, :day)
      anchor_at = DateTime.add(canonical_at, 60, :second)
      fixed_reset = DateTime.add(anchor_at, 604_800, :second)

      canonical =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "35",
          canonical_reset,
          canonical_at
        )

      # corroboration must itself be fresh at the observations that rely on it
      corroborate_weekly_restart!(identity, fixed_reset, DateTime.add(anchor_at, 3_300, :second))

      quarantined =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "0",
          fixed_reset,
          DateTime.add(anchor_at, 3_600, :second)
        )

      assert quarantined.id == canonical.id
      assert Decimal.equal?(quarantined.used_percent, Decimal.new("35"))
      assert DateTime.compare(quarantined.reset_at, canonical_reset) == :eq

      confirmed =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "0",
          fixed_reset,
          DateTime.add(anchor_at, 3_660, :second)
        )

      assert confirmed.id == canonical.id
      assert Decimal.equal?(confirmed.used_percent, Decimal.new("0"))
      assert DateTime.compare(confirmed.reset_at, fixed_reset) == :eq
    end

    @tag :quota_confirmed_convergence
    test "a backward usage reset re-anchor converges after two matching observations" do
      # provider-side usage reset: the reset moves earlier mid-cycle with new
      # values (observed 2026-07-12 on the free-plan monthly window). a single
      # observation must stay rejected — an old cached decaying snapshot has
      # the same higher-percent/earlier-reset shape — but two consecutive
      # matching snapshots must re-anchor the canonical row
      identity = active_identity_fixture()

      canonical_at =
        DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

      canonical_reset = DateTime.add(canonical_at, 27, :day)
      reanchored_reset = DateTime.add(canonical_at, 11, :day)

      monthly = fn percent, reset, observed, extra ->
        Map.merge(
          %{
            quota_key: "account",
            quota_scope: "account",
            quota_family: "account",
            window_kind: "primary",
            window_minutes: 43_200,
            used_percent: Decimal.new(percent),
            reset_at: reset,
            source: "codex_usage_api",
            source_precision: "observed",
            freshness_state: "fresh",
            last_sync_at: observed,
            observed_at: observed
          },
          extra
        )
      end

      assert {:ok, canonical} =
               QuotaWindows.record_evidence(
                 identity,
                 monthly.("18.5", canonical_reset, canonical_at, %{
                   credits: 3_416,
                   active_limit: 4_192
                 }),
                 canonical_at
               )

      first_at = DateTime.add(canonical_at, 60, :second)

      assert {:ok, quarantined} =
               QuotaWindows.record_evidence(
                 identity,
                 monthly.("100", reanchored_reset, first_at, %{}),
                 first_at
               )

      assert quarantined.id == canonical.id
      assert Decimal.equal?(quarantined.used_percent, Decimal.new("18.5"))
      assert DateTime.compare(quarantined.reset_at, canonical_reset) == :eq

      confirm_at = DateTime.add(canonical_at, 120, :second)

      assert {:ok, confirmed} =
               QuotaWindows.record_evidence(
                 identity,
                 monthly.("100", reanchored_reset, confirm_at, %{}),
                 confirm_at
               )

      assert confirmed.id == canonical.id
      assert Decimal.equal?(confirmed.used_percent, Decimal.new("100"))
      assert DateTime.compare(confirmed.reset_at, reanchored_reset) == :eq
    end

    @tag :quota_confirmed_convergence
    test "credit-only backward re-anchor adopts the reset while keeping credit-derived percent" do
      # the free-plan shape observed live: canonical capacity-bearing monthly
      # (18.5% = credits/capacity, reset in 27d) while the provider reports
      # 100% used with the reset re-anchored 16 days earlier and only a credit
      # balance. values must stay credit-derived on every observation; the
      # earlier reset is adopted only after two matching observations
      identity = active_identity_fixture()

      canonical_at =
        DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

      canonical_reset = DateTime.add(canonical_at, 27, :day)
      reanchored_reset = DateTime.add(canonical_at, 11, :day)

      monthly = fn percent, reset, observed, extra ->
        Map.merge(
          %{
            quota_key: "account",
            quota_scope: "account",
            quota_family: "account",
            window_kind: "primary",
            window_minutes: 43_200,
            used_percent: Decimal.new(percent),
            reset_at: reset,
            source: "codex_usage_api",
            source_precision: "observed",
            freshness_state: "fresh",
            last_sync_at: observed,
            observed_at: observed
          },
          extra
        )
      end

      assert {:ok, canonical} =
               QuotaWindows.record_evidence(
                 identity,
                 monthly.("18.5", canonical_reset, canonical_at, %{
                   credits: 3_416,
                   active_limit: 4_192
                 }),
                 canonical_at
               )

      expected_percent =
        Decimal.new(4_192)
        |> Decimal.sub(Decimal.new(3_416))
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.div(Decimal.new(4_192))

      first_at = DateTime.add(canonical_at, 60, :second)

      assert {:ok, first} =
               QuotaWindows.record_evidence(
                 identity,
                 monthly.("100", reanchored_reset, first_at, %{credits: 3_416}),
                 first_at
               )

      assert first.id == canonical.id
      assert first.active_limit == 4_192
      assert first.credits == 3_416
      assert DateTime.compare(first.reset_at, canonical_reset) == :eq

      assert Decimal.equal?(
               Decimal.round(first.used_percent, 6),
               Decimal.round(expected_percent, 6)
             )

      confirm_at = DateTime.add(canonical_at, 120, :second)

      assert {:ok, confirmed} =
               QuotaWindows.record_evidence(
                 identity,
                 monthly.("100", reanchored_reset, confirm_at, %{credits: 3_416}),
                 confirm_at
               )

      assert confirmed.id == canonical.id
      assert confirmed.active_limit == 4_192
      assert confirmed.credits == 3_416
      assert DateTime.compare(confirmed.reset_at, reanchored_reset) == :eq

      assert Decimal.equal?(
               Decimal.round(confirmed.used_percent, 6),
               Decimal.round(expected_percent, 6)
             )
    end

    @tag :quota_confirmed_convergence
    test "inconsistent backward re-anchor observations keep the canonical snapshot" do
      identity = active_identity_fixture()

      canonical_at =
        DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

      canonical_reset = DateTime.add(canonical_at, 27, :day)

      monthly = fn percent, reset, observed ->
        %{
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: "primary",
          window_minutes: 43_200,
          used_percent: Decimal.new(percent),
          reset_at: reset,
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          last_sync_at: observed,
          observed_at: observed,
          credits: 3_416,
          active_limit: 4_192
        }
      end

      assert {:ok, canonical} =
               QuotaWindows.record_evidence(
                 identity,
                 monthly.("18.5", canonical_reset, canonical_at),
                 canonical_at
               )

      # two earlier-reset observations whose resets disagree by minutes never
      # confirm each other, so the canonical values survive
      for {drift_seconds, observed_offset} <- [{0, 60}, {180, 120}] do
        assert {:ok, retained} =
                 QuotaWindows.record_evidence(
                   identity,
                   monthly.(
                     "100",
                     DateTime.add(canonical_at, 11 * 24 * 3600 + drift_seconds, :second),
                     DateTime.add(canonical_at, observed_offset, :second)
                   ),
                   DateTime.add(canonical_at, observed_offset, :second)
                 )

        assert retained.id == canonical.id
        assert Decimal.equal?(retained.used_percent, Decimal.new("18.5"))
        assert DateTime.compare(retained.reset_at, canonical_reset) == :eq
      end
    end

    @tag :quota_confirmed_convergence
    test "higher complete snapshots commit immediately and clear a lower candidate" do
      identity = active_identity_fixture()
      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(canonical_at, 2, :hour)

      canonical =
        record_confirmed_convergence!(identity, :account, "primary", "22", reset_at, canonical_at)

      candidate_at = DateTime.add(canonical_at, 10, :second)

      first =
        record_confirmed_convergence!(identity, :account, "primary", "14", reset_at, candidate_at)

      assert_canonical_snapshot(first, canonical)
      assert_confirmed_candidate(first, "14", reset_at, candidate_at)

      higher_at = DateTime.add(candidate_at, 10, :second)

      higher =
        record_confirmed_convergence!(identity, :account, "primary", "23", reset_at, higher_at)

      assert Decimal.equal?(higher.used_percent, Decimal.new("23"))
      assert DateTime.compare(higher.observed_at, higher_at) == :eq
      refute confirmed_candidate(higher)
    end

    @tag :quota_confirmed_convergence
    test "equal complete provider evidence independently clears a lower candidate" do
      identity = active_identity_fixture()
      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(canonical_at, 2, :hour)

      canonical =
        record_confirmed_convergence!(identity, :account, "primary", "22", reset_at, canonical_at)

      candidate_at = DateTime.add(canonical_at, 10, :second)

      candidate =
        record_confirmed_convergence!(identity, :account, "primary", "14", reset_at, candidate_at)

      assert_canonical_snapshot(candidate, canonical)
      assert_confirmed_candidate(candidate, "14", reset_at, candidate_at)

      equal_at = DateTime.add(candidate_at, 10, :second)

      equal =
        record_confirmed_convergence!(identity, :account, "primary", "22.0", reset_at, equal_at)

      assert equal.id == canonical.id
      assert Decimal.equal?(equal.used_percent, Decimal.new("22"))
      assert DateTime.compare(equal.reset_at, reset_at) == :eq
      assert DateTime.compare(equal.observed_at, equal_at) == :eq
      assert DateTime.compare(equal.last_sync_at, equal_at) == :eq
      assert equal.freshness_state == "fresh"
      assert equal.source == "codex_usage_api"
      assert equal.source_precision == "observed"
      refute confirmed_candidate(equal)
    end

    @tag :quota_confirmed_convergence
    test "changed lower pairs and non-increasing timestamps cannot confirm" do
      identity = active_identity_fixture()
      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(canonical_at, 2, :hour)

      canonical =
        record_confirmed_convergence!(identity, :model, "secondary", "22", reset_at, canonical_at)

      candidate_at = DateTime.add(canonical_at, 10, :second)

      first =
        record_confirmed_convergence!(identity, :model, "secondary", "1", reset_at, candidate_at)

      assert_canonical_snapshot(first, canonical)
      assert_confirmed_candidate(first, "1", reset_at, candidate_at)

      changed_at = DateTime.add(candidate_at, 10, :second)

      changed =
        record_confirmed_convergence!(identity, :model, "secondary", "2", reset_at, changed_at)

      assert_canonical_snapshot(changed, canonical)
      assert_confirmed_candidate(changed, "2", reset_at, changed_at)

      duplicate =
        record_confirmed_convergence!(identity, :model, "secondary", "2.0", reset_at, changed_at)

      assert_canonical_snapshot(duplicate, canonical)
      assert_confirmed_candidate(duplicate, "2", reset_at, changed_at)

      older =
        record_confirmed_convergence!(
          identity,
          :model,
          "secondary",
          "2",
          reset_at,
          DateTime.add(changed_at, -1, :second)
        )

      assert_canonical_snapshot(older, canonical)
      assert_confirmed_candidate(older, "2", reset_at, changed_at)
    end

    @tag :quota_confirmed_convergence
    test "stale candidates do not confirm and expired canonicals accept a complete lower pair" do
      identity = active_identity_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      canonical_at = DateTime.add(now, -10, :second)
      stale_candidate_at = DateTime.add(now, -4, :second)
      canonical_reset_at = DateTime.add(now, 4, :second)
      candidate_reset_at = DateTime.add(now, -1, :second)

      canonical =
        record_confirmed_convergence!(
          identity,
          :upstream_model,
          "primary",
          "22",
          canonical_reset_at,
          canonical_at
        )

      first =
        record_confirmed_convergence!(
          identity,
          :upstream_model,
          "primary",
          "14",
          candidate_reset_at,
          stale_candidate_at
        )

      assert_canonical_snapshot(first, canonical)
      refute confirmed_candidate(first)

      fresh_at = now

      restarted =
        record_confirmed_convergence!(
          identity,
          :upstream_model,
          "primary",
          "14",
          canonical_reset_at,
          fresh_at
        )

      assert_canonical_snapshot(restarted, canonical)
      assert_confirmed_candidate(restarted, "14", canonical_reset_at, fresh_at)

      expired_identity = active_identity_fixture()
      expired_reset_at = DateTime.add(now, -1, :second)

      expired =
        record_confirmed_convergence!(
          expired_identity,
          :feature,
          "secondary",
          "22",
          expired_reset_at,
          DateTime.add(now, -60, :second)
        )

      next_reset_at = DateTime.add(now, 2, :hour)

      accepted =
        record_confirmed_convergence!(
          expired_identity,
          :feature,
          "secondary",
          "1",
          next_reset_at,
          now
        )

      assert accepted.id == expired.id
      assert Decimal.equal?(accepted.used_percent, Decimal.new("1"))
      assert DateTime.compare(accepted.reset_at, next_reset_at) == :eq
      assert DateTime.compare(accepted.observed_at, now) == :eq
      refute confirmed_candidate(accepted)
    end

    @tag :quota_confirmed_convergence
    test "a lower reset conflict restarts confirmation without splicing the canonical pair" do
      identity = active_identity_fixture()
      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      canonical_reset_at = DateTime.add(canonical_at, 2, :hour)

      canonical =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "22",
          canonical_reset_at,
          canonical_at
        )

      candidate_at = DateTime.add(canonical_at, 10, :second)
      candidate_reset_at = DateTime.add(canonical_reset_at, 5, :second)

      first =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "14",
          candidate_reset_at,
          candidate_at
        )

      assert_canonical_snapshot(first, canonical)
      assert_confirmed_candidate(first, "14", candidate_reset_at, candidate_at)

      conflicting_at = DateTime.add(candidate_at, 10, :second)
      conflicting_reset_at = DateTime.add(candidate_reset_at, 6, :second)

      conflicting =
        record_confirmed_convergence!(
          identity,
          :account,
          "secondary",
          "14.0",
          conflicting_reset_at,
          conflicting_at
        )

      assert_canonical_snapshot(conflicting, canonical)
      assert_confirmed_candidate(conflicting, "14", conflicting_reset_at, conflicting_at)
    end

    @tag :quota_confirmed_convergence
    test "equivalent lower snapshots from distinct rich identities cannot confirm each other" do
      identity = active_identity_fixture()
      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(canonical_at, 2, :hour)

      canonical =
        record_confirmed_convergence!(identity, :model, "primary", "22", reset_at, canonical_at)

      candidate_at = DateTime.add(canonical_at, 10, :second)

      candidate =
        record_confirmed_convergence!(identity, :model, "primary", "1", reset_at, candidate_at)

      assert_canonical_snapshot(candidate, canonical)
      assert_confirmed_candidate(candidate, "1", reset_at, candidate_at)

      sibling_at = DateTime.add(candidate_at, 10, :second)

      sibling_attrs =
        :model
        |> confirmed_convergence_attrs("primary", "1.0", reset_at, sibling_at)
        |> Map.merge(%{
          model: "example-model-sibling",
          raw_limit_id: "model-limit-sibling",
          raw_limit_name: "Model sibling limit",
          raw_metered_feature: "model-sibling-meter"
        })

      assert {:ok, sibling} = QuotaWindows.record_evidence(identity, sibling_attrs, sibling_at)
      assert sibling.id != canonical.id
      assert sibling.model == "example-model-sibling"
      assert sibling.raw_limit_id == "model-limit-sibling"
      assert Decimal.equal?(sibling.used_percent, Decimal.new("1"))
      assert DateTime.compare(sibling.reset_at, reset_at) == :eq
      refute confirmed_candidate(sibling)

      persisted = QuotaWindows.list_evidence(identity)
      persisted_canonical = Enum.find(persisted, &(&1.id == canonical.id))
      persisted_sibling = Enum.find(persisted, &(&1.id == sibling.id))

      assert_canonical_snapshot(persisted_canonical, canonical)
      assert_confirmed_candidate(persisted_canonical, "1", reset_at, candidate_at)
      assert Decimal.equal?(persisted_sibling.used_percent, Decimal.new("1"))
      assert DateTime.compare(persisted_sibling.observed_at, sibling_at) == :eq
    end

    @tag :quota_confirmed_convergence
    @tag :quota_reset_cycle_regression
    test "fresh relative weak-zero evidence refreshes liveness but cannot launder stale canonical values" do
      identity = active_identity_fixture()
      evaluation_at = quota_reset_evaluation_at()

      canonical_at =
        DateTime.add(
          evaluation_at,
          -Quotas.Evidence.freshness_ttl_seconds() - 60,
          :second
        )

      canonical_reset_at = DateTime.add(evaluation_at, 10, :minute)

      canonical =
        :account
        |> confirmed_convergence_attrs(
          "primary",
          "22",
          canonical_reset_at,
          canonical_at
        )
        |> Map.put(:metadata, %{
          "fixture" => "confirmed-convergence",
          "reset_after_seconds" => 600
        })
        |> then(&EvidenceStore.record_evidence(identity, &1, canonical_at, evaluation_at))
        |> then(fn {:ok, stored} -> stored end)

      assert Quotas.Evidence.current_freshness_state(canonical, evaluation_at) == "stale"

      incoming_at = DateTime.add(evaluation_at, -1, :second)
      incoming_reset_at = DateTime.add(canonical_reset_at, -3, :second)

      refreshed =
        :account
        |> confirmed_convergence_attrs("primary", "0", incoming_reset_at, incoming_at)
        |> Map.put(:metadata, %{
          "fixture" => "confirmed-convergence",
          "reset_after_seconds" => 597
        })
        |> then(&EvidenceStore.record_evidence(identity, &1, incoming_at, evaluation_at))
        |> then(fn {:ok, stored} -> stored end)

      assert refreshed.id == canonical.id
      assert Decimal.equal?(refreshed.used_percent, Decimal.new("22"))
      assert DateTime.compare(refreshed.reset_at, canonical_reset_at) == :eq
      # Contradictory weak-zero evidence cannot launder the canonical values,
      # but a fresh same-cycle provider response still re-confirms the window
      # so quota admission does not deadlock stale within the cycle.
      assert DateTime.compare(refreshed.observed_at, incoming_at) == :eq
      assert DateTime.compare(refreshed.last_sync_at, incoming_at) == :eq
      assert refreshed.freshness_state == "fresh"
      assert Quotas.Evidence.current_freshness_state(refreshed, evaluation_at) == "fresh"
      refute confirmed_candidate(refreshed)
    end

    @tag :quota_confirmed_convergence
    @tag :quota_reset_cycle_regression
    test "usage payload percentages remain consumed values across parser and persistence" do
      observed_at = quota_reset_evaluation_at()
      primary_reset_at = DateTime.add(observed_at, 5, :hour)
      secondary_reset_at = DateTime.add(observed_at, 7, :day)

      for {primary_percent, primary_reset, secondary_percent, secondary_reset} <- [
            {0, {:relative, 18_000}, 1, {:absolute, secondary_reset_at}},
            {2, {:absolute, primary_reset_at}, 0, :missing}
          ] do
        identity = active_identity_fixture()

        payload =
          account_usage_payload(
            primary_percent,
            primary_reset,
            secondary_percent,
            secondary_reset
          )

        assert {:ok, parsed} =
                 QuotaWindows.codex_usage_quota_windows_from_payload(payload, observed_at)

        assert {:ok, persisted} =
                 upsert_codex_usage_payload_at(identity, payload, observed_at, observed_at)

        parsed_primary = Enum.find(parsed, &(&1.window_kind == "primary"))
        parsed_secondary = Enum.find(parsed, &(&1.window_kind == "secondary"))
        persisted_primary = Enum.find(persisted, &(&1.window_kind == "primary"))
        persisted_secondary = Enum.find(persisted, &(&1.window_kind == "secondary"))

        assert Decimal.equal?(parsed_primary.used_percent, Decimal.new(primary_percent))
        assert Decimal.equal?(parsed_secondary.used_percent, Decimal.new(secondary_percent))
        assert Decimal.equal?(persisted_primary.used_percent, Decimal.new(primary_percent))
        assert Decimal.equal?(persisted_secondary.used_percent, Decimal.new(secondary_percent))

        if secondary_reset == :missing do
          assert parsed_secondary.reset_at == nil
          assert persisted_secondary.reset_at == nil
        end
      end
    end

    for {incoming_percent, expected_percent} <- [{43, "43"}, {22, "22"}, {14, "22"}] do
      @tag :quota_confirmed_convergence
      @tag :quota_reset_cycle_regression
      test "absolute same-cycle #{incoming_percent}% usage refreshes stale evidence without weakening it" do
        identity = active_identity_fixture()
        evaluation_at = quota_reset_evaluation_at()
        canonical_at = stale_quota_observed_at(evaluation_at)
        canonical_reset_at = DateTime.add(evaluation_at, 10, :minute)

        assert {:ok, [canonical]} =
                 upsert_codex_usage_payload_at(
                   identity,
                   account_primary_usage_payload(22, reset_at: canonical_reset_at),
                   canonical_at,
                   evaluation_at
                 )

        incoming_at = DateTime.add(evaluation_at, -1, :second)

        assert {:ok, [stored]} =
                 upsert_codex_usage_payload_at(
                   identity,
                   account_primary_usage_payload(unquote(incoming_percent),
                     reset_at: DateTime.add(canonical_reset_at, -3, :second),
                     reset_after_seconds: 597
                   ),
                   incoming_at,
                   evaluation_at
                 )

        assert stored.id == canonical.id
        assert Decimal.equal?(stored.used_percent, Decimal.new(unquote(expected_percent)))
        assert DateTime.compare(stored.reset_at, canonical_reset_at) == :eq
        assert DateTime.compare(stored.observed_at, incoming_at) == :eq
        assert DateTime.compare(stored.last_sync_at, incoming_at) == :eq
        assert Quotas.Evidence.current_freshness_state(stored, evaluation_at) == "fresh"
        refute confirmed_candidate(stored)
      end
    end

    @tag :quota_confirmed_convergence
    @tag :quota_reset_cycle_regression
    test "same-cycle usage with minute-scale backward reset drift refreshes stale evidence" do
      identity = active_identity_fixture()
      evaluation_at = quota_reset_evaluation_at()
      canonical_at = stale_quota_observed_at(evaluation_at)
      canonical_reset_at = DateTime.add(evaluation_at, 10, :minute)

      assert {:ok, [canonical]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(22, reset_at: canonical_reset_at),
                 canonical_at,
                 evaluation_at
               )

      incoming_at = DateTime.add(evaluation_at, -1, :second)

      assert {:ok, [stored]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(43,
                   reset_at: DateTime.add(canonical_reset_at, -90, :second),
                   reset_after_seconds: 510
                 ),
                 incoming_at,
                 evaluation_at
               )

      assert stored.id == canonical.id
      assert Decimal.equal?(stored.used_percent, Decimal.new("43"))
      assert DateTime.compare(stored.reset_at, canonical_reset_at) == :eq
      assert DateTime.compare(stored.observed_at, incoming_at) == :eq
      assert DateTime.compare(stored.last_sync_at, incoming_at) == :eq
      assert Quotas.Evidence.current_freshness_state(stored, evaluation_at) == "fresh"
      refute confirmed_candidate(stored)
    end

    @tag :quota_confirmed_convergence
    @tag :quota_reset_cycle_regression
    test "lower same-cycle usage with minute-scale backward drift keeps the higher canonical percent" do
      identity = active_identity_fixture()
      evaluation_at = quota_reset_evaluation_at()
      canonical_at = stale_quota_observed_at(evaluation_at)
      canonical_reset_at = DateTime.add(evaluation_at, 40, :minute)

      assert {:ok, [canonical]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(22,
                   reset_at: canonical_reset_at,
                   reset_after_seconds: 3300
                 ),
                 canonical_at,
                 evaluation_at
               )

      incoming_at = DateTime.add(evaluation_at, -1, :second)

      assert {:ok, [stored]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(8,
                   reset_at: DateTime.add(canonical_reset_at, -24, :minute),
                   reset_after_seconds: 959
                 ),
                 incoming_at,
                 evaluation_at
               )

      assert stored.id == canonical.id
      assert Decimal.equal?(stored.used_percent, Decimal.new("22"))
      assert DateTime.compare(stored.reset_at, canonical_reset_at) == :eq
      assert DateTime.compare(stored.observed_at, incoming_at) == :eq
      assert DateTime.compare(stored.last_sync_at, incoming_at) == :eq
      assert Quotas.Evidence.current_freshness_state(stored, evaluation_at) == "fresh"
      refute confirmed_candidate(stored)
    end

    for {window_kind, drift_seconds, incoming_percent} <- [
          {"primary", -1440, 8},
          {"secondary", -361, 2}
        ] do
      @tag :quota_confirmed_convergence
      @tag :quota_reset_cycle_regression
      test "positive #{window_kind} usage claim raises a stored same-cycle weak-zero claim" do
        identity = active_identity_fixture()
        evaluation_at = quota_reset_evaluation_at()
        canonical_at = DateTime.add(evaluation_at, -60, :second)

        {window_seconds, window_minutes} =
          case unquote(window_kind) do
            "primary" -> {18_000, 300}
            "secondary" -> {604_800, 10_080}
          end

        canonical_reset_at = DateTime.add(evaluation_at, div(window_seconds, 4), :second)

        zero_claim_payload = %{
          "rate_limit" => %{
            "#{unquote(window_kind)}_window" => %{
              "used_percent" => 0,
              "limit_window_seconds" => window_seconds,
              "reset_at" => DateTime.to_iso8601(canonical_reset_at),
              "reset_after_seconds" => DateTime.diff(canonical_reset_at, canonical_at, :second)
            }
          }
        }

        assert {:ok, [canonical]} =
                 upsert_codex_usage_payload_at(
                   identity,
                   zero_claim_payload,
                   canonical_at,
                   evaluation_at
                 )

        assert canonical.window_minutes == window_minutes
        assert Decimal.equal?(canonical.used_percent, Decimal.new(0))

        incoming_at = DateTime.add(evaluation_at, -1, :second)
        incoming_reset_at = DateTime.add(canonical_reset_at, unquote(drift_seconds), :second)

        positive_claim_payload = %{
          "rate_limit" => %{
            "#{unquote(window_kind)}_window" => %{
              "used_percent" => unquote(incoming_percent),
              "limit_window_seconds" => window_seconds,
              "reset_at" => DateTime.to_iso8601(incoming_reset_at),
              "reset_after_seconds" => DateTime.diff(incoming_reset_at, incoming_at, :second)
            }
          }
        }

        assert {:ok, [stored]} =
                 upsert_codex_usage_payload_at(
                   identity,
                   positive_claim_payload,
                   incoming_at,
                   evaluation_at
                 )

        assert stored.id == canonical.id
        assert Decimal.equal?(stored.used_percent, Decimal.new(unquote(incoming_percent)))
        assert DateTime.compare(stored.reset_at, canonical_reset_at) == :eq
        assert DateTime.compare(stored.observed_at, incoming_at) == :eq
        assert DateTime.compare(stored.last_sync_at, incoming_at) == :eq
        assert Quotas.Evidence.current_freshness_state(stored, evaluation_at) == "fresh"
        refute confirmed_candidate(stored)
      end
    end

    @tag :quota_confirmed_convergence
    @tag :quota_reset_cycle_regression
    test "same-cycle exhausted usage on a stale window re-confirms liveness without laundering" do
      identity = active_identity_fixture()
      evaluation_at = quota_reset_evaluation_at()
      canonical_at = stale_quota_observed_at(evaluation_at)
      canonical_reset_at = DateTime.add(evaluation_at, 10, :minute)

      assert {:ok, [canonical]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(22,
                   reset_at: canonical_reset_at,
                   reset_after_seconds: 1560
                 ),
                 canonical_at,
                 evaluation_at
               )

      incoming_at = DateTime.add(evaluation_at, -1, :second)

      assert {:ok, [stored]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(100,
                   reset_at: DateTime.add(canonical_reset_at, -3, :second),
                   reset_after_seconds: 597
                 ),
                 incoming_at,
                 evaluation_at
               )

      assert stored.id == canonical.id
      assert Decimal.equal?(stored.used_percent, Decimal.new("22"))
      assert DateTime.compare(stored.reset_at, canonical_reset_at) == :eq
      assert DateTime.compare(stored.observed_at, incoming_at) == :eq
      assert DateTime.compare(stored.last_sync_at, incoming_at) == :eq
      assert Quotas.Evidence.current_freshness_state(stored, evaluation_at) == "fresh"
    end

    @tag :quota_confirmed_convergence
    @tag :quota_reset_cycle_regression
    test "later absolute full-window outlier cannot launder a fresh known reset" do
      identity = active_identity_fixture()
      evaluation_at = quota_reset_evaluation_at()
      canonical_at = DateTime.add(evaluation_at, -60, :second)
      canonical_reset_at = DateTime.add(evaluation_at, 10, :minute)

      assert {:ok, [canonical]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(22, reset_at: canonical_reset_at),
                 canonical_at,
                 evaluation_at
               )

      incoming_at = DateTime.add(evaluation_at, -1, :second)

      assert {:ok, [stored]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(0,
                   reset_at: DateTime.add(evaluation_at, 5, :hour),
                   reset_after_seconds: 18_000
                 ),
                 incoming_at,
                 evaluation_at
               )

      assert_canonical_snapshot(stored, canonical)
      refute confirmed_candidate(stored)
    end

    @tag :quota_confirmed_convergence
    @tag :quota_reset_cycle_regression
    test "older absolute same-cycle observation cannot refresh canonical timestamps" do
      identity = active_identity_fixture()
      evaluation_at = quota_reset_evaluation_at()
      canonical_at = DateTime.add(evaluation_at, -60, :second)
      canonical_reset_at = DateTime.add(evaluation_at, 10, :minute)

      assert {:ok, [canonical]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(22, reset_at: canonical_reset_at),
                 canonical_at,
                 evaluation_at
               )

      older_at = DateTime.add(canonical_at, -1, :second)

      assert {:ok, [stored]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(43,
                   reset_at: canonical_reset_at,
                   reset_after_seconds: 601
                 ),
                 older_at,
                 evaluation_at
               )

      assert_canonical_snapshot(stored, canonical)
      refute confirmed_candidate(stored)
    end

    @tag :quota_confirmed_convergence
    @tag :quota_reset_cycle_regression
    test "same logical account retains source-distinct header and usage rows" do
      identity = active_identity_fixture()
      observed_at = quota_reset_evaluation_at()
      reset_at = DateTime.add(observed_at, 10, :minute)

      header_attrs =
        :account
        |> confirmed_convergence_attrs("primary", "17", reset_at, observed_at)
        |> Map.put(:source, "codex_response_headers")

      assert {:ok, header} = EvidenceStore.record_evidence(identity, header_attrs, observed_at)

      assert {:ok, [usage]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(22,
                   reset_at: reset_at,
                   reset_after_seconds: 600
                 ),
                 observed_at,
                 observed_at
               )

      assert header.id != usage.id

      assert Enum.sort(Enum.map(QuotaWindows.list_evidence(identity), & &1.source)) == [
               "codex_response_headers",
               "codex_usage_api"
             ]
    end

    for {reset_metadata, incoming_percent} <- [
          {:relative_only, 17},
          {:explicit_and_relative, 43}
        ] do
      @tag :quota_confirmed_convergence
      @tag :quota_reset_cycle_regression
      test "#{reset_metadata} provider reset metadata does not replace a stale 100% canonical" do
        identity = active_identity_fixture()
        evaluation_at = quota_reset_evaluation_at()
        canonical_at = stale_quota_observed_at(evaluation_at)
        canonical_reset_at = DateTime.add(evaluation_at, 10, :minute)

        assert {:ok, [canonical]} =
                 upsert_codex_usage_payload_at(
                   identity,
                   account_primary_usage_payload(100, reset_at: canonical_reset_at),
                   canonical_at,
                   evaluation_at
                 )

        incoming_at = DateTime.add(evaluation_at, -1, :second)

        reset_opts =
          case unquote(reset_metadata) do
            :relative_only ->
              [reset_after_seconds: 601]

            :explicit_and_relative ->
              [reset_at: canonical_reset_at, reset_after_seconds: 601]
          end

        assert {:ok, [stored]} =
                 upsert_codex_usage_payload_at(
                   identity,
                   account_primary_usage_payload(unquote(incoming_percent), reset_opts),
                   incoming_at,
                   evaluation_at
                 )

        selected =
          identity
          |> QuotaWindows.list_evidence()
          |> WindowSelector.best_account_window(:primary_5h, evaluation_at)

        measurements = Measurements.for_window(selected)

        assert stored.id == canonical.id
        assert selected.id == canonical.id
        assert Decimal.equal?(selected.used_percent, Decimal.new("100"))
        assert Decimal.equal?(measurements.used_percent, Decimal.new("100"))
        assert DateTime.compare(selected.reset_at, canonical_reset_at) == :eq
        refute confirmed_candidate(selected)
      end
    end

    @tag :quota_confirmed_convergence
    @tag :quota_reset_cycle_regression
    test "same-cycle 100% provider snapshot does not immediately replace a stale usable canonical" do
      identity = active_identity_fixture()
      evaluation_at = quota_reset_evaluation_at()
      canonical_at = stale_quota_observed_at(evaluation_at)
      canonical_reset_at = DateTime.add(evaluation_at, 10, :minute)

      assert {:ok, [canonical]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(61, reset_at: canonical_reset_at),
                 canonical_at,
                 evaluation_at
               )

      incoming_at = DateTime.add(evaluation_at, -1, :second)

      assert {:ok, [stored]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(100, reset_at: canonical_reset_at),
                 incoming_at,
                 evaluation_at
               )

      selected =
        identity
        |> QuotaWindows.list_evidence()
        |> WindowSelector.best_account_window(:primary_5h, evaluation_at)

      measurements = Measurements.for_window(selected)

      assert stored.id == canonical.id
      assert selected.id == canonical.id
      assert Decimal.equal?(selected.used_percent, Decimal.new("61"))
      assert Decimal.equal?(measurements.used_percent, Decimal.new("61"))
      assert DateTime.compare(selected.reset_at, canonical_reset_at) == :eq
      assert_confirmed_candidate(selected, "100", canonical_reset_at, incoming_at)

      confirmed_at = DateTime.add(incoming_at, 1, :second)

      assert {:ok, [confirmed]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(100, reset_at: canonical_reset_at),
                 confirmed_at,
                 evaluation_at
               )

      assert confirmed.id == canonical.id
      assert Decimal.equal?(confirmed.used_percent, Decimal.new("100"))
      assert DateTime.compare(confirmed.reset_at, canonical_reset_at) == :eq
      assert DateTime.compare(confirmed.observed_at, confirmed_at) == :eq
      refute confirmed_candidate(confirmed)
    end

    @tag :quota_confirmed_convergence
    @tag :quota_reset_cycle_regression
    test "forward provider reset cycle atomically replaces a stale canonical snapshot" do
      identity = active_identity_fixture()
      evaluation_at = quota_reset_evaluation_at()
      canonical_at = stale_quota_observed_at(evaluation_at)
      canonical_reset_at = DateTime.add(evaluation_at, 10, :minute)

      assert {:ok, [canonical]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(61, reset_at: canonical_reset_at),
                 canonical_at,
                 evaluation_at
               )

      incoming_at = DateTime.add(evaluation_at, -1, :second)
      incoming_reset_at = DateTime.add(canonical_reset_at, 2, :hour)

      assert {:ok, [stored]} =
               upsert_codex_usage_payload_at(
                 identity,
                 account_primary_usage_payload(0, reset_at: incoming_reset_at),
                 incoming_at,
                 evaluation_at
               )

      selected =
        identity
        |> QuotaWindows.list_evidence()
        |> WindowSelector.best_account_window(:primary_5h, evaluation_at)

      measurements = Measurements.for_window(selected)

      assert stored.id == canonical.id
      assert selected.id == canonical.id
      assert Decimal.equal?(selected.used_percent, Decimal.new("0"))
      assert Decimal.equal?(measurements.used_percent, Decimal.new("0"))
      assert DateTime.compare(selected.reset_at, incoming_reset_at) == :eq
      assert DateTime.compare(selected.observed_at, incoming_at) == :eq
      refute confirmed_candidate(selected)
    end

    @tag :quota_confirmed_convergence
    test "a provably newer cycle accepts lower evidence while stale, resetless, and inferred samples do not" do
      identity = active_identity_fixture()
      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(canonical_at, 5, :minute)

      canonical =
        record_confirmed_convergence!(identity, :account, "primary", "22", reset_at, canonical_at)

      stale_at = DateTime.add(canonical_at, 10, :second)

      stale =
        confirmed_convergence_attrs(:account, "primary", "14", reset_at, stale_at)
        |> Map.put(:freshness_state, "stale")
        |> then(&QuotaWindows.record_evidence(identity, &1, stale_at))
        |> then(fn {:ok, stored} -> stored end)

      assert_canonical_snapshot(stale, canonical)
      refute confirmed_candidate(stale)

      resetless_at = DateTime.add(canonical_at, 20, :second)

      resetless =
        confirmed_convergence_attrs(:account, "primary", "14", nil, resetless_at)
        |> then(&QuotaWindows.record_evidence(identity, &1, resetless_at))
        |> then(fn {:ok, stored} -> stored end)

      assert_canonical_snapshot(resetless, canonical)
      refute confirmed_candidate(resetless)

      inferred_at = DateTime.add(canonical_at, 30, :second)

      inferred =
        confirmed_convergence_attrs(:account, "primary", "14", reset_at, inferred_at)
        |> Map.put(:source_precision, "inferred")
        |> then(&QuotaWindows.record_evidence(identity, &1, inferred_at))
        |> then(fn {:ok, stored} -> stored end)

      assert_canonical_snapshot(inferred, canonical)
      refute confirmed_candidate(inferred)

      next_cycle_at = DateTime.add(canonical_at, 40, :second)
      next_reset_at = DateTime.add(reset_at, 2, :hour)

      next_cycle =
        record_confirmed_convergence!(
          identity,
          :account,
          "primary",
          "14",
          next_reset_at,
          next_cycle_at
        )

      assert Decimal.equal?(next_cycle.used_percent, Decimal.new("14"))
      assert DateTime.compare(next_cycle.reset_at, next_reset_at) == :eq
      assert DateTime.compare(next_cycle.observed_at, next_cycle_at) == :eq
      refute confirmed_candidate(next_cycle)
    end

    for boundary_percent <- ["0", "100"] do
      @tag :quota_confirmed_convergence
      test "confirms the #{boundary_percent}% boundary deterministically" do
        identity = active_identity_fixture()
        canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
        reset_at = DateTime.add(canonical_at, 2, :hour)

        canonical =
          record_confirmed_convergence!(
            identity,
            :feature,
            "primary",
            "22",
            reset_at,
            canonical_at
          )

        observed_at = DateTime.add(canonical_at, 10, :second)

        first =
          record_confirmed_convergence!(
            identity,
            :feature,
            "primary",
            unquote(boundary_percent),
            reset_at,
            observed_at
          )

        if unquote(boundary_percent) == "0" do
          assert_canonical_snapshot(first, canonical)
          assert_confirmed_candidate(first, "0", reset_at, observed_at)

          confirmed_at = DateTime.add(observed_at, 10, :second)

          confirmed =
            record_confirmed_convergence!(
              identity,
              :feature,
              "primary",
              "0.0",
              reset_at,
              confirmed_at
            )

          assert Decimal.equal?(confirmed.used_percent, Decimal.new("0"))
          assert DateTime.compare(confirmed.observed_at, confirmed_at) == :eq
          refute confirmed_candidate(confirmed)
        else
          assert Decimal.equal?(first.used_percent, Decimal.new("100"))
          assert DateTime.compare(first.observed_at, observed_at) == :eq
          refute confirmed_candidate(first)
        end
      end
    end

    @tag :quota_confirmed_convergence
    test "first lower candidate changes only bounded private metadata and updated_at" do
      identity = active_identity_fixture()
      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(canonical_at, 2, :hour)

      canonical =
        record_confirmed_convergence!(identity, :model, "primary", "22", reset_at, canonical_at)

      candidate_at = DateTime.add(canonical_at, 10, :second)

      candidate =
        record_confirmed_convergence!(
          identity,
          :model,
          "primary",
          "1.000",
          reset_at,
          candidate_at
        )

      assert_canonical_snapshot(candidate, canonical)
      assert candidate.metadata != canonical.metadata
      assert DateTime.compare(candidate.updated_at, canonical.updated_at) == :gt
      assert_confirmed_candidate(candidate, "1", reset_at, candidate_at)

      assert candidate.metadata
             |> Map.drop(Map.keys(canonical.metadata))
             |> Map.values()
             |> Enum.flat_map(&Map.keys/1)
             |> Enum.sort() == ["count", "observed_at", "reset_at", "used_percent", "version"]

      refute inspect(candidate.metadata) =~ "raw-provider-response"
      refute inspect(candidate.metadata) =~ "fixture-user@example.com"
    end

    @tag :quota_candidate_contract
    test "normalized evidence owns persistence descriptor and logical window keys" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      evidence =
        :model
        |> confirmed_convergence_attrs(
          "primary",
          "1",
          DateTime.add(observed_at, 1, :hour),
          observed_at
        )
        |> Map.merge(%{
          model: " Example-Model ",
          upstream_model: " UPSTREAM-MODEL ",
          raw_limit_id: " limit-id ",
          raw_limit_name: " Limit name ",
          raw_metered_feature: " meter "
        })
        |> Quotas.Evidence.new!(observed_at)

      assert Quotas.Evidence.identity_key(evidence) ==
               {"model", "codex_model", "example-model", "upstream-model", "model_quota",
                "primary", 300, "codex_usage_api", "limit-id", "Limit name", "meter"}

      assert Quotas.Evidence.descriptor_key(evidence) ==
               {"model", "codex_model", "example-model", "upstream-model", "model_quota",
                "codex_usage_api", "limit-id", "Limit name", "meter"}

      assert Quotas.Evidence.logical_window_key(evidence) ==
               {"model", "codex_model", "example-model", "upstream-model", "model_quota",
                "primary", 300}
    end

    @tag :quota_candidate_contract
    test "candidate metadata round-trips losslessly and malformed values clear without confirmation" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      reset_at = DateTime.add(observed_at, 1, :hour)

      evidence =
        :account
        |> confirmed_convergence_attrs(
          "primary",
          "14.123456789012345678901234567890",
          reset_at,
          observed_at
        )
        |> Quotas.Evidence.new!(observed_at)

      metadata = EvidenceStore.put_candidate(%{"fixture" => true}, evidence)
      assert {:ok, candidate} = EvidenceStore.parse_candidate(metadata)
      assert Decimal.equal?(candidate.used_percent, evidence.used_percent)
      assert candidate.reset_at == reset_at
      assert candidate.observed_at == observed_at
      assert EvidenceStore.candidate_equivalent?(candidate, evidence)

      assert EvidenceStore.candidate_equivalent?(candidate, %{
               evidence
               | reset_at: DateTime.add(reset_at, 5, :second)
             })

      refute EvidenceStore.candidate_equivalent?(candidate, %{
               evidence
               | reset_at: DateTime.add(reset_at, 6, :second)
             })

      encoded_candidate = metadata |> Map.drop(["fixture"]) |> Map.values() |> List.first()
      assert map_size(encoded_candidate) == 5
      assert encoded_candidate["used_percent"] == "14.12345678901234567890123456789"

      for malformed <- [
            Map.put(encoded_candidate, "version", 2),
            Map.put(encoded_candidate, "count", 2),
            Map.put(encoded_candidate, "used_percent", "not-a-decimal"),
            Map.put(encoded_candidate, "used_percent", "NaN"),
            Map.put(encoded_candidate, "used_percent", "Infinity"),
            Map.put(encoded_candidate, "used_percent", "Inf"),
            Map.put(encoded_candidate, "used_percent", "-0.0001"),
            Map.put(encoded_candidate, "used_percent", "100.0001"),
            Map.put(encoded_candidate, "reset_at", "not-a-time"),
            Map.put(encoded_candidate, "extra", true)
          ] do
        malformed_metadata =
          metadata
          |> EvidenceStore.clear_candidate()
          |> Map.put(metadata |> Map.drop(["fixture"]) |> Map.keys() |> List.first(), malformed)

        assert EvidenceStore.parse_candidate(malformed_metadata) == :none
        assert EvidenceStore.clear_candidate(malformed_metadata) == %{"fixture" => true}
      end

      for candidate_percent <- [Decimal.new("NaN"), Decimal.new("Infinity")] do
        refute EvidenceStore.candidate_equivalent?(
                 %{candidate | used_percent: candidate_percent},
                 evidence
               )
      end

      for boundary <- ["0", "100"] do
        boundary_metadata =
          Map.put(
            metadata,
            metadata |> Map.drop(["fixture"]) |> Map.keys() |> List.first(),
            Map.put(encoded_candidate, "used_percent", boundary)
          )

        assert {:ok, %{used_percent: decoded}} = EvidenceStore.parse_candidate(boundary_metadata)
        assert Decimal.equal?(decoded, Decimal.new(boundary))
      end
    end

    @tag :quota_candidate_contract
    test "candidate validity honors exact freshness reset and future-skew boundaries" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      ttl = Quotas.Evidence.freshness_ttl_seconds()
      skew = Quotas.Evidence.future_observed_skew_seconds()

      assert EvidenceStore.candidate_valid?(
               %{
                 used_percent: Decimal.new("14"),
                 reset_at: DateTime.add(now, 1, :second),
                 observed_at: DateTime.add(now, -ttl, :second)
               },
               now
             )

      refute EvidenceStore.candidate_valid?(
               %{
                 used_percent: Decimal.new("14"),
                 reset_at: DateTime.add(now, 1, :second),
                 observed_at: DateTime.add(now, -ttl - 1, :second)
               },
               now
             )

      refute EvidenceStore.candidate_valid?(
               %{used_percent: Decimal.new("14"), reset_at: now, observed_at: now},
               now
             )

      assert EvidenceStore.candidate_valid?(
               %{
                 used_percent: Decimal.new("14"),
                 reset_at: DateTime.add(now, skew + 1, :second),
                 observed_at: DateTime.add(now, skew, :second)
               },
               now
             )

      refute EvidenceStore.candidate_valid?(
               %{
                 used_percent: Decimal.new("14"),
                 reset_at: DateTime.add(now, skew + 2, :second),
                 observed_at: DateTime.add(now, skew + 1, :second)
               },
               now
             )
    end

    @tag :quota_confirmed_convergence
    test "candidate validity applies TTL reset-expiry and future-skew cutoffs during convergence" do
      ttl = Quotas.Evidence.freshness_ttl_seconds()
      future_skew = Quotas.Evidence.future_observed_skew_seconds()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      cutoff_margin = 60

      for {label, candidate_at, reset_at, confirmation_at, expected_result} <- [
            {:ttl_in_budget, DateTime.add(now, -ttl + cutoff_margin, :second),
             DateTime.add(now, cutoff_margin, :second), now, :confirmed},
            {:ttl_past, DateTime.add(now, -ttl - cutoff_margin, :second),
             DateTime.add(now, cutoff_margin, :second), now, :candidate_restarted},
            {:reset_exact, DateTime.add(now, -2, :second), now, now, :rejected},
            {:reset_future, DateTime.add(now, -2, :second),
             DateTime.add(now, cutoff_margin, :second), now, :confirmed},
            {:future_skew_in_budget, DateTime.add(now, future_skew - cutoff_margin, :second),
             DateTime.add(now, future_skew + 60, :second),
             DateTime.add(now, future_skew + 1, :second), :confirmed},
            {:future_skew_past, DateTime.add(now, future_skew + cutoff_margin, :second),
             DateTime.add(now, future_skew + cutoff_margin + 60, :second),
             DateTime.add(now, future_skew + cutoff_margin + 1, :second), :rejected}
          ] do
        identity = active_identity_fixture(%{account_label: "Candidate cutoff #{label}"})
        canonical_at = DateTime.add(candidate_at, -1, :second)

        canonical =
          record_confirmed_convergence!(
            identity,
            :account,
            "primary",
            "22",
            DateTime.add(reset_at, -1, :second),
            canonical_at
          )

        first =
          record_confirmed_convergence!(
            identity,
            :account,
            "primary",
            "14",
            reset_at,
            candidate_at
          )

        second =
          record_confirmed_convergence!(
            identity,
            :account,
            "primary",
            "14.0",
            reset_at,
            confirmation_at
          )

        case expected_result do
          :confirmed ->
            assert Decimal.equal?(second.used_percent, Decimal.new("14"))
            refute confirmed_candidate(second)

          :candidate_restarted ->
            assert_canonical_snapshot(first, canonical)
            assert_canonical_snapshot(second, canonical)
            assert_confirmed_candidate(second, "14", reset_at, confirmation_at)

          :rejected ->
            assert_canonical_snapshot(first, canonical)
            assert_canonical_snapshot(second, canonical)
        end
      end
    end

    @tag :quota_confirmed_convergence
    test "accepted runtime pressure stays separate and invalidates every matching provider candidate" do
      identity = active_identity_fixture()
      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(canonical_at, 2, :hour)

      provider_rows =
        for suffix <- ["alpha", "beta"] do
          attrs =
            :model
            |> confirmed_convergence_attrs("primary", "22", reset_at, canonical_at)
            |> Map.merge(%{
              raw_limit_id: "provider-limit-#{suffix}",
              raw_limit_name: "Provider limit #{suffix}",
              raw_metered_feature: "provider-meter-#{suffix}"
            })

          assert {:ok, canonical} = QuotaWindows.record_evidence(identity, attrs, canonical_at)

          lower_attrs =
            attrs
            |> Map.put(:used_percent, Decimal.new("1"))
            |> Map.put(:observed_at, DateTime.add(canonical_at, 10, :second))
            |> Map.put(:last_sync_at, DateTime.add(canonical_at, 10, :second))

          assert {:ok, candidate} =
                   QuotaWindows.record_evidence(
                     identity,
                     lower_attrs,
                     DateTime.add(canonical_at, 10, :second)
                   )

          assert candidate.id == canonical.id
          assert candidate.raw_limit_id == "provider-limit-#{suffix}"

          assert_confirmed_candidate(
            candidate,
            "1",
            reset_at,
            DateTime.add(canonical_at, 10, :second)
          )

          %{canonical: canonical, candidate: candidate}
        end

      unrelated_candidates =
        for attrs <- [
              :model
              |> confirmed_convergence_attrs("primary", "22", reset_at, canonical_at)
              |> Map.merge(%{
                model: "example-model-sibling",
                raw_limit_id: "provider-limit-sibling",
                raw_limit_name: "Provider limit sibling",
                raw_metered_feature: "provider-meter-sibling"
              }),
              confirmed_convergence_attrs(
                :account,
                "primary",
                "22",
                reset_at,
                canonical_at
              )
            ] do
          assert {:ok, canonical} = QuotaWindows.record_evidence(identity, attrs, canonical_at)

          candidate_at = DateTime.add(canonical_at, 10, :second)

          lower_attrs =
            attrs
            |> Map.put(:used_percent, Decimal.new("1"))
            |> Map.put(:observed_at, candidate_at)
            |> Map.put(:last_sync_at, candidate_at)

          assert {:ok, candidate} =
                   QuotaWindows.record_evidence(identity, lower_attrs, candidate_at)

          assert candidate.id == canonical.id
          assert_confirmed_candidate(candidate, "1", reset_at, candidate_at)
          candidate
        end

      source_attrs =
        :model
        |> confirmed_convergence_attrs("primary", "22", reset_at, canonical_at)
        |> Map.merge(%{
          raw_limit_id: "runtime-source-limit",
          raw_limit_name: "Runtime source limit",
          raw_metered_feature: "runtime-source-meter"
        })

      assert {:ok, source_canonical} =
               QuotaWindows.record_evidence(identity, source_attrs, canonical_at)

      candidate_at = DateTime.add(canonical_at, 10, :second)

      source_lower_attrs =
        source_attrs
        |> Map.put(:used_percent, Decimal.new("1"))
        |> Map.put(:observed_at, candidate_at)
        |> Map.put(:last_sync_at, candidate_at)

      assert {:ok, source_candidate} =
               QuotaWindows.record_evidence(identity, source_lower_attrs, candidate_at)

      assert source_candidate.id == source_canonical.id
      assert_confirmed_candidate(source_candidate, "1", reset_at, candidate_at)

      source_candidate =
        source_candidate
        |> Ecto.Changeset.change(source: "codex_response_headers")
        |> Repo.update!()

      unrelated_candidates = [source_candidate | unrelated_candidates]

      runtime_at = DateTime.add(canonical_at, 20, :second)

      runtime_attrs =
        :model
        |> confirmed_convergence_attrs("primary", "91", reset_at, runtime_at)
        |> Map.merge(%{
          source: "codex_rate_limit_event",
          raw_limit_id: nil,
          raw_limit_name: nil,
          raw_metered_feature: nil
        })

      assert {:ok, runtime} = QuotaWindows.record_evidence(identity, runtime_attrs, runtime_at)
      assert runtime.source == "codex_rate_limit_event"
      assert runtime.raw_limit_id == nil
      assert Enum.all?(provider_rows, &(&1.candidate.id != runtime.id))

      persisted = QuotaWindows.list_evidence(identity)
      assert Enum.count(persisted, &(&1.source == "codex_usage_api")) == 4
      assert Enum.count(persisted, &(&1.source == "codex_rate_limit_event")) == 1

      for %{canonical: canonical} <- provider_rows do
        provider = Enum.find(persisted, &(&1.id == canonical.id))
        assert_provider_canonical_snapshot(provider, canonical)
        refute confirmed_candidate(provider)
      end

      for candidate <- unrelated_candidates do
        preserved = Enum.find(persisted, &(&1.id == candidate.id))

        assert_confirmed_candidate(
          preserved,
          "1",
          reset_at,
          DateTime.add(canonical_at, 10, :second)
        )
      end
    end

    @tag :quota_confirmed_convergence
    test "rejected runtime pressure preserves every matching provider candidate" do
      identity = active_identity_fixture()
      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(canonical_at, 2, :hour)

      runtime_attrs =
        :model
        |> confirmed_convergence_attrs("primary", "91", reset_at, canonical_at)
        |> Map.merge(%{
          source: "codex_rate_limit_event",
          raw_limit_id: nil,
          raw_limit_name: nil,
          raw_metered_feature: nil
        })

      assert {:ok, runtime} =
               QuotaWindows.record_evidence(identity, runtime_attrs, canonical_at)

      provider =
        record_confirmed_convergence!(
          identity,
          :model,
          "primary",
          "22",
          reset_at,
          canonical_at
        )

      candidate_at = DateTime.add(canonical_at, 10, :second)

      candidate =
        record_confirmed_convergence!(
          identity,
          :model,
          "primary",
          "14",
          reset_at,
          candidate_at
        )

      assert_confirmed_candidate(candidate, "14", reset_at, candidate_at)

      runtime_at = DateTime.add(candidate_at, 10, :second)

      rejected_runtime_attrs =
        runtime_attrs
        |> Map.put(:used_percent, Decimal.new("1"))
        |> Map.put(:observed_at, runtime_at)
        |> Map.put(:last_sync_at, runtime_at)

      assert {:ok, rejected_runtime} =
               QuotaWindows.record_evidence(identity, rejected_runtime_attrs, runtime_at)

      assert rejected_runtime.id == runtime.id
      assert Decimal.equal?(rejected_runtime.used_percent, Decimal.new("91"))

      persisted_provider =
        identity
        |> QuotaWindows.list_evidence()
        |> Enum.find(&(&1.id == provider.id))

      assert_canonical_snapshot(persisted_provider, candidate)
      assert_confirmed_candidate(persisted_provider, "14", reset_at, candidate_at)
    end

    @tag :quota_confirmed_convergence
    test "failed and absent live probes preserve the original candidate" do
      for routes <- [
            %{
              "/backend-api/wham/usage" => {503, %{"error" => "unavailable"}},
              "/backend-api/codex/usage" => {503, %{"error" => "unavailable"}}
            },
            %{
              "/backend-api/wham/usage" => {200, %{}},
              "/backend-api/codex/usage" => {200, %{}}
            }
          ] do
        upstream = start_path_upstream(routes)

        %{identity: identity, pool: pool, assignment: assignment} =
          usage_assignment_fixture(upstream)

        canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
        reset_at = DateTime.add(canonical_at, 2, :hour)

        canonical =
          record_confirmed_convergence!(
            identity,
            :feature,
            "secondary",
            "22",
            reset_at,
            canonical_at
          )

        candidate_at = DateTime.add(canonical_at, 10, :second)

        candidate =
          record_confirmed_convergence!(
            identity,
            :feature,
            "secondary",
            "1",
            reset_at,
            candidate_at
          )

        assert {:ok, _result} = Upstreams.reconcile_pool_account(pool, assignment)

        original =
          identity
          |> QuotaWindows.list_evidence()
          |> Enum.find(&(&1.id == canonical.id))

        assert original.id == candidate.id
        assert_canonical_snapshot(original, canonical)
        assert_confirmed_candidate(original, "1", reset_at, candidate_at)
      end
    end

    @tag :quota_confirmed_convergence
    test "same-account advisory lock serializes equivalent lower writes into one canonical pair" do
      {identity, canonical, canonical_at, reset_at} =
        Sandbox.unboxed_run(Repo, fn ->
          identity = active_identity_fixture()
          canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
          reset_at = DateTime.add(canonical_at, 2, :hour)

          canonical =
            record_confirmed_convergence!(
              identity,
              :account,
              "primary",
              "22",
              reset_at,
              canonical_at
            )

          {identity, canonical, canonical_at, reset_at}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(
            from(window in Quota.AccountQuotaWindow,
              where: window.upstream_identity_id == ^identity.id
            )
          )

          Repo.delete_all(from(identity in UpstreamIdentity, where: identity.id == ^identity.id))
        end)
      end)

      parent = self()
      first_at = DateTime.add(canonical_at, 10, :second)
      second_at = DateTime.add(first_at, 10, :second)

      first =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
              Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [identity.id])
              send(parent, {:first_lock_acquired, backend_pid})

              receive do
                :persist_first -> :ok
              end

              record_confirmed_convergence!(
                identity,
                :account,
                "primary",
                "14",
                reset_at,
                first_at
              )
            end)
          end)
        end)

      assert_receive {:first_lock_acquired, first_backend_pid}

      second =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            send(parent, {:second_connection_ready, backend_pid})

            record_confirmed_convergence!(
              identity,
              :account,
              "primary",
              "14.0",
              DateTime.add(reset_at, 1, :second),
              second_at
            )
          end)
        end)

      assert_receive {:second_connection_ready, second_backend_pid}
      refute second_backend_pid == first_backend_pid
      assert_backend_waiting_on_lock!(second_backend_pid)
      send(first.pid, :persist_first)

      assert {:ok, first_result} = Task.await(first)
      second_result = Task.await(second)
      assert first_result.id == canonical.id
      assert second_result.id == canonical.id
      assert Decimal.equal?(second_result.used_percent, Decimal.new("14"))
      assert DateTime.compare(second_result.reset_at, DateTime.add(reset_at, 1, :second)) == :eq
      assert DateTime.compare(second_result.observed_at, second_at) == :eq
      refute confirmed_candidate(second_result)

      assert [persisted] =
               Sandbox.unboxed_run(Repo, fn -> QuotaWindows.list_evidence(identity) end)

      assert persisted.id == canonical.id
      assert Decimal.equal?(persisted.used_percent, Decimal.new("14"))
      assert DateTime.compare(persisted.reset_at, DateTime.add(reset_at, 1, :second)) == :eq
    end

    @tag :quota_confirmed_convergence
    @tag :quota_candidate_contract
    test "admin quota read model and MCP quota output never project private candidates" do
      owner_scope = fixture_owner_scope()
      pool = pool_fixture()
      identity = active_identity_fixture()
      assert {:ok, assignment} = PoolAssignments.create_pool_assignment(pool, identity, %{})
      assert {:ok, _assignment} = PoolAssignments.activate_pool_assignment(assignment)

      canonical_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(canonical_at, 2, :hour)

      canonical =
        record_confirmed_convergence!(identity, :account, "primary", "22", reset_at, canonical_at)

      candidate_evidence =
        :account
        |> confirmed_convergence_attrs(
          "primary",
          "14",
          reset_at,
          DateTime.add(canonical_at, 10, :second)
        )
        |> Quotas.Evidence.new!(DateTime.add(canonical_at, 10, :second))

      candidate_metadata = EvidenceStore.put_candidate(canonical.metadata, candidate_evidence)
      assert {:ok, candidate} = EvidenceStore.parse_candidate(candidate_metadata)
      assert Decimal.equal?(candidate.used_percent, Decimal.new("14"))

      assert {:ok, _canonical} =
               canonical
               |> Ecto.Changeset.change(metadata: candidate_metadata)
               |> Repo.update()

      admin_projection = QuotaReadModel.account_summaries_for_pool_ids([pool.id], canonical_at)

      assert {:ok, mcp_projection, mcp_text} =
               QuotaMetadata.list_upstream_quotas(%{}, %{auth: %{scope: owner_scope}})

      refute contains_confirmed_candidate?(admin_projection)
      refute contains_confirmed_candidate?(mcp_projection)
      refute contains_confirmed_candidate?(mcp_text)
      refute inspect(admin_projection) =~ "fixture"
      refute inspect(mcp_projection) =~ "fixture"
    end

    @tag :quota_rich_identity
    test "characterizes true duplicate rich identities as an atomic batch error" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      existing_attrs = rich_identity_attrs(observed_at, %{raw_limit_id: "existing-limit"})

      assert {:ok, [existing]} =
               QuotaWindows.upsert_quota_windows(identity, [existing_attrs],
                 delete_missing?: false
               )

      valid_sibling =
        rich_identity_attrs(observed_at, %{
          window_kind: "secondary",
          window_minutes: 10_080,
          raw_limit_id: "valid-sibling-limit"
        })

      duplicate_attrs = rich_identity_attrs(observed_at, %{raw_limit_id: "duplicate-limit"})

      assert {:error, %{code: :duplicate_quota_window_kind}} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [valid_sibling, duplicate_attrs, duplicate_attrs],
                 delete_missing?: false
               )

      assert [persisted] = QuotaWindows.list_evidence(identity)
      assert persisted.id == existing.id
      assert persisted.raw_limit_id == "existing-limit"
      assert Decimal.equal?(persisted.used_percent, Decimal.new("22"))
    end

    @tag :quota_rich_identity
    test "retains rich siblings merged from separate successful usage probe paths" do
      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {200,
             weekly_only_payload(%{
               "additional_rate_limits" => [
                 %{
                   "limit_name" => "GPT-5.3-Codex-Spark",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 31,
                       "limit_window_seconds" => 604_800
                     }
                   }
                 }
               ]
             })},
          "/backend-api/codex/usage" =>
            {200,
             %{
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 22,
                   "limit_window_seconds" => 18_000,
                   "reset_after_seconds" => 900
                 }
               },
               "additional_rate_limits" => [
                 %{
                   "limit_name" => "Codex Spark",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 41,
                       "limit_window_seconds" => 604_800
                     }
                   }
                 }
               ]
             }}
        })

      %{identity: identity, pool: pool, assignment: assignment} =
        usage_assignment_fixture(upstream)

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

      first_rows =
        identity
        |> QuotaWindows.list_evidence()
        |> Enum.filter(&(&1.quota_scope == "model" and &1.window_kind == "secondary"))

      assert length(first_rows) == 2

      assert MapSet.new(first_rows, & &1.raw_limit_name) ==
               MapSet.new(["GPT-5.3-Codex-Spark", "Codex Spark"])

      assert MapSet.size(MapSet.new(first_rows, &{&1.quota_key, &1.window_kind})) == 1
      assert MapSet.size(MapSet.new(first_rows, & &1.id)) == 2

      first_ids = Map.new(first_rows, &{&1.raw_limit_name, &1.id})

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

      repeated_rows =
        identity
        |> QuotaWindows.list_evidence()
        |> Enum.filter(&(&1.quota_scope == "model" and &1.window_kind == "secondary"))

      assert length(repeated_rows) == 2
      assert Map.new(repeated_rows, &{&1.raw_limit_name, &1.id}) == first_ids
    end

    for {dimension, variant} <- [
          {:scope, %{quota_scope: "feature"}},
          {:family, %{quota_family: "additional_limit"}},
          {:model, %{model: "example-model-beta"}},
          {:upstream_model, %{upstream_model: "provider-example-model-beta"}},
          {:duration, %{window_minutes: 600}},
          {:source, %{source: "codex_response_headers"}},
          {:raw_limit_id, %{raw_limit_id: "provider-limit-beta"}},
          {:raw_limit_name, %{raw_limit_name: "Provider limit beta"}},
          {:raw_metered_feature, %{raw_metered_feature: "provider-meter-beta"}}
        ] do
      @tag :quota_rich_identity
      test "retains stable sibling rows when rich identity differs by #{dimension}" do
        identity = active_identity_fixture()
        observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
        base = rich_identity_attrs(observed_at)
        sibling = Map.merge(base, unquote(Macro.escape(variant)))

        assert {:ok, stored} =
                 QuotaWindows.upsert_quota_windows(
                   identity,
                   [base, sibling],
                   delete_missing?: false
                 )

        assert length(stored) == 2
        assert MapSet.size(MapSet.new(stored, & &1.id)) == 2
        original_ids = MapSet.new(stored, & &1.id)

        assert {:ok, repeated} =
                 QuotaWindows.upsert_quota_windows(
                   identity,
                   [base, sibling],
                   delete_missing?: false
                 )

        assert MapSet.new(repeated, & &1.id) == original_ids

        persisted = QuotaWindows.list_evidence(identity)
        assert length(persisted) == 2
        assert MapSet.new(persisted, & &1.id) == original_ids
      end
    end

    @tag :quota_rich_identity
    test "refreshes source-distinct rich evidence without selecting the other source row" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      header_attrs =
        rich_identity_attrs(observed_at, %{source: "codex_response_headers"})

      usage_attrs = rich_identity_attrs(DateTime.add(observed_at, 10, :second))

      assert {:ok, [header]} =
               QuotaWindows.upsert_quota_windows(identity, [header_attrs], delete_missing?: false)

      assert {:ok, [usage]} =
               QuotaWindows.upsert_quota_windows(identity, [usage_attrs], delete_missing?: false)

      refute usage.id == header.id
      assert header.source == "codex_response_headers"
      assert usage.source == "codex_usage_api"

      assert {:ok, [refreshed_header]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   rich_identity_attrs(DateTime.add(observed_at, 20, :second), %{
                     source: "codex_response_headers",
                     used_percent: Decimal.new("24")
                   })
                 ],
                 delete_missing?: false
               )

      assert {:ok, [refreshed_usage]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   rich_identity_attrs(DateTime.add(observed_at, 30, :second), %{
                     used_percent: Decimal.new("25")
                   })
                 ],
                 delete_missing?: false
               )

      assert refreshed_header.id == header.id
      assert refreshed_usage.id == usage.id
      assert refreshed_header.source == "codex_response_headers"
      assert refreshed_usage.source == "codex_usage_api"

      persisted = QuotaWindows.list_evidence(identity)
      assert length(persisted) == 2

      assert Map.new(persisted, &{&1.source, &1.id}) == %{
               "codex_response_headers" => header.id,
               "codex_usage_api" => usage.id
             }
    end

    for {dimension, initial, normalized} <- [
          {:model, "Example-Model", "example-model"},
          {:upstream_model, "Provider-Example-Model", "provider-example-model"}
        ] do
      @tag :quota_rich_identity
      test "normalizes #{dimension} identity case while preserving the canonical row id" do
        identity = active_identity_fixture()
        observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
        dimension = unquote(dimension)

        assert {:ok, first} =
                 QuotaWindows.record_evidence(
                   identity,
                   rich_identity_attrs(observed_at, %{dimension => unquote(initial)}),
                   observed_at
                 )

        later_at = DateTime.add(observed_at, 10, :second)

        assert {:ok, normalized_row} =
                 QuotaWindows.record_evidence(
                   identity,
                   rich_identity_attrs(later_at, %{
                     dimension => unquote(normalized),
                     used_percent: Decimal.new("23")
                   }),
                   later_at
                 )

        assert normalized_row.id == first.id
        assert [persisted] = QuotaWindows.list_evidence(identity)
        assert persisted.id == first.id
        assert Decimal.equal?(persisted.used_percent, Decimal.new("23"))
      end
    end

    @tag :quota_rich_identity
    test "migrates one unambiguous historical Spark alias onto the canonical key" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, historical} =
               QuotaWindows.record_evidence(
                 identity,
                 rich_identity_attrs(observed_at, %{
                   quota_key: "codex_bengalfox",
                   model: "gpt-5.3-codex-spark",
                   upstream_model: nil,
                   raw_limit_id: "codex_bengalfox",
                   raw_limit_name: "GPT-5.3-Codex-Spark",
                   raw_metered_feature: "codex_bengalfox"
                 }),
                 observed_at
               )

      later_at = DateTime.add(observed_at, 10, :second)

      assert {:ok, canonical} =
               QuotaWindows.record_evidence(
                 identity,
                 rich_identity_attrs(later_at, %{
                   quota_key: "codex_spark",
                   model: "GPT-5.3-CODEX-SPARK",
                   upstream_model: nil,
                   raw_limit_id: "codex_bengalfox",
                   raw_limit_name: "GPT-5.3-Codex-Spark",
                   raw_metered_feature: "codex_bengalfox",
                   used_percent: Decimal.new("23")
                 }),
                 later_at
               )

      assert canonical.id == historical.id
      assert canonical.quota_key == "codex_spark"
      assert [persisted] = QuotaWindows.list_evidence(identity)
      assert persisted.id == historical.id
    end

    @tag :quota_rich_identity
    test "refuses ambiguous Spark alias migration without changing either row" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      aliases =
        for {quota_key, raw_limit_id} <- [
              {"codex_bengalfox", "provider-limit-alpha"},
              {"gpt_5_3_codex_spark", "provider-limit-beta"}
            ] do
          assert {:ok, alias_row} =
                   QuotaWindows.record_evidence(
                     identity,
                     rich_identity_attrs(observed_at, %{
                       quota_key: quota_key,
                       model: "gpt-5.3-codex-spark",
                       upstream_model: nil,
                       raw_limit_id: raw_limit_id
                     }),
                     observed_at
                   )

          alias_row
        end

      before =
        Map.new(aliases, &{&1.id, Map.take(&1, [:quota_key, :raw_limit_id, :used_percent])})

      later_at = DateTime.add(observed_at, 10, :second)

      assert {:error, %{code: :ambiguous_quota_window_alias}} =
               QuotaWindows.record_evidence(
                 identity,
                 rich_identity_attrs(later_at, %{
                   quota_key: "codex_spark",
                   model: "gpt-5.3-codex-spark",
                   upstream_model: nil,
                   raw_limit_id: "canonical-provider-limit"
                 }),
                 later_at
               )

      persisted = QuotaWindows.list_evidence(identity)
      assert length(persisted) == 2

      assert Map.new(persisted, &{&1.id, Map.take(&1, [:quota_key, :raw_limit_id])}) ==
               Map.new(before, fn {id, attrs} ->
                 {id, Map.take(attrs, [:quota_key, :raw_limit_id])}
               end)

      assert Enum.all?(persisted, fn row ->
               Decimal.equal?(row.used_percent, before[row.id].used_percent)
             end)
    end

    test "stores Spark rate-limit events without deriving rolling weekly resets" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      primary_reset_at = DateTime.add(observed_at, 900, :second)

      assert {:ok, [primary, secondary]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limits" => %{
                     "primary" => %{
                       "used_percent" => 14,
                       "window_minutes" => 300,
                       "reset_after_seconds" => 900
                     },
                     "secondary" => %{
                       "used_percent" => 24,
                       "window_minutes" => 10_080,
                       "reset_after_seconds" => 604_800
                     }
                   }
                 },
                 observed_at
               )

      assert primary.quota_key == "codex_spark"
      assert primary.window_kind == "primary"
      assert primary.source == "codex_rate_limit_event"
      assert primary.source_precision == "inferred"
      assert DateTime.compare(primary.reset_at, primary_reset_at) == :eq

      assert secondary.quota_key == "codex_spark"
      assert secondary.window_kind == "secondary"
      assert secondary.source == "codex_rate_limit_event"
      assert secondary.source_precision == "inferred"
      assert is_nil(secondary.reset_at)

      assert [stored_primary, stored_secondary] =
               QuotaWindows.list_quota_windows(identity)

      assert stored_primary.quota_key == "codex_spark"
      assert stored_primary.window_kind == "primary"
      assert DateTime.compare(stored_primary.reset_at, primary_reset_at) == :eq
      assert stored_secondary.quota_key == "codex_spark"
      assert stored_secondary.window_kind == "secondary"
      assert stored_secondary.source_precision == "inferred"
      assert is_nil(stored_secondary.reset_at)

      stale_weekly_reset_at = DateTime.add(observed_at, 604_800, :second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 50,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(stale_weekly_reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert [stored_stale_secondary] =
               identity
               |> QuotaWindows.list_quota_windows()
               |> Enum.filter(&(&1.window_kind == "secondary"))

      assert DateTime.compare(stored_stale_secondary.reset_at, stale_weekly_reset_at) == :eq

      assert {:ok, [_secondary]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "metered_feature" => "codex_bengalfox",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 51,
                       "window_minutes" => 10_080,
                       "reset_after_seconds" => 604_800
                     }
                   }
                 },
                 DateTime.add(observed_at, 60, :second)
               )

      assert [%{reset_at: nil, source_precision: "inferred"}] =
               identity
               |> QuotaWindows.list_quota_windows()
               |> Enum.filter(&(&1.window_kind == "secondary"))
    end

    test "Codex response headers merge without deleting unmentioned windows" do
      identity = active_identity_fixture()
      reset_at = DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.truncate(:second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("10"),
                   display_label: "Account",
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 },
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("20"),
                   display_label: "Account",
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 },
                 %{
                   quota_key: "codex_spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("55"),
                   display_label: "GPT-5.3-Codex-Spark",
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      assert {:ok, [_primary]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-primary-used-percent", ["12"]},
                   {"x-codex-primary-window-minutes", ["300"]},
                   {"x-codex-primary-reset-at", [DateTime.to_iso8601(reset_at)]}
                 ]
               )

      assert Enum.map(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               &{&1.quota_key, &1.window_kind, Decimal.to_integer(&1.used_percent), &1.source}
             ) == [
               {"account", "primary", 12, "codex_response_headers"},
               {"account", "secondary", 20, "codex_usage_api"},
               {"codex_spark", "primary", 55, "codex_usage_api"}
             ]

      assert {:ok, [_spark]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-bengalfox-primary-used-percent", ["44"]},
                   {"x-codex-bengalfox-primary-window-minutes", ["300"]},
                   {"x-codex-bengalfox-limit-name", ["gpt-5.3-codex-spark"]}
                 ]
               )

      assert Enum.map(
               QuotaWindows.quota_window_selection_data(identity).routing_windows,
               &{&1.quota_key, &1.window_kind, Decimal.to_integer(&1.used_percent), &1.source}
             ) == [
               {"account", "primary", 12, "codex_response_headers"},
               {"account", "secondary", 20, "codex_usage_api"},
               {"codex_spark", "primary", 55, "codex_usage_api"},
               {"codex_spark", "primary", 44, "codex_response_headers"}
             ]
    end

    test "account-only replacement preserves existing additional quota windows" do
      identity = active_identity_fixture()

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("40"),
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 },
                 %{
                   quota_key: "codex_spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("55"),
                   display_label: "GPT-5.3-Codex-Spark",
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("67"),
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      assert Enum.map(
               QuotaWindows.list_quota_windows(identity),
               &{&1.quota_key, &1.window_kind}
             ) ==
               [
                 {"account", "primary"},
                 {"account", "secondary"},
                 {"codex_spark", "primary"}
               ]
    end

    test "preserves unknown reset-bearing Codex header families with raw identifiers" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(observed_at, 3600, :second)

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-future-family-primary-used-percent", ["33.5"]},
                   {"x-codex-future-family-primary-window-minutes", ["60"]},
                   {"x-codex-future-family-primary-reset-at", [DateTime.to_iso8601(reset_at)]}
                 ],
                 observed_at
               )

      assert window.quota_key == "codex_future_family"
      assert window.window_kind == "primary"
      assert window.source == "codex_response_headers"
      assert window.source_precision == "observed"
      assert window.quota_scope == "feature"
      assert window.quota_family == "codex_future_family"
      assert window.display_label == "codex_future_family"
      assert window.raw_limit_id == "codex_future_family"
      assert window.raw_metered_feature == "codex_future_family"
      assert Decimal.equal?(window.used_percent, Decimal.from_float(33.5))
      assert DateTime.compare(window.observed_at, observed_at) == :eq
      assert DateTime.compare(window.reset_at, reset_at) == :eq
      assert QuotaWindows.usable_window?(window, observed_at)
    end

    test "preserves unknown reset-bearing usage families with raw upstream identifiers" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      expected_reset_at = DateTime.add(observed_at, 1_200, :second)

      assert {:ok, windows} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 10,
                       "limit_window_seconds" => 18_000,
                       "reset_after_seconds" => 900
                     }
                   },
                   "additional_rate_limits" => [
                     %{
                       "limit_id" => "future-limit",
                       "rate_limit" => %{
                         "primary_window" => %{
                           "used_percent" => 42,
                           "limit_window_seconds" => 18_000,
                           "reset_after_seconds" => 1_200
                         }
                       }
                     }
                   ]
                 },
                 observed_at
               )

      assert unknown = Enum.find(windows, &(&1.quota_key == "future_limit"))
      assert unknown.window_kind == "primary"
      assert unknown.source == "codex_usage_api"
      assert unknown.source_precision == "inferred"
      assert unknown.quota_scope == "feature"
      assert unknown.quota_family == "future_limit"
      assert unknown.display_label == "future-limit"
      assert unknown.limit_name == nil
      assert unknown.model == nil
      assert unknown.raw_limit_id == "future-limit"
      assert unknown.raw_limit_name == nil
      assert unknown.raw_metered_feature == "future-limit"
      assert DateTime.compare(unknown.reset_at, expected_reset_at) == :eq
      assert QuotaWindows.usable_window?(unknown, observed_at)
    end

    test "stores reset-bearing Codex rate limit events for unknown limit families" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(observed_at, 1800, :second)

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "metered_limit_name" => "codex_future_family",
                   "rate_limits" => %{
                     "primary" => %{
                       "used_percent" => "45",
                       "window_minutes" => "300",
                       "reset_at" => DateTime.to_unix(reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert window.quota_key == "codex_future_family"
      assert window.window_kind == "primary"
      assert window.source == "codex_rate_limit_event"
      assert window.source_precision == "observed"
      assert window.quota_scope == "feature"
      assert window.quota_family == "codex_future_family"
      assert window.raw_limit_id == "codex_future_family"
      assert DateTime.compare(window.reset_at, reset_at) == :eq
      assert QuotaWindows.usable_window?(window, observed_at)
    end

    test "normalizes explicit reset-bearing rate-limit error payloads" do
      observed_at = ~U[2026-04-27 12:00:00Z]

      assert [evidence] =
               Quotas.parse_rate_limit_error(
                 %{
                   "limit_id" => "codex_future_family",
                   "window_kind" => "secondary",
                   "window_minutes" => "10080",
                   "used_percent" => "100",
                   "reset_after_seconds" => "120"
                 },
                 observed_at
               )

      assert evidence.source == "codex_rate_limit_error"
      assert evidence.source_precision == "observed"
      assert evidence.quota_scope == "feature"
      assert evidence.quota_family == "codex_future_family"
      assert evidence.raw_limit_id == "codex_future_family"
      assert evidence.window_kind == "secondary"
      assert evidence.observed_at == observed_at
      assert DateTime.compare(evidence.reset_at, DateTime.add(observed_at, 120, :second)) == :eq
      refute Quotas.Evidence.routing_usable?(evidence, observed_at)
    end

    test "remaps weekly-duration primary header slot to the weekly secondary window" do
      observed_at = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(observed_at, 3 * 24 * 3600, :second)

      assert [evidence] =
               Quotas.parse_codex_headers(
                 [
                   {"x-codex-primary-used-percent", ["42"]},
                   {"x-codex-primary-window-minutes", ["10080"]},
                   {"x-codex-primary-reset-at", [DateTime.to_iso8601(reset_at)]}
                 ],
                 observed_at
               )

      assert evidence.quota_key == "account"
      assert evidence.window_kind == "secondary"
      assert evidence.window_minutes == 10_080
      assert evidence.source == "codex_response_headers"
      assert DateTime.compare(evidence.reset_at, reset_at) == :eq
    end

    test "weekly-duration primary header slot merges into one weekly identity beside secondary headers" do
      observed_at = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(observed_at, 3 * 24 * 3600, :second)

      assert [evidence] =
               Quotas.parse_codex_headers(
                 [
                   {"x-codex-primary-used-percent", ["42"]},
                   {"x-codex-primary-window-minutes", ["10080"]},
                   {"x-codex-primary-reset-at", [DateTime.to_iso8601(reset_at)]},
                   {"x-codex-secondary-used-percent", ["67"]},
                   {"x-codex-secondary-window-minutes", ["10080"]},
                   {"x-codex-secondary-reset-at", [DateTime.to_iso8601(reset_at)]}
                 ],
                 observed_at
               )

      assert evidence.window_kind == "secondary"
      assert evidence.window_minutes == 10_080
      assert Decimal.equal?(evidence.used_percent, Decimal.new("67"))
    end

    test "remaps weekly-duration primary rate limit event slot to the weekly secondary window" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(observed_at, 3 * 24 * 3600, :second)

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "primary" => %{
                       "used_percent" => "42",
                       "window_minutes" => "10080",
                       "reset_at" => DateTime.to_unix(reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert window.quota_key == "account"
      assert window.window_kind == "secondary"
      assert window.window_minutes == 10_080
      assert window.source == "codex_rate_limit_event"
      assert DateTime.compare(window.reset_at, reset_at) == :eq
    end

    test "remaps weekly-duration primary rate-limit error payloads to the weekly secondary window" do
      observed_at = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(observed_at, 3 * 24 * 3600, :second)

      assert [evidence] =
               Quotas.parse_rate_limit_error(
                 %{
                   "window_kind" => "primary",
                   "window_minutes" => "10080",
                   "used_percent" => "100",
                   "reset_at" => DateTime.to_unix(reset_at)
                 },
                 observed_at
               )

      assert evidence.quota_key == "account"
      assert evidence.window_kind == "secondary"
      assert evidence.window_minutes == 10_080
      assert evidence.source == "codex_rate_limit_error"
    end

    test "resetless evidence persists for display but is not routing usable" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-future-limit-primary-used-percent", ["22"]},
                   {"x-future-limit-primary-window-minutes", ["300"]}
                 ],
                 observed_at
               )

      assert window.quota_key == "future_limit"
      assert window.window_kind == "primary"
      assert window.source == "codex_response_headers"
      assert window.source_precision == "inferred"
      assert window.quota_scope == "feature"
      assert window.quota_family == "future_limit"
      assert window.display_label == "future_limit"
      assert window.raw_limit_id == "future_limit"
      assert window.raw_metered_feature == "future_limit"
      assert window.reset_at == nil
      assert DateTime.compare(window.observed_at, observed_at) == :eq
      assert QuotaWindows.fresh_window?(window, observed_at)
      refute QuotaWindows.usable_window?(window, observed_at)

      refute QuotaWindows.quota_window_selection_data(identity,
               at: observed_at
             ).usable?
    end

    test "stores Codex rate limit reached type header as sanitized metadata" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(observed_at, 900, :second)

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-primary-used-percent", ["100"]},
                   {"x-codex-primary-window-minutes", ["300"]},
                   {"x-codex-primary-reset-at", [DateTime.to_iso8601(reset_at)]},
                   {"x-codex-rate-limit-reached-type", ["workspace_member_credits_depleted"]}
                 ],
                 observed_at
               )

      assert window.quota_key == "account"
      assert window.source == "codex_response_headers"
      assert window.metadata["header_limit_id"] == "codex"
      assert window.metadata["rate_limit_reached_type"] == "workspace_member_credits_depleted"
      refute QuotaWindows.usable_window?(window, observed_at)
    end

    test "ignores unknown Codex rate limit reached type header values" do
      observed_at = ~U[2026-04-27 12:00:00Z]

      assert [evidence] =
               Quotas.parse_codex_headers(
                 [
                   {"x-codex-primary-used-percent", ["99"]},
                   {"x-codex-primary-window-minutes", ["300"]},
                   {"x-codex-rate-limit-reached-type", ["future_workspace_limit"]}
                 ],
                 observed_at
               )

      refute Map.has_key?(evidence.metadata, "rate_limit_reached_type")
    end

    test "model-specific quota evidence only routes matching requested or upstream models" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(observed_at, 900, :second)

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "gpt-5.3-codex-spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("33"),
                   reset_at: reset_at,
                   display_label: "GPT-5.3-Codex-Spark",
                   source: "codex_usage_api",
                   source_precision: "observed",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   upstream_model: "upstream-gpt-5.3-codex-spark",
                   raw_limit_id: "codex_bengalfox",
                   raw_limit_name: "gpt-5.3-codex-spark",
                   raw_metered_feature: "codex_bengalfox",
                   observed_at: observed_at,
                   freshness_state: "fresh"
                 }
               ])

      assert QuotaWindows.usable_window?(window, observed_at)

      assert QuotaWindows.usable_window?(window, observed_at, model: "gpt-5.3-codex-spark")

      assert QuotaWindows.usable_window?(window, observed_at,
               upstream_model: "upstream-gpt-5.3-codex-spark"
             )

      refute QuotaWindows.usable_window?(window, observed_at, model: "gpt-6-codex-other")

      matching_selection =
        QuotaWindows.quota_window_selection_data(identity,
          at: observed_at,
          model: "gpt-5.3-codex-spark"
        )

      assert matching_selection.usable?
      assert Enum.map(matching_selection.fresh_windows, & &1.id) == [window.id]

      unrelated_selection =
        QuotaWindows.quota_window_selection_data(identity,
          at: observed_at,
          model: "gpt-6-codex-other"
        )

      refute unrelated_selection.usable?
      assert Enum.map(unrelated_selection.windows, & &1.id) == [window.id]
      assert unrelated_selection.fresh_windows == []
      assert unrelated_selection.blocked_windows == []
    end

    test "newer reset-bearing usage evidence advances reset-bearing header evidence" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      old_reset_at = DateTime.add(observed_at, 900, :second)
      new_observed_at = DateTime.add(observed_at, 60, :second)
      new_reset_at = DateTime.add(new_observed_at, 604_800, :second)

      assert {:ok, [header_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-secondary-used-percent", ["100"]},
                   {"x-codex-secondary-window-minutes", ["10080"]},
                   {"x-codex-secondary-reset-at", [DateTime.to_iso8601(old_reset_at)]}
                 ],
                 observed_at
               )

      assert header_window.source == "codex_response_headers"
      assert Decimal.equal?(header_window.used_percent, Decimal.new("100.000"))
      refute QuotaWindows.usable_window?(header_window, observed_at)

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("0"),
                     reset_at: new_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     quota_scope: "account",
                     quota_family: "account",
                     observed_at: new_observed_at,
                     freshness_state: "fresh"
                   }
                 ]
               )

      refute merged_window.id == header_window.id
      assert merged_window.source == "codex_usage_api"
      assert DateTime.compare(merged_window.reset_at, new_reset_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("0"))
      assert QuotaWindows.usable_window?(merged_window, new_observed_at)
    end

    test "newer usage evidence cannot roll back a later header reset" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      header_reset_at = DateTime.add(observed_at, 604_800, :second)
      usage_observed_at = DateTime.add(observed_at, 60, :second)
      usage_reset_at = DateTime.add(observed_at, 900, :second)

      assert {:ok, [header_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-secondary-used-percent", ["20"]},
                   {"x-codex-secondary-window-minutes", ["10080"]},
                   {"x-codex-secondary-reset-at", [DateTime.to_iso8601(header_reset_at)]}
                 ],
                 observed_at
               )

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("0"),
                     reset_at: usage_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     quota_scope: "account",
                     quota_family: "account",
                     observed_at: usage_observed_at,
                     freshness_state: "fresh"
                   }
                 ]
               )

      refute merged_window.id == header_window.id
      assert merged_window.source == "codex_usage_api"
      assert DateTime.compare(merged_window.reset_at, usage_reset_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("0"))
    end

    @tag :upstream_quota_dashboard_regression
    test "usage evidence does not override higher-precedence rate-limit event evidence" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      event_reset_at = DateTime.add(observed_at, 900, :second)
      usage_observed_at = DateTime.add(observed_at, 60, :second)
      usage_reset_at = DateTime.add(usage_observed_at, 604_800, :second)

      assert {:ok, [event_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 100,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(event_reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert event_window.source == "codex_rate_limit_event"

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("0"),
                     reset_at: usage_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     quota_scope: "account",
                     quota_family: "account",
                     observed_at: usage_observed_at,
                     freshness_state: "fresh"
                   }
                 ]
               )

      refute merged_window.id == event_window.id
      assert merged_window.source == "codex_usage_api"
      assert DateTime.compare(merged_window.reset_at, usage_reset_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("0"))
    end

    test "usage evidence replaces zero percent-only rate-limit event evidence" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      event_reset_at = DateTime.add(observed_at, 604_800, :second)
      usage_observed_at = DateTime.add(observed_at, 60, :second)
      usage_reset_at = DateTime.add(usage_observed_at, 604_800, :second)
      later_event_observed_at = DateTime.add(usage_observed_at, 60, :second)
      later_event_reset_at = DateTime.add(later_event_observed_at, 604_800, :second)

      assert {:ok, [event_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 0,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(event_reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert event_window.source == "codex_rate_limit_event"

      assert {:ok, [usage_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("12"),
                     reset_at: usage_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     quota_scope: "account",
                     quota_family: "account",
                     observed_at: usage_observed_at,
                     freshness_state: "fresh"
                   }
                 ]
               )

      refute usage_window.id == event_window.id
      assert usage_window.source == "codex_usage_api"
      assert DateTime.compare(usage_window.reset_at, usage_reset_at) == :eq
      assert Decimal.equal?(usage_window.used_percent, Decimal.new("12"))

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_rate_limit_event(
                 identity,
                 %{
                   "type" => "codex.rate_limits",
                   "rate_limits" => %{
                     "secondary" => %{
                       "used_percent" => 0,
                       "window_minutes" => 10_080,
                       "reset_at" => DateTime.to_unix(later_event_reset_at)
                     }
                   }
                 },
                 later_event_observed_at
               )

      assert merged_window.id == event_window.id
      assert merged_window.source == "codex_rate_limit_event"
      assert DateTime.to_unix(merged_window.reset_at) == DateTime.to_unix(later_event_reset_at)
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("0"))
    end

    @tag :upstream_quota_evidence_stability
    test "weak zero usage outlier keeps the stronger account snapshot unchanged" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      reset_at = DateTime.add(observed_at, 2, :hour)
      weak_observed_at = DateTime.add(observed_at, 60, :second)
      weak_reset_at = DateTime.add(weak_observed_at, 4, :hour)

      assert {:ok, [known_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("11"),
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("0"),
                   reset_at: weak_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: weak_observed_at
                 }
               ])

      assert merged_window.id == known_window.id
      assert merged_window.source == "codex_usage_api"
      assert DateTime.compare(merged_window.reset_at, reset_at) == :eq
      assert DateTime.compare(merged_window.observed_at, observed_at) == :eq
      assert DateTime.compare(merged_window.last_sync_at, known_window.last_sync_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("11"))
    end

    @tag :upstream_quota_evidence_stability
    test "relative weak zero usage outlier cannot split account percent from its reset" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(observed_at, 2, :hour)
      weak_observed_at = DateTime.add(observed_at, 60, :second)
      weak_reset_at = DateTime.add(reset_at, 23, :minute)
      recovered_observed_at = DateTime.add(observed_at, 120, :second)

      payload = fn used_percent, sample_at, sample_reset_at ->
        %{
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => 18_000,
              "reset_after_seconds" => DateTime.diff(sample_reset_at, sample_at, :second),
              "reset_at" => DateTime.to_unix(sample_reset_at)
            }
          }
        }
      end

      assert {:ok, [known_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload.(10, observed_at, reset_at),
                 observed_at
               )

      assert {:ok, [after_outlier]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload.(0, weak_observed_at, weak_reset_at),
                 weak_observed_at
               )

      assert after_outlier.id == known_window.id
      assert Decimal.equal?(after_outlier.used_percent, Decimal.new("10"))
      assert DateTime.compare(after_outlier.reset_at, reset_at) == :eq

      assert {:ok, [recovered_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload.(10, recovered_observed_at, reset_at),
                 recovered_observed_at
               )

      assert recovered_window.id == known_window.id
      assert Decimal.equal?(recovered_window.used_percent, Decimal.new("10"))
      assert DateTime.compare(recovered_window.reset_at, reset_at) == :eq
    end

    @tag :upstream_quota_evidence_stability
    test "incomplete free-plan usage cannot split percent from preserved credit capacity" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(observed_at, 28, :day)
      incomplete_observed_at = DateTime.add(observed_at, 60, :second)
      incomplete_reset_at = DateTime.add(observed_at, 12, :day)

      payload = fn used_percent, sample_at, sample_reset_at ->
        %{
          "credits" => %{"balance" => 3_521},
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => 2_592_000,
              "reset_after_seconds" => DateTime.diff(sample_reset_at, sample_at, :second),
              "reset_at" => DateTime.to_unix(sample_reset_at)
            }
          }
        }
      end

      assert {:ok, [complete_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload.(16.007, observed_at, reset_at),
                 observed_at
               )

      assert complete_window.active_limit == 4_192
      assert complete_window.credits == 3_521
      assert Decimal.equal?(complete_window.used_percent, Decimal.new("16.007"))

      assert {:ok, [after_incomplete]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload.(100, incomplete_observed_at, incomplete_reset_at),
                 incomplete_observed_at
               )

      assert after_incomplete.id == complete_window.id
      assert after_incomplete.active_limit == 4_192
      assert after_incomplete.credits == 3_521
      assert_in_delta Decimal.to_float(after_incomplete.used_percent), 16.006_679, 0.000_001

      assert DateTime.compare(after_incomplete.reset_at, reset_at) == :eq
    end

    @tag :upstream_quota_evidence_stability
    test "relative free-plan usage cannot replace an explicit reset or its metadata" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(observed_at, 28, :day)
      incoming_at = DateTime.add(observed_at, 60, :second)

      assert {:ok, [complete_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "credits" => %{"balance" => 3_521},
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 16.007,
                       "limit_window_seconds" => 2_592_000,
                       "reset_at" => DateTime.to_unix(reset_at),
                       "reset_after_seconds" => DateTime.diff(reset_at, observed_at, :second)
                     }
                   }
                 },
                 observed_at
               )

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "credits" => %{"balance" => 3_521},
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 100,
                       "limit_window_seconds" => 2_592_000,
                       "reset_after_seconds" => 2_592_000
                     }
                   }
                 },
                 incoming_at
               )

      assert merged_window.id == complete_window.id
      assert merged_window.source_precision == "observed"
      assert DateTime.compare(merged_window.reset_at, reset_at) == :eq

      assert merged_window.metadata["reset_after_seconds"] ==
               complete_window.metadata["reset_after_seconds"]

      assert merged_window.active_limit == 4_192
      assert merged_window.credits == 3_521
      assert_in_delta Decimal.to_float(merged_window.used_percent), 16.006_679, 0.000_001
    end

    for incoming_percent <- [16.007, 8] do
      @tag :upstream_quota_evidence_stability
      test "relative free-plan #{incoming_percent} percent usage keeps explicit reset provenance" do
        identity = active_identity_fixture()
        observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
        reset_at = DateTime.add(observed_at, 28, :day)
        incoming_at = DateTime.add(observed_at, 60, :second)

        assert {:ok, [complete_window]} =
                 QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                   identity,
                   %{
                     "credits" => %{"balance" => 3_521},
                     "rate_limit" => %{
                       "primary_window" => %{
                         "used_percent" => 16.007,
                         "limit_window_seconds" => 2_592_000,
                         "reset_at" => DateTime.to_unix(reset_at),
                         "reset_after_seconds" => DateTime.diff(reset_at, observed_at, :second)
                       }
                     }
                   },
                   observed_at
                 )

        assert {:ok, [merged_window]} =
                 QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                   identity,
                   %{
                     "credits" => %{"balance" => 3_521},
                     "rate_limit" => %{
                       "primary_window" => %{
                         "used_percent" => unquote(incoming_percent),
                         "limit_window_seconds" => 2_592_000,
                         "reset_after_seconds" => 2_592_000
                       }
                     }
                   },
                   incoming_at
                 )

        assert merged_window.id == complete_window.id
        assert merged_window.source_precision == "observed"
        assert DateTime.compare(merged_window.reset_at, reset_at) == :eq

        assert merged_window.metadata["reset_after_seconds"] ==
                 complete_window.metadata["reset_after_seconds"]

        assert merged_window.active_limit == 4_192
        assert merged_window.credits == 3_521
        assert_in_delta Decimal.to_float(merged_window.used_percent), 16.006_679, 0.000_001
      end
    end

    @tag :upstream_quota_evidence_stability
    test "zero free-plan credit balance replaces stale positive credits atomically" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(observed_at, 28, :day)
      incoming_at = DateTime.add(observed_at, 60, :second)

      complete_payload = %{
        "credits" => %{"balance" => 3_521},
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 16.007,
            "limit_window_seconds" => 2_592_000,
            "reset_at" => DateTime.to_unix(reset_at)
          }
        }
      }

      assert {:ok, [_complete_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 complete_payload,
                 observed_at
               )

      exhausted_payload =
        put_in(complete_payload, ["credits", "balance"], 0)
        |> put_in(["rate_limit", "primary_window", "used_percent"], 100)

      assert {:ok, [exhausted_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 exhausted_payload,
                 incoming_at
               )

      assert exhausted_window.active_limit == 4_192
      assert exhausted_window.credits == 0
      assert Decimal.equal?(exhausted_window.used_percent, Decimal.new(100))
      assert DateTime.compare(exhausted_window.reset_at, reset_at) == :eq
    end

    @tag :upstream_quota_evidence_stability
    test "missing free-plan credit balance preserves the last known balance" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(observed_at, 28, :day)
      incoming_at = DateTime.add(observed_at, 60, :second)

      assert {:ok, [_complete_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "credits" => %{"balance" => 3_521},
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 16.007,
                       "limit_window_seconds" => 2_592_000,
                       "reset_at" => DateTime.to_unix(reset_at)
                     }
                   }
                 },
                 observed_at
               )

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 %{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 100,
                       "limit_window_seconds" => 2_592_000,
                       "reset_at" => DateTime.to_unix(reset_at)
                     }
                   }
                 },
                 incoming_at
               )

      assert merged_window.active_limit == 4_192
      assert merged_window.credits == 3_521
      assert_in_delta Decimal.to_float(merged_window.used_percent), 16.006_679, 0.000_001
      assert DateTime.compare(merged_window.reset_at, reset_at) == :eq
    end

    @tag :upstream_quota_evidence_stability
    test "free-plan credit balance above known capacity preserves the last known balance" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(observed_at, 28, :day)
      incoming_at = DateTime.add(observed_at, 60, :second)

      payload = fn credits, used_percent ->
        %{
          "credits" => %{"balance" => credits},
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => 2_592_000,
              "reset_at" => DateTime.to_unix(reset_at)
            }
          }
        }
      end

      assert {:ok, [_complete_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload.(3_521, 16.007),
                 observed_at
               )

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 payload.(5_000, 100),
                 incoming_at
               )

      assert merged_window.active_limit == 4_192
      assert merged_window.credits == 3_521
      assert_in_delta Decimal.to_float(merged_window.used_percent), 16.006_679, 0.000_001
      assert DateTime.compare(merged_window.reset_at, reset_at) == :eq
    end

    @tag :upstream_quota_evidence_stability
    test "runtime usage without credits preserves a known credit balance" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(observed_at, 2, :hour)
      incoming_at = DateTime.add(observed_at, 60, :second)

      assert {:ok, [known_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 4_192,
                   credits: 3_521,
                   used_percent: Decimal.new("16.007"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("43"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: incoming_at
                 }
               ])

      assert merged_window.id == known_window.id
      assert merged_window.active_limit == 4_192
      assert merged_window.credits == 3_521
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("43"))
      assert DateTime.compare(merged_window.reset_at, reset_at) == :eq
    end

    @tag :upstream_quota_evidence_stability
    test "stronger account usage snapshot replaces the earlier snapshot atomically" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      reset_at = DateTime.add(observed_at, 2, :hour)
      weak_observed_at = DateTime.add(observed_at, 60, :second)
      weak_reset_at = DateTime.add(weak_observed_at, 4, :hour)

      assert {:ok, [known_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("6"),
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("7"),
                   reset_at: weak_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: weak_observed_at
                 }
               ])

      assert merged_window.id == known_window.id
      assert DateTime.compare(merged_window.reset_at, weak_reset_at) == :eq
      assert DateTime.compare(merged_window.observed_at, weak_observed_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("7"))
    end

    @tag :upstream_quota_evidence_stability
    test "provider 5h snapshots converge atomically regardless of arrival order" do
      observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      short_reset_at = DateTime.add(observed_at, 45, :minute)
      long_reset_at = DateTime.add(observed_at, 4, :hour)
      one_second_later = DateTime.add(observed_at, 1, :second)

      snapshot = fn used_percent, reset_at, sample_at ->
        {%{
           "rate_limit" => %{
             "primary_window" => %{
               "used_percent" => used_percent,
               "limit_window_seconds" => 18_000,
               "reset_after_seconds" => DateTime.diff(reset_at, sample_at, :second),
               "reset_at" => DateTime.to_unix(reset_at)
             }
           }
         }, sample_at}
      end

      # Values always converge on the long-reset snapshot, while observation
      # liveness follows the latest fresh same-cycle provider confirmation even
      # when that confirmation's values were rejected. Metadata keeps the value
      # provenance of the accepted long-reset sample.
      sequences = [
        {[
           snapshot.(1, short_reset_at, observed_at),
           snapshot.(2, long_reset_at, one_second_later)
         ], one_second_later, one_second_later},
        {[
           snapshot.(2, long_reset_at, observed_at),
           snapshot.(1, short_reset_at, one_second_later)
         ], one_second_later, observed_at},
        {[
           snapshot.(2, short_reset_at, observed_at),
           snapshot.(2, long_reset_at, one_second_later)
         ], one_second_later, one_second_later},
        {[
           snapshot.(2, long_reset_at, observed_at),
           snapshot.(2, short_reset_at, one_second_later)
         ], one_second_later, observed_at}
      ]

      for {samples, expected_observed_at, expected_value_anchor_at} <- sequences do
        identity = active_identity_fixture()

        merged_window =
          Enum.reduce(samples, nil, fn {payload, sample_at}, _previous ->
            assert {:ok, [window]} =
                     QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                       identity,
                       payload,
                       sample_at
                     )

            window
          end)

        assert DateTime.compare(merged_window.reset_at, long_reset_at) == :eq
        assert DateTime.compare(merged_window.observed_at, expected_observed_at) == :eq
        assert Decimal.equal?(merged_window.used_percent, Decimal.new("2.000"))

        assert merged_window.metadata["reset_after_seconds"] ==
                 DateTime.diff(long_reset_at, expected_value_anchor_at, :second)
      end
    end

    @tag :upstream_quota_evidence_stability
    test "new account cycle replaces an expired stronger snapshot" do
      identity = active_identity_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      expired_observed_at = DateTime.add(now, -120, :second)
      expired_reset_at = DateTime.add(now, -60, :second)
      next_reset_at = DateTime.add(now, 5, :hour)

      assert {:ok, [expired_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("88"),
                   reset_at: expired_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: expired_observed_at
                 }
               ])

      assert {:ok, [next_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("0"),
                   reset_at: next_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert next_window.id == expired_window.id
      assert DateTime.compare(next_window.reset_at, next_reset_at) == :eq
      assert DateTime.compare(next_window.observed_at, now) == :eq
      assert Decimal.equal?(next_window.used_percent, Decimal.new("0"))
    end

    @tag :upstream_quota_evidence_stability
    test "weak zero usage refresh does not restamp weekly model evidence without timing" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      primary_reset_at = DateTime.add(observed_at, 2, :hour)
      weekly_reset_at = DateTime.add(observed_at, 5, :day)
      weak_observed_at = DateTime.add(observed_at, 60, :second)
      weak_primary_reset_at = DateTime.add(weak_observed_at, 5, :hour)
      weak_weekly_reset_at = DateTime.add(weak_observed_at, 7, :day)

      assert {:ok, known_windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   display_label: "GPT-5.3-Codex-Spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("1"),
                   reset_at: primary_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 },
                 %{
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   display_label: "GPT-5.3-Codex-Spark",
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("15"),
                   reset_at: weekly_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, merged_windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   display_label: "GPT-5.3-Codex-Spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("0"),
                   reset_at: weak_primary_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: weak_observed_at
                 },
                 %{
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   display_label: "GPT-5.3-Codex-Spark",
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("0"),
                   reset_at: weak_weekly_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: weak_observed_at
                 }
               ])

      primary_window = Enum.find(merged_windows, &(&1.window_kind == "primary"))
      weekly_window = Enum.find(merged_windows, &(&1.window_kind == "secondary"))
      known_primary_window = Enum.find(known_windows, &(&1.window_kind == "primary"))
      known_weekly_window = Enum.find(known_windows, &(&1.window_kind == "secondary"))

      assert primary_window.id == known_primary_window.id
      assert weekly_window.id == known_weekly_window.id
      assert DateTime.compare(primary_window.reset_at, primary_reset_at) == :eq
      assert DateTime.compare(weekly_window.reset_at, weekly_reset_at) == :eq
      assert DateTime.compare(primary_window.observed_at, weak_observed_at) == :eq
      assert DateTime.compare(weekly_window.observed_at, observed_at) == :eq
      assert Decimal.equal?(primary_window.used_percent, Decimal.new("1"))
      assert Decimal.equal?(weekly_window.used_percent, Decimal.new("15"))
    end

    @tag :upstream_quota_evidence_stability
    test "weak zero usage refresh can replace expired stronger evidence" do
      identity = active_identity_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      expired_observed_at = DateTime.add(now, -120, :second)
      expired_reset_at = DateTime.add(now, -60, :second)
      fresh_reset_at = DateTime.add(now, 5, :hour)

      assert {:ok, [expired_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   display_label: "GPT-5.3-Codex-Spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("33"),
                   reset_at: expired_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: expired_observed_at
                 }
               ])

      refute QuotaWindows.fresh_window?(expired_window, now)

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   display_label: "GPT-5.3-Codex-Spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("0"),
                   reset_at: fresh_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert merged_window.id == expired_window.id
      assert DateTime.compare(merged_window.reset_at, fresh_reset_at) == :eq
      assert DateTime.compare(merged_window.observed_at, now) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("0"))
    end

    @tag :upstream_quota_evidence_stability
    test "later nonzero usage refresh replaces weak zero usage evidence" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      weak_reset_at = DateTime.add(observed_at, 4, :hour)
      improved_observed_at = DateTime.add(observed_at, 60, :second)
      improved_reset_at = DateTime.add(improved_observed_at, 2, :hour)

      assert {:ok, [weak_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("0"),
                   reset_at: weak_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("9"),
                   reset_at: improved_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: improved_observed_at
                 }
               ])

      assert merged_window.id == weak_window.id
      assert DateTime.compare(merged_window.reset_at, improved_reset_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("9"))
    end

    @tag :upstream_quota_evidence_stability
    test "credit-only monthly usage remains usable without fabricating percent capacity" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      reset_at = DateTime.add(observed_at, 15, :day)

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 43_200,
                   credits: 3817,
                   used_percent: Decimal.new("100"),
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      measurements = Measurements.for_window(window)

      assert measurements.remaining == Decimal.new(3817)
      assert measurements.capacity == nil
      assert measurements.remaining_percent == nil
      refute "exhausted" in QuotaWindows.routing_window_reason_codes(window, observed_at)
      assert QuotaWindows.usable_window?(window, observed_at)

      assert %{eligible?: true, routing_state: :precise, exclusions: []} =
               QuotaWindows.routing_quota_eligibility(identity, at: observed_at)
    end

    @tag :upstream_quota_evidence_stability
    test "credit-only monthly usage refresh keeps existing capacity and recalculates used percent" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      reset_at = DateTime.add(observed_at, 30, :day)
      weak_observed_at = DateTime.add(observed_at, 60, :second)
      weak_reset_at = DateTime.add(weak_observed_at, 15, :day)

      assert {:ok, [known_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 43_200,
                   active_limit: 4018,
                   credits: 3817,
                   used_percent: Decimal.new("5"),
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 43_200,
                   credits: 3817,
                   used_percent: Decimal.new("100"),
                   reset_at: weak_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: weak_observed_at
                 }
               ])

      expected_used_percent =
        Decimal.new(4018)
        |> Decimal.sub(Decimal.new(3817))
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.div(Decimal.new(4018))

      measurements = Measurements.for_window(merged_window)

      assert merged_window.id == known_window.id
      assert merged_window.active_limit == 4018
      assert merged_window.credits == 3817
      assert DateTime.compare(merged_window.reset_at, reset_at) == :eq

      assert Decimal.equal?(
               Decimal.round(merged_window.used_percent, 6),
               Decimal.round(expected_used_percent, 6)
             )

      assert Decimal.equal?(Decimal.round(measurements.remaining_percent, 0), Decimal.new("95"))
      assert QuotaWindows.usable_window?(merged_window, weak_observed_at)

      assert %{eligible?: true, routing_state: :precise, exclusions: []} =
               QuotaWindows.routing_quota_eligibility(identity, at: weak_observed_at)
    end

    test "headers cannot roll back a reset advanced by usage evidence" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      old_reset_at = DateTime.add(observed_at, 900, :second)
      usage_observed_at = DateTime.add(observed_at, 60, :second)
      usage_reset_at = DateTime.add(usage_observed_at, 604_800, :second)
      header_observed_at = DateTime.add(usage_observed_at, 60, :second)

      assert {:ok, [_header_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-secondary-used-percent", ["100"]},
                   {"x-codex-secondary-window-minutes", ["10080"]},
                   {"x-codex-secondary-reset-at", [DateTime.to_iso8601(old_reset_at)]}
                 ],
                 observed_at
               )

      assert {:ok, [usage_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "account",
                     window_kind: "secondary",
                     window_minutes: 10_080,
                     used_percent: Decimal.new("0"),
                     reset_at: usage_reset_at,
                     source: "codex_usage_api",
                     source_precision: "observed",
                     quota_scope: "account",
                     quota_family: "account",
                     observed_at: usage_observed_at,
                     freshness_state: "fresh"
                   }
                 ]
               )

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-secondary-used-percent", ["100"]},
                   {"x-codex-secondary-window-minutes", ["10080"]},
                   {"x-codex-secondary-reset-at", [DateTime.to_iso8601(old_reset_at)]}
                 ],
                 header_observed_at
               )

      refute merged_window.id == usage_window.id
      assert merged_window.source == "codex_response_headers"
      assert DateTime.compare(merged_window.reset_at, old_reset_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("100"))
      refute QuotaWindows.usable_window?(merged_window, header_observed_at)
    end

    test "resetless usage evidence cannot downgrade reset-bearing header evidence" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(observed_at, 900, :second)

      assert {:ok, [header_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-bengalfox-primary-used-percent", ["44"]},
                   {"x-codex-bengalfox-primary-window-minutes", ["300"]},
                   {"x-codex-bengalfox-primary-reset-at", [DateTime.to_iso8601(reset_at)]},
                   {"x-codex-bengalfox-limit-name", ["gpt-5.3-codex-spark"]}
                 ],
                 observed_at
               )

      assert header_window.source == "codex_response_headers"
      assert header_window.source_precision == "observed"
      assert header_window.model == "gpt-5.3-codex-spark"
      assert header_window.upstream_model == nil
      assert header_window.raw_limit_id == "codex_bengalfox"
      assert header_window.raw_limit_name == "gpt-5.3-codex-spark"
      assert header_window.raw_metered_feature == "codex_bengalfox"
      assert DateTime.compare(header_window.reset_at, reset_at) == :eq
      assert QuotaWindows.usable_window?(header_window, observed_at)

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "gpt-5.3-codex-spark",
                     window_kind: "primary",
                     window_minutes: 300,
                     used_percent: Decimal.new("12"),
                     display_label: "GPT-5.3-Codex-Spark",
                     limit_name: nil,
                     metered_feature: nil,
                     source: "codex_usage_api",
                     source_precision: "inferred",
                     quota_scope: "model",
                     quota_family: "codex_model",
                     model: "gpt-5.3-codex-spark",
                     upstream_model: nil,
                     raw_limit_id: nil,
                     raw_limit_name: nil,
                     raw_metered_feature: nil,
                     observed_at: DateTime.add(observed_at, 60, :second),
                     freshness_state: "fresh"
                   }
                 ]
               )

      refute merged_window.id == header_window.id
      assert merged_window.source == "codex_usage_api"
      assert merged_window.source_precision == "inferred"
      assert merged_window.model == "gpt-5.3-codex-spark"
      assert merged_window.upstream_model == nil
      assert merged_window.raw_limit_id == nil
      assert merged_window.raw_limit_name == nil
      assert merged_window.raw_metered_feature == nil
      assert merged_window.reset_at == nil
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("12"))
      refute QuotaWindows.usable_window?(merged_window, observed_at)

      assert [persisted] =
               QuotaWindows.quota_window_selection_data(identity, at: observed_at).routing_windows

      assert persisted.id == header_window.id
    end

    test "fresh resetless evidence replaces stale reset-bearing evidence" do
      identity = active_identity_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      stale_observed_at = DateTime.add(now, -Quotas.Evidence.freshness_ttl_seconds() - 1, :second)
      reset_at = DateTime.add(now, 900, :second)

      assert {:ok, [stale_reset_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-bengalfox-primary-used-percent", ["44"]},
                   {"x-codex-bengalfox-primary-window-minutes", ["300"]},
                   {"x-codex-bengalfox-primary-reset-at", [DateTime.to_iso8601(reset_at)]},
                   {"x-codex-bengalfox-limit-name", ["gpt-5.3-codex-spark"]}
                 ],
                 stale_observed_at
               )

      refute QuotaWindows.fresh_window?(stale_reset_window, now)
      refute QuotaWindows.usable_window?(stale_reset_window, now)

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "gpt-5.3-codex-spark",
                     window_kind: "primary",
                     window_minutes: 300,
                     used_percent: Decimal.new("12"),
                     source: "codex_usage_api",
                     source_precision: "inferred",
                     quota_scope: "model",
                     quota_family: "codex_model",
                     model: "gpt-5.3-codex-spark",
                     observed_at: now,
                     freshness_state: "fresh"
                   }
                 ]
               )

      refute merged_window.id == stale_reset_window.id
      assert merged_window.source == "codex_usage_api"
      assert merged_window.source_precision == "inferred"
      assert merged_window.raw_limit_id == nil
      assert merged_window.raw_limit_name == nil
      assert merged_window.raw_metered_feature == nil
      assert merged_window.reset_at == nil
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("12"))
      refute QuotaWindows.usable_window?(merged_window, now)
    end

    test "fresh resetless evidence replaces expired reset-bearing evidence" do
      identity = active_identity_fixture()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      expired_reset_at = DateTime.add(now, -60, :second)

      assert {:ok, [expired_reset_window]} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-bengalfox-primary-used-percent", ["44"]},
                   {"x-codex-bengalfox-primary-window-minutes", ["300"]},
                   {"x-codex-bengalfox-primary-reset-at",
                    [DateTime.to_iso8601(expired_reset_at)]},
                   {"x-codex-bengalfox-limit-name", ["gpt-5.3-codex-spark"]}
                 ],
                 DateTime.add(now, -30, :second)
               )

      refute QuotaWindows.fresh_window?(expired_reset_window, now)
      refute QuotaWindows.usable_window?(expired_reset_window, now)

      assert {:ok, [merged_window]} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     quota_key: "gpt-5.3-codex-spark",
                     window_kind: "primary",
                     window_minutes: 300,
                     used_percent: Decimal.new("12"),
                     source: "codex_usage_api",
                     source_precision: "inferred",
                     quota_scope: "model",
                     quota_family: "codex_model",
                     model: "gpt-5.3-codex-spark",
                     observed_at: now,
                     freshness_state: "fresh"
                   }
                 ]
               )

      refute merged_window.id == expired_reset_window.id
      assert merged_window.source == "codex_usage_api"
      assert merged_window.source_precision == "inferred"
      assert merged_window.raw_limit_id == nil
      assert merged_window.raw_limit_name == nil
      assert merged_window.raw_metered_feature == nil
      assert merged_window.reset_at == nil
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("12"))
      refute QuotaWindows.usable_window?(merged_window, now)
    end

    test "expired and stale quota evidence remains visible but routing unusable" do
      identity = active_identity_fixture()
      now = ~U[2026-04-27 12:00:00Z]

      expired_reset_at = DateTime.add(now, -60, :second)
      stale_observed_at = DateTime.add(now, -Quotas.Evidence.freshness_ttl_seconds() - 1, :second)
      stale_reset_at = DateTime.add(now, 600, :second)

      assert {:ok, [expired_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("10"),
                   reset_at: expired_reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: DateTime.add(now, -30, :second)
                 }
               ])

      assert {:ok, [stale_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("20"),
                   reset_at: stale_reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: stale_observed_at
                 }
               ])

      assert Enum.map(
               QuotaWindows.list_quota_windows(identity),
               & &1.window_kind
             ) == [
               "primary",
               "secondary"
             ]

      refute QuotaWindows.fresh_window?(expired_window, now)
      refute QuotaWindows.usable_window?(expired_window, now)
      refute QuotaWindows.fresh_window?(stale_window, now)
      refute QuotaWindows.usable_window?(stale_window, now)

      selection =
        QuotaWindows.quota_window_selection_data(identity, at: now)

      refute selection.usable?
      assert Enum.map(selection.blocked_windows, & &1.window_kind) == ["primary", "secondary"]
      assert selection.fresh_windows == []
    end

    test "malformed quota numeric and reset values are ignored without crashing" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 12:00:00Z]

      assert {:ok, []} =
               QuotaWindows.upsert_quota_windows_from_codex_headers(
                 identity,
                 [
                   {"x-codex-primary-used-percent", ["not-a-number"]},
                   {"x-codex-primary-window-minutes", ["300"]},
                   {"x-codex-primary-reset-at", ["999999999999999999999999"]}
                 ],
                 observed_at
               )

      assert [] =
               Quotas.parse_codex_headers(
                 [
                   {"x-codex-future-family-primary-used-percent", ["50"]},
                   {"x-codex-future-family-primary-window-minutes", ["0"]},
                   {"x-codex-future-family-primary-reset-at", ["definitely-not-a-date"]}
                 ],
                 observed_at
               )

      assert [] =
               Quotas.parse_rate_limit_error(
                 %{
                   "limit_id" => "codex_future_family",
                   "window_minutes" => "not-minutes",
                   "reset_at" => "definitely-not-a-date"
                 },
                 observed_at
               )
    end

    test "routing quota eligibility reports sanitized exclusion reasons" do
      now = ~U[2026-04-27 12:00:00Z]
      future_reset = DateTime.add(now, 900, :second)

      missing_identity = active_identity_fixture()

      missing =
        QuotaWindows.routing_quota_eligibility(missing_identity, at: now)

      refute missing.eligible?
      assert [%{code: "quota_evidence_missing"}] = missing.exclusions

      resetless_identity = active_identity_fixture()

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(resetless_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("20"),
                   source: "codex_usage_api",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      resetless =
        QuotaWindows.routing_quota_eligibility(resetless_identity, at: now)

      refute resetless.eligible?
      assert [%{reason_codes: ["reset_missing"]}] = resetless.exclusions

      stale_identity = active_identity_fixture()
      stale_observed_at = DateTime.add(now, -Quotas.Evidence.freshness_ttl_seconds() - 1, :second)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(stale_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("20"),
                   reset_at: future_reset,
                   source: "codex_usage_api",
                   freshness_state: "fresh",
                   observed_at: stale_observed_at
                 }
               ])

      stale =
        QuotaWindows.routing_quota_eligibility(stale_identity, at: now)

      refute stale.eligible?
      assert [%{reason_codes: ["not_fresh"]}] = stale.exclusions

      expired_identity = active_identity_fixture()

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(expired_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("20"),
                   reset_at: DateTime.add(now, -60, :second),
                   source: "codex_usage_api",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      expired =
        QuotaWindows.routing_quota_eligibility(expired_identity, at: now)

      refute expired.eligible?
      assert [%{reason_codes: ["expired", "not_fresh"]}] = expired.exclusions

      exhausted_identity = active_identity_fixture()

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(exhausted_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("100"),
                   reset_at: future_reset,
                   source: "codex_usage_api",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      exhausted =
        QuotaWindows.routing_quota_eligibility(exhausted_identity, at: now)

      refute exhausted.eligible?
      assert [%{reason_codes: ["exhausted"]}] = exhausted.exclusions

      zero_credit_identity = active_identity_fixture()

      assert {:ok, [zero_credit_window]} =
               QuotaWindows.upsert_quota_windows(zero_credit_identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("0"),
                   reset_at: future_reset,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert QuotaWindows.usable_window?(zero_credit_window, now)

      zero_credit =
        QuotaWindows.routing_quota_eligibility(zero_credit_identity,
          at: now
        )

      assert zero_credit.eligible?
    end

    @tag :upstream_quota_evidence_stability
    test "routing stays precise when weak zero usage refresh follows usable account evidence" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      reset_at = DateTime.add(observed_at, 2, :hour)
      weak_observed_at = DateTime.add(observed_at, 60, :second)
      weak_reset_at = DateTime.add(weak_observed_at, 4, :hour)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("11"),
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert %{eligible?: true, routing_state: :precise} =
               QuotaWindows.routing_quota_eligibility(identity, at: observed_at)

      assert {:ok, [_merged]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: 0,
                   credits: 0,
                   used_percent: Decimal.new("0"),
                   reset_at: weak_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: weak_observed_at
                 }
               ])

      assert %{eligible?: true, routing_state: :precise, exclusions: []} =
               QuotaWindows.routing_quota_eligibility(identity, at: weak_observed_at)

      assert [persisted] =
               QuotaWindows.quota_window_selection_data(identity, at: weak_observed_at).routing_windows

      assert DateTime.compare(persisted.reset_at, reset_at) == :eq
      assert Decimal.equal?(persisted.used_percent, Decimal.new("11"))
    end

    @tag :upstream_quota_evidence_stability
    test "model quota refresh preserves useful percent when usage API reports weak zero evidence" do
      identity = active_identity_fixture()
      observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      reset_at = DateTime.add(observed_at, 5, :hour)
      weak_observed_at = DateTime.add(observed_at, 90, :second)
      weak_reset_at = DateTime.add(weak_observed_at, 5, :hour)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("1"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: observed_at
                 }
               ])

      assert {:ok, [_merged]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "codex_spark",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   active_limit: nil,
                   credits: nil,
                   used_percent: Decimal.new("0"),
                   reset_at: weak_reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: weak_observed_at
                 }
               ])

      assert [persisted] =
               QuotaWindows.quota_window_selection_data(identity, at: weak_observed_at).routing_windows

      assert Decimal.equal?(persisted.used_percent, Decimal.new("1"))
      assert DateTime.compare(persisted.reset_at, reset_at) == :eq
      assert DateTime.compare(persisted.observed_at, observed_at) == :eq
    end

    test "routing quota eligibility rejects usable model evidence without account primary baseline" do
      identity = active_identity_fixture()
      now = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "gpt-5.3-codex-spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("20"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   upstream_model: "provider-gpt-5.3-codex-spark",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      selection =
        QuotaWindows.quota_window_selection_data(identity,
          at: now,
          model: "gpt-5.3-codex-spark",
          upstream_model: "provider-gpt-5.3-codex-spark"
        )

      assert selection.usable?
      assert selection.primary == nil
      assert selection.blocked_windows == []

      eligibility =
        QuotaWindows.routing_quota_eligibility(identity,
          at: now,
          model: "gpt-5.3-codex-spark",
          upstream_model: "provider-gpt-5.3-codex-spark"
        )

      refute eligibility.eligible?
      assert [%{code: "quota_account_primary_missing"}] = eligibility.exclusions
    end

    test "routing quota eligibility allows weekly probe when stale weekly primary header evidence exists" do
      identity = active_identity_fixture()
      now = ~U[2026-04-27 12:00:00Z]
      stale_observed_at = DateTime.add(now, -Quotas.Evidence.freshness_ttl_seconds() - 1, :second)
      reset_at = DateTime.add(now, 604_800, :second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("3"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: stale_observed_at
                 },
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("0"),
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "authoritative",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      selection =
        QuotaWindows.quota_window_selection_data(identity, at: now)

      assert selection.primary == nil

      assert %{window_kind: "secondary", window_minutes: 10_080, source: "codex_usage_api"} =
               selection.secondary

      assert selection.blocked_windows == []

      assert %{eligible?: true, routing_state: :weekly_only_probe, exclusions: []} =
               QuotaWindows.routing_quota_eligibility(identity, at: now)
    end

    test "routing quota eligibility allows weekly probe when weekly evidence is stale but unexpired" do
      identity = active_identity_fixture()
      now = ~U[2026-04-27 12:00:00Z]
      stale_observed_at = DateTime.add(now, -Quotas.Evidence.freshness_ttl_seconds() - 1, :second)
      reset_at = DateTime.add(now, 604_800, :second)

      assert {:ok, [_weekly]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("1"),
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   quota_scope: "account",
                   quota_family: "account",
                   freshness_state: "fresh",
                   observed_at: stale_observed_at
                 }
               ])

      selection =
        QuotaWindows.quota_window_selection_data(identity, at: now)

      refute selection.usable?
      assert %{window_kind: "secondary", window_minutes: 10_080} = selection.secondary

      assert %{eligible?: true, routing_state: :weekly_only_probe, exclusions: []} =
               QuotaWindows.routing_quota_eligibility(identity, at: now)
    end

    test "routing quota eligibility reports exhausted weekly quota with reset time" do
      identity = active_identity_fixture()
      now = ~U[2026-04-27 12:00:00Z]
      reset_at = ~U[2026-05-11 02:55:14Z]

      assert {:ok, [_weekly]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("100"),
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   quota_scope: "account",
                   quota_family: "account",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [
                 %{
                   code: "quota_weekly_exhausted",
                   reason_codes: ["exhausted"],
                   reset_at: "2026-05-11T02:55:14.000000Z"
                 }
               ]
             } = QuotaWindows.routing_quota_eligibility(identity, at: now)
    end

    test "routing quota eligibility allows exhausted secondary weekly evidence with positive credits" do
      identity = active_identity_fixture()
      now = ~U[2026-04-27 12:00:00Z]
      reset_at = ~U[2026-05-11 02:55:14Z]

      assert {:ok, [_primary, _weekly]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("20"),
                   reset_at: DateTime.add(now, 900, :second),
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 },
                 %{
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("100"),
                   credits: 25,
                   reset_at: reset_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   quota_scope: "account",
                   quota_family: "account",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert %{
               eligible?: true,
               routing_state: :credit_backed_probe,
               exclusions: [],
               selection: %{blocked_windows: [%{window_kind: "secondary", credits: 25}]}
             } = QuotaWindows.routing_quota_eligibility(identity, at: now)
    end

    test "routing quota eligibility rejects usable account evidence when a matching model window is blocked" do
      identity = active_identity_fixture()
      now = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("20"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 },
                 %{
                   quota_key: "gpt-5.3-codex-spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("100"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   upstream_model: "provider-gpt-5.3-codex-spark",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      selection =
        QuotaWindows.quota_window_selection_data(identity,
          at: now,
          model: "gpt-5.3-codex-spark",
          upstream_model: "provider-gpt-5.3-codex-spark"
        )

      assert selection.usable?
      assert Enum.count(selection.routing_windows) == 2
      assert [%{quota_scope: "model"}] = selection.blocked_windows

      eligibility =
        QuotaWindows.routing_quota_eligibility(identity,
          at: now,
          model: "gpt-5.3-codex-spark",
          upstream_model: "provider-gpt-5.3-codex-spark"
        )

      refute eligibility.eligible?
      assert [%{quota_scope: "model", reason_codes: ["exhausted"]}] = eligibility.exclusions
    end

    test "routing quota eligibility honors requested and upstream model scope" do
      identity = active_identity_fixture()
      now = ~U[2026-04-27 12:00:00Z]
      reset_at = DateTime.add(now, 900, :second)

      assert {:ok, _windows} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("20"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: now
                 },
                 %{
                   quota_key: "gpt-5.3-codex-spark",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("20"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   quota_scope: "model",
                   quota_family: "codex_model",
                   model: "gpt-5.3-codex-spark",
                   upstream_model: "provider-gpt-5.3-codex-spark",
                   freshness_state: "fresh",
                   observed_at: now
                 }
               ])

      assert %{eligible?: true, exclusions: []} =
               QuotaWindows.routing_quota_eligibility(identity,
                 at: now,
                 model: "gpt-5.3-codex-spark"
               )

      assert %{eligible?: true, exclusions: []} =
               QuotaWindows.routing_quota_eligibility(identity,
                 at: now,
                 upstream_model: "provider-gpt-5.3-codex-spark"
               )

      wrong_model =
        QuotaWindows.routing_quota_eligibility(identity,
          at: now,
          model: "gpt-6-codex-other",
          upstream_model: "provider-gpt-6-codex-other"
        )

      assert wrong_model.eligible?
      assert wrong_model.exclusions == []
    end

    test "rejects invalid and duplicate quota windows" do
      identity = active_identity_fixture()

      assert {:error, changeset} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 0,
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      assert %{window_minutes: ["must be greater than 0"]} = errors_on(changeset)

      assert {:error, %{code: :duplicate_quota_window_kind}} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{window_kind: "primary", window_minutes: 300, source: "codex_usage_api"},
                 %{window_kind: "primary", window_minutes: 300, source: "codex_usage_api"}
               ])
    end

    test "accepts known binary keys while ignoring unknown binary keys" do
      identity = active_identity_fixture()

      assert {:ok, [window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   "window_kind" => "primary",
                   "window_minutes" => 300,
                   "used_percent" => "42.5",
                   "source" => "codex_usage_api",
                   "freshness_state" => "fresh",
                   "unknown_legacy_key" => "ignored"
                 }
               ])

      assert window.window_kind == "primary"
      assert window.window_minutes == 300
      assert window.used_percent == Decimal.new("42.5")
    end

    test "quota refresh refuses workspace slot conflicts without mutating windows" do
      identity =
        active_identity_fixture(%{
          workspace_id: "ws_quota_guard",
          seat_type: "member-seat"
        })

      assert {:ok, identity} =
               IdentityLifecycle.activate_upstream_identity_with_plan(identity, %{
                 plan_family: "pro",
                 plan_label: "Pro"
               })

      assert {:ok, [existing]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("12"),
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      assert {:error,
              {:identity_conflict, :workspace_identity_mismatch,
               %{
                 path: "upstream_identity.reconciliation",
                 stored_workspace_ref: stored_workspace_ref,
                 incoming_workspace_ref: incoming_workspace_ref,
                 stored_plan_family: "pro",
                 incoming_plan_family: "team",
                 stored_seat_type: "member-seat",
                 incoming_seat_type: "enterprise-seat"
               } = conflict}} =
               QuotaWindows.upsert_quota_windows(
                 identity,
                 [
                   %{
                     window_kind: "primary",
                     window_minutes: 300,
                     used_percent: Decimal.new("88"),
                     source: "codex_usage_api",
                     freshness_state: "fresh"
                   }
                 ],
                 delete_missing?: true,
                 identity_attrs: %{
                   workspace_id: "ws_quota_other",
                   plan_family: "team",
                   seat_type: "enterprise-seat"
                 }
               )

      assert String.starts_with?(stored_workspace_ref, "ws:")
      assert String.starts_with?(incoming_workspace_ref, "ws:")

      assert [persisted] = QuotaWindows.list_quota_windows(identity)
      assert persisted.id == existing.id
      assert Decimal.equal?(persisted.used_percent, Decimal.new("12"))
      assert Repo.get!(UpstreamIdentity, identity.id).plan_family == "pro"
      assert Repo.get!(UpstreamIdentity, identity.id).workspace_id == "ws_quota_guard"

      conflict_text = inspect(conflict)
      refute conflict_text =~ "ws_quota_guard"
      refute conflict_text =~ "ws_quota_other"
      refute conflict_text =~ identity.chatgpt_account_id
    end

    test "reconciliation records sanitized identity conflicts without refreshing health plan or quota" do
      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {200,
             %{
               "plan_type" => "Team",
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 64,
                   "limit_window_seconds" => 18_000,
                   "reset_after_seconds" => 900
                 }
               }
             }}
        })

      pool = pool_fixture()

      identity =
        active_identity_fixture(%{
          chatgpt_account_id: "acct_reconcile_conflict_#{System.unique_integer([:positive])}",
          workspace_id: "ws_reconcile_guard",
          metadata: %{"base_url" => FakeUpstream.url(upstream)}
        })

      assert {:ok, identity} =
               IdentityLifecycle.activate_upstream_identity_with_plan(identity, %{
                 plan_family: "free",
                 plan_label: "Free"
               })

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, assignment} =
               PoolAssignments.activate_pool_assignment(assignment)

      configure_upstream_secret_key!()
      access_token = generated_secret("reconcile-conflict")

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "access_token",
                 plaintext: access_token
               })

      assert {:ok, [existing]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("17"),
                   source: "codex_usage_api",
                   freshness_state: "fresh"
                 }
               ])

      before_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)

      assert {:ok, result} = Upstreams.reconcile_pool_account(pool, assignment)
      assert result.status == :failed
      assert result.quota.code == "workspace_identity_mismatch"
      assert result.health.code == "health_skipped"

      reloaded_identity = Repo.get!(UpstreamIdentity, identity.id)
      assert reloaded_identity.plan_family == "free"
      assert reloaded_identity.plan_label == "Free"
      assert reloaded_identity.status == "active"
      assert reloaded_identity.workspace_id == "ws_reconcile_guard"

      reloaded_assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert reloaded_assignment.status == before_assignment.status
      assert reloaded_assignment.health_status == before_assignment.health_status
      assert reloaded_assignment.eligibility_status == before_assignment.eligibility_status
      assert reloaded_assignment.last_healthcheck_at == before_assignment.last_healthcheck_at
      refute Map.has_key?(reloaded_assignment.metadata, "last_reconciliation")

      assert %{
               "path" => "upstream_identity.reconciliation",
               "stored_workspace_ref" => stored_workspace_ref,
               "incoming_workspace_ref" => "legacy",
               "stored_plan_family" => "free",
               "incoming_plan_family" => "team"
             } = reloaded_assignment.metadata["identity_conflict"]

      assert String.starts_with?(stored_workspace_ref, "ws:")
      assert [persisted] = QuotaWindows.list_quota_windows(identity)
      assert persisted.id == existing.id
      assert Decimal.equal?(persisted.used_percent, Decimal.new("17"))
      assert {:ok, ^access_token} = Secrets.decrypt_active_secret(identity, "access_token")

      conflict_text = inspect(reloaded_assignment.metadata["identity_conflict"])
      refute conflict_text =~ "ws_reconcile_guard"
      refute conflict_text =~ identity.chatgpt_account_id
      refute conflict_text =~ access_token
    end

    test "token refresh refuses ambiguous legacy workspace slots without mutating state" do
      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => generated_secret("unused-access")}}
        })

      account_id = "acct_refresh_conflict_#{System.unique_integer([:positive])}"

      legacy_identity =
        active_identity_fixture(%{
          chatgpt_account_id: account_id,
          metadata: %{"base_url" => FakeUpstream.url(upstream)}
        })

      _concrete_identity =
        active_identity_fixture(%{
          chatgpt_account_id: account_id,
          workspace_id: "ws_refresh_guard"
        })

      configure_upstream_secret_key!()
      refresh_token = generated_secret("refresh-conflict")

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(legacy_identity, %{
                 secret_kind: "refresh_token",
                 plaintext: refresh_token
               })

      before_identity = Repo.get!(UpstreamIdentity, legacy_identity.id)

      assert {:error,
              {:identity_conflict, :workspace_identity_mismatch,
               %{incoming_workspace_ref: "legacy", stored_workspace_ref: stored_workspace_ref} =
                 conflict}} = TokenRefresh.refresh_access_token(legacy_identity)

      assert String.starts_with?(stored_workspace_ref, "ws:")
      assert Repo.get!(UpstreamIdentity, legacy_identity.id).status == before_identity.status
      assert Repo.get!(UpstreamIdentity, legacy_identity.id).metadata == before_identity.metadata
      assert FakeUpstream.count(upstream) == 0

      assert {:ok, ^refresh_token} =
               Secrets.decrypt_active_secret(legacy_identity, "refresh_token")

      conflict_text = inspect(conflict)
      refute conflict_text =~ "ws_refresh_guard"
      refute conflict_text =~ account_id
      refute conflict_text =~ refresh_token
    end

    test "metadata import treats malformed used percent as absent" do
      pool = pool_fixture()

      identity =
        active_identity_fixture(%{
          metadata: %{
            "quota_windows" => [
              %{
                "window_kind" => "primary",
                "window_minutes" => 300,
                "used_percent" => "not-a-decimal",
                "source" => "codex_usage_api",
                "freshness_state" => "fresh"
              }
            ]
          }
        })

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{})

      assert {:ok, assignment} =
               PoolAssignments.activate_pool_assignment(assignment)

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

      assert [window] = QuotaWindows.list_quota_windows(identity)
      assert window.used_percent == nil
    end
  end

  defp active_identity_fixture(attrs \\ %{}) do
    defaults = %{
      chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
      account_label: "Primary account",
      onboarding_method: "import",
      metadata: %{}
    }

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(Map.merge(defaults, attrs))

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    identity
  end

  defp subject_identity_attrs(account_id, attrs \\ %{}) do
    Map.merge(
      %{
        chatgpt_account_id: account_id,
        account_label: "Subject identity",
        onboarding_method: "import",
        metadata: %{}
      },
      attrs
    )
  end

  defp weekly_only_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "rate_limit" => %{
          "primary_window" => %{"used_percent" => 67, "limit_window_seconds" => 604_800}
        }
      },
      overrides
    )
  end

  defp provider_shape_window_attrs(observed_at, shape, opts \\ []) do
    used_percent = Decimal.new(Keyword.get(opts, :used_percent, "12"))

    primary = [
      provider_shape_window("account", "primary", 300, observed_at, used_percent),
      provider_shape_window("codex_spark", "primary", 300, observed_at, used_percent)
    ]

    weekly = [
      provider_shape_window("account", "secondary", 10_080, observed_at, used_percent),
      provider_shape_window("codex_spark", "secondary", 10_080, observed_at, used_percent)
    ]

    case shape do
      :full -> primary ++ weekly
      :primary_only -> primary
      :weekly_only -> weekly
    end
  end

  defp provider_shape_window(quota_key, window_kind, window_minutes, observed_at, used_percent) do
    scope_attrs =
      if quota_key == "account" do
        %{quota_scope: "account", quota_family: "account"}
      else
        %{
          quota_scope: "model",
          quota_family: "codex_model",
          model: "gpt-5.3-codex-spark",
          display_label: "GPT-5.3-Codex-Spark",
          limit_name: "GPT-5.3-Codex-Spark",
          metered_feature: "codex_bengalfox"
        }
      end

    Map.merge(scope_attrs, %{
      quota_key: quota_key,
      window_kind: window_kind,
      window_minutes: window_minutes,
      used_percent: used_percent,
      reset_at: DateTime.add(observed_at, window_minutes, :minute),
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: observed_at,
      observed_at: observed_at,
      metadata: %{"limit_window_seconds" => window_minutes * 60}
    })
  end

  defp quota_window_shape(windows) do
    windows
    |> Enum.map(&{&1.quota_key, &1.window_kind, &1.window_minutes})
    |> Enum.sort()
  end

  defp reset_bearing_account_primary_payload do
    %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 12,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900
        }
      }
    }
  end

  defp descriptor_weekly_limit(limit_name) do
    %{
      "limit_name" => limit_name,
      "metered_feature" => "example_meter",
      "rate_limit" => %{
        "secondary_window" => %{
          "used_percent" => 42,
          "limit_window_seconds" => 604_800,
          "reset_after_seconds" => 3_600
        }
      }
    }
  end

  defp persist_descriptor_primary!(
         identity,
         observed_at,
         limit_name,
         source,
         overrides
       )
       when is_list(overrides) do
    persist_descriptor_primary!(
      identity,
      observed_at,
      limit_name,
      source,
      "example_meter",
      overrides
    )
  end

  defp persist_descriptor_primary!(
         identity,
         observed_at,
         limit_name,
         source \\ "codex_usage_api",
         raw_metered_feature \\ "example_meter",
         overrides \\ []
       ) do
    raw_limit_id = limit_name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

    attrs =
      rich_identity_attrs(
        observed_at,
        Map.merge(
          %{
            quota_key: raw_limit_id,
            model: limit_name,
            upstream_model: nil,
            raw_limit_id: raw_metered_feature,
            raw_limit_name: limit_name,
            raw_metered_feature: raw_metered_feature,
            source: source
          },
          Map.new(overrides)
        )
      )

    assert {:ok, stored} = QuotaWindows.record_evidence(identity, attrs, observed_at)
    stored
  end

  defp configure_descriptor_zero_coverage_mode(:metadata, identity, assignment, existing) do
    metadata_window =
      rich_identity_attrs(existing.observed_at, %{
        quota_key: existing.quota_key,
        raw_limit_id: existing.raw_limit_id,
        raw_limit_name: existing.raw_limit_name,
        raw_metered_feature: existing.raw_metered_feature,
        source: "local_reconciliation"
      })

    assert {:ok, identity} =
             IdentityLifecycle.update_upstream_identity(identity, %{
               metadata: Map.put(identity.metadata, "quota_windows", [metadata_window])
             })

    {identity, assignment, []}
  end

  defp configure_descriptor_zero_coverage_mode(:option, identity, assignment, existing) do
    opts =
      [
        quota_windows: [
          rich_identity_attrs(existing.observed_at, %{
            quota_key: existing.quota_key,
            raw_limit_id: existing.raw_limit_id,
            raw_limit_name: existing.raw_limit_name,
            raw_metered_feature: existing.raw_metered_feature,
            source: "local_reconciliation"
          })
        ]
      ]

    {identity, assignment, opts}
  end

  defp configure_descriptor_zero_coverage_mode(_mode, identity, assignment, _existing),
    do: {identity, assignment, []}

  defp usage_assignment_fixture(upstream) do
    pool = pool_fixture()

    identity =
      active_identity_fixture(%{
        chatgpt_account_id: "acct_usage_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(upstream)}
      })

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{})

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment)

    configure_upstream_secret_key!()

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: generated_secret("usage")
             })

    %{identity: identity, pool: pool, assignment: assignment}
  end

  defp start_path_upstream(routes) do
    {:ok, upstream} = FakeUpstream.start_link({:path_json, routes})
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp configure_upstream_secret_key!(
         key \\ Base.encode64(:crypto.hash(:sha256, "test-upstream-secret-key"))
       ) do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: key,
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end

  defp fixture_owner_scope do
    %{user: user} = bootstrap_owner_fixture()
    Scope.for_user(user, ["instance_owner"])
  end

  defp runtime_secret(label), do: Enum.join(["upstreams", label, "secret", "redacted"], "-")

  defp auth_json_fixture(opts) do
    tokens =
      Keyword.get(opts, :tokens, %{
        "id_token" => Keyword.get(opts, :id_token, id_token_fixture()),
        "access_token" => Keyword.get(opts, :access_token, jwt_token(%{"exp" => future_unix()})),
        "refresh_token" => Keyword.get(opts, :refresh_token, runtime_secret("auth-json-refresh")),
        "account_id" => Keyword.get(opts, :account_id, "acct_fixture_auth_json")
      })

    %{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => tokens,
      "last_refresh" => "2026-05-03T00:00:00Z"
    }
    |> Jason.encode!()
  end

  defp id_token_fixture do
    jwt_token(%{
      "email" => "fixture-user@example.com",
      "https://api.openai.com/auth" => %{
        "chatgpt_account_id" => "acct_fixture_auth_json",
        "chatgpt_user_id" => "user_fixture_auth_json",
        "chatgpt_plan_type" => "pro"
      }
    })
  end

  defp jwt_token(payload) do
    header = %{"alg" => "none", "typ" => "JWT"}
    encode = &Base.url_encode64(Jason.encode!(&1), padding: false)

    Enum.join([encode.(header), encode.(payload), Base.url_encode64("sig", padding: false)], ".")
  end

  defp future_unix, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()
  defp past_unix, do: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_unix()

  defp active_secret_count(secret_kind) do
    Repo.aggregate(
      from(secret in EncryptedSecret,
        where: secret.secret_kind == ^secret_kind and secret.status == "active"
      ),
      :count
    )
  end

  defp active_secret_count(secret_kind, identity) do
    Repo.aggregate(
      from(secret in EncryptedSecret,
        where:
          secret.upstream_identity_id == ^identity.id and secret.secret_kind == ^secret_kind and
            secret.status == "active"
      ),
      :count
    )
  end

  defp generated_secret(label) do
    "fixture-secret-#{label}-#{System.unique_integer([:positive])}"
  end

  defp rich_identity_attrs(observed_at, overrides \\ %{}) do
    Map.merge(
      %{
        quota_key: "example-quota",
        window_kind: "primary",
        window_minutes: 300,
        used_percent: Decimal.new("22"),
        reset_at: DateTime.add(observed_at, 2, :hour),
        source: "codex_usage_api",
        source_precision: "observed",
        quota_scope: "model",
        quota_family: "codex_model",
        model: "example-model-alpha",
        upstream_model: "provider-example-model-alpha",
        raw_limit_id: "provider-limit-alpha",
        raw_limit_name: "Provider limit alpha",
        raw_metered_feature: "provider-meter-alpha",
        freshness_state: "fresh",
        last_sync_at: observed_at,
        observed_at: observed_at,
        metadata: %{"fixture" => "rich-identity"}
      },
      overrides
    )
  end

  # persists an independent runtime-sourced weekly row whose reset matches
  # the claimed restart anchor, corroborating the usage-endpoint restart on a
  # second provider surface
  defp corroborate_weekly_restart!(identity, anchored_reset, observed_at) do
    assert {:ok, _window} =
             QuotaWindows.record_evidence(
               identity,
               %{
                 quota_key: "account",
                 quota_scope: "account",
                 quota_family: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("0"),
                 reset_at: anchored_reset,
                 source: "codex_response_headers",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 last_sync_at: observed_at,
                 observed_at: observed_at
               },
               observed_at
             )
  end

  defp record_confirmed_convergence!(
         identity,
         evidence_scope,
         window_kind,
         used_percent,
         reset_at,
         observed_at
       ) do
    attrs =
      confirmed_convergence_attrs(
        evidence_scope,
        window_kind,
        used_percent,
        reset_at,
        observed_at
      )

    assert {:ok, stored} = QuotaWindows.record_evidence(identity, attrs, observed_at)
    stored
  end

  defp confirmed_convergence_attrs(
         evidence_scope,
         window_kind,
         used_percent,
         reset_at,
         observed_at
       ) do
    evidence_scope
    |> confirmed_convergence_identity_attrs()
    |> Map.merge(%{
      window_kind: window_kind,
      window_minutes: if(window_kind == "primary", do: 300, else: 10_080),
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: observed_at,
      observed_at: observed_at,
      metadata: %{"fixture" => "confirmed-convergence"}
    })
  end

  defp confirmed_convergence_identity_attrs(:account) do
    %{quota_key: "account", quota_scope: "account", quota_family: "account"}
  end

  defp confirmed_convergence_identity_attrs(:model) do
    %{
      quota_key: "model-quota",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "example-model",
      raw_limit_id: "model-limit",
      raw_limit_name: "Model limit",
      raw_metered_feature: "model-meter"
    }
  end

  defp confirmed_convergence_identity_attrs(:upstream_model) do
    %{
      quota_key: "upstream-model-quota",
      quota_scope: "upstream_model",
      quota_family: "codex_model",
      upstream_model: "provider-example-model",
      raw_limit_id: "upstream-model-limit",
      raw_limit_name: "Upstream model limit",
      raw_metered_feature: "upstream-model-meter"
    }
  end

  defp confirmed_convergence_identity_attrs(:feature) do
    %{
      quota_key: "example-feature",
      quota_scope: "feature",
      quota_family: "additional_limit",
      raw_limit_id: "feature-limit",
      raw_limit_name: "Feature limit",
      raw_metered_feature: "feature-meter"
    }
  end

  defp confirmed_convergence_lower_percent(:account), do: "14"
  defp confirmed_convergence_lower_percent(_evidence_scope), do: "1"

  defp stale_quota_observed_at(evaluation_at) do
    DateTime.add(evaluation_at, -Quotas.Evidence.freshness_ttl_seconds() - 60, :second)
  end

  defp quota_reset_evaluation_at, do: ~U[2026-07-11 12:00:00Z]

  defp upsert_codex_usage_payload_at(identity, payload, observed_at, evaluation_at) do
    with {:ok, windows} <-
           QuotaWindows.codex_usage_quota_windows_from_payload(payload, observed_at) do
      windows
      |> Enum.map(&EvidenceStore.record_evidence(identity, &1, observed_at, evaluation_at))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, window}, {:ok, stored} -> {:cont, {:ok, [window | stored]}}
        {:error, reason}, _result -> {:halt, {:error, reason}}
      end)
      |> then(fn
        {:ok, stored} -> {:ok, Enum.reverse(stored)}
        {:error, _reason} = error -> error
      end)
    end
  end

  defp account_primary_usage_payload(used_percent, reset_opts) do
    primary_window =
      %{
        "used_percent" => used_percent,
        "limit_window_seconds" => 18_000
      }
      |> maybe_put_usage_reset_at(reset_opts[:reset_at])
      |> maybe_put_usage_reset_after(reset_opts[:reset_after_seconds])

    %{"rate_limit" => %{"primary_window" => primary_window}}
  end

  defp account_usage_payload(primary_percent, primary_reset, secondary_percent, secondary_reset) do
    %{
      "rate_limit" => %{
        "primary_window" => usage_payload_window(primary_percent, 18_000, primary_reset),
        "secondary_window" => usage_payload_window(secondary_percent, 604_800, secondary_reset)
      }
    }
  end

  defp usage_payload_window(used_percent, window_seconds, reset) do
    %{
      "used_percent" => used_percent,
      "limit_window_seconds" => window_seconds
    }
    |> then(fn window ->
      case reset do
        {:absolute, reset_at} -> Map.put(window, "reset_at", DateTime.to_iso8601(reset_at))
        {:relative, seconds} -> Map.put(window, "reset_after_seconds", seconds)
        :missing -> window
      end
    end)
  end

  defp maybe_put_usage_reset_at(window, %DateTime{} = reset_at),
    do: Map.put(window, "reset_at", DateTime.to_iso8601(reset_at))

  defp maybe_put_usage_reset_at(window, _reset_at), do: window

  defp maybe_put_usage_reset_after(window, reset_after_seconds)
       when is_integer(reset_after_seconds),
       do: Map.put(window, "reset_after_seconds", reset_after_seconds)

  defp maybe_put_usage_reset_after(window, _reset_after_seconds), do: window

  defp assert_backend_waiting_on_lock!(backend_pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    assert_backend_waiting_on_lock!(backend_pid, deadline)
  end

  defp assert_backend_waiting_on_lock!(backend_pid, deadline) do
    rows =
      Repo.query!(
        """
        SELECT wait_event_type, wait_event
        FROM pg_stat_activity
        WHERE pid = $1
          AND wait_event_type = 'Lock'
          AND wait_event = 'advisory'
        """,
        [backend_pid]
      ).rows

    cond do
      rows == [["Lock", "advisory"]] ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          0 -> assert_backend_waiting_on_lock!(backend_pid, deadline)
        end

      true ->
        flunk("backend did not enter an advisory lock wait")
    end
  end

  defp assert_canonical_snapshot(stored, canonical) do
    canonical_fields =
      Quota.AccountQuotaWindow.__schema__(:fields) -- [:metadata, :updated_at, :used_percent]

    assert Map.take(stored, canonical_fields) == Map.take(canonical, canonical_fields)
    assert Decimal.equal?(stored.used_percent, canonical.used_percent)
  end

  defp assert_provider_canonical_snapshot(stored, canonical) do
    canonical_fields = [
      :id,
      :upstream_identity_id,
      :quota_key,
      :window_kind,
      :window_minutes,
      :active_limit,
      :credits,
      :reset_at,
      :display_label,
      :limit_name,
      :metered_feature,
      :source,
      :source_precision,
      :quota_scope,
      :quota_family,
      :model,
      :upstream_model,
      :raw_limit_id,
      :raw_limit_name,
      :raw_metered_feature,
      :freshness_state,
      :last_sync_at,
      :observed_at,
      :merge_precedence,
      :created_at
    ]

    assert Map.take(stored, canonical_fields) == Map.take(canonical, canonical_fields)
    assert Decimal.equal?(stored.used_percent, canonical.used_percent)
    assert stored.metadata == canonical.metadata
  end

  defp assert_confirmed_candidate(stored, used_percent, reset_at, observed_at) do
    candidate = confirmed_candidate(stored)

    assert candidate == %{
             "version" => 1,
             "used_percent" =>
               used_percent |> Decimal.new() |> Decimal.normalize() |> Decimal.to_string(:normal),
             "reset_at" => DateTime.to_iso8601(reset_at),
             "observed_at" => DateTime.to_iso8601(observed_at),
             "count" => 1
           }
  end

  defp confirmed_candidate(stored) do
    stored.metadata
    |> Map.drop(["fixture"])
    |> Map.values()
    |> Enum.find(fn
      %{
        "version" => 1,
        "used_percent" => used_percent,
        "reset_at" => reset_at,
        "observed_at" => observed_at,
        "count" => 1
      }
      when is_binary(used_percent) and is_binary(reset_at) and is_binary(observed_at) ->
        true

      _other ->
        false
    end)
  end

  defp contains_confirmed_candidate?(value) when is_struct(value), do: false

  defp contains_confirmed_candidate?(value) when is_map(value) do
    confirmed_candidate_value?(value) or
      Enum.any?(value, fn {key, nested_value} ->
        contains_confirmed_candidate?(key) or contains_confirmed_candidate?(nested_value)
      end)
  end

  defp contains_confirmed_candidate?(value) when is_list(value),
    do: Enum.any?(value, &contains_confirmed_candidate?/1)

  defp contains_confirmed_candidate?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_confirmed_candidate?/1)

  defp contains_confirmed_candidate?(value) when is_binary(value) do
    String.contains?(value, ["\"count\" => 1", "\"version\" => 1", "used_percent\""])
  end

  defp contains_confirmed_candidate?(_value), do: false

  defp confirmed_candidate_value?(%{
         "version" => 1,
         "used_percent" => used_percent,
         "reset_at" => reset_at,
         "observed_at" => observed_at,
         "count" => 1
       })
       when is_binary(used_percent) and is_binary(reset_at) and is_binary(observed_at),
       do: true

  defp confirmed_candidate_value?(_value), do: false

  defp audit_events(action, target_id) do
    Repo.all(
      from(event in AuditEvent,
        where: event.action == ^action and event.target_id == ^target_id,
        order_by: [asc: event.occurred_at, asc: event.id]
      )
    )
  end

  defp assert_decimal_equal(%Decimal{} = actual, expected) when is_binary(expected) do
    assert Decimal.equal?(actual, Decimal.new(expected))
  end
end
