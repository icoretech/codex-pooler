defmodule CodexPoolerWeb.Dev.QuotaObservationsFixture do
  @moduledoc false
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  @spec limit() :: map()
  def limit do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    selected = %AccountQuotaWindow{
      quota_scope: "account",
      quota_key: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: now,
      last_sync_at: now,
      updated_at: now,
      reset_at: DateTime.add(now, 6, :day),
      used_percent: Decimal.new(18),
      metadata: %{},
      merge_precedence: 60
    }

    older = DateTime.add(now, -1, :day)

    stale = %{
      selected
      | source: "codex_response_headers",
        observed_at: older,
        last_sync_at: older,
        updated_at: older,
        used_percent: Decimal.new(90),
        reset_at: DateTime.add(now, 5, :day)
    }

    raw = [stale, selected]

    raw
    |> WindowSelector.logical_windows(now)
    |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil), now, nil, raw)
    |> Enum.find(&(&1.key == :weekly))
  end
end
