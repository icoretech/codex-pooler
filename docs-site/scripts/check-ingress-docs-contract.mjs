import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../..", import.meta.url));

const read = async (path) => readFile(new URL(path, `file://${root}/`), "utf8");
const normalizeWhitespace = (text) => text.replace(/\s+/g, " ").trim().toLowerCase();

const required = (text, marker, file) => {
  if (!normalizeWhitespace(text).includes(normalizeWhitespace(marker))) {
    throw new Error(`${file} is missing required ingress policy marker: ${marker}`);
  }
};

const firewallMetric = "codex_pooler_ingress_firewall_denied_count";
const firewallSelectors = [
  [/namespace\s*=\s*"\$namespace"/, 'namespace="$namespace"'],
  [/job\s*=\s*"codex-pooler-app"/, 'job="codex-pooler-app"'],
  [/pod\s*=~\s*"\$\{pod:regex\}"/, 'pod=~"${pod:regex}"']
];

const firewallQueryIssue = (expression) => {
  if (typeof expression !== "string") return "target expression is not a string";

  if (!/sum\s+by\s*\(\s*scope\s*,\s*reason\s*\)\s*\(\s*rate\s*\(/.test(expression)) {
    return "missing sum by (scope, reason) rate aggregation";
  }

  const selectorMatch = expression.match(
    /codex_pooler_ingress_firewall_denied_count\{(.*)\}\s*\[\$__rate_interval\]/
  );

  if (!selectorMatch) return "missing firewall metric selector or rate interval";

  for (const [pattern, selector] of firewallSelectors) {
    if (!pattern.test(selectorMatch[1])) return `missing selector ${selector}`;
  }

  return null;
};

const firewallQueryFromDashboard = (dashboard) => {
  if (!dashboard || typeof dashboard !== "object" || !Array.isArray(dashboard.panels)) {
    throw new Error("generated dashboard has no panels array");
  }

  const expressions = dashboard.panels.flatMap((panel) =>
    Array.isArray(panel?.targets)
      ? panel.targets.map((target) => target?.expr).filter((expression) => typeof expression === "string")
      : []
  );
  const firewallExpressions = expressions.filter((expression) => expression.includes(firewallMetric));

  if (firewallExpressions.length !== 1) {
    throw new Error(`generated dashboard must contain one ${firewallMetric} target`);
  }

  return firewallExpressions[0];
};

const verifyFirewallDashboardQuery = (dashboard) => {
  const expression = firewallQueryFromDashboard(dashboard);
  const issue = firewallQueryIssue(expression);

  if (issue) throw new Error(`generated firewall dashboard query is invalid: ${issue}`);
};

const verifyMalformedFirewallQueriesAreRejected = () => {
  const validExpression =
    'sum by (scope, reason) (rate(codex_pooler_ingress_firewall_denied_count{namespace="$namespace", job="codex-pooler-app", pod=~"${pod:regex}"}[$__rate_interval]))';
  const malformedExpressions = [
    validExpression.replace('namespace="$namespace", ', ""),
    validExpression.replace('job="codex-pooler-app"', 'job=~"codex-pooler-app"'),
    validExpression.replace('pod=~"${pod:regex}"', 'pod="${pod:regex}"')
  ];

  for (const expression of malformedExpressions) {
    if (!firewallQueryIssue(expression)) {
      throw new Error("malformed firewall dashboard selector was accepted");
    }
  }
};

const forbidden = (text, expression, file) => {
  if (expression.test(text)) {
    throw new Error(`${file} contains stale ingress policy syntax: ${expression}`);
  }
};

const staleFirewallProtectsMetrics =
  /\bruntime firewall\s+(?:protects|covers|applies to)\s+`?\/metrics\b|\b\/metrics\s+(?:is\s+)?(?:protected|covered)\s+by\s+(?:the\s+)?runtime firewall\b/i;

const staleUnconditionalPrunedHelper404 =
  /\bpruned(?:\s+(?:app-server|runtime))?\s+helper(?:\s+(?:candidate|route)s?)?[^.\n]{0,120}(?:\b(?:always|unconditional(?:ly)?)\b[^.\n]{0,120}\b404\b|\b404\b[^.\n]{0,120}\b(?:always|unconditional(?:ly)?)\b)/i;

const verifyStalePolicyIsRejected = () => {
  const stalePolicies = [
    "forwarded_client_ip_source: :none",
    "X-Forwarded-For takes precedence over X-Real-IP",
    "x-forwarded-for then x-real-ip fallback"
  ];

  for (const stalePolicy of stalePolicies) {
    let rejected = false;

    try {
      forbidden(
        stalePolicy,
        /forwarded_client_ip_source\s*:\s*:none|X-Forwarded-For takes precedence over X-Real-IP|x-forwarded-for then x-real-ip fallback/i,
        "stale-policy fixture"
      );
    } catch {
      rejected = true;
    }

    if (!rejected) {
      throw new Error(`stale ingress policy was accepted: ${stalePolicy}`);
    }
  }
};

const files = {
  configuration: "docs-site/src/content/docs/getting-started/configuration.mdx",
  contract: "docs-site/src/content/_docs-contract.md",
  matrix: "test/support/compatibility_matrix.ex",
  dashboard: "docs-site/public/operators/monitoring/codex-pooler-runtime-triage.json"
};

const [configuration, contract, matrix, dashboardText] = await Promise.all(Object.values(files).map(read));
const dashboard = JSON.parse(dashboardText);

verifyStalePolicyIsRejected();
verifyMalformedFirewallQueriesAreRejected();
verifyFirewallDashboardQuery(dashboard);

for (const marker of [
  "### Forwarded client IP policy",
  "default `x_forwarded_for` with depth `0`",
  "Depth `2` selects the second XFF entry from the right",
  "The directly connected peer counts toward the configured proxy depth, but is not an XFF entry.",
  "duplicate XFF field occurrences are combined in wire order",
  "exactly one X-Real-IP field",
  "settings are unavailable on a cold start, runtime and MCP requests return `503`",
  "code `1008`"
]) {
  required(configuration, marker, files.configuration);
}

for (const marker of [
  "## Runtime ingress firewall contract",
  "forwarded_client_ip_source",
  "forwarded_proxy_depth",
  "forwarded_client_ip_test.exs",
  "settings_unavailable",
  "websocket_revoked"
]) {
  required(contract, marker, files.contract);
}

for (const marker of [
  "default_source: :x_forwarded_for",
  "default_proxy_depth: 0",
  "positional_depth: %{ range: 1..16, selected_entry: :nth_from_right",
  "cold_settings: %{status: 503",
  "revoked_websocket: %{ close_code: 1008",
  "metric: \"codex_pooler_ingress_firewall_denied_count\""
]) {
  required(matrix, marker, files.matrix);
}

for (const [file, text] of [
  [files.configuration, configuration],
  [files.contract, contract]
]) {
  forbidden(
    text,
    /forwarded_client_ip_source\s*[:=]\s*:none|X-Forwarded-For takes precedence over X-Real-IP|x-forwarded-for then x-real-ip fallback/i,
    file
  );
  forbidden(text, staleFirewallProtectsMetrics, file);
  forbidden(text, staleUnconditionalPrunedHelper404, file);
}

process.stdout.write(
  "ingress docs contract: PASS (firewall dashboard query structurally verified: sum by (scope, reason), namespace, job, pod selectors)\n"
);
