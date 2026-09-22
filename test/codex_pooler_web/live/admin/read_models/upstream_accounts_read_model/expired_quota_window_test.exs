defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.ExpiredQuotaWindowTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel

  setup :register_and_log_in_user

  # Degraded shape: the Usage API poll stopped succeeding, so every row of the
  # weekly window aged past the freshness TTL, and one row of the same logical
  # window describes a cycle that ended weeks ago at 100%. The ended cycle says
  # nothing about the running one; the card must present the running cycle's
  # last report, not the expired exhaustion.
  test "an expired exhausted row never wins the account card when every row of the window is stale",
       %{scope: scope} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    assert {:ok, [_, _]} =
             Windows.upsert_quota_windows(identity, [
               weekly_attrs(now, "codex_rate_limit_event", "100"),
               weekly_attrs(now, "codex_usage_api", "30")
             ])

    running_reset = DateTime.add(now, 3, :day)

    age_row!(identity, "codex_rate_limit_event",
      reset_at: DateTime.add(now, -60, :day),
      observed_at: DateTime.add(now, -67, :day)
    )

    age_row!(identity, "codex_usage_api",
      reset_at: running_reset,
      observed_at: DateTime.add(now, -2, :hour)
    )

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    weekly = Enum.find(account.quota_limits, &(&1.key == :weekly))

    assert weekly.evidence_state == :stale
    assert weekly.percent_value == 70
    assert weekly.meter_state == :historical
    assert [%{source: "Usage API"}] = Enum.filter(weekly.observations, & &1.selected?)
  end

  # Control for the rule above: with no expired row in the group, an all-stale
  # exhausted report of the running cycle keeps its fail-closed pessimism.
  test "an all-stale exhausted row of the running cycle still wins the account card", %{scope: scope} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    assert {:ok, [_, _]} =
             Windows.upsert_quota_windows(identity, [
               weekly_attrs(now, "codex_rate_limit_event", "100"),
               weekly_attrs(now, "codex_usage_api", "30")
             ])

    running_reset = DateTime.add(now, 3, :day)

    for source <- ["codex_rate_limit_event", "codex_usage_api"] do
      age_row!(identity, source, reset_at: running_reset, observed_at: DateTime.add(now, -2, :hour))
    end

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    weekly = Enum.find(account.quota_limits, &(&1.key == :weekly))

    assert weekly.evidence_state == :stale
    assert weekly.percent_value == 0
    assert weekly.meter_state == :historical_exhausted
    assert [%{source: "Rate-limit event"}] = Enum.filter(weekly.observations, & &1.selected?)
  end

  defp weekly_attrs(now, source, used_percent) do
    %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used_percent),
      reset_at: DateTime.add(now, 3, :day),
      source: source,
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: now,
      observed_at: now
    }
  end

  defp age_row!(identity, source, opts) do
    reset_at = Keyword.fetch!(opts, :reset_at)
    observed_at = Keyword.fetch!(opts, :observed_at)

    assert {1, _} =
             from(window in AccountQuotaWindow,
               where: window.upstream_identity_id == ^identity.id and window.source == ^source
             )
             |> Repo.update_all(set: [reset_at: reset_at, observed_at: observed_at, last_sync_at: observed_at])
  end
end
