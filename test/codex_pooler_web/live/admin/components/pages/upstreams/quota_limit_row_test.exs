defmodule CodexPoolerWeb.Admin.QuotaLimitRowTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaLimitRow
  alias CodexPoolerWeb.DateTimeDisplay

  test "keeps the existing quota-meter ids, determinate value, threshold tone, stripes, and reset hook" do
    html =
      render_component(&QuotaLimitRow.quota_limit_row/1, %{
        id: "quota-row-baseline",
        limit: %{
          label: "Weekly",
          percent: Decimal.new(75),
          percent_value: 75,
          percent_label: "75%",
          burning_credits: true,
          count_label: "500 credits",
          count_title: "Credit balance",
          reset_label: "in 6d 23h",
          reset_title: "resets August 31, 2026 at 12:00 UTC",
          reset_semantics: :anchored,
          reset_at: ~U[2026-08-31 12:00:00Z]
        }
      })

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#quota-row-baseline[data-role='upstream-limit-chart']") != []

    assert LazyHTML.query(
             document,
             "#quota-row-baseline-progress[data-role='upstream-limit-progress'][value='75'][max='100'].progress-success.progress-striped"
           ) != []

    assert LazyHTML.query(
             document,
             "#quota-row-baseline-reset[data-countdown-state='running'][phx-hook='RelativeCountdown'][data-countdown-at='2026-08-31T12:00:00Z']"
           ) != []

    assert LazyHTML.query(document, "#quota-row-baseline-count") |> LazyHTML.text() =~
             "500 credits"
  end

  test "renders stale historical quota evidence with row-local accessible descriptions" do
    html = render_quota_row(stale_limit(Decimal.new(75), 75, "75%"))
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#quota-row[data-evidence-state='stale'][data-meter-state='historical']"
           ) != []

    assert LazyHTML.query(
             document,
             "#quota-row-progress[data-evidence-state='stale'][data-meter-state='historical'].progress-warning[aria-describedby='quota-row-freshness quota-row-observed']"
           ) != []

    assert LazyHTML.query(document, "#quota-row-freshness") |> LazyHTML.text() |> String.trim() ==
             "last reported"

    assert LazyHTML.query(document, "#quota-row-observed") |> LazyHTML.text() |> String.trim() ==
             "last reported"

    assert LazyHTML.query(
             document,
             "#quota-row-reset[data-countdown-state='unconfirmed']:not([data-countdown-at]):not([phx-hook])"
           ) != []

    assert LazyHTML.query(document, "#quota-row-reset") |> LazyHTML.text() =~ "reset unconfirmed"
  end

  test "keeps stale exhaustion error-toned and describes it as historical" do
    html = render_quota_row(stale_limit(Decimal.new(0), 0, "0%"))
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#quota-row[data-evidence-state='stale'][data-meter-state='historical_exhausted']"
           ) != []

    assert LazyHTML.query(
             document,
             "#quota-row-progress.progress-error:not(.progress-success)[aria-describedby='quota-row-freshness quota-row-observed']"
           ) != []

    assert LazyHTML.query(
             document,
             "#quota-row-observed[aria-label='last reported exhausted; evidence stale']"
           ) != []
  end

  test "keeps stale low quota error-toned without presenting it as current" do
    html = render_quota_row(stale_limit(Decimal.new(25), 25, "25%"))
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#quota-row[data-evidence-state='stale'][data-meter-state='historical'] #quota-row-progress.progress-error:not(.progress-success)"
           ) != []
  end

  test "omits reset details for markerless and unknown reset evidence" do
    for {id, evidence_state, meter_state} <- [
          {"quota-row-markerless", :stale, :historical},
          {"quota-row-unknown", :fresh, :current}
        ] do
      html =
        render_component(&QuotaLimitRow.quota_limit_row/1, %{
          id: id,
          limit: %{
            label: "Weekly",
            percent: Decimal.new(100),
            percent_value: 100,
            percent_label: "100%",
            count_label: nil,
            evidence_state: evidence_state,
            meter_state: meter_state,
            freshness_label: if(evidence_state == :stale, do: "last reported", else: "current"),
            observed_label:
              if(evidence_state == :stale, do: "last reported", else: "observed at snapshot"),
            reset_display_state: :absent,
            reset_semantics: :unknown
          }
        })

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(
               document,
               "##{id}[data-evidence-state='#{evidence_state}'][data-meter-state='#{meter_state}']"
             ) != []

      assert LazyHTML.query(document, "##{id}-reset") |> Enum.empty?()
    end
  end

  test "does not render raw provider meter labels when the projection has no safe identity" do
    unsafe_limit_name = "private-provider-limit-name"
    unsafe_metered_feature = "private-provider-metered-feature"
    observed_at = ~U[2026-08-25 12:00:00Z]

    limit =
      %AccountQuotaWindow{
        quota_key: "provider_feature",
        quota_scope: "feature",
        quota_family: "provider_feature",
        display_label: nil,
        model: nil,
        upstream_model: nil,
        limit_name: nil,
        raw_limit_name: unsafe_limit_name,
        metered_feature: unsafe_metered_feature,
        window_kind: "primary",
        window_minutes: 300,
        used_percent: Decimal.new("25"),
        reset_at: DateTime.add(observed_at, 5, :hour),
        source: "codex_usage_api",
        source_precision: "observed",
        freshness_state: "fresh",
        observed_at: observed_at,
        last_sync_at: observed_at,
        updated_at: observed_at,
        metadata: %{}
      }
      |> then(
        &QuotaProjection.quota_limit_rows(
          [&1],
          DateTimeDisplay.preferences_for_user(nil),
          observed_at
        )
      )
      |> Enum.find(&is_binary(&1.key))

    html =
      render_component(&QuotaLimitRow.quota_limit_row/1, %{id: "quota-row-redacted", limit: limit})

    assert html =~ "Additional limit 5h"
    refute html =~ unsafe_limit_name
    refute html =~ unsafe_metered_feature
  end

  @tag :manual_quota_row_render
  test "manual quota row render writes and verifies historical HTML evidence" do
    stale_html = render_quota_row(stale_limit(Decimal.new(75), 75, "75%"))

    exhausted_html =
      render_component(&QuotaLimitRow.quota_limit_row/1, %{
        id: "quota-row-exhausted",
        limit: stale_limit(Decimal.new(0), 0, "0%")
      })

    markerless_html =
      render_component(&QuotaLimitRow.quota_limit_row/1, %{
        id: "quota-row-markerless",
        limit: %{
          label: "Weekly",
          percent: Decimal.new(100),
          percent_value: 100,
          percent_label: "100%",
          count_label: nil,
          evidence_state: :stale,
          meter_state: :historical,
          freshness_label: "last reported",
          observed_label: "last reported",
          reset_display_state: :absent,
          reset_semantics: :unknown
        }
      })

    html = "<section>#{stale_html}#{exhausted_html}#{markerless_html}</section>"
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#quota-row[data-evidence-state='stale'][data-meter-state='historical']"
           ) != []

    assert LazyHTML.query(
             document,
             "#quota-row-progress.progress-warning:not(.progress-success)[aria-describedby='quota-row-freshness quota-row-observed']"
           ) != []

    assert LazyHTML.query(document, "#quota-row-freshness") |> LazyHTML.text() |> String.trim() ==
             "last reported"

    assert LazyHTML.query(document, "#quota-row-observed") |> LazyHTML.text() |> String.trim() ==
             "last reported"

    assert LazyHTML.query(
             document,
             "#quota-row-exhausted-progress.progress-error:not(.progress-success)[aria-describedby='quota-row-exhausted-freshness quota-row-exhausted-observed']"
           ) != []

    assert LazyHTML.query(
             document,
             "#quota-row-exhausted-observed[aria-label='last reported exhausted; evidence stale']"
           ) != []

    assert LazyHTML.query(document, "#quota-row-markerless-reset") |> Enum.empty?()

    evidence_path =
      Path.expand(
        "../../../../../../../.omo/evidence/gpt-reserve-quota-freshness-and-identity/task-2-component.html",
        __DIR__
      )

    File.mkdir_p!(Path.dirname(evidence_path))
    File.write!(evidence_path, html)

    assert File.read!(evidence_path) == html
  end

  defp render_quota_row(limit) do
    render_component(&QuotaLimitRow.quota_limit_row/1, %{id: "quota-row", limit: limit})
  end

  defp stale_limit(percent, percent_value, percent_label) do
    %{
      label: "Weekly",
      percent: percent,
      percent_value: percent_value,
      percent_label: percent_label,
      count_label: nil,
      evidence_state: :stale,
      meter_state: if(percent_value == 0, do: :historical_exhausted, else: :historical),
      freshness_label: "last reported",
      freshness_title: "evidence stale; showing the last reported value",
      observed_label: "last reported",
      observed_title: "observed August 31, 2026 at 12:00 UTC",
      reset_display_state: :unconfirmed,
      reset_label: "reset unconfirmed",
      reset_title: "Reset time is unconfirmed because evidence is stale.",
      reset_semantics: :anchored,
      reset_at: ~U[2026-08-31 12:00:00Z]
    }
  end
end
