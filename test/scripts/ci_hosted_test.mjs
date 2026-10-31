import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
	copyFileSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	realpathSync,
	rmSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

function fixture(t) {
	const root = mkdtempSync(join(tmpdir(), "pooler-hosted-"));
	const repo = join(root, "repo");
	const runner = join(root, "runner");
	const bin = join(root, "bin");
	const calls = join(root, "calls.jsonl");
	const state = join(root, "docker.json");
	for (const directory of [join(repo, "scripts/ci"), runner, bin])
		mkdirSync(directory, { recursive: true });
	t.after(() => rmSync(root, { recursive: true, force: true }));
	for (const name of [
		"hosted.sh",
		"resources.sh",
		"snapshot.mjs",
		"source-identity.mjs",
		"Dockerfile",
	])
		copyFileSync(resolve("scripts/ci", name), join(repo, "scripts/ci", name));
	writeFileSync(join(repo, "mix.lock"), "%{}\n");
	writeFileSync(join(repo, ".gitignore"), "tmp/\n");
	const git = (...args) =>
		execFileSync("git", args, { cwd: repo, stdio: "pipe" }).toString().trim();
	git("init", "--quiet");
	git("config", "user.name", "CI Fixture");
	git("config", "user.email", "ci@example.com");
	git("add", ".");
	git("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "fixture");
	const sha = git("rev-parse", "HEAD");
	const hash = createHash("sha256")
		.update(readFileSync(join(repo, "scripts/ci/Dockerfile")))
		.digest("hex");
	const docker = join(bin, "docker");
	writeFileSync(
		docker,
		`#!${process.execPath}
const fs = require('node:fs');
const a = process.argv.slice(2);
fs.appendFileSync(process.env.CALLS, JSON.stringify(a)+'\\n');
const s = fs.existsSync(process.env.STATE) ? JSON.parse(fs.readFileSync(process.env.STATE)) : {image:false,resources:[]};
const save = () => fs.writeFileSync(process.env.STATE, JSON.stringify(s));
const value = flag => a[a.indexOf(flag)+1];
const label = () => value('--label').split('=')[1];
if(a[0]==='context') console.log('unix:///var/run/docker.sock');
else if(a[0]==='info') console.log('linux/x86_64');
else if(a[0]==='build') { fs.readFileSync(0); s.image=true; save(); }
else if(a[0]==='save') fs.writeFileSync(value('--output'),'owned-image');
else if(a[0]==='load') { fs.readFileSync(value('--input')); s.image=true; save(); }
else if(a[0]==='image' && a[1]==='inspect') {
  if(!s.image) process.exit(1);
  const source=process.env.BAD_SOURCE || process.env.TOOLS_HASH;
  if(a.includes('--format')) console.log('linux amd64 '+source);
  else console.log(JSON.stringify([{Id:process.env.INDEX_ID || 'first-index',Os:'linux',Architecture:'amd64',Config:{Labels:{'io.codex-pooler.ci.tools-source':source}},RootFS:{Type:'layers',Layers:[process.env.ROOTFS_LAYER || 'sha256:fixture']}}]));
}
else if(['container','network','volume'].includes(a[0]) && a[1]==='ls') {
  const filter=a.includes('--filter')?value('--filter').split('=')[2]:undefined;
  console.log(s.resources.filter(r=>r.kind===a[0] && (!filter || r.owner===filter)).map(r=>r.name).join('\\n'));
}
else if(['container','network','volume'].includes(a[0]) && a[1]==='inspect') {
  const r=s.resources.find(r=>r.kind===a[0] && r.name===a.at(-1));
  if(!r)process.exit(1); console.log(r.owner);
}
else if(['container','network','volume'].includes(a[0]) && a[1]==='rm') {
  if(process.env.CLEANUP_FAIL==='1')process.exit(7);
  s.resources=s.resources.filter(r=>r.name!==a.at(-1)); save();
}
else if(['volume','network'].includes(a[0]) && a[1]==='create') { s.resources.push({kind:a[0],name:a.at(-1),owner:label()});save();console.log(a.at(-1)); }
else if(a[0]==='run' && a.includes('--rm')) fs.readFileSync(0);
else if(a[0]==='create' || (a[0]==='run' && a.includes('-d'))) { s.resources.push({kind:'container',name:value('--name'),owner:label()});save();console.log(value('--name')); }
else if(a[0]==='logs')console.log('lane fixture log');
else if(a[0]==='wait')console.log(process.env.LANE_EXIT || '0');
else if(!['start','exec'].includes(a[0])) { console.error('unsupported Docker call: '+a.join(' '));process.exit(91); }
`,
		{ mode: 0o755 },
	);
	writeFileSync(
		join(bin, "sudo"),
		`#!/usr/bin/env bash\nset -eu\n[[ $1 == -n ]]\nshift\n[[ \${OWNERSHIP_EXIT:-0} == 0 ]] || exit "$OWNERSHIP_EXIT"\nexec "$@"\n`,
		{ mode: 0o755 },
	);
	writeFileSync(join(bin, "getconf"), '#!/bin/sh\nprintf "4\\n"\n', {
		mode: 0o755,
	});
	writeFileSync(
		join(bin, "id"),
		`#!/bin/sh\ncase "$1" in -u) printf '${process.getuid() || 1001}\\n' ;; -g) printf '${process.getgid() || 1001}\\n' ;; *) exec /usr/bin/id "$@" ;; esac\n`,
		{ mode: 0o755 },
	);
	const environment = {
		...process.env,
		PATH: `${bin}:${process.env.PATH}`,
		CI_DOCKER_COMMAND: docker,
		GITHUB_ACTIONS: "true",
		GITHUB_REPOSITORY: "icoretech/codex-pooler",
		GITHUB_EVENT_NAME: "push",
		GITHUB_REF: "refs/heads/main",
		GITHUB_SHA: sha,
		DEVELOPMENT_EXPECTED_SHA: sha,
		GITHUB_RUN_ID: "12345",
		GITHUB_RUN_ATTEMPT: "1",
		RUNNER_OS: "Linux",
		RUNNER_ARCH: "X64",
		RUNNER_TEMP: runner,
		CI_LANE: "static",
		DOCKER_CONTEXT: "",
		DOCKER_HOST: "",
		DOCKER_TLS: "",
		DOCKER_TLS_VERIFY: "",
		DOCKER_CERT_PATH: "",
		TOOLS_HASH: hash,
		CALLS: calls,
		STATE: state,
	};
	return {
		repo,
		runner,
		state,
		calls: () => readFileSync(calls, "utf8").trim().split("\n").map(JSON.parse),
		run: (mode, overrides = {}) =>
			spawnSync("bash", ["scripts/ci/hosted.sh", mode], {
				cwd: repo,
				encoding: "utf8",
				env: { ...environment, ...overrides },
			}),
		receipt: (lane = "static", attempt = "1") =>
			JSON.parse(
				readFileSync(
					join(
						repo,
						`tmp/ci-results/github-12345-${attempt}-${lane}/receipt.json`,
					),
				),
			),
	};
}

test("tools cache restores the image without another build and rejects a mismatched source label", (t) => {
	// Given a source-built archive saved by the preparation job.
	const f = fixture(t);
	assert.equal(f.run("tools").status, 0);
	// When another job loads the archive, and then receives an incompatible archive.
	assert.equal(f.run("tools").status, 0);
	const rejected = f.run("tools", { BAD_SOURCE: "different-source" });
	// Then the warm path loads bytes, while source mismatch cannot be accepted.
	assert.equal(f.calls().filter((args) => args[0] === "build").length, 1);
	assert.equal(f.calls().filter((args) => args[0] === "load").length, 2);
	assert.notEqual(rejected.status, 0);
	assert.match(rejected.stderr, /tools image differs/);
});

test("tools outputs use executable runtime identity rather than attestation metadata", (t) => {
	// Given a cached image and its workflow-output file.
	const f = fixture(t);
	const output = join(f.runner, "outputs");
	assert.equal(f.run("tools", { GITHUB_OUTPUT: output }).status, 0);
	// When only its index changes, followed by a real filesystem-layer change.
	assert.equal(
		f.run("tools", { GITHUB_OUTPUT: output, INDEX_ID: "second-index" }).status,
		0,
	);
	assert.equal(
		f.run("tools", {
			GITHUB_OUTPUT: output,
			ROOTFS_LAYER: "sha256:updated-runtime",
		}).status,
		0,
	);
	// Then workflow keys remain compatible only for the same executable content.
	const identities = readFileSync(output, "utf8").trim().split("\n");
	assert.equal(identities.length, 3);
	for (const identity of identities)
		assert.match(identity, /^runtime_identity=[0-9a-f]{64}$/);
	assert.equal(identities[0], identities[1]);
	assert.notEqual(identities[0], identities[2]);
});

for (const lane of ["static", "dialyzer", "partition-3"]) {
	test(`hosted ${lane} owns its cache mounts and removes only transient resources`, (t) => {
		// Given a prepared tools image and fresh compatible cache directories.
		const f = fixture(t);
		assert.equal(f.run("tools").status, 0);
		// When this lane runs through the real orchestration CLI.
		const result = f.run("run", { CI_LANE: lane });
		// Then the runtime receives stable cache targets and completes cleanup.
		assert.equal(result.status, 0, result.stderr + result.stdout);
		const create = f.calls().find((args) => args[0] === "create");
		for (const [part, target] of [
			["build", "/workspace/_build"],
			["deps", "/workspace/deps"],
			["home", "/cache"],
		])
			assert.ok(
				create.includes(
					`type=bind,src=${realpathSync(f.runner)}/pooler-cache/${part},dst=${target}`,
				),
			);
		assert.deepEqual(create.slice(-3), [
			"bash",
			"scripts/ci/phases.sh",
			lane === "partition-3" ? "partition" : lane,
		]);
		const pg = f
			.calls()
			.filter((args) => args[0] === "run" && args.includes("-d"));
		assert.equal(pg.length, lane === "partition-3" ? 1 : 0);
		if (lane === "partition-3") {
			assert.ok(create.includes("MIX_TEST_PARTITION=3"));
			assert.ok(
				create.some((value) =>
					/^CODEX_POOLER_TEST_RUN_NAMESPACE=[0-9a-f]{16}$/.test(value),
				),
			);
		}
		assert.deepEqual(JSON.parse(readFileSync(f.state)).resources, []);
		assert.equal(f.receipt(lane).cleanupExit, 0);
		assert.ok(existsSync(join(f.runner, "pooler-cache/identity")));
	});
}

test("a new run reuses the compatible lane cache without binding source or PostgreSQL into it", (t) => {
	// Given cached bytes from a completed static lane.
	const f = fixture(t);
	assert.equal(f.run("tools").status, 0);
	assert.equal(f.run("run").status, 0);
	writeFileSync(join(f.runner, "pooler-cache/build/retained.beam"), "retained");
	// When the next attempt restores that directory.
	const result = f.run("run", { GITHUB_RUN_ATTEMPT: "2" });
	// Then the cache is reused and retains its contents independently of source workspaces.
	assert.equal(result.status, 0, result.stderr + result.stdout);
	assert.match(result.stdout, /lane_cache=static state=hit/);
	assert.equal(
		readFileSync(join(f.runner, "pooler-cache/build/retained.beam"), "utf8"),
		"retained",
	);
	assert.ok(!existsSync(join(f.runner, "pooler-cache/source.json")));
});

test("a restored cache from a different lane is rejected without deleting its bytes", (t) => {
	// Given a static cache saved under the wrong restoration key.
	const f = fixture(t);
	assert.equal(f.run("tools").status, 0);
	assert.equal(f.run("run").status, 0);
	writeFileSync(join(f.runner, "pooler-cache/build/retained.beam"), "retained");
	// When a Dialyzer lane receives it.
	const result = f.run("run", { CI_LANE: "dialyzer" });
	// Then compatibility fails before workload creation and data remains available for diagnosis.
	assert.notEqual(result.status, 0);
	assert.match(result.stdout, /restored cache is incompatible/);
	assert.equal(
		readFileSync(join(f.runner, "pooler-cache/build/retained.beam"), "utf8"),
		"retained",
	);
});

test("a failing workload retains its exit status and still removes its resources", (t) => {
	// Given a real orchestration boundary whose container reports failure.
	const f = fixture(t);
	assert.equal(f.run("tools").status, 0);
	// When that lane completes.
	const result = f.run("run", { LANE_EXIT: "23" });
	// Then the original failure remains visible after successful cleanup.
	assert.equal(result.status, 23);
	assert.equal(f.receipt().exit, 23);
	assert.equal(f.receipt().cleanupExit, 0);
	assert.deepEqual(JSON.parse(readFileSync(f.state)).resources, []);
});

test("cleanup failure cannot turn a successful container into a successful job", (t) => {
	// Given a completed lane whose owned resources cannot be removed.
	const f = fixture(t);
	assert.equal(f.run("tools").status, 0);
	// When cleanup reaches the unavailable daemon mutation.
	const result = f.run("run", { CLEANUP_FAIL: "1" });
	// Then its receipt and process status both fail.
	assert.notEqual(result.status, 0);
	assert.notEqual(f.receipt().cleanupExit, 0);
});

test("cache ownership repair failure is visible after workload cleanup", (t) => {
	// Given a successful workload whose root-written cache cannot be returned to the runner.
	const f = fixture(t);
	assert.equal(f.run("tools").status, 0);
	// When the actual unprivileged-host ownership boundary refuses chown.
	const result = f.run("run", { OWNERSHIP_EXIT: "17" });
	// Then the job cannot claim a cache-ready success, while transient resources are removed.
	assert.equal(result.status, 17);
	assert.equal(f.receipt().cacheOwnershipExit, 17);
	assert.deepEqual(JSON.parse(readFileSync(f.state)).resources, []);
});

test("cache symlink restoration is refused before resource acquisition or recursive ownership changes", (t) => {
	// Given a restored path that redirects outside the lane cache.
	const f = fixture(t);
	symlinkSync(f.repo, join(f.runner, "pooler-cache"));
	// When the runtime validates its cache boundary.
	const result = f.run("run");
	// Then it refuses the path before invoking Docker.
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /symlink cache directory/);
	assert.equal(existsSync(f.state), false);
});

