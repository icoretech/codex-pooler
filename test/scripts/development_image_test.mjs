import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
	copyFileSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	statSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { snapshot } from "../../scripts/ci/snapshot.mjs";

const publisher = new URL(
	"../../scripts/verification/development-image.sh",
	import.meta.url,
);
const digest = `sha256:${"a".repeat(64)}`;

function fixture(t, overrides = {}) {
	const root = mkdtempSync(join(tmpdir(), "development-image-"));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	const repo = join(root, "repo");
	const bin = join(root, "bin");
	const temporary = join(root, "temporary");
	for (const directory of [repo, bin, temporary]) mkdirSync(directory);
	mkdirSync(join(repo, "scripts/verification"), { recursive: true });
	mkdirSync(join(repo, "scripts/ci"), { recursive: true });
	for (const name of ["snapshot.mjs", "source-identity.mjs"]) {
		copyFileSync(
			new URL(`../../scripts/ci/${name}`, import.meta.url),
			join(repo, "scripts/ci", name),
		);
	}
	copyFileSync(
		publisher,
		join(repo, "scripts/verification/development-image.sh"),
	);
	writeFileSync(
		join(repo, "Dockerfile"),
		"FROM scratch\nCOPY payload /payload\n",
	);
	writeFileSync(join(repo, "payload"), "committed payload\n");
	writeFileSync(join(repo, "removed.txt"), "committed then removed\n");
	writeFileSync(join(repo, ".gitignore"), ".env\ntmp/\n");
	const git = (args) =>
		execFileSync("git", args, { cwd: repo, encoding: "utf8" }).trim();
	git(["init", "-q"]);
	git(["config", "user.name", "Fixture"]);
	git(["config", "user.email", "fixture@example.com"]);
	git(["add", "."]);
	git(["commit", "-qm", "fixture"]);
	const sha = git(["rev-parse", "HEAD"]);
	const remote = join(root, "remote.git");
	git(["init", "--bare", "-q", remote]);
	git(["push", "--quiet", remote, `${sha}:refs/heads/main`]);
	git([
		"config",
		`url.${remote}.insteadOf`,
		"https://github.com/icoretech/codex-pooler",
	]);
	writeFileSync(join(repo, "payload"), "uncommitted payload\n");
	writeFileSync(join(repo, ".env"), "PRIVATE_FIXTURE=value\n");
	writeFileSync(join(repo, "untracked"), "not part of the revision\n");
	writeFileSync(
		join(bin, "uname"),
		'#!/usr/bin/env bash\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; *) exit 1;; esac\n',
		{ mode: 0o755 },
	);
	writeFileSync(
		join(bin, "docker"),
		`#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
const env = process.env;
const root = env.FIXTURE_ROOT;
fs.appendFileSync(path.join(root, 'calls.jsonl'), JSON.stringify({args, config: env.DOCKER_CONFIG || '', credentialsPresent: Boolean(env.ICORETECH_REGISTRY_USER || env.ICORETECH_REGISTRY_PASSWORD || env.GITHUB_TOKEN || env.GH_TOKEN)}) + '\\n');
const present = path.join(root, 'image-present');
const sha = env.GITHUB_SHA;
const source = 'https://github.com/' + env.GITHUB_REPOSITORY;
const labelsPath = path.join(root, 'labels.json');
const labels = fs.existsSync(labelsPath) ? JSON.parse(fs.readFileSync(labelsPath, 'utf8')) : {'org.opencontainers.image.revision': sha, 'org.opencontainers.image.source': source};
if (args[0] === 'context') console.log(env.FIXTURE_DOCKER_ENDPOINT || 'unix:///var/run/docker.sock');
else if (args[0] === 'info') {
  if (env.FIXTURE_DAEMON_DOWN === '1' && fs.existsSync(present)) process.exit(30);
  console.log('linux/x86_64');
} else if (args[0] === 'container' && args[1] === 'ls') {
  if (env.FIXTURE_BUILDER_COLLISION === '1') console.log('foreign-container');
} else if (args[0] === 'buildx' && args[1] === 'create') {
  fs.writeFileSync(path.join(root, 'builder-present'), env.DOCKER_CONFIG);
} else if (args[0] === 'buildx' && args[1] === 'rm') {
  if (env.FIXTURE_BUILDER_REMOVE_FAILURE === '1') process.exit(45);
  fs.rmSync(path.join(root, 'builder-present'), {force:true});
} else if (args[0] === 'buildx' && args[1] === 'inspect') {
  if (args.includes('--bootstrap') && env.FIXTURE_BOOTSTRAP_FAILURE === '1') process.exit(46);
  console.log('Driver: docker');
}
else if (args[0] === 'buildx' && args[1] === 'build') {
  const context = args.at(-1);
  fs.writeFileSync(path.join(root, 'source.json'), JSON.stringify({payload: fs.readFileSync(path.join(context, 'payload'), 'utf8'), removed: fs.existsSync(path.join(context, 'removed.txt')), env: fs.existsSync(path.join(context, '.env')), untracked: fs.existsSync(path.join(context, 'untracked')), git: fs.existsSync(path.join(context, '.git'))}));
  const buildLabels = {};
  for (let i = 0; i < args.length; i++) if (args[i] === '--label') { const value = args[++i]; const split = value.indexOf('='); buildLabels[value.slice(0, split)] = value.slice(split + 1); }
  fs.writeFileSync(labelsPath, JSON.stringify(buildLabels));
  if (env.FIXTURE_BUILD_FAILURE === '1') process.exit(37);
  if (args.includes('--cache-to') && env.FIXTURE_CACHE_EXPORT_MISSING !== '1') {
    const output = args[args.indexOf('--cache-to') + 1].split(',').find(x=>x.startsWith('dest=')).slice(5);
    fs.mkdirSync(path.join(output,'blobs'),{recursive:true});
    fs.writeFileSync(path.join(output,'index.json'),JSON.stringify({schemaVersion:2,manifests:[{digest:'${digest}'}]}));
    fs.writeFileSync(path.join(output,'oci-layout'),JSON.stringify({imageLayoutVersion:'1.0.0'}));
    fs.writeFileSync(path.join(output,'blobs','fresh-layer'),'exported layer');
  }
  fs.writeFileSync(present, 'built');
  if (env.FIXTURE_MAIN_AFTER_BUILD) require('node:child_process').execFileSync('git', ['push', '--quiet', env.FIXTURE_SOURCE_REMOTE, env.FIXTURE_MAIN_AFTER_BUILD + ':refs/heads/main']);
  if (env.FIXTURE_REMOVE_REMOTE_AFTER_BUILD === '1') fs.rmSync(env.FIXTURE_SOURCE_REMOTE, {recursive: true});
  console.log('fixture build complete');
} else if (args[0] === 'image' && args[1] === 'inspect') {
  if (!fs.existsSync(present)) process.exit(1);
  console.log(JSON.stringify([{Architecture: env.FIXTURE_ARCH || 'amd64', Os: 'linux', Config: {Labels: labels}}]));
} else if (args[0] === 'image' && args[1] === 'rm') {
  if (env.FIXTURE_REMOVE_FAILURE === '1') process.exit(39);
  fs.rmSync(present, {force: true});
} else if (args[0] === 'login') {
  if (fs.readFileSync(0, 'utf8') !== env.FIXTURE_PASSWORD) process.exit(41);
  fs.writeFileSync(path.join(env.DOCKER_CONFIG, 'config.json'), JSON.stringify({auths: {sample: {auth: 'synthetic-fixture'}}}), {mode: 0o600});
  if (env.FIXTURE_LOGIN_FAILURE === '1') process.exit(42);
} else if (args[0] === 'push') {
  if (env.FIXTURE_PUSH_FAILURE === '1') process.exit(43);
  console.log('digest: ${digest} size: 123');
} else if (args[0] === 'buildx' && args[1] === 'imagetools') {
  if (args[3].includes('@')) console.log(JSON.stringify({architecture: 'amd64', os: 'linux', config: {Labels: {...labels, 'org.opencontainers.image.revision': env.FIXTURE_REMOTE_SHA || sha}}}));
  else console.log('${digest}');
} else process.exit(99);
`,
		{ mode: 0o755 },
	);
	const env = {
		...process.env,
		PATH: `${bin}:${process.env.PATH}`,
		GITHUB_ACTIONS: "true",
		GITHUB_REPOSITORY: "icoretech/codex-pooler",
		GITHUB_EVENT_NAME: "push",
		GITHUB_REF: "refs/heads/feature/Cache_Check",
		GITHUB_RUN_ID: "123",
		GITHUB_RUN_ATTEMPT: "2",
		GITHUB_SHA: sha,
		DEVELOPMENT_EXPECTED_SHA: sha,
		RUNNER_OS: "Linux",
		RUNNER_ARCH: "X64",
		RUNNER_TEMP: temporary,
		FIXTURE_ROOT: root,
		FIXTURE_SOURCE_REMOTE: remote,
		FIXTURE_PASSWORD: "sample-password",
		...overrides,
	};
	for (const name of [
		"DOCKER_HOST",
		"DOCKER_CONTEXT",
		"DOCKER_TLS",
		"DOCKER_TLS_VERIFY",
		"DOCKER_CERT_PATH",
		"DOCKER_CONFIG",
		"BUILDX_CONFIG",
		"BUILDX_BUILDER",
		"ICORETECH_REGISTRY_USER",
		"ICORETECH_REGISTRY_PASSWORD",
		"GITHUB_TOKEN",
		"GH_TOKEN",
		"CI_REHEARSAL",
		"CI_RUN_ID",
		"CI_SOURCE_DIR",
		"CI_SOURCE_RECEIPT",
		"CI_OUTPUT_DIR",
		"CI_STATE_ROOT",
		"CI_IMAGE_CACHE_DIR",
	])
		if (!(name in overrides)) delete env[name];
	return {
		root,
		repo,
		env,
		sha,
		git,
		remote,
		state: join(temporary, "codex-pooler-image-123-2"),
		evidence: join(repo, "tmp/ci-results/github-123-2"),
		run: (mode = "run", cwd = repo) =>
			spawnSync(
				"bash",
				[join(repo, "scripts/verification/development-image.sh"), mode],
				{
					cwd,
					env,
					encoding: "utf8",
				},
			),
		calls: () =>
			existsSync(join(root, "calls.jsonl"))
				? readFileSync(join(root, "calls.jsonl"), "utf8")
						.trim()
						.split("\n")
						.map((line) => JSON.parse(line))
				: [],
	};
}

