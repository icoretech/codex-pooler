// Builds the public starter Grafana dashboard with the Grafana foundation SDK.
//
// The published artifact is generated from code rather than exported from our
// Grafana, because a UI export carries what belongs to our deployment:
// server-managed metadata, saved variable selections, concrete datasource
// UIDs, and links to dashboards a reader does not have. Generating it means
// the download is defined by this file plus panels.mjs, neither of which
// contains any of that, and the reader is prompted for their own Prometheus
// on import.
//
// Regenerate with: npm run build:dashboard

import * as common from "@grafana/grafana-foundation-sdk/common";
import * as dashboard from "@grafana/grafana-foundation-sdk/dashboard";
import * as prometheus from "@grafana/grafana-foundation-sdk/prometheus";
import * as stat from "@grafana/grafana-foundation-sdk/stat";
import * as table from "@grafana/grafana-foundation-sdk/table";
import * as timeseries from "@grafana/grafana-foundation-sdk/timeseries";

import { PANELS } from "./panels.mjs";

// The import input a reader fills in. Never a concrete UID.
export const DATASOURCE_INPUT = "DS_PROMETHEUS";
const DATASOURCE = { type: "prometheus", uid: `\${${DATASOURCE_INPUT}}` };

const BUILDERS = { timeseries, stat, table };

function buildPanel(spec) {
  const module = BUILDERS[spec.type];
  if (!module) throw new Error(`unsupported panel type: ${spec.type}`);

  const panel = new module.PanelBuilder().title(spec.title).datasource(DATASOURCE);

  if (spec.description) panel.description(spec.description);
  if (spec.unit) panel.unit(spec.unit);

  if (spec.type === "timeseries") {
    panel
      .fillOpacity(8)
      .showPoints(common.VisibilityMode.Never)
      .legend(
        new common.VizLegendOptionsBuilder()
          .displayMode(common.LegendDisplayMode.Table)
          .placement(common.LegendPlacement.Bottom)
          .calcs(["lastNotNull", "max"])
          .showLegend(true),
      )
      .tooltip(new common.VizTooltipOptionsBuilder().mode(common.TooltipDisplayMode.Multi));
  }

  for (const query of spec.queries) {
    panel.withTarget(
      new prometheus.DataqueryBuilder()
        .expr(query.expr)
        .legendFormat(query.legend)
        .range()
        .editorMode(prometheus.QueryEditorMode.Code),
    );
  }

  return panel;
}

function withVariables(builder) {
  return builder
    .withVariable(
      new dashboard.QueryVariableBuilder("cluster")
        .label("Cluster")
        .datasource(DATASOURCE)
        .query("label_values(kube_node_info, cluster)")
        .refresh(dashboard.VariableRefresh.OnDashboardLoad),
    )
    .withVariable(
      new dashboard.QueryVariableBuilder("namespace")
        .label("Namespace")
        .datasource(DATASOURCE)
        .query('label_values(up{job="codex-pooler-app"}, namespace)')
        .refresh(dashboard.VariableRefresh.OnDashboardLoad),
    )
    .withVariable(
      new dashboard.QueryVariableBuilder("pod")
        .label("Pod")
        .datasource(DATASOURCE)
        .query('label_values(up{job="codex-pooler-app", namespace="$namespace"}, pod)')
        .refresh(dashboard.VariableRefresh.OnDashboardLoad)
        .multi(true)
        .includeAll(true),
    );
}

export function buildDashboard() {
  const builder = new dashboard.DashboardBuilder("Codex Pooler / Runtime Triage")
    .description(
      "Starter triage view for Codex Pooler runtime health: memory pressure, gateway admission, HTTP traffic, database query pressure, and gateway outcomes.",
    )
    .tags(["codex-pooler", "kubernetes"])
    .editable()
    .tooltip(dashboard.DashboardCursorSync.Crosshair)
    .refresh("1m")
    .time({ from: "now-6h", to: "now" })
    .timezone("browser");

  withVariables(builder);

  for (const spec of PANELS) {
    if (spec.row) {
      builder.withRow(new dashboard.RowBuilder(spec.row));
      continue;
    }
    builder.withPanel(buildPanel(spec).height(spec.h).span(spec.w));
  }

  return builder;
}

// __inputs/__requires are the classic import contract: they make Grafana ask
// the reader which Prometheus to bind, instead of silently pointing at a UID
// that only exists in our cluster. The SDK models the dashboard, not the
// import envelope, so they are attached to the built object.
export function buildPublicDashboard() {
  return {
    __inputs: [
      {
        name: DATASOURCE_INPUT,
        label: "Prometheus",
        description: "Prometheus data source scraping codex-pooler",
        type: "datasource",
        pluginId: "prometheus",
        pluginName: "Prometheus",
      },
    ],
    __requires: [
      { type: "grafana", id: "grafana", name: "Grafana", version: "11.0.0" },
      { type: "datasource", id: "prometheus", name: "Prometheus", version: "1.0.0" },
    ],
    ...buildDashboard().build(),
  };
}
