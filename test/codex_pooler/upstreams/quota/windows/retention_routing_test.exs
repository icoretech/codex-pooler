defmodule CodexPooler.Upstreams.Quota.Windows.RetentionRoutingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.Retention

  @day 86_400
  @spark "gpt-5.3-codex-spark"

  # A model window the provider stopped reporting keeps its last row. While
  # that row is inside retention it stays a blocker, as it always was; once it
  # is past retention every decision must equal the one taken after the
  # runtime-cleanup prune deleted it, whether or not that pass has run.
  describe "a retired model primary on a weekly-only account" do
    test "past retention it no longer blocks the weekly-only probe, exactly as after the prune" do
      now = now()
      identity = weekly_only_account!(now)
      retired = insert_window!(identity, spark_attrs("primary", 300, days_ago(now, retention_days() + 1)))

      assert %{eligible?: true, routing_state: :weekly_only_probe} = spark_eligibility(identity, now)
      assert %{eligible?: true, routing_state: :weekly_only_probe} = snapshot_eligibility(identity, now)

      Repo.delete!(retired)
      assert %{eligible?: true, routing_state: :weekly_only_probe} = spark_eligibility(identity, now)
      assert %{eligible?: true, routing_state: :weekly_only_probe} = snapshot_eligibility(identity, now)
    end

    test "inside retention it still blocks the weekly-only probe" do
      now = now()
      identity = weekly_only_account!(now)
      insert_window!(identity, spark_attrs("primary", 300, days_ago(now, retention_days() - 1)))

      assert %{eligible?: false} = spark_eligibility(identity, now)
      assert %{eligible?: false} = snapshot_eligibility(identity, now)
    end
  end

  describe "a retired model weekly window on an account with usable primary and weekly" do
    test "past retention it no longer keeps the model request off the account" do
      now = now()
      identity = weekly_only_account!(now)
      insert_window!(identity, account_attrs("primary", 300, DateTime.add(now, 3_600, :second), now))
      insert_window!(identity, spark_attrs("secondary", 10_080, days_ago(now, retention_days() + 1)))

      assert %{eligible?: true, routing_state: :precise} = snapshot_eligibility(identity, now)
    end

    test "inside retention it keeps the model request off the account" do
      now = now()
      identity = weekly_only_account!(now)
      insert_window!(identity, account_attrs("primary", 300, DateTime.add(now, 3_600, :second), now))
      insert_window!(identity, spark_attrs("secondary", 10_080, days_ago(now, retention_days() - 1)))

      assert %{eligible?: false} = snapshot_eligibility(identity, now)
    end
  end

  describe "a retired account window on an account the provider reports available without windows" do
    test "past retention it no longer hides the provider-attested availability, exactly as after the prune" do
      now = now()

      identity =
        upstream_identity_fixture(%{
          metadata: %{"credential_epoch" => 1, AccountAvailabilityStore.metadata_key() => AccountAvailabilityStore.encode!(:available, now, 1)}
        })

      retired = insert_window!(identity, account_attrs("primary", 300, days_ago(now, retention_days() + 1), days_ago(now, retention_days() + 2)))

      assert %{eligible?: true, routing_state: :windowless_provider_available} = account_snapshot_eligibility(identity, now)
      Repo.delete!(retired)
      assert %{eligible?: true, routing_state: :windowless_provider_available} = account_snapshot_eligibility(identity, now)
    end
  end

  defp account_snapshot_eligibility(identity, now) do
    snapshot = [identity.id] |> Windows.load_routing_quota_snapshots(now) |> Map.fetch!(identity.id)
    Windows.routing_quota_eligibility_from_snapshot(snapshot, account_only: true)
  end

  defp spark_eligibility(identity, now),
    do: Windows.routing_quota_eligibility(identity, at: now, model: @spark, upstream_model: @spark)

  defp snapshot_eligibility(identity, now) do
    snapshot = [identity.id] |> Windows.load_routing_quota_snapshots(now) |> Map.fetch!(identity.id)
    Windows.routing_quota_eligibility_from_snapshot(snapshot, model: @spark, upstream_model: @spark)
  end

  defp weekly_only_account!(now) do
    identity = upstream_identity_fixture()
    insert_window!(identity, account_attrs("secondary", 10_080, DateTime.add(now, 3, :day), now))
    identity
  end

  defp account_attrs(kind, minutes, reset_at, observed_at) do
    %{quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: kind, window_minutes: minutes, used_percent: Decimal.new("30"), reset_at: reset_at, observed_at: observed_at}
  end

  defp spark_attrs(kind, minutes, reset_at) do
    %{
      quota_key: "codex_spark",
      quota_scope: "model",
      quota_family: "codex_spark",
      model: @spark,
      upstream_model: @spark,
      raw_metered_feature: "codex_bengalfox",
      window_kind: kind,
      window_minutes: minutes,
      used_percent: Decimal.new("0"),
      reset_at: reset_at,
      observed_at: DateTime.add(reset_at, -minutes * 60, :second)
    }
  end

  defp insert_window!(identity, attrs) do
    observed_at = attrs.observed_at

    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(
      Map.merge(
        %{
          upstream_identity_id: identity.id,
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          last_sync_at: observed_at,
          metadata: %{},
          created_at: observed_at,
          updated_at: observed_at
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp days_ago(now, days), do: DateTime.add(now, -days * @day, :second)
  defp retention_days, do: div(Retention.retention_seconds(), @day)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
