import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
	copyFileSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

const script = resolve("scripts/i18n/open-reviewed-pr.sh");
const catalog = "priv/gettext/zh_CN/LC_MESSAGES/default.po";

function fixture(t) {
	const root = mkdtempSync(join(tmpdir(), "translation-pr-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const repo = join(root, "repo");
	const bin = join(root, "bin");
	const remote = join(root, "remote.git");
	const calls = join(root, "calls.jsonl");
	mkdirSync(join(repo, "priv/gettext/zh_CN/LC_MESSAGES"), { recursive: true });
	mkdirSync(bin);
	const git = (...args) =>
		execFileSync("git", args, {
			cwd: repo,
			encoding: "utf8",
			stdio: "pipe",
		}).trim();
	git("init", "--quiet", "--initial-branch=main");
	git("config", "user.name", "Fixture");
	git("config", "user.email", "fixture@example.com");
	git("config", "core.hooksPath", "/dev/null");
	for (const domain of ["default", "errors", "emails"])
		writeFileSync(
			join(repo, `priv/gettext/zh_CN/LC_MESSAGES/${domain}.po`),
			"baseline\n",
		);
	git("add", ".");
	git("commit", "--quiet", "-m", "fixture");
	const initial = git("rev-parse", "HEAD");
	git("init", "--bare", "--quiet", remote);
	git("remote", "add", "origin", remote);
	git("push", "--quiet", "origin", "main");
	copyFileSync(script, join(root, "open-reviewed-pr.sh"));
	writeFileSync(
		join(bin, "gh"),
		`#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.CALLS, JSON.stringify(args)+'\\n');
if (args[0] === 'pr' && args[1] === 'list') console.log(process.env.EXISTING || '0');
if (args[0] === 'pr' && args[1] === 'create') {
  fs.copyFileSync(args[args.indexOf('--body-file') + 1], process.env.PR_BODY);
  console.log('https://github.com/example-org/sample-app/pull/1');
}
if (args[0] === 'workflow') process.exit(Number(process.env.DISPATCH_EXIT || '0'));
`,
		{ mode: 0o755 },
	);
	return {
		root,
		repo,
		git,
		initial,
		change: () => writeFileSync(join(repo, catalog), "reviewed\n"),
		calls: () =>
			existsSync(calls)
				? readFileSync(calls, "utf8").trim().split("\n").map(JSON.parse)
				: [],
		run: (overrides = {}) =>
			spawnSync("bash", [join(root, "open-reviewed-pr.sh")], {
				cwd: repo,
				encoding: "utf8",
				env: {
					...process.env,
					PATH: `${bin}:${process.env.PATH}`,
					CALLS: calls,
					PR_BODY: join(root, "body.md"),
					GITHUB_ACTIONS: "true",
					GITHUB_REPOSITORY: "icoretech/codex-pooler",
					GITHUB_REF: "refs/heads/main",
					GITHUB_RUN_ID: "12345",
					GITHUB_RUN_ATTEMPT: "1",
					...overrides,
				},
			}),
	};
}

test("reviewed catalogs produce one normal branch commit and explicitly dispatched PR validation", (t) => {
	// Given a validated reviewed catalog change on main.
	const f = fixture(t);
	f.change();
	// When the actual publishing CLI runs against a local bare Git remote.
	const result = f.run();
	// Then only the catalog is committed, main is preserved and Development targets that branch.
	assert.equal(result.status, 0, result.stderr);
	const branch = "feat/tolgee-translations-12345-1";
	assert.equal(f.git("rev-parse", "main"), f.initial);
	assert.equal(
		f.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"),
		catalog,
	);
	assert.equal(
		f.git("rev-parse", `origin/${branch}`),
		f.git("rev-parse", "HEAD"),
	);
	assert.deepEqual(
		f.calls().find((args) => args[0] === "workflow"),
		[
			"workflow",
			"run",
			"development.yml",
			"--repo",
			"icoretech/codex-pooler",
			"--ref",
			branch,
			"--field",
			`expected_sha=${f.git("rev-parse", "HEAD")}`,
		],
	);
	assert.equal(
		f.calls().filter((args) => args[0] === "pr" && args[1] === "create").length,
		1,
	);
	assert.doesNotMatch(readFileSync(join(f.root, "body.md"), "utf8"), /\\n/);
});

test("an unchanged pull creates no branch or remote API activity", (t) => {
	// Given a clean main checkout with no reviewed changes.
	const f = fixture(t);
	// When the CLI runs.
	const result = f.run();
	// Then Git and the remote API are unchanged.
	assert.equal(result.status, 0, result.stderr);
	assert.equal(f.git("branch", "--show-current"), "main");
	assert.deepEqual(f.calls(), []);
});

test("an existing translation PR prevents duplicate publication", (t) => {
	// Given newer reviewed text while a previous PR remains open.
	const f = fixture(t);
	f.change();
	// When the service reports the open PR.
	const result = f.run({ EXISTING: "1" });
	// Then the current PR is left untouched without a new branch.
	assert.equal(result.status, 0, result.stderr);
	assert.equal(f.git("rev-parse", "HEAD"), f.initial);
	assert.equal(f.calls().length, 1);
});

test("a failed Development dispatch is a failed publish operation", (t) => {
	// Given a valid catalog change whose explicit CI dispatch is refused.
	const f = fixture(t);
	f.change();
	// When the remote service refuses dispatch before PR creation.
	const result = f.run({ DISPATCH_EXIT: "7" });
	// Then the workflow fails rather than claiming validated PR success.
	assert.equal(result.status, 7);
	assert.equal(f.calls().at(-1)[0], "workflow");
	assert.equal(
		f.calls().some((args) => args[0] === "pr" && args[1] === "create"),
		false,
	);
});

for (const [name, prepare, overrides] of [
	[
		"foreign changes",
		(f) => writeFileSync(join(f.repo, "foreign.txt"), "unrelated"),
		{},
	],
	[
		"staged changes",
		(f) => {
			f.change();
			f.git("add", catalog);
		},
		{},
	],
	["fork", () => {}, { GITHUB_REPOSITORY: "example-org/fork" }],
	["branch", () => {}, { GITHUB_REF: "refs/heads/feat/unrelated" }],
	["invalid identity", () => {}, { GITHUB_RUN_ID: "1;false" }],
]) {
	test(`unsafe ${name} is refused before Git or remote mutation`, (t) => {
		// Given a checkout outside the publication contract.
		const f = fixture(t);
		prepare(f);
		// When the CLI receives that input.
		const result = f.run(overrides);
		// Then no branch, commit, or API call is made.
		assert.notEqual(result.status, 0);
		assert.equal(f.git("rev-parse", "HEAD"), f.initial);
		assert.deepEqual(f.calls(), []);
	});
}
