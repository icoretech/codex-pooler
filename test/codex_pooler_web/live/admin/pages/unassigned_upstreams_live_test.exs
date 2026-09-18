defmodule CodexPoolerWeb.Admin.UnassignedUpstreamsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamCockpitReadModel

  setup :register_and_log_in_user

  for status <- ["active", "paused", "reauth_required"] do
    @status status
    test "unassigned #{@status} accounts disable pool-dependent actions with an explanation", %{
      conn: conn,
      scope: scope
    } do
      %{identity: identity} =
        upstream_assignment_fixture(pool_fixture(), %{
          identity_status: @status,
          assignment_status: "deleted"
        })

      reason = "Assign this account to a Pool before using account actions."
      assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)

      for action <- [:rename, :pause, :reactivate, :refresh_token, :delete] do
        assert %{available?: false, reason: ^reason} = Map.fetch!(cockpit.actions, action)
      end

      {:ok, list_view, _html} = live(conn, ~p"/admin/upstreams")

      assert has_element?(
               list_view,
               "#upstream-account-actions-menu-#{identity.id}[title='#{reason}']"
             )

      for action <- ~w(rename pause reactivate refresh saved-reset-policy delete) do
        assert has_element?(
                 list_view,
                 "##{action}-upstream-account-#{identity.id}[disabled][title='#{reason}']"
               )
      end

      {:ok, detail_view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

      for action <- ~w(rename pause reactivate refresh delete) do
        assert has_element?(
                 detail_view,
                 "#cockpit-#{action}-upstream-account-#{identity.id}[disabled][title='#{reason}']"
               )
      end

      assert has_element?(detail_view, "#saved-reset-policy-submit[disabled][title='#{reason}']")

      if @status in ["paused", "reauth_required"] do
        assert cockpit.actions.replace_auth_json.available?

        assert has_element?(
                 detail_view,
                 "#cockpit-replace-auth-json-upstream-account-#{identity.id}:not([disabled])"
               )
      end

      for event <-
            ~w(open_rename_account pause_account reactivate_account refresh_account open_delete_account) do
        html = render_click(detail_view, event, %{"id" => identity.id})
        assert has_element?(detail_view, "#flash-error", reason)
        refute html =~ "pool assignment was not found"
      end

      assert Repo.reload!(identity) == identity
    end
  end

  test "removing the last of two pool assignments keeps the paused account visible", %{
    conn: conn,
    scope: scope
  } do
    first_pool = pool_fixture()
    second_pool = pool_fixture()

    %{identity: identity, assignment: first_assignment} =
      upstream_assignment_fixture(first_pool, %{
        account_label: "Detached account",
        identity_status: "paused"
      })

    assert {:ok, second_assignment} =
             PoolAssignments.create_pool_assignment(second_pool, identity)

    assert {:ok, %{remaining_assignment_count: 1}} =
             PoolAssignments.delete_pool_assignment(first_pool, first_assignment)

    assert {:ok, %{remaining_assignment_count: 0, identity_deleted?: false}} =
             PoolAssignments.delete_pool_assignment(second_pool, second_assignment)

    assert Repo.reload!(identity) == identity
    assert [visible_identity] = Upstreams.list_visible_upstream_identities(scope)
    assert visible_identity.id == identity.id

    {:ok, list_view, _html} = live(conn, ~p"/admin/upstreams")
    assert has_element?(list_view, "#upstream-account-#{identity.id}", "Detached account")

    {:ok, detail_view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    assert has_element?(detail_view, "#upstream-cockpit-title", "Detached account")
    assert has_element?(detail_view, "#upstream-assignments-empty", "No Pool assignments")
  end

  test "the owner can see an unassigned account before any pools exist", %{
    conn: conn,
    scope: scope
  } do
    identity = upstream_identity_fixture(%{account_label: "Unassigned account"})

    assert Pools.list_visible_pools(scope) == []
    assert [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [])
    assert account.identity.id == identity.id
    assert account.assignments == []

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    assert has_element?(view, "#upstream-account-#{identity.id}", "Unassigned account")
  end

  test "pool filters exclude unassigned accounts while status and search still apply", %{
    conn: conn,
    scope: scope
  } do
    first_pool = pool_fixture()
    second_pool = pool_fixture()
    %{identity: first_identity} = upstream_assignment_fixture(first_pool)
    %{identity: second_identity} = upstream_assignment_fixture(second_pool)

    %{identity: unassigned_identity} =
      upstream_assignment_fixture(first_pool, %{
        account_label: "Detached account",
        identity_status: "paused",
        assignment_status: "deleted"
      })

    assert [account] =
             UpstreamAccountsReadModel.list_visible_accounts(scope, [first_pool], %{
               "pool_id" => first_pool.id
             })

    assert account.identity.id == first_identity.id

    assert [unassigned_account] =
             UpstreamAccountsReadModel.list_visible_accounts(scope, [first_pool, second_pool], %{
               "status" => "paused",
               "query" => "Detached"
             })

    assert unassigned_account.identity.id == unassigned_identity.id
    assert unassigned_account.assignments == []

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams?pool_id=#{first_pool.id}")
    assert has_element?(view, "#upstream-account-#{first_identity.id}")
    refute has_element?(view, "#upstream-account-#{second_identity.id}")
    refute has_element?(view, "#upstream-account-#{unassigned_identity.id}")
  end

  test "pool operators cannot discover unassigned accounts or accounts in other pools", %{
    scope: owner_scope
  } do
    visible_pool = pool_fixture()
    hidden_pool = pool_fixture()
    %{identity: visible_identity} = upstream_assignment_fixture(visible_pool)
    %{identity: hidden_identity} = upstream_assignment_fixture(hidden_pool)

    %{identity: unassigned_identity} =
      upstream_assignment_fixture(visible_pool, %{assignment_status: "deleted"})

    %{user: operator, temporary_password: password} =
      operator_fixture(owner_scope, %{"password_change_required" => "false"})

    operator_pool_assignment_fixture(operator, visible_pool,
      created_by_user_id: owner_scope.user.id
    )

    scope = Scope.for_user(operator)

    assert [identity] =
             Upstreams.list_visible_upstream_identities(scope,
               pool_ids: [visible_pool.id, hidden_pool.id],
               include_unassigned: true
             )

    assert identity.id == visible_identity.id
    assert Upstreams.list_visible_upstream_identities(nil) == []

    assert [account] =
             UpstreamAccountsReadModel.list_visible_accounts(scope, [visible_pool, hidden_pool])

    assert account.identity.id == visible_identity.id
    assert :error = UpstreamCockpitReadModel.load_visible(scope, unassigned_identity.id)
    assert :error = UpstreamCockpitReadModel.load_visible(scope, hidden_identity.id)

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => operator.email, "password" => password})

    conn = log_in_user(build_conn(), operator, token)
    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    assert has_element?(view, "#upstream-account-#{visible_identity.id}")
    refute has_element?(view, "#upstream-account-#{unassigned_identity.id}")
    refute has_element?(view, "#upstream-account-#{hidden_identity.id}")

    assert {:error, {:redirect, %{to: "/admin/upstreams"}}} =
             live(conn, ~p"/admin/upstreams/#{unassigned_identity.id}")
  end

  for target <- [:previous_pool, :new_pool] do
    @target target
    test "the owner can attach a paused unassigned account to #{@target} without resuming it", %{
      conn: conn,
      scope: scope
    } do
      previous_pool = pool_fixture()

      target_pool =
        case @target do
          :previous_pool -> previous_pool
          :new_pool -> pool_fixture()
        end

      %{identity: identity, assignment: previous_assignment} =
        upstream_assignment_fixture(previous_pool, %{
          account_label: "Paused unassigned account",
          identity_status: "paused",
          assignment_status: "deleted"
        })

      %{identity: deleted_identity} =
        upstream_assignment_fixture(previous_pool, %{identity_status: "deleted"})

      {options, []} = PoolForm.upstream_identity_options(scope)
      assert Enum.any?(options, &(&1.value == identity.id and &1.status == "paused"))
      refute Enum.any?(options, &(&1.value == deleted_identity.id))

      {:ok, view, _html} =
        live(conn, ~p"/admin/upstreams?edit_pool_id=#{target_pool.id}&step=upstreams")

      assert has_element?(view, "#pool-edit-dialog", "Paused unassigned account")

      view
      |> element("#pool-edit-form")
      |> render_submit(%{
        "pool_edit" => %{
          "id" => target_pool.id,
          "name" => target_pool.name,
          "status" => "active",
          "routing_strategy" => "bridge_ring",
          "upstream_identity_ids" => [identity.id],
          "api_key_ids" => []
        }
      })

      assert [assignment] =
               target_pool
               |> Upstreams.list_pool_assignments()
               |> Enum.reject(&(&1.status == "deleted"))

      assert assignment.upstream_identity_id == identity.id
      assert assignment.status == "active"
      assert Repo.reload!(identity).status == "paused"
      assert Upstreams.list_eligible_pool_assignments(target_pool) == []

      case @target do
        :previous_pool -> assert assignment.id == previous_assignment.id
        :new_pool -> assert Repo.reload!(previous_assignment).status == "deleted"
      end

      assert {:ok, cockpit} = UpstreamCockpitReadModel.load_visible(scope, identity.id)
      assert cockpit.actions.rename.available?
      assert cockpit.actions.reactivate.available?
      assert cockpit.actions.delete.available?
      refute cockpit.actions.pause.available?

      {:ok, detail_view, _html} = live(conn, ~p"/admin/upstreams/#{identity.id}")

      for action <- ~w(rename reactivate delete) do
        assert has_element?(
                 detail_view,
                 "#cockpit-#{action}-upstream-account-#{identity.id}:not([disabled])"
               )

        assert has_element?(
                 view,
                 "##{action}-upstream-account-#{identity.id}:not([disabled])"
               )
      end

      assert {:ok, _result} =
               Upstreams.rename_account_for_scope(scope, identity, %{account_label: "Reattached"})

      assert Repo.reload!(identity).account_label == "Reattached"
    end
  end
end