test("branch builds export the event commit and retain the local builder cache without publishing", (t) => {
	const f = fixture(t);
	const result = f.run();
	assert.equal(result.status, 0, result.stderr);
	assert.deepEqual(JSON.parse(readFileSync(join(f.root, "source.json"))), {
		payload: "committed payload\n",
		removed: true,
		env: false,
		untracked: false,
		git: false,
	});
	const receipt = JSON.parse(readFileSync(join(f.evidence, "image.json")));
	assert.match(
		receipt.tag,
		new RegExp(`^cache-check-${f.sha.slice(0, 8)}-[0-9]+$`),
	);
	assert.equal(receipt.revision, f.sha);
	assert.equal(receipt.published, false);
	assert.equal(receipt.platform, "linux/amd64");
	const commands = f.calls().map(({ args }) => args);
	const build = commands.find(
		(args) => args[0] === "buildx" && args[1] === "build",
	);
	assert.equal(build[build.indexOf("--builder") + 1], "default");
	assert.equal(build[build.indexOf("--platform") + 1], "linux/amd64");
	assert.ok(build.includes(`org.opencontainers.image.revision=${f.sha}`));
	assert.equal(
		commands.some((args) => ["push", "login"].includes(args[0])),
		false,
	);
	assert.equal(
		commands.some(
			(args) =>
				args.includes("prune") ||
				args.includes("--no-cache") ||
				args.includes("--cache-to"),
		),
		false,
	);
	assert.equal(existsSync(f.state), false);
	assert.equal(f.run("cleanup").status, 0);
});

