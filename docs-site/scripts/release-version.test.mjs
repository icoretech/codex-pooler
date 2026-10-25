import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createRenderer } from "@astrojs/starlight/expressive-code";
import ecConfig from "../ec.config.mjs";
import { renderReleaseVersion } from "../plugins/release-version.mjs";
import manifest from "../../.release-please-manifest.json" with { type: "json" };

const guide = await readFile(new URL("../src/content/docs/deployment/docker-compose.mdx", import.meta.url), "utf8");
const source = guide.match(/```bash\n([^`]*__CODEX_POOLER_RELEASE_VERSION__[^`]*)\n```/)?.[1];
assert.ok(source, "the Compose guide must have a manifest-derived release snippet");
const expected = `export CODEX_POOLER_IMAGE=ghcr.io/icoretech/codex-pooler
export CODEX_POOLER_IMAGE_TAG=${manifest["."]}
scripts/self-host/generate-env.sh`;
const nodes = (node) => [node, ...(node.children ?? []).flatMap(nodes)];
const text = (node) => node.type === "text" ? node.value : (node.children ?? []).map(text).join("");

test("release snippet renders the manifest version before highlighting and copying", async () => {
  const { ec } = await createRenderer(ecConfig);
  const result = await ec.render({ code: source, language: "bash" });
  const tree = nodes(result.renderedGroupAst);
  const code = tree.find((node) => node.tagName === "code");
  const copy = tree.find((node) => node.properties?.dataCode !== undefined);
  assert.ok(code);
  assert.ok(copy);
  assert.equal(copy.properties.dataCode.replace(/\u007f/g, "\n"), expected);
  assert.ok(text(code).includes(`CODEX_POOLER_IMAGE_TAG=${manifest["."]}`));
  assert.ok(!text(code).includes("__CODEX_POOLER_RELEASE_VERSION__"));
});

test("Markdown export uses the same release substitution without rewriting ordinary content", () => {
  assert.equal(renderReleaseVersion(source), expected);
  assert.equal(renderReleaseVersion(source, "1.2.3"), expected.replace(manifest["."], "1.2.3"));
  assert.equal(renderReleaseVersion("ordinary documentation 0.0.0"), "ordinary documentation 0.0.0");
});

for (const version of [null, "", "   ", 123]) {
  test(`release rendering refuses an invalid manifest value: ${JSON.stringify(version)}`, () => {
    assert.throws(() => renderReleaseVersion(source, version), { name: "TypeError", message: "release manifest must provide a nonempty version" });
  });
}
