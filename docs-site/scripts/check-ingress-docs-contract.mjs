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

const forbidden = (text, expression, file) => {
  if (expression.test(text)) {
    throw new Error(`${file} contains stale ingress policy syntax: ${expression}`);
  }
};

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
  resolverTest: "test/codex_pooler_web/plugs/runtime_ingress/forwarded_client_ip_test.exs"
};

const [configuration, contract, matrix, resolverTest] = await Promise.all(
  Object.values(files).map(read)
);

verifyStalePolicyIsRejected();

for (const marker of [
  "### Forwarded client IP policy",
  "default `x_forwarded_for` with depth `0`",
  "Depth `2` selects the second XFF entry from the right",
  "The directly connected peer counts toward the configured proxy depth, but is not an XFF entry.",
  "duplicate XFF field occurrences are combined in wire order",
  "exactly one X-Real-IP field",
  "settings are unavailable on a cold start, runtime and MCP requests return `503`",
  "code `1008`",
  "codex_pooler_ingress_firewall_denied_count",
  "scope` and `reason`"
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

required(
  resolverTest,
  "positional depth selects from the right without parsing entries to its left",
  files.resolverTest
);

for (const [file, text] of [
  [files.configuration, configuration],
  [files.contract, contract]
]) {
  forbidden(
    text,
    /forwarded_client_ip_source\s*[:=]\s*:none|X-Forwarded-For takes precedence over X-Real-IP|x-forwarded-for then x-real-ip fallback/i,
    file
  );
}

process.stdout.write("ingress docs contract: PASS\n");
