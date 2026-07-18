defmodule CodexPoolerWeb.Dev.ComponentShowcaseCatalogExtended do
  @moduledoc false

  alias CodexPoolerWeb.Admin.ApiKeyWizardComponents
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PolicyEditorComponents
  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents
  alias CodexPoolerWeb.CoreComponents
  alias CodexPoolerWeb.Dev.ComponentShowcaseCatalog
  alias CodexPoolerWeb.Dev.ComponentShowcaseStats
  alias CodexPoolerWeb.Layouts
  alias CodexPoolerWeb.Observatory.Components.{Activity, States, Telemetry, Toolbar}

  def entries do
    [
      entry(
        "5.11-object-inspector",
        "### 5.11 Object inspector and request-log drawer",
        "object_inspector/1",
        AdminComponents,
        :object_inspector,
        selectors: ["#showcase-object-inspector"]
      ),
      entry(
        "5.11-request-drawer",
        "### 5.11 Object inspector and request-log drawer",
        "request-log drawer",
        RequestLogDetailDrawer,
        :request_log_detail_drawer,
        availability: :interactive,
        review_state: "request-drawer",
        selectors: [
          "#component-showcase[data-review-state='request-drawer'].drawer-open",
          "[data-role='request-log-detail-drawer-side']",
          "#request-log-detail-sidebar[role='dialog']"
        ]
      )
    ] ++
      ComponentShowcaseStats.catalog_entries() ++
      [
        entry(
          "5.14-policy-dialog",
          "### 5.14 Policy editor dialog and wizard",
          "policy_editor_dialog/1",
          PolicyEditorComponents,
          :policy_editor_dialog,
          availability: :interactive,
          review_state: "policy-dialog",
          selectors: ["#showcase-policy-editor[open]", "#showcase-policy-editor-tabs"]
        ),
        private_entry(
          "5.14-policy-mode-leaf",
          "### 5.14 Policy editor dialog and wizard",
          "policy_mode_card/1",
          ApiKeyWizardComponents,
          :policy_mode_card,
          "Policy mode cards are private leaves rendered only through the real API-key wizard."
        ),
        entry("5.15-filter-date", section_515(), "filter_form/1", AdminComponents, :filter_form,
          exports: [{AdminComponents, :cally_date_filter, 1}],
          selectors: ["#showcase-filter-form", "#showcase_filter_from-picker"]
        ),
        entry("5.15-empty-state", section_515(), "empty_state/1", AdminComponents, :empty_state,
          selectors: ["#showcase-empty-state"]
        ),
        entry(
          "5.15-notices",
          section_515(),
          "extended_notice/1",
          AdminComponents,
          :extended_notice,
          selectors: Enum.map(~w(info success warning error), &"#showcase-notice-#{&1}")
        ),
        entry("5.15-actions", section_515(), "action_button/1", AdminComponents, :action_button,
          exports: [{AdminComponents, :diagnostic_popover, 1}],
          selectors:
            Enum.map(~w(primary secondary danger ghost disabled link), &"#showcase-button-#{&1}") ++
              ["#showcase-diagnostic-popover"]
        ),
        entry("5.15-flash", section_515(), "flash_group/1", Layouts, :flash_group,
          exports: [{CoreComponents, :flash, 1}],
          availability: :interactive,
          review_state: "flash",
          selectors: [
            "#component-showcase[data-review-state='flash']",
            "#flash-group",
            "#flash-info[role='alert']"
          ]
        ),
        entry("5.15-theme-toggle", section_515(), "theme_toggle/1", Layouts, :theme_toggle,
          selectors: ["#showcase-theme-toggle.card.relative.flex.flex-row.rounded-full"]
        ),
        entry("5.15-inputs", section_515(), "input/1", CoreComponents, :input,
          exports: [{CoreComponents, :otp_input, 1}],
          selectors:
            Enum.map(~w(text select textarea checkbox error), &"#showcase-input-#{&1}") ++
              ["#showcase-input-otp_otp"]
        ),
        product_entry(
          "5.16-cockpit",
          "### 5.16 Upstream cockpit (detail-page pattern)",
          "cockpit_components.ex",
          UpstreamCockpitComponents,
          :cockpit_page,
          "The authenticated cockpit composite remains on its real fixture-backed route; this task explicitly preserves concurrent cockpit work."
        ),
        entry("6.1-shell", "### 6.1 Shell and toolbar", "Layouts.app", Layouts, :app,
          selectors: ["#component-showcase[data-review-state='catalog']"]
        ),
        entry("6.1-toolbar", "### 6.1 Shell and toolbar", "Toolbar.toolbar", Toolbar, :toolbar,
          selectors: ["#observatory-toolbar"]
        ),
        entry(
          "6.2-telemetry",
          "### 6.2 Telemetry grid",
          "Telemetry.telemetry",
          Telemetry,
          :telemetry,
          selectors: ["#observatory-overview", "#observatory-models"]
        ),
        entry("6.2-activity", "### 6.2 Telemetry grid", "Activity.activity", Activity, :activity,
          selectors: ["#observatory-activity", "#observatory-traffic", "#observatory-outcomes"]
        ),
        entry(
          "6.3-states",
          "### 6.3 Window control and refresh states",
          "States.state",
          States,
          :state,
          selectors: state_selectors()
        )
      ]
  end

  defp entry(id, section, source, module, function, opts),
    do: ComponentShowcaseCatalog.entry(id, section, source, module, function, opts)

  defp private_entry(id, section, source, module, function, reason),
    do: ComponentShowcaseCatalog.private_entry(id, section, source, module, function, reason)

  defp product_entry(id, section, source, module, function, reason),
    do: ComponentShowcaseCatalog.product_entry(id, section, source, module, function, reason)

  defp section_515,
    do: "### 5.15 Filters, empty state, notices, buttons, flash, theme toggle"

  defp state_selectors do
    Enum.map(
      ~w(loading empty stale error),
      &"#observatory-state-#{&1}"
    ) ++ ["#observatory-state-empty-anatomy"]
  end
end
