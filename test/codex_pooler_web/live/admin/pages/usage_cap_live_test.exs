defmodule CodexPoolerWeb.Admin.UsageCapLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [start_upstream: 1]

  alias CodexPooler.{Accounts, FakeUpstream, ProviderCreditsFixtures, Repo}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaLimitRow

  @detection_timeout_ms 15_000

  setup :register_and_log_in_user

  test "list and cockpit save a cap that both pages and the audit trail reflect, and blank lifts it", %{conn: conn} do
    fixture = shared_account!()
    identity = fixture.identity
    {:ok, list, _} = live(conn, ~p"/admin/upstreams?#{%{"pool_id" => fixture.b.id}}")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    render_click(element(list, list_action(identity)))
    assert has_element?(list, "#usage-cap-policy-dialog #usage-cap-percent[min='1'][max='99'][step='1'][placeholder='No cap']")
    assert has_element?(list, "#usage-cap-policy-dialog-eyebrow", "Upstream account · Synthetic usage cap")
    assert has_element?(list, "#usage-cap-policy-help", "A turn already running finishes")
    assert has_element?(list, "#usage-cap-policy-redemption-help", "automatic saved-reset redemption")
    refute has_element?(list, "#usage-cap-percent[value]")

    render_change(form(list, "#usage-cap-policy-form", %{"usage_cap_policy" => %{"usage_cap_percent" => "80"}}))
    render_submit(form(list, "#usage-cap-policy-form"))
    assert Repo.reload!(identity).usage_cap_percent == 80
    refute has_element?(list, "#usage-cap-policy-form")
    assert has_element?(list, "#flash-info", "Usage cap updated")

    await_element!(cockpit, "#upstream-quota-limit-weekly-usage-cap-marker[data-cap-percent='80'][style*='left: 20%']")
    assert has_element?(list, "#upstream-account-#{identity.id}-limit-weekly-usage-cap-marker[data-cap-percent='80'][style*='left: 20%'][title='Usage cap: 80%']")
    refute has_element?(cockpit, "[data-role='usage-cap-reached']")

    events = Repo.all(from audit in AuditEvent, where: audit.action == "upstream_account.usage_cap_policy_update", select: audit.pool_id)
    assert Enum.sort(events) == Enum.sort([fixture.a.id, fixture.b.id])

    render_click(element(cockpit, "#usage-cap-policy-open"))
    assert has_element?(cockpit, "#usage-cap-percent[value='80']")
    render_submit(form(cockpit, "#usage-cap-policy-form", %{"usage_cap_policy" => %{"usage_cap_percent" => ""}}))
    assert is_nil(Repo.reload!(identity).usage_cap_percent)
    await_absent!(list, "#upstream-account-#{identity.id}-limit-weekly-usage-cap-marker")
    refute has_element?(cockpit, "#upstream-quota-limit-weekly-usage-cap-marker")
  end

  test "a cap at or below the weekly usage shows the reached badge", %{conn: conn, scope: scope} do
    fixture = shared_account!()
    assert {:ok, _} = CodexPooler.Upstreams.update_usage_cap_policy_for_scope(scope, fixture.identity.id, %{usage_cap_percent: 10})
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{fixture.identity.id}")
    assert has_element?(list, "#upstream-account-#{fixture.identity.id}-limit-weekly-usage-cap-reached", "Usage cap reached")
    assert has_element?(cockpit, "#upstream-quota-limit-weekly-usage-cap-reached", "Usage cap reached")
    assert has_element?(cockpit, "#upstream-quota-limit-weekly-usage-cap-marker[style*='left: 90%']")
    assert has_element?(list, "#upstream-account-#{fixture.identity.id}-routing-readiness-state", "usage_cap_reached")
    assert has_element?(list, "#upstream-account-#{fixture.identity.id}-routing-readiness-label", "Held by usage cap")
  end

  test "a plan without a weekly window carries the cap on its 30-day row", %{conn: conn} do
    pool = pool_fixture(%{name: "Synthetic monthly cap Pool"})
    %{identity: identity} = active_upstream_assignment_fixture(pool, %{account_label: "Synthetic monthly cap"})
    reset_at = DateTime.utc_now() |> DateTime.add(20, :day) |> DateTime.truncate(:second)

    assert {:ok, [_monthly]} =
             CodexPooler.Upstreams.Quota.Windows.upsert_quota_windows(identity, [
               %{quota_key: "account", window_kind: "primary", window_minutes: 43_200, used_percent: Decimal.new("35"), reset_at: reset_at, source: "codex_usage_api", source_precision: "observed", quota_scope: "account", quota_family: "account", freshness_state: "fresh"}
             ])

    identity |> Ecto.Changeset.change(usage_cap_percent: 30) |> Repo.update!()
    {:ok, list, _} = live(conn, ~p"/admin/upstreams?#{%{"pool_id" => pool.id}}")

    assert has_element?(list, "#upstream-account-#{identity.id}-limit-primary_30d-usage-cap-marker[data-cap-percent='30'][style*='left: 70%']")
    assert has_element?(list, "#upstream-account-#{identity.id}-limit-primary_30d-usage-cap-reached", "Usage cap reached")
    refute has_element?(list, "#upstream-account-#{identity.id}-usage-cap-unmeasurable")
  end

  test "an account without a weekly or 30-day window says the cap has no effect", %{conn: conn} do
    pool = pool_fixture(%{name: "Synthetic windowless cap Pool"})
    %{identity: identity} = active_upstream_assignment_fixture(pool, %{account_label: "Synthetic windowless cap"})
    identity |> Ecto.Changeset.change(usage_cap_percent: 40) |> Repo.update!()
    {:ok, list, _} = live(conn, ~p"/admin/upstreams?#{%{"pool_id" => pool.id}}")

    assert has_element?(list, "#upstream-account-#{identity.id}-usage-cap-unmeasurable", "Usage cap 40% has no effect right now")
    refute has_element?(list, "[data-role='usage-cap-marker']")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    assert has_element?(cockpit, "#cockpit-usage-cap-unmeasurable", "no current weekly or 30-day quota reading")
  end

  test "out-of-range and non-numeric values show a form error and save nothing", %{conn: conn} do
    fixture = shared_account!()
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    render_click(element(list, list_action(fixture.identity)))

    for bad <- ["0", "100", "-5", "abc"] do
      render_submit(form(list, "#usage-cap-policy-form", %{"usage_cap_policy" => %{"usage_cap_percent" => bad}}))
      assert has_element?(list, "#usage-cap-policy-errors[role='alert']")
    end

    assert is_nil(Repo.reload!(fixture.identity).usage_cap_percent)
    assert Repo.aggregate(from(audit in AuditEvent, where: audit.action == "upstream_account.usage_cap_policy_update"), :count) == 0
  end

  test "forged extra fields are rejected and never retarget another identity", %{conn: conn} do
    fixture = shared_account!()
    other = upstream_assignment_fixture(fixture.a).identity
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    render_click(element(list, list_action(fixture.identity)))
    refute has_element?(list, "#usage-cap-policy-form input[name*='identity'], #usage-cap-policy-form input[name*='pool']")
    render_submit(list, "save_usage_cap_policy", %{"usage_cap_policy" => %{"usage_cap_percent" => "70", "identity_id" => other.id}})
    assert has_element?(list, "#usage-cap-policy-errors[role='alert']")
    assert is_nil(Repo.reload!(fixture.identity).usage_cap_percent)
    assert is_nil(Repo.reload!(other).usage_cap_percent)
  end

  test "one-Pool operators get no control and forged saves change nothing", %{scope: scope} do
    fixture = shared_account!()
    %{conn: conn} = restricted_operator!(scope, [fixture.a])
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{fixture.identity.id}")
    refute has_element?(list, list_action(fixture.identity))
    refute has_element?(cockpit, "#usage-cap-policy-open")

    render_click(list, "open_usage_cap_policy", %{"id" => fixture.identity.id})
    render_click(cockpit, "open_usage_cap_policy", %{"id" => fixture.identity.id})

    for view <- [list, cockpit] do
      refute has_element?(view, "#usage-cap-policy-form")
      render_submit(view, "save_usage_cap_policy", %{"usage_cap_policy" => %{"usage_cap_percent" => "50"}})
      assert has_element?(view, "#flash-error")
    end

    assert is_nil(Repo.reload!(fixture.identity).usage_cap_percent)
    assert Repo.aggregate(from(audit in AuditEvent, where: audit.action == "upstream_account.usage_cap_policy_update"), :count) == 0
  end

  describe "quota limit row" do
    test "the marker sits at the remaining-quota position of the cap" do
      html = render_component(&QuotaLimitRow.quota_limit_row/1, id: "row", account_label: "Synthetic", limit: limit(%{usage_cap_percent: 80, usage_capped?: false}))
      assert html =~ ~s(data-role="usage-cap-marker")
      assert html =~ "left: 20%"
      assert html =~ ~s(aria-label="Usage cap: 80%")
      assert html =~ ~s(title="Usage cap: 80%")
      refute html =~ "Usage cap reached"
    end

    test "the reached badge shows only while capped" do
      html = render_component(&QuotaLimitRow.quota_limit_row/1, id: "row", account_label: "Synthetic", limit: limit(%{usage_cap_percent: 5, usage_capped?: true}))
      assert html =~ "Usage cap reached"
      assert html =~ "badge-warning"
      assert html =~ "left: 95%"
    end

    test "no cap draws neither marker nor badge" do
      html = render_component(&QuotaLimitRow.quota_limit_row/1, id: "row", account_label: "Synthetic", limit: limit(%{}))
      refute html =~ "usage-cap-marker"
      refute html =~ "Usage cap reached"
    end
  end

  defp limit(extra) do
    Map.merge(
      %{
        key: :weekly,
        label: "Weekly",
        percent: Decimal.new(60),
        percent_value: 60,
        percent_label: "60%",
        count_label: nil,
        count_title: nil,
        evidence_state: :fresh,
        meter_state: :current,
        measurement_pending?: false,
        reset_label: nil,
        reset_display_state: :absent,
        reset_semantics: :unknown,
        reset_at: nil,
        reset_title: nil
      },
      extra
    )
  end

  defp shared_account! do
    a = pool_fixture(%{name: "Synthetic usage cap Pool A"})
    b = pool_fixture(%{name: "Synthetic usage cap Pool B"})
    now = DateTime.utc_now()
    payload = ProviderCreditsFixtures.usage_payload(:included, now: now)
    fake = start_upstream({:path_json, ProviderCreditsFixtures.usage_routes(payload)})
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(a, %{account_label: "Synthetic usage cap", metadata: %{"usage_base_url" => FakeUpstream.url(fake), "base_url" => FakeUpstream.url(fake)}})
    Repo.insert!(%PoolUpstreamAssignment{pool_id: b.id, upstream_identity_id: identity.id, assignment_label: "Synthetic shared assignment", status: "active", health_status: "active", eligibility_status: "eligible", created_at: now, updated_at: now, metadata: %{}})
    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    %{a: a, b: b, identity: identity, assignment: assignment, fake: fake}
  end

  defp list_action(identity), do: "#usage-cap-policy-upstream-account-#{identity.id}"

  defp restricted_operator!(scope, pools) do
    %{user: operator} = operator_fixture(scope, %{"email" => unique_user_email(), "role" => "instance_admin", "password_change_required" => "false"})
    Enum.each(pools, &operator_pool_assignment_fixture(operator, &1, created_by_user_id: scope.user.id))
    assert {:ok, %{token: token}} = Accounts.login_user(%{"email" => operator.email, "password" => valid_user_password()})
    %{user: operator, conn: build_conn() |> log_in_user(operator, token)}
  end

  defp await_element!(view, selector), do: await_predicate!(fn -> has_element?(view, selector) end)
  defp await_absent!(view, selector), do: await_predicate!(fn -> not has_element?(view, selector) end)
  defp await_predicate!(predicate), do: await_predicate!(predicate, System.monotonic_time(:millisecond) + @detection_timeout_ms)

  defp await_predicate!(predicate, deadline) do
    if predicate.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "mounted usage cap state was not observed"

      receive do
      after
        10 -> await_predicate!(predicate, deadline)
      end
    end
  end
end
