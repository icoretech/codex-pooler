import assert from "node:assert/strict";
import test from "node:test";

import { hookLabel, interpolateLabel, readHookLabels } from "./hook_labels.mjs";

test("reads only an object label contract and falls back for missing or malformed input", () => {
	assert.deepEqual(readHookLabels('{"copied":"已复制"}'), { copied: "已复制" });
	for (const value of [undefined, "", "invalid-json", "null", '"text"', "[]"]) {
		assert.deepEqual(readHookLabels(value), {});
	}
	for (const labels of [{}, { copy: "" }, { copy: 3 }, { copy: null }]) {
		assert.equal(hookLabel(labels, "copy", "Copy"), "Copy");
	}
	assert.equal(hookLabel({ copy: "复制" }, "copy", "Copy"), "复制");
});

test("interpolates named placeholders in translated order without replacing literal currency", () => {
	assert.equal(
		hookLabel({ ago: "%{duration} 前（%{source}）" }, "ago", "%{duration} ago", {
			duration: "2h 15m",
			source: "$& <runtime>",
		}),
		"2h 15m 前（$& <runtime>）",
	);
	assert.equal(interpolateLabel("%{value} / %{value}", { value: 7 }), "7 / 7");
	assert.equal(interpolateLabel("%{missing}", {}), "%{missing}");
});
