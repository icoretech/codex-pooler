import assert from "node:assert/strict";
import test from "node:test";

import { buildPublicDashboard } from "../dashboards/runtime-triage.mjs";

test("stat panels retain their last non-null reading with the installed SDK", () => {
  const dashboard = buildPublicDashboard();
  const stats = dashboard.panels.filter((panel) => panel.type === "stat");

  assert.ok(stats.length > 0);
  for (const panel of stats) {
    assert.deepEqual(panel.options.reduceOptions, {
      values: false,
      calcs: ["lastNotNull"],
    }, panel.title);
  }
});
