// Writes the public starter dashboard to public/, and verifies the result is
// something an outside reader can actually import.
//
// The previous artifact was a Grafana v2 resource export whose layout was
// empty: panels defined, none placed, no schemaVersion. It imported as a blank
// dashboard and stayed broken because nothing looked at it. These assertions
// run on every regeneration so that cannot recur silently.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { buildPublicDashboard } from "./runtime-triage.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const target = resolve(here, "../public/operators/monitoring/codex-pooler-runtime-triage.json");

const built = buildPublicDashboard();
const serialized = JSON.stringify(built);
const problems = [];
const require_ = (condition, message) => {
  if (!condition) problems.push(message);
};

// Importability: the classic paste-box path needs all three. A resource export
// satisfies none of them.
require_(Array.isArray(built.panels) && built.panels.length > 0, "no panels were emitted");
require_(typeof built.schemaVersion === "number", "no schemaVersion was emitted");
require_(built.spec === undefined, "output is a Grafana resource, not a classic dashboard");

// Portability and sanitization: the reader must be prompted for a datasource,
// and nothing may name our deployment.
require_((built.__inputs ?? []).length > 0, "no __inputs, so the datasource would be hardcoded");
require_(
  !/"uid":\s*"(?!\$\{)[A-Za-z0-9_-]{8,}"/.test(serialized),
  "a concrete datasource uid leaked into the output",
);
require_(built.metadata === undefined, "server-managed metadata leaked into the output");
require_(built.status === undefined, "server-managed status leaked into the output");

// Visible controls must affect a query, datasource, link, annotation, or a
// dependent variable. Otherwise the dashboard offers an operator a control
// that cannot change anything.
const templateVariables = built.templating?.list ?? [];
const variableUsage = JSON.stringify({
  panels: built.panels,
  annotations: built.annotations,
  links: built.links,
  templating: templateVariables,
});

for (const variable of templateVariables) {
  const escapedName = variable.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const reference = new RegExp(
    `\\$(?:${escapedName}(?![A-Za-z0-9_])|\\{${escapedName}(?::[^}]*)?\\})`,
  );

  require_(reference.test(variableUsage), `template variable "${variable.name}" is never referenced`);
}

if (problems.length > 0) {
  console.error("build:dashboard FAILED");
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

const rendered = `${JSON.stringify(built, null, 2)}\n`;
const panels = built.panels.filter((panel) => panel.type !== "row");
const metrics = new Set(serialized.match(/codex_pooler_[a-z0-9_]+/g) ?? []);
const summary = `${panels.length} panels, schemaVersion ${built.schemaVersion}, ${metrics.size} codex_pooler metrics`;

// --check keeps the committed download honest: it fails when someone edits the
// panel inventory without regenerating, or edits the JSON by hand.
if (process.argv.includes("--check")) {
  let committed;
  try {
    committed = readFileSync(target, "utf8");
  } catch {
    console.error("build:dashboard --check FAILED: the published dashboard is missing");
    process.exit(1);
  }

  if (committed !== rendered) {
    console.error(
      "build:dashboard --check FAILED: the published dashboard is stale.\nRegenerate with: npm run build:dashboard",
    );
    process.exit(1);
  }

  console.log(`build:dashboard --check ok (${summary})`);
} else {
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, rendered);
  console.log(`build:dashboard wrote ${summary}`);
}