test("translation branch dispatch runs the hosted lane for its checked out revision", (t) => {
	// Given an automation branch whose push cannot trigger another workflow.
	const f = fixture(t);
	const identity = {
		GITHUB_EVENT_NAME: "workflow_dispatch",
		GITHUB_REF: "refs/heads/feat/tolgee-translations-12345-1",
	};
	assert.equal(f.run("tools", identity).status, 0);
	// When Development is explicitly dispatched on that branch.
	const result = f.run("run", identity);
	// Then the normal lane succeeds with its ordinary receipt.
	assert.equal(result.status, 0, result.stderr);
	assert.equal(f.receipt().exit, 0);
});

for (const environment of [
	{ GITHUB_REPOSITORY: "example-org/fork" },
	{ GITHUB_EVENT_NAME: "pull_request" },
	{
		GITHUB_EVENT_NAME: "workflow_dispatch",
		GITHUB_REF: "refs/heads/feat/tolgee-translations-12345-1",
		DEVELOPMENT_EXPECTED_SHA: "f".repeat(40),
	},
	{ GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_REF: "refs/heads/main" },
	{
		GITHUB_EVENT_NAME: "workflow_dispatch",
		GITHUB_REF: "refs/heads/feat/unrelated",
	},
	{ GITHUB_SHA: "a".repeat(40) },
	{ CI_LANE: "partition-5" },
	{ DOCKER_HOST: "tcp://example.invalid:2375" },
]) {
	test(`hosted runtime rejects invalid execution identity ${JSON.stringify(environment)}`, (t) => {
		// Given an identity outside the canonical supported push/lane contract.
		const f = fixture(t);
		// When the real entrypoint is invoked.
		const result = f.run("run", environment);
		// Then resource acquisition never starts.
		assert.notEqual(result.status, 0);
		assert.equal(existsSync(f.state), false);
	});
}
