defmodule CodexPoolerWeb.Dev.ComponentShowcaseCatalog do
  @moduledoc false

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer
  alias CodexPoolerWeb.Admin.RequestLogsPresentation
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaLimitRow
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.SavedResetMeter
  alias CodexPoolerWeb.Dev.ComponentShowcaseCatalogExtended
  alias CodexPoolerWeb.Observatory.Components.{Activity, Telemetry}

  def entries do
    [
      entry(
        "5.1-page-header",
        "### 5.1 Page header",
        "page_header/1",
        AdminComponents,
        :page_header,
        selectors: ["#showcase-page-header"]
      ),
      entry(
        "5.2-metric-strip-card",
        "### 5.2 Metric strip and metric card",
        "metric_strip/1",
        AdminComponents,
        :metric_strip,
        exports: [{AdminComponents, :metric_card, 1}],
        selectors:
          ["#showcase-metric-strip", "#showcase-metric-breakdown"] ++
            Enum.map(~w(neutral primary success warning error), &"#showcase-metric-#{&1}")
      ),
      entry(
        "5.3-admin-surface",
        "### 5.3 Admin surface (card with header, count, actions, toolbar, footer)",
        "admin_surface/1",
        AdminComponents,
        :admin_surface,
        selectors: ["#showcase-admin-surface"]
      ),
      entry(
        "5.4-account-card",
        "### 5.4 Upstream account card",
        "account_card/1",
        AccountCard,
        :account_card,
        selectors: ["#showcase-account-card [data-role='upstream-account-card']"]
      ),
      entry(
        "5.5-quota-row",
        "### 5.5 Quota progress row (including striped credit-backed state)",
        "quota_limit_row/1",
        QuotaLimitRow,
        :quota_limit_row,
        selectors: Enum.map(~w(success warning error neutral credit), &"#showcase-quota-#{&1}")
      ),
      entry(
        "5.6-reset-bank",
        "### 5.6 Saved-reset badge and meter",
        "saved_reset_count_badge/1",
        SavedResetMeter,
        :saved_reset_count_badge,
        exports: [{SavedResetMeter, :saved_reset_meter, 1}],
        selectors:
          Enum.map(
            ~w(badge-active badge-inactive meter-active meter-inactive),
            &"#showcase-reset-#{&1}"
          )
      ),
      entry(
        "5.7-chip-families",
        "### 5.7 Chips (status, count, metadata, severity, protocol, redacted)",
        "status_chip_class/1",
        AdminBadges,
        :status_chip_class,
        exports: [
          {AdminBadges, :count_chip_class, 0},
          {AdminBadges, :metadata_chip_class, 1},
          {AdminBadges, :alert_severity_chip_class, 1},
          {RequestLogsPresentation, :request_log_protocol_badge, 1},
          {AdminComponents, :redacted_status_badge, 1}
        ],
        selectors:
          Enum.map(~w(active paused failed pending unknown), &"#showcase-status-#{&1}") ++
            ["#showcase-count-chip"] ++
            Enum.map(~w(neutral primary success warning error), &"#showcase-metadata-#{&1}") ++
            Enum.map(~w(critical warning info unknown), &"#showcase-severity-#{&1}") ++
            Enum.map(~w(websocket sse multipart json fallback), &"#showcase-protocol-#{&1}") ++
            Enum.map(~w(ok warning error redacted), &"#showcase-redacted-#{&1}")
      ),
      private_entry(
        "5.8-definition-row",
        "### 5.8 Compact and definition lists",
        "detail_row/1",
        RequestLogDetailDrawer,
        :detail_row,
        "The definition-row leaf is private; the real exported request drawer owns and tests it."
      ),
      entry(
        "5.8-ranked-list",
        "### 5.8 Compact and definition lists",
        "ranked compact rows",
        Telemetry,
        :telemetry,
        selectors: ["#observatory-models [data-role='observatory-model-row']"]
      ),
      entry(
        "5.8-zebra-table",
        "### 5.8 Compact and definition lists",
        "Zebra tables",
        Activity,
        :activity,
        selectors: ["#observatory-outcomes-table"]
      ),
      entry(
        "5.9-plan-badge",
        "### 5.9 Plan badge — all tones",
        "plan_badge/1",
        AdminBadges,
        :plan_badge,
        selectors:
          Enum.map(~w(free pro team enterprise generated unknown), &"#showcase-plan-#{&1}")
      ),
      entry(
        "5.10-dropdown-menu",
        "### 5.10 Dropdown action menu",
        "dropdown_action_item/1",
        AdminComponents,
        :dropdown_action_item,
        selectors:
          Enum.map(
            ~w(secondary warning positive danger disabled link copy),
            &"#showcase-dropdown-#{&1}"
          )
      )
    ] ++ ComponentShowcaseCatalogExtended.entries()
  end

  def entry(id, section, source, module, function, opts) do
    %{
      id: id,
      section_id: section_id(id),
      section: section,
      source: source,
      exports: [{module, function, 1} | Keyword.get(opts, :exports, [])],
      selectors: Keyword.fetch!(opts, :selectors),
      scope_selector: Keyword.get(opts, :scope_selector),
      render_contract: Keyword.get(opts, :render_contract),
      availability: Keyword.get(opts, :availability, :rendered),
      review_state: Keyword.get(opts, :review_state, "catalog"),
      reason: nil
    }
  end

  def product_entry(id, section, source, module, function, reason) do
    %{
      id: id,
      section_id: section_id(id),
      section: section,
      source: source,
      exports: [{module, function, 1}],
      selectors: [],
      scope_selector: nil,
      render_contract: nil,
      availability: :product_route,
      review_state: nil,
      reason: reason
    }
  end

  def private_entry(id, section, source, module, function, reason) do
    %{
      id: id,
      section_id: section_id(id),
      section: section,
      source: source,
      exports: [{module, function, 1}],
      selectors: [],
      scope_selector: nil,
      render_contract: nil,
      availability: :private_leaf,
      review_state: nil,
      reason: reason
    }
  end

  defp section_id(id), do: id |> String.split("-", parts: 2) |> hd()
end