test("Renovate branch pushes build automatically without registry credentials or publication", (t) => {
	const f = fixture(t, {
		GITHUB_REF: "refs/heads/renovate/sample-package-1.x",
		GITHUB_ACTOR: "renovate[bot]",
	});
	assert.equal("ICORETECH_REGISTRY_USER" in f.env, false);
	assert.equal("ICORETECH_REGISTRY_PASSWORD" in f.env, false);
	const result = f.run();
	assert.equal(result.status, 0, result.stderr);
	const receipt = JSON.parse(readFileSync(join(f.evidence, "image.json")));
	assert.equal(receipt.published, false);
	assert.equal(receipt.revision, f.sha);
	assert.match(
		receipt.tag,
		new RegExp(`^sample-package-1\\.x-${f.sha.slice(0, 8)}-[0-9]+$`),
	);
	const commands = f.calls().map(({ args }) => args);
	assert.equal(
		commands.filter((args) => args[0] === "buildx" && args[1] === "build")
			.length,
		1,
	);
	assert.equal(
		commands.some((args) => ["login", "push"].includes(args[0])),
		false,
	);
	assert.equal(existsSync(f.state), false);
});

test("translation branch dispatch builds its revision without publishing", (t) => {
	// Given a translation branch dispatched with the normal image workflow.
	const f = fixture(t, {
		GITHUB_EVENT_NAME: "workflow_dispatch",
		GITHUB_REF: "refs/heads/feat/tolgee-translations-12345-1",
	});
	// When the real image entrypoint runs.
	const result = f.run();
	// Then it builds the event revision, never logging into or pushing a registry.
	assert.equal(result.status, 0, result.stderr);
	const receipt = JSON.parse(readFileSync(join(f.evidence, "image.json")));
	assert.equal(receipt.revision, f.sha);
	assert.equal(receipt.published, false);
	assert.equal(
		f.calls().some(({ args }) => ["login", "push"].includes(args[0])),
		false,
	);
});

