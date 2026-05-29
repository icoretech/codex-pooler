defmodule CodexPooler.Admin.StatsAuthorizationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.Stats

  test "invalid and unauthorized scopes fail without returning data" do
    pool = pool_fixture(%{slug: "stats-invalid", name: "Stats Invalid"})
    scope = owner_scope()

    assert {:error, %{code: :invalid_window}} =
             Stats.build_dashboard(scope, %{window: "30d"})

    assert {:error, %{code: :pool_not_found}} =
             Stats.build_dashboard(scope, %{pool_id: Ecto.UUID.generate()})

    assert {:error, %{code: :unauthorized}} = Stats.build_dashboard(nil, %{pool_id: pool.id})
  end

  test "owners get all-pool reporting stats and owner filter candidates" do
    scope = owner_scope()
    pool_a = pool_fixture(%{slug: "stats-owner-a", name: "Stats Owner A"})
    pool_b = pool_fixture(%{slug: "stats-owner-b", name: "Stats Owner B"})
    pool_c = pool_fixture(%{slug: "stats-owner-c", name: "Stats Owner C"})

    stats_usage_fixture(pool_a, 10, "Owner A key")
    stats_usage_fixture(pool_b, 20, "Owner B key")
    stats_usage_fixture(pool_c, 30, "Owner C key")

    assert {:ok, dashboard} = Stats.build_dashboard(scope, %{window: "24h"})

    assert dashboard.selected_pool == nil
    assert dashboard.kpis.requests.value == 3
    assert dashboard.kpis.tokens.total_tokens == 60

    assert dashboard.filters.pool_options |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([pool_a.id, pool_b.id, pool_c.id])

    assert dashboard.tables.top_api_keys |> Enum.map(& &1.display_name) |> MapSet.new() ==
             MapSet.new(["Owner A key", "Owner B key", "Owner C key"])
  end

  test "assigned admins get aggregate stats across assigned pools only" do
    %{user: owner} = bootstrap_owner_fixture()
    owner_scope = Scope.for_user(owner)
    %{user: admin} = operator_fixture(owner, %{"email" => "stats-admin@example.com"})
    pool_a = pool_fixture(%{slug: "stats-assigned-a", name: "Stats Assigned A"})
    pool_b = pool_fixture(%{slug: "stats-assigned-b", name: "Stats Assigned B"})
    pool_c = pool_fixture(%{slug: "stats-assigned-c", name: "Stats Assigned C"})

    operator_pool_assignment_fixture(admin, pool_a, created_by_user_id: owner.id)
    operator_pool_assignment_fixture(admin, pool_b, created_by_user_id: owner.id)

    stats_usage_fixture(pool_a, 10, "Assigned A key")
    stats_usage_fixture(pool_b, 20, "Assigned B key")
    stats_usage_fixture(pool_c, 30, "Hidden C key")

    admin_scope = Scope.for_user(admin)

    assert {:ok, dashboard} = Stats.build_dashboard(admin_scope, %{window: "24h"})

    assert dashboard.kpis.requests.value == 2
    assert dashboard.kpis.tokens.total_tokens == 30

    assert dashboard.filters.pool_options |> Enum.map(& &1.id) |> MapSet.new() ==
             MapSet.new([pool_a.id, pool_b.id])

    top_key_names = Enum.map(dashboard.tables.top_api_keys, & &1.display_name)

    assert "Assigned A key" in top_key_names
    assert "Assigned B key" in top_key_names
    refute "Hidden C key" in top_key_names

    assert {:ok, pool_a_dashboard} =
             Stats.build_dashboard(admin_scope, %{pool_id: pool_a.id, window: "24h"})

    assert pool_a_dashboard.selected_pool.id == pool_a.id
    assert pool_a_dashboard.kpis.tokens.total_tokens == 10

    assert {:ok, pool_b_dashboard} =
             Stats.build_dashboard(admin_scope, %{pool_id: pool_b.id, window: "24h"})

    assert pool_b_dashboard.selected_pool.id == pool_b.id
    assert pool_b_dashboard.kpis.tokens.total_tokens == 20

    assert {:error, %{code: :pool_not_found, message: hidden_message}} =
             Stats.build_dashboard(admin_scope, %{pool_id: pool_c.id, window: "24h"})

    assert {:error, %{code: :pool_not_found, message: random_message}} =
             Stats.build_dashboard(admin_scope, %{pool_id: Ecto.UUID.generate(), window: "24h"})

    assert hidden_message == random_message

    assert {:ok, owner_dashboard} = Stats.build_dashboard(owner_scope, %{window: "24h"})
    assert owner_dashboard.kpis.tokens.total_tokens == 60
  end

  test "unassigned admins get explicit empty scoped stats" do
    %{user: owner} = bootstrap_owner_fixture()
    %{user: admin} = operator_fixture(owner, %{"email" => "stats-empty-admin@example.com"})
    pool = pool_fixture(%{slug: "stats-unassigned-hidden", name: "Stats Unassigned Hidden"})

    stats_usage_fixture(pool, 30, "Unassigned hidden key")

    admin_scope = Scope.for_user(admin)

    assert {:ok, dashboard} = Stats.build_dashboard(admin_scope, %{window: "24h"})

    assert dashboard.selected_pool == nil
    assert dashboard.filters.pool_options == []
    assert dashboard.kpis.requests.value == 0
    assert dashboard.kpis.tokens.total_tokens == 0
    assert dashboard.tables.top_api_keys == []
    assert dashboard.tables.upstreams == []
    assert dashboard.quota.accounts == []
    assert dashboard.charts.requests == []
    assert dashboard.charts.tokens == []
    assert dashboard.charts.estimated_cost == []
    assert dashboard.sources.requests == 0
    assert dashboard.sources.settlements == 0
    assert [%{code: :no_reporting_pools}] = dashboard.empty_states

    assert {:error, %{code: :pool_not_found}} =
             Stats.build_dashboard(admin_scope, %{pool_id: pool.id, window: "24h"})
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture()
    Scope.for_user(user, ["instance_owner"])
  end

  defp stats_usage_fixture(pool, total_tokens, api_key_display_name) do
    %{api_key: api_key} = active_api_key_fixture(pool, %{display_name: api_key_display_name})
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        correlation_id: "stats-auth-#{System.unique_integer([:positive])}",
        requested_model: "gpt-stats-auth"
      })

    attempt = attempt_fixture(request, assignment)

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      total_tokens: total_tokens,
      input_tokens: total_tokens,
      output_tokens: 0,
      estimated_cost_micros: 0
    })
  end
end
