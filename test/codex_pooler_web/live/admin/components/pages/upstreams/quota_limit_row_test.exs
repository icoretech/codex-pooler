defmodule CodexPoolerWeb.Admin.QuotaLimitRowTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.{CreditBalanceStore, RoutingQuotaSnapshot}
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaLimitRow
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.ProviderCreditsComponents
  alias CodexPoolerWeb.DateTimeDisplay

  test "renders qualified recovery context beside canonical values with stable disclosure controls" do
    now = ~U[2026-09-07 12:00:00Z]
    consumed_at = DateTime.add(now, -4, :minute)
    candidate_at = DateTime.add(now, -1, :minute)
    reset_at = DateTime.add(now, 6, :day)

    window = %AccountQuotaWindow{
      id: "retained-quota",
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(100),
      observed_at: DateTime.add(now, -6, :minute),
      last_sync_at: now,
      reset_at: reset_at,
      metadata: %{
        "__quota_confirmed_candidate_v1" => %{"version" => 1, "used_percent" => "32", "reset_at" => DateTime.to_iso8601(reset_at), "observed_at" => DateTime.to_iso8601(candidate_at), "count" => 1},
        "__quota_candidate_provider_status_v1" => %{"version" => 1, "allowed" => true, "limit_reached" => false, "observed_at" => DateTime.to_iso8601(candidate_at)}
      }
    }

    redemption = %{"phase" => "consumed_pending_probe", "included_window_descriptors" => [%{"window_kind" => "secondary", "window_minutes" => 10_080}], "consumed_at" => DateTime.to_iso8601(consumed_at)}
    preferences = DateTimeDisplay.preferences_for_user(nil)
    project = fn retained -> QuotaProjection.quota_limit_rows([retained], preferences, now, [retained], redemption) |> Enum.find(&(&1.key == :weekly)) end
    limit = project.(window)
    html = render_quota_row(limit)
    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "#quota-row [data-role='last-verified-quota']") |> LazyHTML.text() == "Last verified quota"
    assert LazyHTML.query(document, "#quota-row [data-role='unconfirmed-quota-report']") |> LazyHTML.text() == "New quota report awaiting verification"
    assert LazyHTML.query(document, "#quota-row-progress[value='0']") != []
    assert LazyHTML.query(document, "#quota-row-reset") |> LazyHTML.text() != ""
    assert LazyHTML.query(document, "#quota-row-observations-dialog[data-preserve-open][data-quota-dialog-preserve]") != []
    assert LazyHTML.query(document, "#quota-row-observations-dialog-title[tabindex='-1'][data-dialog-focus-fallback]") != []
    assert LazyHTML.query(document, "#quota-row-observations-dialog-title") |> LazyHTML.text() |> String.trim() == "Quota evidence"
    assert LazyHTML.query(document, "#quota-row-observations-dialog-eyebrow") |> LazyHTML.text() |> String.trim() == "Weekly · Sample <upstream> & account"
    assert LazyHTML.query(document, "#quota-row-observations-dialog") |> LazyHTML.attribute("aria-labelledby") == ["quota-row-observations-dialog-title quota-row-observations-dialog-eyebrow"]
    assert Enum.empty?(LazyHTML.query(document, "#quota-row-observations-dialog-eyebrow upstream"))
    assert LazyHTML.query(document, "#quota-row-observations-dialog-scroll[data-preserve-scroll]") != []
    assert LazyHTML.query(document, "[data-selected='true'] [data-role='last-verified-quota']") |> LazyHTML.text() == "Last verified quota"
    assert LazyHTML.query(document, "[data-selected='true'] summary") |> LazyHTML.text() =~ "fresh"
    assert LazyHTML.query(document, "[data-selected='true'] dl") |> LazyHTML.text() =~ "Source freshness does not mean the new quota cycle has been accepted."

    updated_limit = project.(%{window | observed_at: DateTime.add(now, -5, :minute), reset_at: DateTime.add(reset_at, 60), used_percent: Decimal.new(96)})
    updated_document = updated_limit |> render_quota_row() |> LazyHTML.from_fragment()
    assert LazyHTML.query(updated_document, "#quota-row-progress[value='4']") != []
    assert LazyHTML.query(updated_document, "#quota-row-reset[data-countdown-at='#{DateTime.to_iso8601(DateTime.add(reset_at, 60))}']") != []
    refute LazyHTML.query(document, "[data-selected='true'] summary") |> LazyHTML.text() == LazyHTML.query(updated_document, "[data-selected='true'] summary") |> LazyHTML.text()

    for selector <- ["details", "details > summary"] do
      assert LazyHTML.query(document, "[data-selected='true'] #{selector}") |> LazyHTML.attribute("id") == LazyHTML.query(updated_document, "[data-selected='true'] #{selector}") |> LazyHTML.attribute("id")
    end

    unqualified_window = put_in(window.metadata["__quota_confirmed_candidate_v1"]["observed_at"], DateTime.to_iso8601(DateTime.add(now, 1)))
    unqualified_html = project.(unqualified_window) |> render_quota_row()
    refute unqualified_html =~ "New quota report awaiting verification"
    assert unqualified_html =~ "Last verified quota"

    sibling = %{window | id: "retained-quota-sibling", observed_at: DateTime.add(now, -7, :minute)}
    distinct_limit = QuotaProjection.quota_limit_rows([window], preferences, now, [window, sibling], redemption) |> Enum.find(&(&1.key == :weekly))
    distinct_document = distinct_limit |> render_quota_row() |> LazyHTML.from_fragment()

    for selector <- ["[data-role='quota-observation']", "[data-role='quota-observation'] details", "[data-role='quota-observation'] summary"] do
      ids = LazyHTML.query(distinct_document, selector) |> LazyHTML.attribute("id")
      assert length(ids) == 2
      assert length(Enum.uniq(ids)) == 2
    end

    if evidence_dir = System.get_env("SAVED_RESET_COMPONENT_EVIDENCE_DIR") do
      File.mkdir_p!(evidence_dir)
      File.write!(Path.join(evidence_dir, "task-9-quota-rendered.html"), html)
      File.write!(Path.join(evidence_dir, "task-9-quota-updated.html"), render_quota_row(updated_limit))
      File.write!(Path.join(evidence_dir, "task-9-quota-unqualified.html"), unqualified_html)
      File.write!(Path.join(evidence_dir, "task-9-quota-distinct.html"), render_quota_row(distinct_limit))
    end
  end

  for {key, kind, minutes, label} <- [{:weekly, "secondary", 10_080, "Weekly"}, {:primary_30d, "primary", 43_200, "30-day"}] do
    @tag :pending_quota_measurement
    test "shows #{label} values and localized report time when a different source still supplies the meter" do
      now = ~U[2026-09-07 12:00:00Z]
      reported_at = DateTime.add(now, -60)
      reset_at = DateTime.add(now, 6, :day)
      preferences = DateTimeDisplay.preferences_for_user(nil)
      reported_time = DateTimeDisplay.format_datetime(reported_at, preferences)

      usage = %AccountQuotaWindow{
        id: "retained-provider",
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account",
        window_kind: unquote(kind),
        window_minutes: unquote(minutes),
        source: "codex_usage_api",
        source_precision: "observed",
        used_percent: Decimal.new(99),
        reset_at: reset_at,
        observed_at: DateTime.add(now, -300),
        last_sync_at: now,
        freshness_state: "fresh",
        metadata: %{
          "__quota_confirmed_candidate_v1" => %{"version" => 1, "used_percent" => "7", "reset_at" => DateTime.to_iso8601(reset_at), "observed_at" => DateTime.to_iso8601(reported_at), "count" => 1},
          "__quota_candidate_provider_status_v1" => %{"version" => 1, "allowed" => true, "limit_reached" => false, "observed_at" => DateTime.to_iso8601(reported_at)}
        }
      }

      event = %{usage | id: "selected-event", source: "codex_rate_limit_event", observed_at: DateTime.add(now, -180), metadata: %{}}
      redemption = %{"phase" => "confirmed_by_quota", "consumed_at" => DateTime.to_iso8601(DateTime.add(now, -240)), "result" => %{"applied" => true, "code" => "reset"}}

      render = fn selected, provider, clock ->
        QuotaProjection.quota_limit_rows([selected], preferences, clock, [selected, provider], redemption, 1)
        |> Enum.find(&(&1.key == unquote(key)))
        |> render_quota_row()
        |> LazyHTML.from_fragment()
      end

      document = render.(event, usage, now)
      assert LazyHTML.query(document, "#quota-row-progress[value='1']") |> Enum.any?()

      assert Enum.empty?(LazyHTML.query(document, "#quota-row [data-role='pending-quota-measurement']"))
      text = LazyHTML.query(document, "#quota-row-observations-dialog [data-role='pending-quota-measurement']") |> LazyHTML.text()
      assert text =~ unquote(label) <> " remaining: 1% verified"
      assert text =~ "93% reported"
      assert text =~ reported_time
      assert text =~ "awaiting verification"
      assert LazyHTML.query(document, "#quota-row-observations-open") |> LazyHTML.attribute("aria-controls") == ["quota-row-observations-dialog"]

      Gettext.with_locale("zh_CN", fn ->
        text = render.(event, usage, now) |> LazyHTML.query("#quota-row-observations-dialog [data-role='pending-quota-measurement']") |> LazyHTML.text()
        assert text =~ "已核实 1%"
        assert text =~ "93% 待核实"
        assert text =~ reported_time
      end)

      for {selected, provider, clock} <- [
            {event, %{usage | metadata: %{}}, now},
            {event, usage, DateTime.add(now, 16, :minute)},
            {event, put_in(usage.metadata["__quota_candidate_provider_status_v1"]["allowed"], false), now},
            {event, %{usage | source_precision: "unknown"}, now},
            {event, %{usage | metadata: Map.put(usage.metadata, "credential_epoch", 2)}, now},
            {%{event | observed_at: DateTime.add(reported_at, 1)}, usage, now},
            {%{event | used_percent: Decimal.new(7)}, usage, now},
            {event, put_in(usage.metadata["__quota_confirmed_candidate_v1"]["reset_at"], DateTime.to_iso8601(DateTime.add(reset_at, 7, :day))), now}
          ] do
        assert Enum.empty?(LazyHTML.query(render.(selected, provider, clock), "[data-role='pending-quota-measurement']"))
      end

      five_hour = %{usage | window_kind: "primary", window_minutes: 300}
      [primary] = QuotaProjection.quota_limit_rows([five_hour], preferences, now, [five_hour], redemption) |> Enum.filter(&(&1.key == :primary_5h))
      assert Enum.empty?(primary |> render_quota_row() |> LazyHTML.from_fragment() |> LazyHTML.query("[data-role='pending-quota-measurement']"))
    end
  end

  test "opens observations without changing the compact meter and renders a closed accessible dialog" do
    now = ~U[2026-09-07 12:00:00Z]

    [limit] =
      QuotaProjection.quota_limit_rows(
        [private_meter_window(now, "private-demo", "25")],
        DateTimeDisplay.preferences_for_user(nil),
        now
      )
      |> Enum.filter(&is_binary(&1.key))

    entries =
      for index <- 1..8,
          do: %{hd(limit.observations) | key: "entry-#{index}", selected?: index == 1}

    expanded_document = LazyHTML.from_fragment(render_quota_row(%{limit | observations: entries}))

    assert Enum.count(LazyHTML.query(expanded_document, "[data-role='quota-observation']:not(.hidden)")) == 5

    assert Enum.count(LazyHTML.query(expanded_document, "[data-extra-evidence='true'].hidden")) ==
             3

    assert LazyHTML.query(expanded_document, "#quota-row-observations-dialog-show-all")
           |> LazyHTML.text() =~ "Show all 8 records"

    html = render_quota_row(limit)
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#quota-row-observations-open[aria-haspopup='dialog'][phx-click]"
           ) != []

    assert LazyHTML.query(
             document,
             "#quota-row-observations-dialog:not([open])[aria-modal='true']"
           ) != []

    assert LazyHTML.query(document, "#quota-row-observations-dialog [data-selected='true']")
           |> LazyHTML.text() =~ "Usage API"

    assert LazyHTML.query(document, "#quota-row-progress[value='75']") != []

    refute html =~ "Displayed remaining"

    assert LazyHTML.query(document, "[data-role='quota-observation-progress'][value='75.0']") !=
             []

    assert LazyHTML.query(document, "#quota-row-observations-open.hover\\:border-success\\/25") !=
             []

    assert LazyHTML.query(document, "[data-selected='true'] [aria-label*='selected for display']") !=
             []

    assert LazyHTML.query(document, "[data-selected='true'] .badge") |> Enum.empty?()

    refute LazyHTML.query(
             document,
             "[data-selected='true'] details[data-preserve-open] > summary"
           )
           |> Enum.empty?()

    assert LazyHTML.query(document, "[data-selected='true'] details[open]") |> Enum.empty?()

    assert LazyHTML.query(document, "[data-selected='true'] dl") |> LazyHTML.text() =~
             "Source precision"

    refute html =~ "private-demo"
    refute html =~ "sources differ"
  end

  test "keeps quota-meter ids, determinate value, threshold tone and reset hook" do
    html =
      render_component(&QuotaLimitRow.quota_limit_row/1, %{
        id: "quota-row-baseline",
        account_label: "Sample upstream",
        limit: %{
          label: "Weekly",
          percent: Decimal.new(75),
          percent_value: 75,
          percent_label: "75%",
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
             "#quota-row-baseline-progress[data-role='upstream-limit-progress'][value='75'][max='100'].progress-success"
           ) != []

    assert LazyHTML.query(
             document,
             "#quota-row-baseline-reset[data-countdown-state='running'][phx-hook='RelativeCountdown'][data-countdown-at='2026-08-31T12:00:00Z']"
           ) != []

    assert LazyHTML.query(document, "#quota-row-baseline-count") |> LazyHTML.text() =~
             "500 credits"
  end

  test "credit precision agrees in the visible label, progress value and accessible label" do
    now = ~U[2026-09-07 12:00:00Z]

    window = %AccountQuotaWindow{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      source: "codex_usage_api",
      source_precision: "observed",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(100),
      active_limit: 12_500,
      credits: 12_497,
      observed_at: now,
      last_sync_at: now,
      freshness_state: "fresh",
      reset_at: DateTime.add(now, 86_400),
      merge_precedence: 60
    }

    limit =
      QuotaProjection.quota_limit_rows(
        [window],
        DateTimeDisplay.preferences_for_user(nil),
        now
      )
      |> Enum.find(&(&1.key == :weekly))

    metadata = CreditBalanceStore.transition(%{"credential_epoch" => 1}, %{"credits" => %{"balance" => 12_497}}, now, 1)
    snapshot = RoutingQuotaSnapshot.from_identity(%UpstreamIdentity{id: Ecto.UUID.generate(), metadata: metadata}, [window], now)
    summary = QuotaProjection.provider_credits_summary(snapshot)
    included = limit |> render_quota_row() |> LazyHTML.from_fragment()
    document = render_component(&ProviderCreditsComponents.provider_credits_summary/1, %{id: "credits", summary: summary}) |> LazyHTML.from_fragment()

    refute Enum.empty?(LazyHTML.query(included, "#quota-row-progress[value='0']"))
    refute Enum.empty?(LazyHTML.query(included, "#quota-row-progress[aria-label='Weekly included Codex quota remaining 0%']"))
    assert Enum.empty?(LazyHTML.query(included, ".progress-striped, #quota-row-count"))
    assert LazyHTML.query(document, "#credits-percent") |> LazyHTML.text() =~ "99.9%"
    refute Enum.empty?(LazyHTML.query(document, "#credits-progress[value='99.9'][aria-valuetext='99.9% of observed baseline'].progress-striped"))
  end

  test "qualifies a retained zero-percent measurement pending provider confirmation through the existing compact trigger" do
    baseline_html =
      render_component(&QuotaLimitRow.quota_limit_row/1, %{
        id: "quota-row-baseline-structure",
        account_label: "Sample upstream",
        limit: %{
          label: "Weekly",
          percent: Decimal.new(0),
          percent_value: 0,
          percent_label: "0%",
          observations: [observation()],
          evidence_state: :fresh,
          meter_state: :current,
          reset_display_state: :absent,
          reset_semantics: :unknown
        }
      })

    conflict_html =
      render_component(&QuotaLimitRow.quota_limit_row/1, %{
        id: "quota-row-conflict",
        account_label: "Sample upstream",
        limit: %{
          label: "Weekly",
          percent: Decimal.new(0),
          percent_value: 0,
          percent_label: "0%",
          observations: [%{observation() | measurement_pending?: true}],
          measurement_pending?: true,
          measurement_pending_label: "Retained measurement awaits confirmation",
          measurement_pending_detail: "Retained measurement; newer provider measurement awaits confirmation",
          evidence_state: :fresh,
          meter_state: :current,
          reset_display_state: :absent,
          reset_semantics: :unknown
        }
      })

    baseline = LazyHTML.from_fragment(baseline_html)
    conflict = LazyHTML.from_fragment(conflict_html)

    assert LazyHTML.query(conflict, "#quota-row-conflict[data-measurement-pending='true']") != []

    assert LazyHTML.query(
             conflict,
             "#quota-row-conflict-observations-open[aria-describedby='quota-row-conflict-pending-description'][aria-label*='0% remaining'][aria-label*='awaits confirmation']"
           ) != []

    assert LazyHTML.query(
             conflict,
             "#quota-row-conflict-progress.progress-warning[aria-describedby='quota-row-conflict-pending-description'][aria-label*='0% remaining'][aria-label*='awaits confirmation']"
           ) != []

    assert LazyHTML.query(
             conflict,
             "#quota-row-conflict .text-base-content.decoration-warning.decoration-dotted.underline-offset-4"
           ) != []

    assert LazyHTML.query(conflict, "#quota-row-conflict-pending-description.sr-only")
           |> LazyHTML.text() =~ "Retained measurement awaits confirmation"

    assert LazyHTML.query(conflict, "#quota-row-conflict [data-role='upstream-limit-title']")
           |> LazyHTML.text() ==
             LazyHTML.query(
               baseline,
               "#quota-row-baseline-structure [data-role='upstream-limit-title']"
             )
             |> LazyHTML.text()

    assert LazyHTML.query(conflict, "#quota-row-conflict [data-role='upstream-limit-progress']")
           |> Enum.count() == 1

    assert LazyHTML.query(conflict, "#quota-row-conflict > div") |> Enum.count() ==
             LazyHTML.query(baseline, "#quota-row-baseline-structure > div") |> Enum.count()

    for selector <- ["> button", "> progress"] do
      assert LazyHTML.query(conflict, "#quota-row-conflict #{selector}") |> Enum.count() ==
               LazyHTML.query(baseline, "#quota-row-baseline-structure #{selector}")
               |> Enum.count()
    end

    assert LazyHTML.query(conflict, "#quota-row-conflict > p") |> Enum.empty?()

    assert LazyHTML.query(
             conflict,
             "#quota-row-conflict > details, #quota-row-conflict > section, #quota-row-conflict [data-role='upstream-reconciliation-status']"
           )
           |> Enum.empty?()

    assert LazyHTML.query(
             conflict,
             "#quota-row-conflict-observations-dialog [data-selected='true'] details[open]"
           ) != []
  end

  test "keeps stale state internal while restoring the compact historical row" do
    html = render_quota_row(stale_limit(Decimal.new(75), 75, "75%"))
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#quota-row[data-evidence-state='stale'][data-meter-state='historical']"
           ) != []

    assert LazyHTML.query(
             document,
             "#quota-row-progress[data-evidence-state='stale'][data-meter-state='historical'].progress-success:not([aria-describedby])"
           ) != []

    assert LazyHTML.query(document, "#quota-row-freshness") |> Enum.empty?()
    assert LazyHTML.query(document, "#quota-row-observed") |> Enum.empty?()
    assert LazyHTML.query(document, "#quota-row-reset") |> Enum.empty?()
  end

  test "keeps stale exhaustion error-toned without adding historical copy" do
    html = render_quota_row(stale_limit(Decimal.new(0), 0, "0%"))
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(
             document,
             "#quota-row[data-evidence-state='stale'][data-meter-state='historical_exhausted']"
           ) != []

    assert LazyHTML.query(
             document,
             "#quota-row-progress.progress-error:not(.progress-success):not([aria-describedby])"
           ) != []

    assert LazyHTML.query(document, "#quota-row-freshness") |> Enum.empty?()
    assert LazyHTML.query(document, "#quota-row-observed") |> Enum.empty?()
  end

  test "keeps the previous percent thresholds for stale low quota" do
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
          account_label: "Sample upstream",
          limit: %{
            label: "Weekly",
            percent: Decimal.new(100),
            percent_value: 100,
            percent_label: "100%",
            count_label: nil,
            evidence_state: evidence_state,
            meter_state: meter_state,
            freshness_label: if(evidence_state == :stale, do: "last reported", else: "current"),
            observed_label: if(evidence_state == :stale, do: "last reported", else: "observed at snapshot"),
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
      render_component(&QuotaLimitRow.quota_limit_row/1, %{id: "quota-row-redacted", account_label: "Sample upstream", limit: limit})

    assert html =~ "Additional limit 5h"
    refute html =~ unsafe_limit_name
    refute html =~ unsafe_metered_feature
  end

  test "renders colliding additional meters under fingerprinted private DOM ids" do
    observed_at = ~U[2026-08-25 12:00:00Z]
    raw_meter_values = ["private-component-meter-alpha", "private-component-meter-beta"]

    projected_limits =
      raw_meter_values
      |> Enum.with_index(25)
      |> Enum.map(fn {raw_meter_value, used_percent} ->
        private_meter_window(observed_at, raw_meter_value, used_percent)
      end)
      |> QuotaProjection.quota_limit_rows(
        DateTimeDisplay.preferences_for_user(nil),
        observed_at
      )
      |> Enum.reject(&is_atom(&1.key))

    html =
      projected_limits
      |> Enum.map_join(fn limit ->
        render_component(&QuotaLimitRow.quota_limit_row/1, %{
          id: "quota-row-#{limit.key}",
          account_label: "Sample upstream",
          limit: limit
        })
      end)

    document = LazyHTML.from_fragment(html)

    rendered_ids =
      document
      |> LazyHTML.query("[data-role='upstream-limit-chart']")
      |> Enum.map(fn node -> node |> LazyHTML.attribute("id") |> List.first() end)

    assert length(rendered_ids) == 2
    assert rendered_ids == Enum.uniq(rendered_ids)
    assert Enum.all?(rendered_ids, &Regex.match?(~r/-meter-[0-9a-f]{24}$/, &1))
    assert LazyHTML.text(document) =~ "Approved component meter 5h"

    for private_value <- raw_meter_values do
      reversible_token = private_value |> Base.encode32(padding: false) |> String.downcase()

      refute html =~ private_value
      refute html =~ reversible_token
    end
  end

  @tag :manual_quota_row_render
  test "manual quota row render verifies the restored compact HTML" do
    stale_html = render_quota_row(stale_limit(Decimal.new(75), 75, "75%"))

    exhausted_html =
      render_component(&QuotaLimitRow.quota_limit_row/1, %{
        id: "quota-row-exhausted",
        account_label: "Sample upstream",
        limit: stale_limit(Decimal.new(0), 0, "0%")
      })

    markerless_html =
      render_component(&QuotaLimitRow.quota_limit_row/1, %{
        id: "quota-row-markerless",
        account_label: "Sample upstream",
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
             "#quota-row-progress.progress-success:not([aria-describedby])"
           ) != []

    assert LazyHTML.query(document, "#quota-row-freshness") |> Enum.empty?()
    assert LazyHTML.query(document, "#quota-row-observed") |> Enum.empty?()

    assert LazyHTML.query(
             document,
             "#quota-row-exhausted-progress.progress-error:not(.progress-success):not([aria-describedby])"
           ) != []

    assert LazyHTML.query(document, "#quota-row-exhausted-observed") |> Enum.empty?()

    assert LazyHTML.query(document, "#quota-row-markerless-reset") |> Enum.empty?()
  end

  defp render_quota_row(limit) do
    render_component(&QuotaLimitRow.quota_limit_row/1, %{id: "quota-row", account_label: "Sample <upstream> & account", limit: limit})
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

  defp private_meter_window(observed_at, raw_meter_value, used_percent) do
    %AccountQuotaWindow{
      quota_key: "component_shared_meter",
      quota_scope: "feature",
      quota_family: "component_shared_family",
      display_label: "Approved component meter",
      raw_metered_feature: raw_meter_value,
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new(used_percent),
      reset_at: DateTime.add(observed_at, 5, :hour),
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: observed_at,
      last_sync_at: observed_at,
      updated_at: observed_at,
      metadata: %{}
    }
  end

  defp observation do
    %{
      key: "selected-observation",
      source: "Usage API",
      slot: "secondary",
      used: "100%",
      remaining: "0%",
      remaining_value: 0.0,
      observed_at: "September 9, 2026 at 17:56 UTC",
      reset_at: "September 15, 2026 at 02:20 UTC",
      freshness: "fresh",
      elapsed?: false,
      selected?: true,
      measurement_pending?: false,
      permission_facts: %{allowed: true, limit_reached: false},
      details: []
    }
  end
end
