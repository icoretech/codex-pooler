defmodule CodexPooler.UpstreamsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Secrets, as: Secrets

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Pools
  alias CodexPooler.Quotas
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Auth.{CodexAuth, CodexAuthJson, TokenRefresh}
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.TokenLinking

  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Charts.Measurements

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
      assert imported_assignment.eligibility_status == "eligible"
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
               QuotaWindows.list_quota_windows(identity),
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
               QuotaWindows.list_quota_windows(identity),
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
               QuotaWindows.list_quota_windows(identity),
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
      assert window.source_precision == "observed"
      assert window.freshness_state == "fresh"
      assert window.metadata["limit_window_seconds"] == unknown_window_seconds
      assert window.metadata["reset_after_seconds"] == reset_after_seconds

      assert DateTime.compare(
               window.reset_at,
               DateTime.add(observed_at, reset_after_seconds, :second)
             ) == :eq

      assert Enum.map(
               QuotaWindows.list_quota_windows(identity),
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
      assert spark.id == historical_alias.id
      assert Decimal.equal?(spark.used_percent, Decimal.new("44"))

      assert Enum.map(
               QuotaWindows.list_quota_windows(identity),
               &{&1.quota_key, &1.window_kind}
             ) ==
               [
                 {"account", "primary"},
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
      assert account_primary.source_precision == "observed"
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
               QuotaWindows.list_quota_windows(identity),
               &{&1.quota_key, &1.window_kind}
             ) ==
               [
                 {"account", "secondary"},
                 {"codex_spark", "secondary"}
               ]
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
               QuotaWindows.list_quota_windows(identity),
               &(&1.window_kind == "primary")
             )
    end

    test "honors explicit weekly usage reset_at while ignoring full-window reset_after refreshes" do
      identity = active_identity_fixture()
      observed_at = ~U[2026-04-27 13:00:00Z]
      explicit_reset_at = DateTime.add(observed_at, 3 * 24 * 60 * 60, :second)

      assert {:ok, [weekly]} =
               QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
                 identity,
                 weekly_only_payload(%{
                   "rate_limit" => %{
                     "primary_window" => %{
                       "used_percent" => 67,
                       "limit_window_seconds" => 604_800,
                       "reset_after_seconds" => 604_800,
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

    test "preserves non-weekly usage reset_after_seconds countdowns" do
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
      assert primary.source_precision == "observed"
      assert DateTime.compare(primary.reset_at, DateTime.add(observed_at, 900, :second)) == :eq
      assert QuotaWindows.usable_window?(primary, observed_at)
    end

    test "does not treat non-5h account primary evidence as precise routing evidence" do
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

      assert %{
               eligible?: false,
               routing_state: :blocked,
               exclusions: [%{code: "quota_account_primary_missing"}]
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
      assert model_window.source_precision == "observed"
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

    test "refreshes 5h quota from API usage endpoint before weekly-only wham fallback" do
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
          "/api/codex/usage" => {200, primary_payload},
          "/backend-api/codex/usage" => {200, weekly_only_payload()},
          "/wham/usage" => {200, weekly_only_payload()}
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
               QuotaWindows.list_quota_windows(identity),
               &{&1.window_kind, &1.used_percent}
             ) ==
               [
                 {"primary", Decimal.new("12.000")},
                 {"secondary", Decimal.new("34.000")}
               ]

      assert [request | _] = FakeUpstream.requests(upstream)
      assert request.path == "/api/codex/usage"
    end

    test "provider usage refresh updates reported plan metadata" do
      upstream =
        start_path_upstream(%{
          "/api/codex/usage" =>
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
          "/api/codex/usage" =>
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
      assert account_primary.source_precision == "observed"
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
               "/api/codex/usage",
               "/backend-api/codex/usage"
             ]
    end

    test "reconciliation clears stale additional 5h rows when current usage reports weekly-only" do
      stale_reset_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      upstream =
        start_path_upstream(%{
          "/api/codex/usage" =>
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
               QuotaWindows.list_quota_windows(identity),
               &{&1.quota_key, &1.window_kind}
             ) ==
               [
                 {"account", "primary"},
                 {"codex_spark", "primary"}
               ]

      [account_primary, model_primary] =
        QuotaWindows.list_quota_windows(identity)

      assert account_primary.source == "codex_usage_api"
      assert account_primary.source_precision == "observed"
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
               "/api/codex/usage",
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
               "/api/codex/usage",
               "/backend-api/codex/usage",
               "/wham/usage",
               "/backend-api/wham/usage"
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
             FakeUpstream.raw_response(html_403,
               status: 403,
               headers: [{"content-type", "text/html; charset=utf-8"}]
             ),
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
               "/api/codex/usage",
               "/backend-api/codex/usage",
               "/wham/usage",
               "/backend-api/wham/usage"
             ]
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
      assert primary.source_precision == "observed"
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
               QuotaWindows.list_quota_windows(identity),
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
               QuotaWindows.list_quota_windows(identity),
               &{&1.quota_key, &1.window_kind, Decimal.to_integer(&1.used_percent), &1.source}
             ) == [
               {"account", "primary", 12, "codex_response_headers"},
               {"account", "secondary", 20, "codex_usage_api"},
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
      assert unknown.source_precision == "observed"
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

      assert merged_window.id == header_window.id
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

      assert merged_window.id == header_window.id
      assert merged_window.source == "codex_response_headers"
      assert DateTime.compare(merged_window.reset_at, header_reset_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("20.000"))
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

      assert merged_window.id == event_window.id
      assert merged_window.source == "codex_rate_limit_event"
      assert DateTime.compare(merged_window.reset_at, event_reset_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("100.0"))
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

      assert usage_window.id == event_window.id
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
      assert merged_window.source == "codex_usage_api"
      assert DateTime.compare(merged_window.reset_at, usage_reset_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("12"))
    end

    @tag :upstream_quota_evidence_stability
    test "weak zero usage refresh keeps stronger account percent evidence while refreshing reset metadata" do
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
      assert DateTime.compare(merged_window.reset_at, weak_reset_at) == :eq
      assert DateTime.compare(merged_window.observed_at, weak_observed_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("11"))
    end

    @tag :upstream_quota_evidence_stability
    test "weak zero usage refresh keeps stronger model percent evidence visible" do
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
      assert DateTime.compare(primary_window.reset_at, weak_primary_reset_at) == :eq
      assert DateTime.compare(weekly_window.reset_at, weak_weekly_reset_at) == :eq
      assert DateTime.compare(primary_window.observed_at, weak_observed_at) == :eq
      assert DateTime.compare(weekly_window.observed_at, weak_observed_at) == :eq
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
      observed_at = ~U[2026-07-09 10:19:00Z]
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

      assert merged_window.id == usage_window.id
      assert merged_window.source == "codex_usage_api"
      assert DateTime.compare(merged_window.reset_at, usage_reset_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("0"))
      assert QuotaWindows.usable_window?(merged_window, header_observed_at)
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

      assert merged_window.id == header_window.id
      assert merged_window.source == "codex_response_headers"
      assert merged_window.source_precision == "observed"
      assert merged_window.model == "gpt-5.3-codex-spark"
      assert merged_window.upstream_model == nil
      assert merged_window.raw_limit_id == "codex_bengalfox"
      assert merged_window.raw_limit_name == "gpt-5.3-codex-spark"
      assert merged_window.raw_metered_feature == "codex_bengalfox"
      assert DateTime.compare(merged_window.reset_at, reset_at) == :eq
      assert Decimal.equal?(merged_window.used_percent, Decimal.new("44.000"))
      assert QuotaWindows.usable_window?(merged_window, observed_at)

      assert [persisted] = QuotaWindows.list_quota_windows(identity)
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

      assert merged_window.id == stale_reset_window.id
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

      assert merged_window.id == expired_reset_window.id
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

      assert [persisted] = QuotaWindows.list_quota_windows(identity)
      assert DateTime.compare(persisted.reset_at, weak_reset_at) == :eq
      assert Decimal.equal?(persisted.used_percent, Decimal.new("11"))
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
      assert %{window_kind: "secondary", window_minutes: 10_080} = selection.secondary
      assert Enum.map(selection.blocked_windows, & &1.window_kind) == ["primary"]

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
          "/api/codex/usage" =>
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