test("only main publishes and verifies the registry digest and source labels", (t) => {
	const f = fixture(t, {
		GITHUB_REF: "refs/heads/main",
		ICORETECH_REGISTRY_USER: "sample-user",
		ICORETECH_REGISTRY_PASSWORD: "sample-password",
	});
	const sibling = `${f.state}-other`;
	mkdirSync(sibling);
	writeFileSync(join(sibling, "keep"), "unrelated");
	const result = f.run();
	assert.equal(result.status, 0, result.stderr);
	assert.doesNotMatch(result.stdout + result.stderr, /sample-password/);
	const receipt = JSON.parse(readFileSync(join(f.evidence, "image.json")));
	assert.equal(receipt.published, true);
	assert.equal(receipt.digest, digest);
	assert.equal(receipt.image, "registry.icorete.ch/icoretech/codex-pooler");
	assert.match(receipt.tag, new RegExp(`^main-${f.sha.slice(0, 8)}-[0-9]+$`));
	assert.equal(f.calls().filter(({ args }) => args[0] === "push").length, 1);
	assert.equal(f.calls().filter(({ args }) => args[0] === "login").length, 1);
	assert.equal(existsSync(f.state), false);
	assert.equal(readFileSync(join(sibling, "keep"), "utf8"), "unrelated");
});

for (const timing of ["before", "during"]) {
	test(`main superseded ${timing} the build verifies its image without publishing`, (t) => {
		const f = fixture(t, {
			GITHUB_REF: "refs/heads/main",
			ICORETECH_REGISTRY_USER: "sample-user",
			ICORETECH_REGISTRY_PASSWORD: "sample-password",
		});
		const next = f.git([
			"commit-tree",
			`${f.sha}^{tree}`,
			"-p",
			f.sha,
			"-m",
			"next revision",
		]);
		if (timing === "before")
			f.git(["push", "--quiet", f.remote, `${next}:refs/heads/main`]);
		else f.env.FIXTURE_MAIN_AFTER_BUILD = next;

		const result = f.run();

		assert.equal(result.status, 0, result.stderr);
		const receipt = JSON.parse(readFileSync(join(f.evidence, "image.json")));
		assert.equal(receipt.revision, f.sha);
		assert.equal(receipt.published, false);
		assert.equal(receipt.digest, "");
		assert.equal(f.calls().filter(({ args }) => args[1] === "build").length, 1);
		assert.equal(
			f.calls().some(({ args }) => ["push", "login"].includes(args[0])),
			false,
		);
		assert.equal(existsSync(f.state), false);
	});
}

for (const timing of ["before", "during"]) {
	test(`an unavailable main remote ${timing} the build fails without publishing`, (t) => {
		const f = fixture(t, {
			GITHUB_REF: "refs/heads/main",
			ICORETECH_REGISTRY_USER: "sample-user",
			ICORETECH_REGISTRY_PASSWORD: "sample-password",
		});
		if (timing === "before") rmSync(f.remote, { recursive: true });
		else f.env.FIXTURE_REMOVE_REMOTE_AFTER_BUILD = "1";

		const result = f.run();

		assert.equal(result.status, 1, result.stderr);
		assert.match(result.stderr, /cannot resolve current main revision/);
		assert.equal(
			f.calls().some(({ args }) => ["push", "login"].includes(args[0])),
			false,
		);
		assert.equal(existsSync(join(f.evidence, "image.json")), false);
		assert.equal(existsSync(f.state), false);
	});
}

function hostedCache(f, warm = false) {
	const cache = join(f.env.RUNNER_TEMP, "pooler-image-cache");
	f.env.CI_IMAGE_CACHE_DIR = cache;
	if (warm) {
		mkdirSync(join(cache, "blobs"), { recursive: true });
		writeFileSync(
			join(cache, "index.json"),
			JSON.stringify({ schemaVersion: 2, manifests: [{ digest }] }),
		);
		writeFileSync(
			join(cache, "oci-layout"),
			JSON.stringify({ imageLayoutVersion: "1.0.0" }),
		);
		writeFileSync(join(cache, "blobs/old-layer"), "previous layer");
	}
	return cache;
}

for (const warm of [false, true]) {
	test(`hosted ${warm ? "warm" : "cold"} image build exports a fresh reusable cache and removes its builder`, (t) => {
		const f = fixture(t);
		const cache = hostedCache(f, warm);
		const result = f.run();
		assert.equal(result.status, 0, result.stderr);
		const calls = f.calls();
		const create = calls.find(({ args }) => args[1] === "create");
		assert.equal(create.config, join(f.state, "docker"));
		assert.deepEqual(create.args.slice(0, 6), [
			"buildx",
			"create",
			"--name",
			"pooler-image-123-2",
			"--driver",
			"docker-container",
		]);
		const build = calls.find(({ args }) => args[1] === "build").args;
		assert.equal(build[build.indexOf("--builder") + 1], "pooler-image-123-2");
		assert.equal(build.includes("--cache-from"), warm);
		if (warm)
			assert.equal(
				build[build.indexOf("--cache-from") + 1],
				`type=local,src=${cache}`,
			);
		assert.equal(
			build[build.indexOf("--cache-to") + 1],
			`type=local,dest=${f.state}/cache-export,mode=max`,
		);
		assert.equal(
			readFileSync(join(cache, "blobs/fresh-layer"), "utf8"),
			"exported layer",
		);
		assert.equal(existsSync(join(cache, "blobs/old-layer")), false);
		assert.equal(existsSync(join(f.root, "builder-present")), false);
		assert.equal(existsSync(f.state), false);
		const receipt = JSON.parse(readFileSync(join(f.evidence, "image.json")));
		assert.equal(receipt.cacheImported, warm);
		assert.equal(receipt.cacheExported, true);
		assert.equal(receipt.published, false);
		assert.ok(
			calls.some(
				({ args }) =>
					args[0] === "buildx" &&
					args[1] === "rm" &&
					args.at(-1) === "pooler-image-123-2",
			),
		);
	});
}

