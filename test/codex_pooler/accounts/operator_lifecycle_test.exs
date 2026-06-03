defmodule CodexPooler.Accounts.OperatorLifecycleTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{Scope, Session, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{Membership, OperatorPoolAssignment}
  alias CodexPooler.Repo

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures, only: [pool_fixture: 1]

  describe "operator lifecycle contract" do
    @tag :operator_lifecycle
    test "exports the expected public operator lifecycle APIs" do
      assert_operator_api!(:list_operators, 0)
      assert_operator_api!(:list_operators_for_management, 1)
      assert_operator_api!(:change_new_operator, 1)
      assert_operator_api!(:change_operator, 1)
      assert_operator_api!(:operator_lifecycle, 1)
      assert_operator_api!(:create_operator, 3)
      assert_operator_api!(:update_operator, 4)
      assert_operator_api!(:update_current_operator_profile, 3)
      assert_operator_api!(:deactivate_operator, 4)
      assert_operator_api!(:reactivate_operator, 4)
      assert_operator_api!(:reset_operator_password, 4)
      assert_operator_api!(:resend_operator_temporary_password, 4)
    end

    @tag :operator_lifecycle
    test "creates operators with normalized email, a valid temporary password, forced password change, and audit rows" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      create_changeset =
        call_operator_api!(:change_new_operator, [%{"email" => " Operator@Example.COM "}])

      assert Ecto.Changeset.apply_changes(create_changeset).email == "operator@example.com"

      assert {:ok, %{user: %User{} = operator, temporary_password: temporary_password}} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{
                     "display_name" => "  Second Operator  ",
                     "email" => "  SECOND.OPERATOR@Example.COM  "
                   }),
                   operator_metadata(%{request_id: "operator-create-contract"})
                 ]
               )

      assert operator.email == "second.operator@example.com"
      assert operator.display_name == "Second Operator"
      assert operator.status == "active"
      assert operator.password_change_required == true

      loaded_operator = Repo.reload!(operator)
      assert loaded_operator.datetime_format == "default"
      assert loaded_operator.timezone == "Etc/UTC"

      assert Repo.get_by(Membership,
               user_id: operator.id,
               role: "instance_admin",
               status: "active"
             )

      assert is_binary(temporary_password)
      assert byte_size(temporary_password) >= 8
      refute operator.password_hash == temporary_password

      assert %Ecto.Changeset{} = call_operator_api!(:change_operator, [operator])

      assert Accounts.get_user_by_email_and_password(operator.email, temporary_password).id ==
               operator.id

      assert Enum.any?(call_operator_api!(:list_operators, []), &(&1.id == operator.id))

      assert {:ok, operators} =
               call_operator_api!(:list_operators_for_management, [owner])

      assert Enum.any?(operators, &(&1.id == operator.id))
      assert audit = Repo.get_by(AuditEvent, action: "operator.create", actor_user_id: owner.id)
      refute inspect(audit.details) =~ temporary_password
    end

    @tag :operator_lifecycle
    test "owners create instance admins with assigned pools in one transaction" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner)
      pool_a = pool_fixture(%{slug: "operator-admin-a", name: "Operator Admin A"})
      pool_b = pool_fixture(%{slug: "operator-admin-b", name: "Operator Admin B"})

      assert {:ok, %{user: %User{} = operator}} =
               Accounts.create_operator(
                 owner_scope,
                 valid_operator_attributes(%{
                   "email" => "assigned-admin@example.com",
                   "role" => "instance_admin",
                   "pool_ids" => [pool_a.id, pool_b.id]
                 }),
                 operator_metadata(%{request_id: "operator-create-assigned-admin"})
               )

      assert Repo.get_by(Membership,
               user_id: operator.id,
               role: "instance_admin",
               status: "active"
             )

      refute Repo.get_by(Membership,
               user_id: operator.id,
               role: "instance_owner",
               status: "active"
             )

      assigned_pool_ids =
        OperatorPoolAssignment
        |> where(
          [assignment],
          assignment.user_id == ^operator.id and assignment.status == "active"
        )
        |> select([assignment], assignment.pool_id)
        |> Repo.all()
        |> Enum.sort()

      assert assigned_pool_ids == Enum.sort([pool_a.id, pool_b.id])
      assert Accounts.operator_lifecycle(operator).role == "instance_admin"

      assert Enum.sort(Accounts.operator_lifecycle(operator).assigned_pool_ids) ==
               assigned_pool_ids

      audit = Repo.get_by!(AuditEvent, action: "operator.create", actor_user_id: owner.id)
      assert audit.details["role"] == "instance_admin"
      assert Enum.sort(audit.details["assigned_pool_ids"]) == assigned_pool_ids
      assert audit.details["assigned_pool_count"] == 2
    end

    @tag :operator_lifecycle
    test "owners create instance owners without pool assignments" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      pool = pool_fixture(%{slug: "ignored-owner-pool", name: "Ignored Owner Pool"})

      assert {:ok, %{user: %User{} = created_owner}} =
               Accounts.create_operator(
                 Scope.for_user(owner),
                 valid_operator_attributes(%{
                   "email" => "created-owner@example.com",
                   "role" => "instance_owner",
                   "pool_ids" => [pool.id]
                 }),
                 operator_metadata(%{request_id: "operator-create-owner"})
               )

      assert Repo.get_by(Membership,
               user_id: created_owner.id,
               role: "instance_owner",
               status: "active"
             )

      refute Repo.get_by(OperatorPoolAssignment, user_id: created_owner.id, status: "active")

      assert Accounts.operator_lifecycle(created_owner) == %{
               role: "instance_owner",
               assigned_pool_ids: []
             }
    end

    @tag :operator_lifecycle
    test "operator form changesets have explicit create and update contracts" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert %Ecto.Changeset{} =
               Accounts.change_new_operator(%{"email" => "new.operator@example.com"})

      assert %Ecto.Changeset{} = Accounts.change_operator(owner)

      assert_raise FunctionClauseError, fn ->
        Accounts.change_operator(%{"email" => "not-an-existing-operator@example.com"})
      end

      assert_raise FunctionClauseError, fn ->
        Accounts.change_new_operator(:invalid)
      end
    end

    @tag :operator_lifecycle
    test "honors an explicit false password-change requirement on create" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok, %{user: %User{} = operator, temporary_password: temporary_password}} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{
                     "email" => "current-password.operator@example.com",
                     "password_change_required" => "false"
                   }),
                   operator_metadata(%{request_id: "operator-create-password-current-contract"})
                 ]
               )

      refute operator.password_change_required
      refute Repo.reload!(operator).password_change_required

      assert Accounts.get_user_by_email_and_password(operator.email, temporary_password).id ==
               operator.id
    end

    @tag :operator_lifecycle
    test "rejects duplicate normalized operator emails" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok, _result} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{"email" => "Operator@Example.com"}),
                   operator_metadata()
                 ]
               )

      assert {:error, %Ecto.Changeset{} = changeset} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{"email" => " operator@example.COM "}),
                   operator_metadata()
                 ]
               )

      assert %{email: [_ | _]} = errors_on(changeset)
    end

    @tag :operator_lifecycle
    test "rejects invalid manually supplied temporary passwords without auditing creation" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{
                     "email" => "operator@example.com",
                     "temporary_password" => "short"
                   }),
                   operator_metadata()
                 ]
               )

      assert %{password: ["should be at least 8 character(s)"]} = errors_on(changeset)
      refute Accounts.get_user_by_email("operator@example.com")
      refute Repo.get_by(AuditEvent, action: "operator.create", actor_user_id: owner.id)
    end

    @tag :operator_lifecycle
    test "operator lifecycle mutations require an instance owner actor" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: admin} = operator_fixture(owner, %{"email" => "admin@example.com"})
      %{user: target} = operator_fixture(owner, %{"email" => "target@example.com"})
      admin_scope = Scope.for_user(admin, ["instance_admin"])

      assert {:error, :operator_management_denied} =
               Accounts.list_operators_for_management(admin_scope)

      assert {:error, :operator_management_denied} =
               Accounts.create_operator(
                 admin_scope,
                 valid_operator_attributes(%{"email" => "denied-create@example.com"}),
                 operator_metadata(%{request_id: "operator-create-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.update_operator(
                 admin_scope,
                 target,
                 %{"display_name" => "Denied Update"},
                 operator_metadata(%{request_id: "operator-update-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.deactivate_operator(
                 admin_scope,
                 target,
                 %{"reason" => "denied"},
                 operator_metadata(%{request_id: "operator-deactivate-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.reactivate_operator(
                 admin_scope,
                 target,
                 %{},
                 operator_metadata(%{request_id: "operator-reactivate-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.reset_operator_password(
                 admin_scope,
                 target,
                 %{},
                 operator_metadata(%{request_id: "operator-reset-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.resend_operator_temporary_password(
                 admin_scope,
                 target,
                 %{},
                 operator_metadata(%{request_id: "operator-resend-denied-contract"})
               )

      refute Accounts.get_user_by_email("denied-create@example.com")
      assert Repo.reload!(target).display_name == "Operator"
      assert Repo.reload!(target).status == "active"
      refute Repo.get_by(AuditEvent, action: "operator.update", actor_user_id: admin.id)
      refute Repo.get_by(AuditEvent, action: "operator.deactivate", actor_user_id: admin.id)
      refute Repo.get_by(AuditEvent, action: "operator.password_reset", actor_user_id: admin.id)
    end

    @tag :operator_lifecycle
    test "operator management uses active memberships instead of cached scope roles" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: admin} = operator_fixture(owner, %{"email" => "admin@example.com"})
      %{user: target} = operator_fixture(owner, %{"email" => "target@example.com"})

      assert {:ok, operators} = Accounts.list_operators_for_management(Scope.for_user(owner, []))
      assert Enum.any?(operators, &(&1.id == owner.id))

      stale_owner_scope = Scope.for_user(admin, ["instance_owner"])

      assert {:error, :operator_management_denied} =
               Accounts.list_operators_for_management(stale_owner_scope)

      assert {:error, :operator_management_denied} =
               Accounts.create_operator(
                 stale_owner_scope,
                 valid_operator_attributes(%{"email" => "stale-owner-role@example.com"}),
                 operator_metadata(%{request_id: "operator-stale-role-denied-contract"})
               )

      assert {:error, :operator_management_denied} =
               Accounts.update_operator(
                 stale_owner_scope,
                 target,
                 %{"display_name" => "Stale Owner Update"},
                 operator_metadata(%{request_id: "operator-stale-update-denied-contract"})
               )

      refute Accounts.get_user_by_email("stale-owner-role@example.com")
      assert Repo.reload!(target).display_name == "Operator"

      refute Repo.get_by(AuditEvent,
               action: "operator.update",
               actor_user_id: admin.id,
               target_id: target.id
             )
    end

    @tag :operator_lifecycle
    test "current operator profile updates are self-service and limited to profile fields" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator} = operator_fixture(owner, %{"email" => "operator@example.com"})

      operator =
        operator
        |> Ecto.Changeset.change(password_change_required: false)
        |> Repo.update!()

      assert {:ok, %User{} = updated} =
               Accounts.update_current_operator_profile(
                 operator,
                 %{
                   "display_name" => "  Self Service Operator  ",
                   "email" => " SELF.SERVICE@Example.COM ",
                   "password_change_required" => true,
                   "status" => "disabled"
                 },
                 operator_metadata(%{request_id: "operator-profile-self-service"})
               )

      assert updated.id == operator.id
      assert updated.email == "self.service@example.com"
      assert updated.display_name == "Self Service Operator"
      assert updated.status == "active"
      assert updated.password_change_required == false

      assert audit =
               Repo.get_by(AuditEvent,
                 action: "operator.update",
                 actor_user_id: operator.id,
                 target_id: operator.id
               )

      assert audit.correlation_id == "operator-profile-self-service"
    end

    @tag :operator_lifecycle
    test "current operator profile updates persist valid datetime preferences" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator} = operator_fixture(owner, %{"email" => "operator@example.com"})

      for {datetime_format, timezone} <- [
            {"default", "Etc/UTC"},
            {"short", "America/New_York"},
            {"long", "Europe/Rome"},
            {"iso8601", "Europe/Rome"}
          ] do
        assert {:ok, %User{} = updated} =
                 Accounts.update_current_operator_profile(
                   Repo.reload!(operator),
                   %{
                     "datetime_format" => datetime_format,
                     "timezone" => timezone
                   },
                   operator_metadata(%{request_id: "operator-profile-datetime-valid"})
                 )

        assert updated.datetime_format == datetime_format
        assert updated.timezone == timezone

        loaded = Repo.reload!(operator)
        assert loaded.datetime_format == datetime_format
        assert loaded.timezone == timezone
      end
    end

    @tag :operator_lifecycle
    test "current operator profile rejects invalid datetime preferences without persistence" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator} = operator_fixture(owner, %{"email" => "operator@example.com"})

      assert {:ok, %User{} = operator} =
               Accounts.update_current_operator_profile(
                 operator,
                 %{
                   "datetime_format" => "short",
                   "timezone" => "Europe/Rome"
                 },
                 operator_metadata(%{request_id: "operator-profile-datetime-baseline"})
               )

      invalid_examples = [
        {%{"datetime_format" => "relative", "timezone" => "Europe/Rome"}, :datetime_format},
        {%{"datetime_format" => "short", "timezone" => "UTC+2"}, :timezone},
        {%{"datetime_format" => "short", "timezone" => "Europe/NotAZone"}, :timezone}
      ]

      for {attrs, field} <- invalid_examples do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Accounts.update_current_operator_profile(
                   Repo.reload!(operator),
                   attrs,
                   operator_metadata(%{request_id: "operator-profile-datetime-invalid"})
                 )

        assert %{^field => [_ | _]} = errors_on(changeset)

        loaded = Repo.reload!(operator)
        assert loaded.datetime_format == "short"
        assert loaded.timezone == "Europe/Rome"
      end
    end

    @tag :operator_lifecycle
    test "datetime format storage constraint rejects invalid direct persistence" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator} = operator_fixture(owner, %{"email" => "operator@example.com"})

      invalid_insert_changeset =
        %User{}
        |> Ecto.Changeset.change(%{
          email: "invalid-datetime-format@example.com",
          password_hash: "stored-hash",
          status: "active",
          password_change_required: false,
          datetime_format: "relative",
          timezone: "Etc/UTC"
        })
        |> Ecto.Changeset.check_constraint(:datetime_format,
          name: :users_datetime_format_check
        )

      assert {:error, %Ecto.Changeset{} = insert_changeset} =
               Repo.insert(invalid_insert_changeset)

      assert %{datetime_format: [_ | _]} = errors_on(insert_changeset)

      invalid_update_changeset =
        operator
        |> Ecto.Changeset.change(datetime_format: "relative")
        |> Ecto.Changeset.check_constraint(:datetime_format,
          name: :users_datetime_format_check
        )

      assert {:error, %Ecto.Changeset{} = update_changeset} =
               Repo.update(invalid_update_changeset)

      assert %{datetime_format: [_ | _]} = errors_on(update_changeset)
      assert Repo.reload!(operator).datetime_format == "default"
    end

    @tag :operator_lifecycle
    test "updates editable operator fields and persists password_change_required changes with audit rows" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator} = operator_fixture(owner, %{"email" => "operator@example.com"})
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, %User{} = updated} =
               call_operator_api!(
                 :update_operator,
                 [
                   scope,
                   operator.id,
                   %{
                     "display_name" => "  Updated Operator  ",
                     "email" => " UPDATED.OPERATOR@Example.COM ",
                     "password_change_required" => false
                   },
                   operator_metadata(%{request_id: "operator-update-contract"})
                 ]
               )

      assert updated.id == operator.id
      assert updated.email == "updated.operator@example.com"
      assert updated.display_name == "Updated Operator"
      assert updated.password_change_required == false
      assert Repo.get_by(AuditEvent, action: "operator.update", actor_user_id: owner.id)
    end

    @tag :operator_lifecycle
    test "owners edit admin pool assignments transactionally" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner)
      original_pool = pool_fixture(%{slug: "operator-original", name: "Operator Original"})
      new_pool = pool_fixture(%{slug: "operator-new", name: "Operator New"})
      removed_pool = pool_fixture(%{slug: "operator-removed", name: "Operator Removed"})

      {:ok, %{user: operator}} =
        Accounts.create_operator(
          owner_scope,
          valid_operator_attributes(%{
            "email" => "assignment-edit@example.com",
            "role" => "instance_admin",
            "pool_ids" => [original_pool.id, removed_pool.id]
          }),
          operator_metadata()
        )

      assert {:ok, %User{} = updated} =
               Accounts.update_operator(
                 owner_scope,
                 operator,
                 %{
                   "display_name" => "Assignment Edited",
                   "role" => "instance_admin",
                   "pool_ids" => [original_pool.id, new_pool.id]
                 },
                 operator_metadata(%{request_id: "operator-assignment-edit"})
               )

      assert updated.display_name == "Assignment Edited"

      active_pool_ids =
        OperatorPoolAssignment
        |> where(
          [assignment],
          assignment.user_id == ^operator.id and assignment.status == "active"
        )
        |> select([assignment], assignment.pool_id)
        |> Repo.all()
        |> Enum.sort()

      assert active_pool_ids == Enum.sort([original_pool.id, new_pool.id])

      assert Repo.get_by(OperatorPoolAssignment,
               user_id: operator.id,
               pool_id: removed_pool.id,
               status: "revoked"
             )

      audit =
        Repo.get_by!(AuditEvent,
          action: "operator.update",
          correlation_id: "operator-assignment-edit"
        )

      assert Enum.sort(audit.details["added_pool_ids"]) == [new_pool.id]
      assert Enum.sort(audit.details["removed_pool_ids"]) == [removed_pool.id]
    end

    @tag :operator_lifecycle
    test "owners promote and demote operators subject to the final owner invariant" do
      reset_bootstrap_state_fixture!()
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner)
      pool = pool_fixture(%{slug: "demoted-owner-pool", name: "Demoted Owner Pool"})
      %{user: target} = operator_fixture(owner_scope, %{"email" => "promoted@example.com"})

      assert {:ok, %User{} = promoted} =
               Accounts.update_operator(
                 owner_scope,
                 target,
                 %{"role" => "instance_owner", "pool_ids" => [pool.id]},
                 operator_metadata(%{request_id: "operator-promote-owner"})
               )

      assert Repo.get_by(Membership,
               user_id: promoted.id,
               role: "instance_owner",
               status: "active"
             )

      refute Repo.get_by(OperatorPoolAssignment, user_id: promoted.id, status: "active")

      assert {:ok, %User{} = demoted} =
               Accounts.update_operator(
                 owner_scope,
                 promoted,
                 %{"role" => "instance_admin", "pool_ids" => [pool.id]},
                 operator_metadata(%{request_id: "operator-demote-owner"})
               )

      assert Repo.get_by(Membership,
               user_id: demoted.id,
               role: "instance_admin",
               status: "active"
             )

      assert Repo.get_by(Membership,
               user_id: demoted.id,
               role: "instance_owner",
               status: "revoked"
             )

      assert Repo.get_by(OperatorPoolAssignment,
               user_id: demoted.id,
               pool_id: pool.id,
               status: "active"
             )

      assert {:error, :last_active_owner} =
               Accounts.update_operator(
                 owner_scope,
                 owner,
                 %{"role" => "instance_admin", "pool_ids" => [pool.id]},
                 operator_metadata(%{request_id: "operator-final-owner-demote"})
               )

      assert Repo.get_by(Membership, user_id: owner.id, role: "instance_owner", status: "active")
      refute Repo.get_by(AuditEvent, correlation_id: "operator-final-owner-demote")
    end

    @tag :operator_lifecycle
    test "admins cannot escalate roles or assignments through direct context calls" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      owner_scope = Scope.for_user(owner)
      pool = pool_fixture(%{slug: "admin-denied-pool", name: "Admin Denied Pool"})
      %{user: admin} = operator_fixture(owner_scope, %{"email" => "admin-denied@example.com"})
      %{user: target} = operator_fixture(owner_scope, %{"email" => "target-denied@example.com"})
      admin_scope = Scope.for_user(admin)

      assert {:error, :operator_management_denied} =
               Accounts.update_operator(
                 admin_scope,
                 target,
                 %{"role" => "instance_owner", "pool_ids" => [pool.id]},
                 operator_metadata(%{request_id: "operator-admin-escalation-denied"})
               )

      refute Repo.get_by(Membership, user_id: target.id, role: "instance_owner", status: "active")

      refute Repo.get_by(OperatorPoolAssignment,
               user_id: target.id,
               pool_id: pool.id,
               status: "active"
             )

      refute Repo.get_by(AuditEvent, correlation_id: "operator-admin-escalation-denied")
    end

    @tag :operator_lifecycle
    test "deactivates operators, revokes their sessions, rejects inactive login, and reactivates them" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator, temporary_password: temporary_password} = operator_fixture(owner)

      assert {:ok, %{token: token}} =
               Accounts.login_user(%{"email" => operator.email, "password" => temporary_password})

      assert Accounts.get_user_by_session_token(token)

      assert {:ok, %User{} = disabled} =
               call_operator_api!(
                 :deactivate_operator,
                 [
                   owner,
                   operator,
                   %{"reason" => "offboarding"},
                   operator_metadata(%{request_id: "operator-deactivate-contract"})
                 ]
               )

      assert disabled.status == "disabled"
      refute Accounts.get_user_by_session_token(token)
      assert Repo.get_by(Session, user_id: operator.id, status: "revoked")

      assert {:error, :invalid_credentials} =
               Accounts.login_user(%{"email" => operator.email, "password" => temporary_password})

      assert Repo.get_by(AuditEvent, action: "operator.deactivate", actor_user_id: owner.id)

      assert {:ok, %{user: %User{} = reactivated, temporary_password: reactivated_password}} =
               call_operator_api!(
                 :reactivate_operator,
                 [
                   owner,
                   disabled,
                   %{"reason" => "returned"},
                   operator_metadata(%{request_id: "operator-reactivate-contract"})
                 ]
               )

      assert reactivated.status == "active"
      assert reactivated.password_change_required == true
      refute Accounts.get_user_by_email_and_password(operator.email, temporary_password)
      assert Accounts.get_user_by_email_and_password(operator.email, reactivated_password)
      assert Repo.get_by(AuditEvent, action: "operator.reactivate", actor_user_id: owner.id)
    end

    test "reactivation honors the submitted password-change requirement" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator, temporary_password: temporary_password} = operator_fixture(owner)

      assert {:ok, %User{} = disabled} =
               call_operator_api!(
                 :deactivate_operator,
                 [
                   owner,
                   operator,
                   %{"reason" => "temporary leave"},
                   operator_metadata(%{request_id: "operator-deactivate-reactivate-flag"})
                 ]
               )

      assert {:ok, %{user: %User{} = reactivated, temporary_password: reactivated_password}} =
               call_operator_api!(
                 :reactivate_operator,
                 [
                   owner,
                   disabled,
                   %{
                     "reason" => "returned",
                     "password_change_required" => false
                   },
                   operator_metadata(%{request_id: "operator-reactivate-flag-contract"})
                 ]
               )

      assert reactivated.status == "active"
      assert reactivated.password_change_required == false
      refute Accounts.get_user_by_email_and_password(operator.email, temporary_password)
      assert Accounts.get_user_by_email_and_password(operator.email, reactivated_password)
    end

    @tag :last_active_owner
    test "protects the final active owner from deactivation" do
      reset_bootstrap_state_fixture!()
      %{user: owner, token: token} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:error, :last_active_owner} =
               call_operator_api!(
                 :deactivate_operator,
                 [owner, owner, %{"reason" => "self-disable"}, operator_metadata()]
               )

      assert Repo.reload!(owner).status == "active"
      assert Accounts.get_user_by_session_token(token)
      refute Repo.get_by(AuditEvent, action: "operator.deactivate", actor_user_id: owner.id)
    end

    @tag :last_active_owner
    test "allows non-final owner deactivation but ignores inactive owners for final-owner safety" do
      reset_bootstrap_state_fixture!()
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: second_owner} = operator_fixture(owner, %{"email" => "second-owner@example.com"})

      assert {:ok, _membership} =
               Pools.create_instance_owner_membership(Scope.for_user(owner, []), second_owner)

      assert {:ok, %User{} = disabled_second_owner} =
               Accounts.deactivate_operator(
                 owner,
                 second_owner,
                 %{"reason" => "rotation"},
                 operator_metadata(%{request_id: "operator-second-owner-deactivate"})
               )

      assert disabled_second_owner.status == "disabled"

      assert {:error, :last_active_owner} =
               Accounts.deactivate_operator(
                 owner,
                 owner,
                 %{"reason" => "inactive owner should not count"},
                 operator_metadata(%{request_id: "operator-final-owner-active-check"})
               )

      assert Repo.reload!(owner).status == "active"
    end

    @tag :operator_lifecycle
    test "migrated former global admins are effective owners for lifecycle actions" do
      reset_bootstrap_state_fixture!()
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      %{user: migrated_owner} =
        operator_fixture(owner, %{"email" => "migrated-owner@example.com"})

      Membership
      |> Repo.get_by!(user_id: migrated_owner.id, role: "instance_admin", status: "active")
      |> Membership.changeset(%{role: "instance_owner"})
      |> Repo.update!()

      migrated_scope = Scope.for_user(migrated_owner, [])

      assert {:ok, operators} = Accounts.list_operators_for_management(migrated_scope)
      assert Enum.any?(operators, &(&1.id == owner.id))

      assert {:ok, %User{} = disabled_owner} =
               Accounts.deactivate_operator(
                 migrated_scope,
                 owner,
                 %{"reason" => "rollout owner migration"},
                 operator_metadata(%{request_id: "operator-migrated-owner-lifecycle"})
               )

      assert disabled_owner.status == "disabled"

      assert Repo.get_by(AuditEvent,
               action: "operator.deactivate",
               actor_user_id: migrated_owner.id,
               target_id: owner.id
             )
    end
  end

  defp assert_operator_api!(name, arity) do
    Code.ensure_loaded!(Accounts)

    assert function_exported?(Accounts, name, arity),
           "expected CodexPooler.Accounts.#{name}/#{arity} to define the operator lifecycle contract"
  end

  defp call_operator_api!(name, args) when is_atom(name) and is_list(args) do
    assert_operator_api!(name, length(args))
    apply(Accounts, name, args)
  end
end
