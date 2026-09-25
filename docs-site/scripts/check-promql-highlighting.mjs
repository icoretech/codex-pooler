import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { createRenderer } from "@astrojs/starlight/expressive-code";
import ecConfig from "../ec.config.mjs";

const warnings = [];
const { ec } = await createRenderer({
  ...ecConfig,
  themes: ["github-light", "github-dark"],
  logger: {
    warn: (message) => warnings.push(message),
    error: (message) => warnings.push(message),
  },
});

const nodes = (node) => [node, ...(node.children ?? []).flatMap(nodes)];
const text = (node) =>
  node.type === "text" ? node.value : (node.children ?? []).map(text).join("");

async function render(code) {
  const result = await ec.render({ code, language: "promql" });
  const tree = nodes(result.renderedGroupAst);
  const copyButton = tree.find((node) => node.properties?.dataCode !== undefined);
  // Expressive Code's copy handler decodes DEL separators back to newlines.
  const copiedText = copyButton?.properties.dataCode.replace(/\u007f/g, "\n");
  assert.equal(copiedText, code, "highlighting must preserve copied query text");
  return tree;
}

// Exercise real tokenization and both theme styles, including the upstream
// grammar's substring and comment/string precedence regression boundaries.
const sample = 'sum by (namespace) (rate(summary_count{namespace="sum by # rate"}[5m])) >= 0 or oncall_total # max(rate(oncall_total))';
const tree = await render(sample);
const spans = tree.filter((node) => node.tagName === "span" && node.properties?.style);
const style = (token) => {
  const span = spans.find((node) => text(node) === token);
  assert.ok(span, `missing intact highlighted token: ${token}`);
  assert.match(span.properties.style, /--0:/, "light-theme token style");
  assert.match(span.properties.style, /--1:/, "dark-theme token style");
  return span.properties.style;
};

assert.notEqual(style("sum"), style("summary_count"), "metric names must not match keyword substrings");
assert.equal(style("summary_count"), style("oncall_total"), "selector keywords must not split metric names");
assert.notEqual(style("rate"), style("summary_count"), "functions must be highlighted");
assert.notEqual(style('"sum by # rate"'), style("sum"), "keywords inside strings must stay strings");
assert.notEqual(style("# max(rate(oncall_total))"), style("rate"), "comments must not tokenize as functions");
assert.notEqual(style("[5m]"), style("summary_count"), "duration ranges must be highlighted");
assert.equal(style(">="), style("sum"), "comparison operators must be highlighted");

async function markdownFiles(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const url = new URL(entry.name + (entry.isDirectory() ? "/" : ""), directory);
    if (entry.isDirectory()) files.push(...(await markdownFiles(url)));
    else if (/\.mdx?$/.test(entry.name)) files.push(url);
  }
  return files;
}

let count = 0;
for (const file of await markdownFiles(new URL("../src/content/docs/", import.meta.url))) {
  const source = await readFile(file, "utf8");
  for (const match of source.matchAll(/^```(\w+)[^\n]*\n([\s\S]*?)\n```/gm)) {
    if (file.pathname.endsWith("/monitoring/promql.mdx")) {
      assert.equal(match[1], "promql", "PromQL recipes must use the registered language");
    }
    if (match[1] === "promql") {
      await render(match[2]);
      count += 1;
    }
  }
}

assert.ok(count > 0, "no PromQL examples found");
assert.deepEqual(warnings, [], "PromQL rendering emitted warnings or errors");
console.log(`PromQL highlighting: PASS (${count} documentation blocks, light/dark styles, exact copy text)`);
