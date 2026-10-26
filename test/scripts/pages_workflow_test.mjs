import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { matchesGlob } from "node:path";
import test from "node:test";

const workflow = readFileSync(
	new URL("../../.github/workflows/pages.yml", import.meta.url),
	"utf8",
);

const triggers = workflow.match(/^on:\n([\s\S]*?)(?=^\S)/m)?.[1];
assert.ok(triggers, "missing workflow triggers");
const pushTrigger = triggers.match(/^ {2}push:\n((?: {4,}.+\n|\n)+)/m)?.[1];
assert.ok(pushTrigger, "missing push trigger");

const listValues = (list) =>
	[...list.matchAll(/^ {6}- (.+)$/gm)].map((match) =>
		match[1].replace(/^(['"])(.*)\1$/, "$2"),
	);

test("Pages admits only main pushes, excluding PRs, tags and manual dispatch before jobs start", () => {
	assert.deepEqual(
		[...triggers.matchAll(/^ {2}(\w+):/gm)].map((match) => match[1]),
		["push"],
	);
	const branches = pushTrigger.match(/^ {4}branches:\n((?: {6}- .+\n)+)/m);
	assert.ok(branches, "missing push branch filter");
	assert.deepEqual(listValues(branches[1]), ["main"]);
	assert.doesNotMatch(triggers, /^ {4}(tags|tags-ignore|branches-ignore):/m);
});

test("Pages deployment requires the successful build and its uploaded artifact", () => {
	assert.match(workflow, / {2}deploy:\n[\s\S]*? {4}needs: build\n/);
	assert.match(workflow, /uses: actions\/upload-pages-artifact@/);
	assert.match(workflow, /name: github-pages-\$\{\{ github.run_attempt \}\}/);
	assert.match(
		workflow,
		/artifact_name: github-pages-\$\{\{ github.run_attempt \}\}/,
	);
});

for (const trigger of ["push", "pull_request"]) {
	test(`Pages policy changes execute their contract tests on ${trigger}`, () => {
		const policy = readFileSync(
			new URL("../../.github/workflows/release-policy.yml", import.meta.url),
			"utf8",
		);
		const paths = policy.match(
			new RegExp(`^  ${trigger}:\\n    paths:\\n((?:      - .+\\n)+)`, "m"),
		);
		assert.ok(paths, `missing ${trigger} paths`);
		for (const path of [
			".github/workflows/pages.yml",
			"test/scripts/pages_workflow_test.mjs",
		])
			assert.ok(
				paths[1].split("\n").includes(`      - '${path}'`),
				`missing ${path}`,
			);
		assert.match(policy, /node --test test\/scripts\/\*_test\.mjs/);
	});
}

const triggeredByMainPush = (changedPaths) => {
	const paths = pushTrigger.match(/^ {4}paths:\n((?: {6}- .+\n)+)/m);
	assert.ok(paths, "missing push path trigger");
	const patterns = listValues(paths[1]);
	return changedPaths.some((path) =>
		patterns.some((pattern) => matchesGlob(path, pattern)),
	);
};

for (const path of [
	"docs-site/src/content/docs/deployment/docker-compose.mdx",
	"docs-site/src/content/docs/clients/example.mdx",
	"docs-site/package-lock.json",
	".release-please-manifest.json",
	".github/workflows/pages.yml",
]) {
	test(`Pages publishes main changes to ${path}`, () => {
		assert.equal(triggeredByMainPush([path]), true);
	});
}

test("unrelated main changes do not register Pages", () => {
	assert.equal(
		triggeredByMainPush(["mix.lock", "lib/sample.ex", "CHANGELOG.md"]),
		false,
	);
});