for (const [name, override, code] of [
	["build", { FIXTURE_BUILD_FAILURE: "1" }, 37],
	["cache export", { FIXTURE_CACHE_EXPORT_MISSING: "1" }, 1],
	["builder bootstrap", { FIXTURE_BOOTSTRAP_FAILURE: "1" }, 46],
]) {
	test(`hosted ${name} failure keeps the previous cache and cleans owned resources`, (t) => {
		const f = fixture(t, override);
		const cache = hostedCache(f, true);
		const result = f.run();
		assert.equal(result.status, code, result.stderr);
		assert.equal(
			readFileSync(join(cache, "blobs/old-layer"), "utf8"),
			"previous layer",
		);
		assert.equal(existsSync(join(f.root, "builder-present")), false);
		assert.equal(existsSync(f.state), false);
		assert.equal(existsSync(join(f.evidence, "image.json")), false);
	});
}

test("hosted builder cleanup failure removes credentials and retains only owned metadata for retry", (t) => {
	const f = fixture(t, {
		GITHUB_REF: "refs/heads/main",
		ICORETECH_REGISTRY_USER: "sample-user",
		ICORETECH_REGISTRY_PASSWORD: "sample-password",
		FIXTURE_BUILDER_REMOVE_FAILURE: "1",
	});
	const cache = hostedCache(f);
	assert.equal(f.run().status, 1);
	assert.equal(existsSync(join(f.state, "docker/config.json")), false);
	assert.equal(existsSync(join(f.state, "context")), false);
	assert.equal(existsSync(join(f.state, "builder")), true);
	assert.equal(existsSync(join(cache, "index.json")), true);
	delete f.env.FIXTURE_BUILDER_REMOVE_FAILURE;
	assert.equal(f.run("cleanup").status, 0);
	assert.equal(existsSync(f.state), false);
});

test("a failed cache promotion restores the previous complete cache", (t) => {
	const f = fixture(t);
	const cache = hostedCache(f, true);
	writeFileSync(
		join(f.root, "bin/mv"),
		'#!/usr/bin/env bash\ncase "$1" in */cache-export) exit 51;; esac\nexec /bin/mv "$@"\n',
		{ mode: 0o755 },
	);
	const result = f.run();
	assert.equal(result.status, 51, result.stderr);
	assert.equal(
		readFileSync(join(cache, "blobs/old-layer"), "utf8"),
		"previous layer",
	);
	assert.equal(existsSync(join(cache, "blobs/fresh-layer")), false);
	assert.equal(existsSync(f.state), false);
	assert.equal(existsSync(join(f.evidence, "image.json")), false);
});

for (const [name, mutate, message] of [
	[
		"outside runner temporary directory",
		(f) => {
			f.env.CI_IMAGE_CACHE_DIR = join(f.root, "cache");
		},
		/must be RUNNER_TEMP/,
	],
	[
		"cache symlink",
		(f) => {
			symlinkSync(f.repo, hostedCache(f));
		},
		/real directory/,
	],
	[
		"nested symlink",
		(f) => {
			symlinkSync(f.repo, join(hostedCache(f, true), "foreign"));
		},
		/cannot contain symlinks/,
	],
	[
		"non-cache contents",
		(f) => {
			const cache = hostedCache(f);
			mkdirSync(cache);
			writeFileSync(join(cache, "keep"), "foreign");
		},
		/not an OCI layout/,
	],
	[
		"invalid index",
		(f) => {
			writeFileSync(join(hostedCache(f, true), "index.json"), "{}");
		},
		/invalid image cache index/,
	],
	[
		"existing builder",
		(f) => {
			hostedCache(f);
			f.env.FIXTURE_BUILDER_COLLISION = "1";
		},
		/builder container already exists/,
	],
]) {
	test(`hosted publisher refuses ${name} before building or publishing`, (t) => {
		const f = fixture(t);
		mutate(f);
		const result = f.run();
		assert.equal(result.status, 1, result.stderr);
		assert.match(result.stderr, message);
		assert.equal(
			f
				.calls()
				.some(
					({ args }) =>
						args[1] === "build" || ["login", "push"].includes(args[0]),
				),
			false,
		);
		assert.equal(
			f.calls().some(({ args }) => args[0] === "buildx" && args[1] === "rm"),
			false,
		);
	});
}

