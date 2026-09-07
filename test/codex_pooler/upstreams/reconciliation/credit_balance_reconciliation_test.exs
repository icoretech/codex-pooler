defmodule CodexPooler.Upstreams.Reconciliation.CreditBalanceReconciliationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.{Accounting, FakeUpstream, Repo}
  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota.{CreditBalanceStore, RoutingQuotaSnapshot, Windows}
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  setup :register_and_log_in_user

  test "provider credit evidence survives fresh event selection in storage, admin and usage compatibility",
       %{conn: conn, scope: scope} do
    now = DateTime.utc_now()
    payload = payload(now)
    {:ok, fake} = FakeUpstream.start_link({:path_json, paths(payload)})
    on_exit(fn -> FakeUpstream.stop(fake) end)

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)
    epoch = CredentialFencing.credential_epoch(identity)

    assert %{balance: 0, observed_at: observed_at} =
             CreditBalanceStore.current(identity.metadata, epoch, DateTime.utc_now())

    before_snapshot =
      RoutingQuotaSnapshot.load_by_identity_ids([identity.id], DateTime.utc_now())[identity.id]

    assert [_] = before_snapshot.raw_windows

    [account] =
      UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])

    assert %{count_label: "0 credits"} = Enum.find(account.quota_limits, &(&1.key == :weekly))

    {:ok, list_view, _} = live(conn, ~p"/admin/upstreams")
    {:ok, cockpit_view, _} = live(conn, ~p"/admin/upstreams/#{identity.id}")
    render_async(list_view)
    render_async(cockpit_view)

    assert has_element?(
             list_view,
             "#upstream-account-#{identity.id}-limit-weekly-count",
             "0 credits"
           )

    assert has_element?(cockpit_view, "#upstream-quota-limit-weekly-count", "0 credits")

    {:ok, _} =
      Windows.record_evidence(identity, %{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: Decimal.new(30),
        source: "codex_rate_limit_event",
        source_precision: "observed",
        # Keep this distinct from the usage reset beyond presentation tolerance.
        reset_at: DateTime.add(now, 93_600),
        observed_at: DateTime.utc_now(),
        freshness_state: "fresh"
      })

    snapshot_at = DateTime.utc_now()
    snapshot = RoutingQuotaSnapshot.load_by_identity_ids([identity.id], snapshot_at)[identity.id]

    assert [%{source: "codex_rate_limit_event"}] =
             RoutingQuotaSnapshot.effective_windows(snapshot)

    rows =
      QuotaProjection.quota_limit_rows(
        RoutingQuotaSnapshot.effective_windows(snapshot),
        DateTimeDisplay.preferences_for_user(nil),
        snapshot_at,
        CreditBalanceStore.current(identity.metadata, epoch, snapshot_at)
      )

    assert %{count_label: "0 credits", percent_label: "70%"} =
             Enum.find(rows, &(&1.key == :weekly))

    assert {:ok, %{credits: %{balance: "0", has_credits: false}}} =
             Accounting.build_codex_usage_for_upstream_identity(identity)

    send(list_view.pid, :reload_upstreams_from_events)
    _ = :sys.get_state(list_view.pid)
    render_async(list_view)
    render_click(cockpit_view, "refresh_data")

    assert has_element?(
             list_view,
             "#upstream-account-#{identity.id}-limit-weekly-count",
             "0 credits"
           )

    assert has_element?(cockpit_view, "#upstream-quota-limit-weekly-count", "0 credits")

    FakeUpstream.set_mode(fake, {:path_json, paths(Map.delete(payload, "credits"))})
    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    assert %{balance: 0, observed_at: ^observed_at} =
             CreditBalanceStore.current(identity.metadata, epoch, DateTime.utc_now())

    stale_at = DateTime.add(observed_at, Evidence.freshness_ttl_seconds() + 1)

    assert {:ok, stale_usage} =
             Accounting.build_codex_usage_for_upstream_identity(identity, as_of: stale_at)

    refute Map.has_key?(stale_usage, :credits)
    assert {:ok, fenced_identity, old_fence} = CredentialFencing.allocate_usage_probe(identity)

    changed =
      fenced_identity
      |> Ecto.Changeset.change(
        metadata: Map.put(fenced_identity.metadata, "credential_epoch", epoch + 1)
      )
      |> Repo.update!()

    assert {:ok, :superseded, _, nil} =
             CredentialFencing.apply_usage_success(identity, old_fence, fn _ ->
               flunk("old credential probe must not write a credit snapshot")
             end)

    assert {:ok, changed_usage} = Accounting.build_codex_usage_for_upstream_identity(changed)
    refute Map.has_key?(changed_usage, :credits)

    assert {:ok, stale_identity_usage} =
             Accounting.build_codex_usage_for_upstream_identity(identity)

    refute Map.has_key?(stale_identity_usage, :credits)

    send(list_view.pid, :reload_upstreams_from_events)
    _ = :sys.get_state(list_view.pid)
    render_async(list_view)
    render_click(cockpit_view, "refresh_data")
    refute has_element?(list_view, "#upstream-account-#{identity.id}-limit-weekly-count")
    refute has_element?(cockpit_view, "#upstream-quota-limit-weekly-count")
    # Distinct unelapsed provider resets and usage reports remain visible after
    # credit counts disappear; neither parent may hide the uncertain quota row.
    refute has_element?(list_view, "#upstream-account-#{identity.id}-limit-weekly-reset")
    refute has_element?(cockpit_view, "#upstream-quota-limit-weekly-reset")

    for {view, selector} <- [
          {list_view, "#upstream-account-#{identity.id}-limit-weekly"},
          {cockpit_view, "#upstream-quota-limit-weekly"}
        ] do
      assert has_element?(view, "#{selector} [data-role='quota-source-disagreement']")
      assert has_element?(view, "#{selector} [data-role='quota-reset-disagreement']")
      assert has_element?(view, "#{selector} [data-source='codex_usage_api']")
      assert has_element?(view, "#{selector} [data-source='codex_rate_limit_event']")
    end

    for malformed <- [nil, "invalid", %{"version" => 99}] do
      changed
      |> Ecto.Changeset.change(
        metadata: Map.put(changed.metadata, "quota_credit_balance", malformed)
      )
      |> Repo.update!()

      assert {:ok, usage} = Accounting.build_codex_usage_for_upstream_identity(identity)
      refute Map.has_key?(usage, :credits)
    end

    FakeUpstream.set_mode(
      fake,
      {:path_json, paths(Map.put(payload, "credits", %{"balance" => 50}))}
    )

    assert {:ok, changed} = PoolReconciliation.refresh_quota_from_usage(changed, assignment)

    assert %{balance: 50, has_credits: nil, unlimited: nil} =
             CreditBalanceStore.current(changed.metadata, epoch + 1, DateTime.utc_now())

    assert {:ok, usage} = Accounting.build_codex_usage_for_upstream_identity(changed)
    refute Map.has_key?(usage, :credits)
  end

  defp payload(now) do
    %{
      "plan_type" => "pro",
      "credits" => %{"balance" => 0, "has_credits" => false, "unlimited" => false},
      "rate_limit" => %{
        "secondary_window" => %{
          "used_percent" => 29,
          "limit_window_seconds" => 604_800,
          "reset_after_seconds" => 86_400,
          "reset_at" => DateTime.to_unix(DateTime.add(now, 86_400))
        }
      }
    }
  end

  defp paths(payload),
    do: Map.new(["/backend-api/wham/usage", "/backend-api/codex/usage"], &{&1, {200, payload}})
end
