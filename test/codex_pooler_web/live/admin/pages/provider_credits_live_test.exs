defmodule CodexPoolerWeb.Admin.ProviderCreditsLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [start_upstream: 1]

  alias CodexPooler.{Accounting, Accounts, FakeUpstream, ProviderCreditsFixtures, Repo, Upstreams}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, RoutingQuotaSnapshot}
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel

  @detection_timeout_ms 15_000
  @spark "gpt-5.3-codex-spark"

  setup :register_and_log_in_user

  test "canonical on and off reach list and cockpit sessions across every Pool", %{conn: conn} do
    fixture = shared_account!(:weekly_credit_only)
    identity = add_observed_baseline!(fixture, "12500", "12497")
    {:ok, list_a, _} = live(conn, ~p"/admin/upstreams?#{%{"pool_id" => fixture.a.id}}")
    {:ok, list_b, _} = live(conn, ~p"/admin/upstreams?#{%{"pool_id" => fixture.b.id}}")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{identity.id}")

    render_click(element(list_b, "#{summary(identity)}-policy-open"))
    render_click(element(cockpit, "#provider-credits-policy-open"))
    assert has_element?(cockpit, "#provider-credits-enabled[checked]")
    assert has_element?(list_b, "#provider-credits-enabled[checked]")

    for view <- [cockpit, list_b] do
      assert has_element?(view, "#provider-credits-policy-dialog[aria-labelledby='provider-credits-policy-dialog-title provider-credits-policy-dialog-eyebrow']")
      assert view |> element("#provider-credits-policy-dialog-title") |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim() == "Provider credits"
      assert has_element?(view, "#provider-credits-policy-dialog-eyebrow", "Upstream account · Synthetic provider credits")
    end

    assert has_element?(list_a, "#upstream-account-#{identity.id}-limit-weekly-observations-dialog-eyebrow", "Weekly · Synthetic provider credits")
    assert has_element?(cockpit, "#upstream-quota-limit-weekly-observations-dialog-eyebrow", "Weekly · Synthetic provider credits")
    assert has_element?(cockpit, "#provider-credits-policy-dialog-footer #provider-credits-save[type='submit'][form='provider-credits-policy-form']")
    refute has_element?(cockpit, "#provider-credits-policy-form #provider-credits-save")
    assert has_element?(cockpit, "#provider-credits-observation-details:not([open])")
    assert has_element?(cockpit, "#provider-credits-details", "not a purchased total")
    assert has_element?(list_a, "#{summary(identity)}[title^='Provider credits available;']")
    assert has_element?(list_a, "#{summary(identity)}-progress[value='99.9'][aria-valuetext='99.9% of observed baseline'].progress-success")
    assert has_element?(list_a, "#upstream-account-#{identity.id}[data-routing-ready-now='true'][data-routing-tone='success']")
    assert has_element?(list_a, "#upstream-account-#{identity.id}-routing-readiness", "Routing ready via credits")
    assert has_element?(list_a, "#upstream-account-#{identity.id}-limit-weekly-progress[value='0']")
    assert has_element?(cockpit, "#upstream-quota-limit-weekly-progress[value='0']")
    cockpit_state = :sys.get_state(cockpit.pid).socket.assigns.cockpit
    assert Enum.all?(cockpit_state.charts.quota_health.items, &(&1.remaining_percent_value == 0.0 and is_nil(&1.capacity)))
    assert cockpit_state.charts.quota_health.kpis.exhausted_count == 2
    assert cockpit_state.charts.quota_health.kpis.routing_conditional_count == 0
    assert Enum.all?(cockpit_state.charts.quota_health.items, &(&1.state_label == "Exhausted" and &1.routing_readiness_label == "Routing ready via credits"))

    render_change(form(cockpit, "#provider-credits-policy-form", %{"provider_credits_policy" => %{"allow_provider_credits" => "false"}}))
    refute has_element?(cockpit, "#provider-credits-enabled[checked]")
    assert has_element?(cockpit, "#provider-credits-policy-form input[type='hidden'][value='false']")
    render_submit(form(cockpit, "#provider-credits-policy-form"))
    refute Repo.reload!(identity).allow_provider_credits
    await_element!(list_a, "#{summary(identity)}[data-policy-enabled='false']")
    await_element!(list_b, "#{summary(identity)}[data-policy-enabled='false']")
    await_element!(list_b, "#provider-credits-enabled:not([checked])")
    assert has_element?(cockpit, "#upstream-provider-credits[data-policy-enabled='false']")
    assert has_element?(list_a, "#{summary(identity)}-percent", "99.9%")
    assert has_element?(list_a, "#upstream-account-#{identity.id}[data-routing-ready-now='false']")
    assert has_element?(cockpit, "#upstream-provider-credits-balance", "12,497")

    render_submit(form(list_b, "#provider-credits-policy-form", %{"provider_credits_policy" => %{"allow_provider_credits" => "true"}}))
    assert Repo.reload!(identity).allow_provider_credits
    await_element!(list_a, "#{summary(identity)}[data-policy-enabled='true']")
    await_element!(cockpit, "#upstream-provider-credits[data-policy-enabled='true']")
    assert has_element?(cockpit, "#upstream-provider-credits[data-availability='available']")
    refreshed = :sys.get_state(cockpit.pid).socket.assigns.cockpit
    assert refreshed.provider_credits_summary.qualification == :provider_attested

    events = Repo.all(from audit in AuditEvent, where: audit.action == "upstream_account.provider_credits_policy_update", select: {audit.pool_id, audit.details})

    for pool <- [fixture.a, fixture.b] do
      assert events |> Enum.filter(&(elem(&1, 0) == pool.id)) |> Enum.map(fn {_pool, details} -> {details["previous_allow_provider_credits"], details["allow_provider_credits"]} end) |> Enum.sort() == [{false, true}, {true, false}]
    end
  end

  @tag credits_negative: true
  test "one-Pool operators get no control and forged saves cannot change the shared identity", %{scope: scope} do
    fixture = shared_account!(:windowless_credit_only)
    %{conn: conn} = restricted_operator!(scope, [fixture.a])
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{fixture.identity.id}")
    refute has_element?(list, list_action(fixture.identity))
    refute has_element?(list, "#{summary(fixture.identity)}-policy-open")
    refute has_element?(cockpit, "#provider-credits-policy-open")

    render_click(list, "open_provider_credits_policy", %{"id" => fixture.identity.id})
    render_click(cockpit, "open_provider_credits_policy", %{"id" => fixture.identity.id})

    for view <- [list, cockpit] do
      refute has_element?(view, "#provider-credits-policy-form")
      render_submit(view, "save_provider_credits_policy", %{"provider_credits_policy" => %{"allow_provider_credits" => "false", "upstream_identity_id" => fixture.identity.id, "pool_id" => fixture.a.id}})
      assert has_element?(view, "#flash-error")
    end

    assert Repo.reload!(fixture.identity).allow_provider_credits
    assert Repo.aggregate(from(audit in AuditEvent, where: audit.action == "upstream_account.provider_credits_policy_update"), :count) == 0
  end

  @tag credits_negative: true
  test "authorized forms reject hidden ownership fields and never retarget the saved identity", %{conn: conn} do
    fixture = shared_account!(:windowless_credit_only)
    other = upstream_assignment_fixture(fixture.a).identity
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    render_click(element(list, list_action(fixture.identity)))
    refute has_element?(list, "#provider-credits-policy-form input[name*='identity'], #provider-credits-policy-form input[name*='pool']")
    render_submit(list, "save_provider_credits_policy", %{"provider_credits_policy" => %{"allow_provider_credits" => "false", "identity_id" => other.id}})
    assert has_element?(list, "#provider-credits-policy-errors[role='alert']")
    assert Repo.reload!(fixture.identity).allow_provider_credits
    assert Repo.reload!(other).allow_provider_credits
  end

  @tag credits_negative: true
  test "revoking one shared Pool closes both editors even while the identity stays visible", %{scope: scope} do
    fixture = shared_account!(:windowless_credit_only)
    %{conn: conn, user: admin} = restricted_operator!(scope, [fixture.a, fixture.b])
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{fixture.identity.id}")
    render_click(element(list, list_action(fixture.identity)))
    render_click(element(cockpit, "#provider-credits-policy-open"))
    assert {:ok, _} = Accounts.update_operator(scope, admin, %{"pool_ids" => [fixture.a.id]})
    await_absent!(list, "#provider-credits-policy-form")
    await_absent!(cockpit, "#provider-credits-policy-form")
    assert has_element?(list, summary(fixture.identity))
    refute has_element?(list, list_action(fixture.identity))
    refute has_element?(cockpit, "#provider-credits-policy-open")
    render_submit(cockpit, "save_provider_credits_policy", %{"provider_credits_policy" => %{"allow_provider_credits" => "false"}})
    assert Repo.reload!(fixture.identity).allow_provider_credits
  end

  for {credits, balance_label} <- [{:fractional, "<1"}, {:unlimited, "Unlimited"}] do
    @tag credits_negative: true
    test "windowless #{credits} observation renders on both pages without invented quota", %{conn: conn} do
      fixture = shared_account!(:windowless_credit_only, credits: unquote(credits))
      {:ok, list, _} = live(conn, ~p"/admin/upstreams")
      {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{fixture.identity.id}")
      assert has_element?(list, "#{summary(fixture.identity)}-balance", unquote(balance_label))
      assert has_element?(cockpit, "#upstream-provider-credits-balance", unquote(balance_label))
      refute has_element?(list, "#{summary(fixture.identity)}-baseline, #{summary(fixture.identity)}-progress, #{summary(fixture.identity)}-percent")
      refute has_element?(cockpit, "#upstream-provider-credits-baseline, #upstream-provider-credits-progress, #upstream-provider-credits-percent")
      refute has_element?(list, "#upstream-account-#{fixture.identity.id}-limits [data-role='upstream-limit-chart']")
      refute has_element?(cockpit, "#upstream-quota-limits [data-role='upstream-limit-chart']")
      assert Repo.aggregate(from(window in AccountQuotaWindow, where: window.upstream_identity_id == ^fixture.identity.id), :count) == 0
    end
  end

  for {credits, detail} <- [{:unknown, "Balance unavailable"}, {:none, "0"}] do
    test "#{credits} credit balance hides the quota row and keeps authorized policy entry", %{conn: conn} do
      fixture = shared_account!(:windowless_credit_only, credits: unquote(credits))
      {:ok, list, _} = live(conn, ~p"/admin/upstreams")
      {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{fixture.identity.id}")

      refute has_element?(list, summary(fixture.identity))
      refute has_element?(cockpit, "#upstream-provider-credits")
      assert has_element?(list, "#{list_action(fixture.identity)} .hero-currency-dollar")
      assert has_element?(cockpit, "#provider-credits-policy-open .hero-currency-dollar")
      render_click(element(list, list_action(fixture.identity)))
      render_click(element(cockpit, "#provider-credits-policy-open"))

      for view <- [list, cockpit] do
        assert has_element?(view, "#provider-credits-policy-form")
        assert has_element?(view, "#provider-credits-details", unquote(detail))
        refute has_element?(view, "#provider-credits-details progress")
      end
    end
  end

  test "fresh windowless provider permission survives policy off without synthesizing a reset window", %{conn: conn, scope: scope} do
    fixture = shared_account!(:windowless_included)
    assert {:ok, _} = Upstreams.update_provider_credits_policy_for_scope(scope, fixture.identity.id, %{allow_provider_credits: false})
    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [fixture.a])
    assert account.quota_readiness.routing_ready_now?
    assert account.quota_readiness.capacity_basis == :windowless_provider_permission
    assert account.quota_readiness.reason_codes == []
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{fixture.identity.id}")
    assert has_element?(list, "#{summary(fixture.identity)}[data-policy-enabled='false'][data-capacity-basis='windowless_provider_permission']")
    assert has_element?(cockpit, "#upstream-provider-credits[data-policy-enabled='false'][data-capacity-basis='windowless_provider_permission']")
    assert has_element?(list, list_action(fixture.identity))
    assert has_element?(cockpit, "#provider-credits-policy-open")
    refute has_element?(list, "#upstream-account-#{fixture.identity.id}-limits [data-countdown-at]")
    refute has_element?(cockpit, "#upstream-quota-limits [data-countdown-at]")
  end

  @tag credits_negative: true
  test "provider-attested on and disabled off match runtime without a universal permission claim", %{conn: conn, scope: scope} do
    fixture = shared_account!(:windowless_credit_only)
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{fixture.identity.id}")

    for enabled <- [true, false] do
      assert {:ok, _} = Upstreams.update_provider_credits_policy_for_scope(scope, fixture.identity.id, %{allow_provider_credits: enabled})
      render_click(cockpit, "refresh_data")
      if not enabled, do: await_element!(list, "#{summary(fixture.identity)}[data-policy-enabled='false']")
      snapshot = current_snapshot(fixture.identity)
      decision = Upstreams.provider_credits_decision(snapshot, %{model: "synthetic-ordinary", upstream_model: "synthetic-ordinary", serving_mode: :full, transport: :http_sse})
      [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [fixture.a])
      assert account.quota_readiness.capacity_basis == decision.capacity_basis
      assert account.quota_readiness.reason_codes == decision.reason_codes
      assert account.quota_readiness.routing_ready_now? == enabled
      assert decision.eligible? == enabled
      refute account.quota_readiness.conditional?
      assert account.provider_credits_summary.capacity_basis == :provider_credits
      assert has_element?(list, "#{summary(fixture.identity)}[data-capacity-basis='provider_credits'][data-reason-codes='#{Enum.join(decision.reason_codes, " ")}']")
      assert has_element?(cockpit, "#upstream-provider-credits[data-capacity-basis='provider_credits'][data-reason-codes='#{Enum.join(decision.reason_codes, " ")}']")
      label = if(enabled, do: "Provider credits available", else: "Provider credits disabled")
      assert has_element?(cockpit, "#upstream-provider-credits[title='#{label}']")
      assert has_element?(list, "#{summary(fixture.identity)}-balance", "25")
    end
  end

  test "included permission at 100 with spend control reached survives opt-out without rewriting public usage", %{conn: conn, scope: scope} do
    fixture = shared_account!(:spend_blocked)
    now = DateTime.utc_now()
    payload = ProviderCreditsFixtures.usage_payload(:spend_blocked, now: now, credits: :none) |> put_in(["rate_limit", "secondary_window", "used_percent"], 100)
    identity = refresh_usage!(fixture, payload)
    as_of = DateTime.utc_now()
    assert {:ok, usage_before} = Accounting.build_codex_usage_for_upstream_identity(identity, as_of: as_of)
    assert {:ok, _} = Upstreams.update_provider_credits_policy_for_scope(scope, identity.id, %{allow_provider_credits: false})
    assert {:ok, usage_after} = Accounting.build_codex_usage_for_upstream_identity(Repo.reload!(identity), as_of: as_of)
    assert usage_before == usage_after
    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [fixture.a])
    assert account.quota_readiness.routing_ready_now?
    assert account.quota_readiness.capacity_basis == :ordinary_provider_permission
    assert account.quota_readiness.reason_codes == []
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    assert has_element?(list, "#upstream-account-#{identity.id}-limit-weekly-progress[value='0']")
    assert has_element?(cockpit, "#upstream-quota-limit-weekly-progress[value='0']")
    assert has_element?(list, "#upstream-account-#{identity.id}-routing-readiness", "Routing ready")
    refute has_element?(cockpit, "#upstream-provider-credits")
    render_click(element(cockpit, "#provider-credits-policy-open"))
    assert has_element?(cockpit, "#provider-credits-enabled:not([checked])")
  end

  @tag credits_negative: true
  test "a later below-exhaustion workspace header denies list and cockpit non-credit readiness", %{conn: conn, scope: scope} do
    fixture = shared_account!(:included, credits: :none)
    denied_at = DateTime.utc_now()
    headers = [{"x-codex-secondary-used-percent", "12"}, {"x-codex-secondary-window-minutes", "10080"}, {"x-codex-secondary-reset-at", Integer.to_string(DateTime.to_unix(DateTime.add(denied_at, 7_200, :second)))}, {"x-codex-rate-limit-reached-type", "workspace_member_credits_depleted"}]
    assert {:ok, [_]} = Windows.upsert_quota_windows_from_codex_headers(fixture.identity, headers, denied_at)
    decision = Upstreams.provider_credits_decision(current_snapshot(fixture.identity), %{account_only: true})
    refute decision.eligible?
    assert "provider_denied" in decision.reason_codes
    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [fixture.a])
    refute account.quota_readiness.routing_ready_now?
    assert account.provider_credits_summary.capacity_basis == :none
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{fixture.identity.id}")
    refute has_element?(list, summary(fixture.identity))
    refute has_element?(cockpit, "#upstream-provider-credits")
    assert has_element?(list, "#upstream-account-#{fixture.identity.id}[data-routing-ready-now='false']")
    render_click(element(cockpit, "#provider-credits-policy-open"))
    assert has_element?(cockpit, "#provider-credits-details", "Provider capacity blocked")
    refute has_element?(list, "#{summary(fixture.identity)}[title='Provider permission available']")
    refute has_element?(cockpit, "#upstream-provider-credits[title='Provider permission available']")
  end

  test "existing exact-model allowance stays conditional rather than granting every model with policy off", %{conn: conn, scope: scope} do
    fixture = shared_account!(:weekly_credit_only, credits: :none)
    now = DateTime.utc_now()

    payload =
      ProviderCreditsFixtures.usage_payload(:weekly_credit_only, now: now, credits: :none)
      |> Map.put("additional_rate_limits", [%{"limit_name" => "GPT-5.3-Codex-Spark", "metered_feature" => "codex_bengalfox", "rate_limit" => %{"allowed" => true, "limit_reached" => false, "primary_window" => %{"used_percent" => 0, "limit_window_seconds" => 18_000, "reset_at" => DateTime.to_unix(DateTime.add(now, 18_000, :second)), "reset_after_seconds" => 18_000}}}])

    identity = refresh_usage!(fixture, payload)
    model_fixture(fixture.a, %{exposed_model_id: @spark, upstream_model_id: @spark, metadata: %{"source_assignment_ids" => [fixture.assignment.id], "source_assignment_models" => %{fixture.assignment.id => %{"slug" => @spark}}}})
    assert {:ok, _} = Upstreams.update_provider_credits_policy_for_scope(scope, identity.id, %{allow_provider_credits: false})
    snapshot = current_snapshot(identity)
    assert %{eligible?: true, capacity_basis: :model_allowance} = Upstreams.provider_credits_decision(snapshot, %{model: @spark, upstream_model: @spark})
    refute Upstreams.provider_credits_decision(snapshot, %{model: "synthetic-other", upstream_model: "synthetic-other"}).eligible?
    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [fixture.a])
    refute account.quota_readiness.routing_ready_now?
    assert account.routing_readiness.state == "model_limited"
    {:ok, list, _} = live(conn, ~p"/admin/upstreams")
    {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    assert has_element?(list, "#upstream-account-#{identity.id}-routing-readiness", "Limited model availability")
    refute has_element?(cockpit, "#upstream-provider-credits")
    render_click(element(cockpit, "#provider-credits-policy-open"))
    assert has_element?(cockpit, "#provider-credits-enabled:not([checked])")
  end

  for enabled? <- [true, false] do
    @tag credits_negative: true
    test "pending banked reset remains visible with provider credits #{if enabled?, do: "enabled", else: "disabled"}", %{conn: conn, scope: scope} do
      fixture = shared_account!(:weekly_credit_only)
      now = DateTime.utc_now()
      redemption = %{"phase" => "consumed_pending_probe", "consumed_at" => DateTime.to_iso8601(now), "deadline_at" => DateTime.to_iso8601(DateTime.add(now, 900))}
      metadata = Map.put(fixture.identity.metadata, "saved_reset_redemption", redemption)
      identity = fixture.identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
      assert {:ok, _} = Upstreams.update_provider_credits_policy_for_scope(scope, identity.id, %{allow_provider_credits: unquote(enabled?)})
      counts = FakeUpstream.physical_counts(fixture.fake)
      {:ok, list, _} = live(conn, ~p"/admin/upstreams")
      {:ok, cockpit, _} = live(conn, ~p"/admin/upstreams/#{identity.id}")
      assert has_element?(list, "#{summary(identity)}[title^='Banked-reset recovery pending']")
      assert has_element?(cockpit, "#upstream-provider-credits[title^='Banked-reset recovery pending']")
      refute has_element?(list, "#saved-reset-operation-list-#{identity.id}")

      list |> element("#upstream-account-#{identity.id}-saved-reset-meter-open") |> render_click()
      assert has_element?(list, "#saved-reset-policy-dialog[open]")
      assert has_element?(list, "#saved-reset-operation-bank-#{identity.id}[data-provider-outcome='unknown'][data-verification-state='pending']")
      assert has_element?(list, "#saved-reset-operation-bank-#{identity.id} [data-role='saved-reset-latest']")
      assert has_element?(list, "#saved-reset-operation-bank-#{identity.id}", "Don't redeem again until this resolves.")
      assert has_element?(cockpit, "#saved-reset-operation-cockpit-#{identity.id}-details[open]")
      assert has_element?(cockpit, "#saved-reset-operation-cockpit-#{identity.id}", "Don't redeem again until this resolves.")
      assert has_element?(cockpit, "#saved-reset-operation-cockpit-#{identity.id}[data-provider-outcome='unknown'][data-verification-state='pending']")
      assert has_element?(cockpit, "#upstream-provider-credits-policy", unquote(if enabled?, do: "Enabled", else: "Disabled"))
      persisted = Repo.reload!(identity)
      assert persisted.allow_provider_credits == unquote(enabled?)
      assert persisted.metadata["saved_reset_redemption"] == redemption
      assert Repo.aggregate(Oban.Job, :count) == 0
      assert FakeUpstream.physical_counts(fixture.fake) == counts
      CodexPooler.TestDiagnostics.puts(Jason.encode!(%{scenario: "pending_reset_explicit_status_independent_of_credit_policy", provider_credits_enabled: unquote(enabled?), bank_open: true, verification: "pending", provider_outcome: "unknown", jobs: 0, provider_calls_added: 0}))
    end
  end

  defp shared_account!(state, opts \\ []) do
    a = pool_fixture(%{name: "Synthetic credits Pool A"})
    b = pool_fixture(%{name: "Synthetic credits Pool B"})
    now = DateTime.utc_now()
    payload = ProviderCreditsFixtures.usage_payload(state, Keyword.put(opts, :now, now))
    fake = start_upstream({:path_json, ProviderCreditsFixtures.usage_routes(payload)})
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(a, %{account_label: "Synthetic provider credits", metadata: %{"usage_base_url" => FakeUpstream.url(fake), "base_url" => FakeUpstream.url(fake)}})
    Repo.insert!(%PoolUpstreamAssignment{pool_id: b.id, upstream_identity_id: identity.id, assignment_label: "Synthetic shared assignment", status: "active", health_status: "active", eligibility_status: "eligible", created_at: now, updated_at: now, metadata: %{}})
    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    %{a: a, b: b, identity: identity, assignment: assignment, fake: fake}
  end

  defp add_observed_baseline!(fixture, baseline, balance) do
    now = DateTime.utc_now()
    payload = ProviderCreditsFixtures.usage_payload(:weekly_credit_only, now: now) |> put_in(["credits", "balance"], baseline)
    refresh_usage!(fixture, payload)
    refresh_usage!(fixture, put_in(payload, ["credits", "balance"], balance))
  end

  defp refresh_usage!(fixture, payload) do
    FakeUpstream.set_mode(fixture.fake, {:path_json, ProviderCreditsFixtures.usage_routes(payload)})
    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(Repo.reload!(fixture.identity), fixture.assignment)
    identity
  end

  defp current_snapshot(identity), do: RoutingQuotaSnapshot.load_by_identity_ids([identity.id], DateTime.utc_now())[identity.id]
  defp summary(identity), do: "#upstream-account-#{identity.id}-provider-credits"
  defp list_action(identity), do: "#provider-credits-policy-upstream-account-#{identity.id}"

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
      assert System.monotonic_time(:millisecond) < deadline, "canonical mounted policy state was not observed"

      receive do
      after
        10 -> await_predicate!(predicate, deadline)
      end
    end
  end
end