for (const [name, overrides, pattern] of [
	[
		"changed translation revision",
		{
			GITHUB_EVENT_NAME: "workflow_dispatch",
			GITHUB_REF: "refs/heads/feat/tolgee-translations-12345-1",
			DEVELOPMENT_EXPECTED_SHA: "f".repeat(40),
		},
		/dispatched translation revision changed/,
	],
	[
		"manual main",
		{ GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_REF: "refs/heads/main" },
		/only branch push/,
	],
	[
		"manual unrelated branch",
		{
			GITHUB_EVENT_NAME: "workflow_dispatch",
			GITHUB_REF: "refs/heads/feat/unrelated",
		},
		/only branch push/,
	],
	["pull requests", { GITHUB_EVENT_NAME: "pull_request" }, /only branch push/],
	["tag pushes", { GITHUB_REF: "refs/tags/v1.0.0" }, /only branch push/],
	[
		"forks",
		{ GITHUB_REPOSITORY: "example-org/sample-app" },
		/unexpected repository/,
	],
	[
		"release branches",
		{
			GITHUB_REF:
				"refs/heads/release-please--branches--main--components--codex-pooler",
		},
		/release automation branch/,
	],
	[
		"release notes branches",
		{
			GITHUB_REF:
				"refs/heads/release-please--branches--main--components--codex-pooler--release-notes",
		},
		/release automation branch/,
	],
	["malformed runs", { GITHUB_RUN_ID: "../123" }, /invalid run identity/],
	["wrong source", { GITHUB_SHA: "f".repeat(40) }, /checkout does not match/],
	[
		"Docker redirection",
		{ DOCKER_HOST: "tcp://example.com:2375" },
		/Docker override is forbidden/,
	],
	[
		"Buildx metadata redirection",
		{ BUILDX_CONFIG: "/tmp/foreign-buildx" },
		/Docker override is forbidden/,
	],
	[
		"Buildx builder redirection",
		{ BUILDX_BUILDER: "foreign-builder" },
		/Docker override is forbidden/,
	],
	[
		"remote contexts",
		{ FIXTURE_DOCKER_ENDPOINT: "ssh://example.com" },
		/local default Docker socket/,
	],
	[
		"missing publish credentials",
		{ GITHUB_REF: "refs/heads/main" },
		/requires registry credentials/,
	],
]) {
	test(`${name} cannot start an image build`, (t) => {
		const f = fixture(t, overrides);
		const result = f.run();
		assert.notEqual(result.status, 0);
		assert.match(result.stderr, pattern);
		assert.equal(
			f
				.calls()
				.some(
					({ args }) =>
						args[1] === "build" || args[0] === "login" || args[0] === "push",
				),
			false,
		);
		assert.equal(existsSync(f.state), false);
	});
}

for (const [name, overrides, code] of [
	["build", { FIXTURE_BUILD_FAILURE: "1" }, 37],
	["login", { FIXTURE_LOGIN_FAILURE: "1" }, 42],
	["push", { FIXTURE_PUSH_FAILURE: "1" }, 43],
	["remote revision", { FIXTURE_REMOTE_SHA: "f".repeat(40) }, 1],
	["local architecture", { FIXTURE_ARCH: "arm64" }, 1],
]) {
	test(`${name} failure propagates and removes owned credentials and context`, (t) => {
		const f = fixture(t, {
			GITHUB_REF: "refs/heads/main",
			ICORETECH_REGISTRY_USER: "sample-user",
			ICORETECH_REGISTRY_PASSWORD: "sample-password",
			...overrides,
		});
		const result = f.run();
		assert.equal(result.status, code, result.stderr);
		assert.equal(existsSync(f.state), false);
		assert.equal(existsSync(join(f.evidence, "image.json")), false);
	});
}

test("a cleanup failure removes credentials and permits an exact-state retry", (t) => {
	const f = fixture(t, {
		GITHUB_REF: "refs/heads/main",
		ICORETECH_REGISTRY_USER: "sample-user",
		ICORETECH_REGISTRY_PASSWORD: "sample-password",
		FIXTURE_REMOVE_FAILURE: "1",
	});
	const result = f.run();
	assert.equal(result.status, 1, result.stderr);
	assert.equal(existsSync(join(f.state, "docker")), false);
	assert.equal(existsSync(join(f.state, "context")), false);
	assert.equal(existsSync(join(f.state, "owner")), true);
	delete f.env.FIXTURE_REMOVE_FAILURE;
	assert.equal(f.run("cleanup").status, 0);
	assert.equal(existsSync(f.state), false);
});

