defmodule CodexPooler.Admin.UpstreamCockpitMetricsTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamCockpitMetrics
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  test "request health and pool contribution are scoped to the caller's visible pools" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)

    {:ok, visible_pool} =
      Pools.create_pool(owner_scope, %{slug: unique_slug("visible"), name: "Visible Cockpit"})

    {:ok, hidden_pool} =
      Pools.create_pool(owner_scope, %{slug: unique_slug("hidden"), name: "Hidden Cockpit"})

    %{identity: visible_identity, assignment: visible_assignment} =
      upstream_assignment_fixture(visible_pool, %{
        account_label: "Scoped cockpit identity",
        assignment_label: "Visible assignment"
      })

    assert {:ok, hidden_assignment} =
             PoolAssignments.create_pool_assignment(hidden_pool, visible_identity, %{
               assignment_label: "Hidden assignment",
               status: "active",
               health_status: "active",
               eligibility_status: "eligible"
             })

    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)
    admin_scope = Scope.for_user(admin)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    visible_admitted_at = DateTime.add(now, -1, :hour)

    insert_request!(visible_pool, visible_assignment, %{
      status: "succeeded",
      admitted_at: visible_admitted_at,
      correlation_id: "visible-cockpit-success"
    })

    insert_request!(hidden_pool, hidden_assignment, %{
      status: "failed",
      admitted_at: DateTime.add(now, -30, :minute),
      correlation_id: "hidden-cockpit-failed"
    })

    assignments = [
      assignment_summary(visible_assignment, visible_pool),
      assignment_summary(hidden_assignment, hidden_pool)
    ]

    request_health = UpstreamCockpitMetrics.request_health(admin_scope, visible_identity)

    contribution =
      UpstreamCockpitMetrics.pool_contribution(admin_scope, visible_identity, assignments)

    assert request_health.kpis.total_requests_7d == 1
    assert request_health.kpis.total_requests_24h == 1
    assert request_health.kpis.failed_requests_24h == 0
    assert request_health.state == "healthy"

    visible_bucket =
      Enum.find(
        request_health.items,
        &(&1.date == Date.to_iso8601(DateTime.to_date(visible_admitted_at)))
      )

    assert visible_bucket.success_count == 1
    assert visible_bucket.failure_count == 0

    contribution_by_pool = Map.new(contribution.items, &{&1.pool_id, &1})
    assert contribution.kpis.assignment_count == 1
    assert contribution.kpis.successful_requests_7d == 1
    assert Map.keys(contribution_by_pool) == [visible_pool.id]
    assert contribution_by_pool[visible_pool.id].successful_request_count_7d == 1
    assert contribution_by_pool[visible_pool.id].share_percent_value == 100.0
    refute Map.has_key?(contribution_by_pool, hidden_pool.id)
    refute inspect(request_health) =~ "hidden-cockpit-failed"
    refute inspect(contribution) =~ "Hidden Cockpit"
  end

  test "quota health is scoped to visible assignments and omits hidden pool labels" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner_scope = Scope.for_user(owner)

    {:ok, visible_pool} =
      Pools.create_pool(owner_scope, %{slug: unique_slug("quota-visible"), name: "Quota Visible"})

    {:ok, hidden_pool} =
      Pools.create_pool(owner_scope, %{slug: unique_slug("quota-hidden"), name: "Quota Hidden"})

    %{identity: identity, assignment: visible_assignment} =
      upstream_assignment_fixture(visible_pool, %{
        account_label: "Quota scoped identity",
        assignment_label: "Quota visible assignment"
      })

    assert {:ok, hidden_assignment} =
             PoolAssignments.create_pool_assignment(hidden_pool, identity, %{
               assignment_label: "Quota hidden assignment",
               status: "active",
               health_status: "active",
               eligibility_status: "eligible"
             })

    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner.id)
    admin_scope = Scope.for_user(admin)

    upsert_quota_window!(identity, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 100,
      credits: 90,
      used_percent: Decimal.new("10"),
      reset_at: DateTime.add(DateTime.utc_now(), 5, :hour),
      observed_at: DateTime.utc_now()
    })

    assignments = [
      assignment_summary(visible_assignment, visible_pool),
      assignment_summary(hidden_assignment, hidden_pool)
    ]

    quota_health = UpstreamCockpitMetrics.quota_health(admin_scope, identity, assignments)

    assert quota_health.kpis.assignment_count == 1

    assert [%{pool_id: visible_pool_id, state: "fresh", remaining_percent_value: 90.0}] =
             quota_health.items

    assert visible_pool_id == visible_pool.id
    refute inspect(quota_health) =~ "Quota Hidden"
    refute inspect(quota_health) =~ "Quota hidden assignment"
  end

  test "recent request event rows return only safe metadata for visible retried and failed requests" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(owner)

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug("events"), name: "Cockpit Events"})

    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    secret = "raw-prompt-#{System.unique_integer([:positive])}"

    failed =
      insert_request!(pool, assignment, %{
        status: "failed",
        admitted_at: DateTime.add(now, -1, :minute),
        correlation_id: "visible-failed-event",
        request_metadata: %{"prompt" => secret},
        response_status_code: 502,
        last_error_code: "upstream_failed"
      })

    retried =
      insert_request!(pool, assignment, %{
        status: "succeeded",
        admitted_at: DateTime.add(now, -2, :minute),
        correlation_id: "visible-retried-event"
      })

    attempt_fixture(retried, assignment, %{
      attempt_number: 2,
      status: "failed",
      completed_at: DateTime.add(now, -1, :minute),
      network_error_code: "retryable_failure"
    })

    rows = UpstreamCockpitMetrics.recent_request_event_rows(scope, identity, 10)

    assert Enum.map(rows, & &1.id) == [failed.id, retried.id]

    assert Enum.all?(rows, fn row ->
             MapSet.new(Map.keys(row)) ==
               MapSet.new([
                 :id,
                 :status,
                 :admitted_at,
                 :completed_at,
                 :response_status_code,
                 :last_error_code,
                 :attempt_count
               ])
           end)

    assert hd(rows).response_status_code == 502
    assert hd(rows).last_error_code == "upstream_failed"
    assert List.last(rows).attempt_count == 2
    refute inspect(rows) =~ secret
    refute inspect(rows) =~ "visible-failed-event"
  end

  defp insert_request!(pool, assignment, attrs) do
    %{api_key: api_key} = active_api_key_fixture(pool)
    admitted_at = Map.fetch!(attrs, :admitted_at)
    status = Map.fetch!(attrs, :status)
    completed_at = Map.get(attrs, :completed_at, DateTime.add(admitted_at, 1, :second))

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: Map.get(attrs, :requested_model, "gpt-cockpit-boundary"),
        endpoint: Map.get(attrs, :endpoint, "/backend-api/codex/responses"),
        transport: Map.get(attrs, :transport, "http_json"),
        status: status,
        usage_status: Map.get(attrs, :usage_status, "usage_known"),
        correlation_id:
          Map.get(
            attrs,
            :correlation_id,
            "cockpit-boundary-#{System.unique_integer([:positive])}"
          ),
        request_metadata: Map.get(attrs, :request_metadata, %{}),
        response_status_code: Map.get(attrs, :response_status_code, response_status_code(status)),
        last_error_code: Map.get(attrs, :last_error_code, request_error_code(status))
      })
      |> Ecto.Changeset.change(%{admitted_at: admitted_at, completed_at: completed_at})
      |> Repo.update!()

    attempt =
      request
      |> attempt_fixture(assignment, %{
        status: attempt_status(status),
        completed_at: completed_at,
        upstream_status_code: response_status_code(status),
        response_metadata: Map.get(attrs, :attempt_response_metadata, %{})
      })
      |> Ecto.Changeset.change(%{
        started_at: admitted_at,
        completed_at: completed_at,
        network_error_code:
          Map.get(attrs, :attempt_network_error_code, request_error_code(status))
      })
      |> Repo.update!()

    ledger_entry_fixture(request, %{
      attempt_id: attempt.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      occurred_at: completed_at,
      usage_status:
        Map.get(attrs, :settlement_usage_status, Map.get(attrs, :usage_status, "usage_known"))
    })

    request
  end

  defp assignment_summary(assignment, pool) do
    %{
      id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      pool_id: assignment.pool_id,
      pool_label: pool.name,
      assignment_label: assignment.assignment_label,
      status: assignment.status,
      health_status: assignment.health_status,
      eligibility_status: assignment.eligibility_status
    }
  end

  defp attempt_status("succeeded"), do: "succeeded"
  defp attempt_status(_status), do: "failed"

  defp response_status_code("succeeded"), do: 200
  defp response_status_code("rejected"), do: 429
  defp response_status_code("cancelled"), do: 499
  defp response_status_code(_status), do: 502

  defp request_error_code("succeeded"), do: nil
  defp request_error_code(status), do: "#{status}_error"

  defp upsert_quota_window!(identity, attrs) do
    attrs =
      Map.merge(
        %{
          quota_key: "account",
          source: "codex_usage",
          source_precision: "authoritative",
          quota_scope: "account",
          quota_family: "account",
          freshness_state: "fresh"
        },
        attrs
      )

    assert {:ok, [_window]} = QuotaWindows.upsert_quota_windows(identity, [attrs])
  end

  defp unique_slug(prefix),
    do: "admin-upstream-cockpit-#{prefix}-#{System.unique_integer([:positive])}"
end