test("daemon loss still removes credentials before reporting incomplete image cleanup", (t) => {
	const f = fixture(t, {
		GITHUB_REF: "refs/heads/main",
		ICORETECH_REGISTRY_USER: "sample-user",
		ICORETECH_REGISTRY_PASSWORD: "sample-password",
		FIXTURE_DAEMON_DOWN: "1",
	});
	const result = f.run();
	assert.equal(result.status, 1, result.stderr);
	assert.equal(existsSync(join(f.state, "docker")), false);
	assert.equal(existsSync(join(f.state, "context")), false);
	assert.equal(existsSync(join(f.state, "owner")), true);
	delete f.env.FIXTURE_DAEMON_DOWN;
	assert.equal(f.run("cleanup").status, 0);
	assert.equal(existsSync(f.state), false);
});

test("cleanup refuses a state directory owned by another revision", (t) => {
	const f = fixture(t);
	mkdirSync(f.state);
	writeFileSync(join(f.state, "owner"), `123:2:${"f".repeat(40)}\n`);
	writeFileSync(join(f.state, "keep"), "foreign");
	assert.equal(f.run("cleanup").status, 1);
	assert.equal(readFileSync(join(f.state, "keep"), "utf8"), "foreign");
	assert.equal(f.calls().length, 0);
});

test("help succeeds without runner credentials and unsupported invocations fail", () => {
	assert.equal(spawnSync("bash", [publisher.pathname, "--help"]).status, 0);
	assert.equal(spawnSync("bash", [publisher.pathname, "publish"]).status, 1);
	assert.equal(
		spawnSync("bash", [publisher.pathname, "run", "extra"]).status,
		1,
	);
});

function rehearsalFixture(t, { ambientGitHub = false, ...overrides } = {}) {
	const f = fixture(t, overrides);
	rmSync(join(f.repo, "removed.txt"));
	const frozen = join(f.root, "frozen");
	const source = snapshot(f.repo, frozen);
	const output = join(f.root, "image-output");
	mkdirSync(output);
	Object.assign(f.env, {
		CI_REHEARSAL: "true",
		CI_RUN_ID: "rehearsal-sample123",
		CI_SOURCE_DIR: join(frozen, "source"),
		CI_SOURCE_RECEIPT: join(frozen, "source.json"),
		CI_STATE_ROOT: join(f.root, "temporary"),
		CI_OUTPUT_DIR: output,
	});
	if (!ambientGitHub)
		for (const key of Object.keys(f.env))
			if (key.startsWith("GITHUB_") || key.startsWith("RUNNER_"))
				delete f.env[key];
	return {
		...f,
		frozen,
		source,
		evidence: output,
		state: join(f.root, "temporary/codex-pooler-image-rehearsal-sample123"),
	};
}

test("rehearsal builds the frozen working snapshot without GitHub variables or a Git working directory", (t) => {
	const f = rehearsalFixture(t);
	writeFileSync(join(f.repo, "payload"), "changed after freezing\n");
	const result = f.run("rehearse", f.root);
	assert.equal(result.status, 0, result.stderr);
	assert.deepEqual(JSON.parse(readFileSync(join(f.root, "source.json"))), {
		payload: "uncommitted payload\n",
		removed: false,
		env: false,
		untracked: true,
		git: false,
	});
	const receipt = JSON.parse(readFileSync(join(f.evidence, "image.json")));
	assert.equal(receipt.sourceKind, "snapshot");
	assert.equal(receipt.revision, f.source.revision);
	assert.equal(receipt.contentHash, f.source.contentHash);
	assert.equal(receipt.published, false);
	assert.equal(receipt.digest, "");
	assert.equal(receipt.image, "pooler-ci-rehearsal");
	assert.equal(statSync(join(f.evidence, "image.json")).mode & 0o777, 0o644);
	assert.equal(
		statSync(join(f.evidence, "image-build.log")).mode & 0o777,
		0o644,
	);
	const labels = JSON.parse(readFileSync(join(f.root, "labels.json")));
	assert.equal(
		labels["org.opencontainers.image.revision"],
		`snapshot:${f.source.contentHash}`,
	);
	assert.equal(labels["io.codex-pooler.ci.base-revision"], f.source.revision);
	assert.equal(labels["io.codex-pooler.ci.snapshot"], f.source.contentHash);
	const commands = f.calls().map(({ args }) => args);
	const build = commands.find(
		(args) => args[0] === "buildx" && args[1] === "build",
	);
	assert.equal(build[build.indexOf("--builder") + 1], "default");
	assert.equal(build[build.indexOf("--platform") + 1], "linux/amd64");
	assert.ok(build.includes("--load"));
	assert.equal(
		commands.some(
			(args) =>
				["push", "login"].includes(args[0]) ||
				args.includes("--push") ||
				args.includes("--cache-to") ||
				args.includes("--no-cache") ||
				args.includes("prune"),
		),
		false,
	);
	assert.equal(existsSync(f.state), false);
	assert.equal(f.run("cleanup", f.root).status, 0);
});

test("rehearsal cannot publish even with inherited main-run credentials", (t) => {
	const f = rehearsalFixture(t, {
		ambientGitHub: true,
		GITHUB_REF: "refs/heads/main",
		ICORETECH_REGISTRY_USER: "sample-user",
		ICORETECH_REGISTRY_PASSWORD: "sample-password",
		GITHUB_TOKEN: "sample-token",
		GH_TOKEN: "sample-token",
	});
	rmSync(f.remote, { recursive: true });
	const result = f.run("rehearse");
	assert.equal(result.status, 0, result.stderr);
	assert.equal(
		f
			.calls()
			.some(
				({ args, credentialsPresent }) =>
					credentialsPresent || ["login", "push"].includes(args[0]),
			),
		false,
	);
	assert.equal(
		JSON.parse(readFileSync(join(f.evidence, "image.json"))).published,
		false,
	);
	assert.equal(existsSync(join(f.evidence, "image-push.log")), false);
});

for (const [name, mutate, message] of [
	[
		"missing opt-in",
		(f) => {
			delete f.env.CI_REHEARSAL;
		},
		/requires explicit CI_REHEARSAL/,
	],
	[
		"invalid identity",
		(f) => {
			f.env.CI_RUN_ID = "../other";
		},
		/invalid rehearsal identity/,
	],
	[
		"relative source",
		(f) => {
			f.env.CI_SOURCE_DIR = "frozen/source";
		},
		/absolute frozen source/,
	],
	[
		"missing receipt",
		(f) => {
			delete f.env.CI_SOURCE_RECEIPT;
		},
		/absolute snapshot receipt/,
	],
	[
		"changed bytes",
		(f) => {
			writeFileSync(join(f.frozen, "source/payload"), "tampered\n");
		},
		/snapshot|identity|hash/i,
	],
	[
		"extra file",
		(f) => {
			writeFileSync(join(f.frozen, "source/extra"), "extra\n");
		},
		/snapshot|identity|hash/i,
	],
	[
		"malformed revision",
		(f) => {
			writeFileSync(
				f.env.CI_SOURCE_RECEIPT,
				JSON.stringify({ ...f.source, revision: "invalid" }),
			);
		},
		/invalid snapshot revision/,
	],
	[
		"malformed hash",
		(f) => {
			writeFileSync(
				f.env.CI_SOURCE_RECEIPT,
				JSON.stringify({ ...f.source, contentHash: "invalid" }),
			);
		},
		/invalid snapshot content hash/,
	],
	[
		"output inside source",
		(f) => {
			f.env.CI_OUTPUT_DIR = f.env.CI_SOURCE_DIR;
		},
		/output must be outside/,
	],
	[
		"state inside source",
		(f) => {
			f.env.CI_STATE_ROOT = f.env.CI_SOURCE_DIR;
		},
		/state must be outside/,
	],
]) {
	test(`rehearsal rejects ${name} before building`, (t) => {
		const f = rehearsalFixture(t);
		mutate(f);
		const result = f.run("rehearse");
		assert.notEqual(result.status, 0);
		assert.match(result.stderr, message);
		assert.equal(
			f
				.calls()
				.some(
					({ args }) =>
						args[1] === "build" || ["login", "push"].includes(args[0]),
				),
			false,
		);
		assert.equal(existsSync(f.state), false);
	});
}

test("rehearsal build failures propagate and remove owned context", (t) => {
	const f = rehearsalFixture(t, { FIXTURE_BUILD_FAILURE: "1" });
	const result = f.run("rehearse");
	assert.equal(result.status, 37, result.stderr);
	assert.equal(existsSync(f.state), false);
	assert.equal(existsSync(join(f.evidence, "image.json")), false);
	assert.equal(existsSync(join(f.evidence, "image-build.log")), true);
});

test("a rehearsal cannot reuse a previous successful image receipt", (t) => {
	const f = rehearsalFixture(t);
	assert.equal(f.run("rehearse").status, 0);
	const first = readFileSync(join(f.evidence, "image.json"), "utf8");
	const result = f.run("rehearse");
	assert.equal(result.status, 1);
	assert.match(result.stderr, /image evidence already exists/);
	assert.equal(readFileSync(join(f.evidence, "image.json"), "utf8"), first);
	assert.equal(f.calls().filter(({ args }) => args[1] === "build").length, 1);
});

test("snapshot opt-in cannot bypass the strict GitHub run mode", (t) => {
	const f = rehearsalFixture(t, { ambientGitHub: true });
	const result = f.run("run");
	assert.equal(result.status, 1);
	assert.match(result.stderr, /use rehearse for snapshot builds/);
	assert.equal(f.calls().length, 0);
});
