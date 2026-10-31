import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
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

function fixture(t) {
	const root = mkdtempSync(join(tmpdir(), "hosted-phases-"));
	const bin = join(root, "bin");
	const output = join(root, "evidence");
	const calls = join(root, "calls.jsonl");
	mkdirSync(bin);
	mkdirSync(output);
	t.after(() => rmSync(root, { recursive: true, force: true }));
	writeFileSync(join(bin, "epmd"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
	// Supply the image's workspace/home boundary without running an application or database.
	writeFileSync(join(bin, "cp"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
	writeFileSync(
		join(bin, "bash"),
		'#!/bin/bash\nexec /bin/bash -c \'export PWD=/workspace; source "$0" "$@"\' "$@"\n',
		{ mode: 0o755 },
	);
	writeFileSync(
		join(bin, "mix"),
		`#!${process.execPath}
const fs=require('node:fs');
const args=process.argv.slice(2);
fs.appendFileSync(process.env.CALLS,JSON.stringify({args,partition:process.env.MIX_TEST_PARTITION,namespace:process.env.CODEX_POOLER_TEST_RUN_NAMESPACE})+'\\n');
if(args[0].startsWith('test.')) {
  const profile=args[0].slice(5);
  if(process.env.MISSING_DURATIONS!==profile)fs.writeFileSync(process.env.CODEX_POOLER_TEST_FILE_DURATIONS,'# codex-pooler test file durations v1 max_cases=8 run_ms=100 async_ms=0\\ntest/sample_test.exs\\t100\\t0\\n');
  console.log(process.env[profile.toUpperCase()+'_RESULT'] || 'Result: 2 passed');
  if(process.env.FAIL_PROFILE===profile)process.exit(23);
}
`,
		{ mode: 0o755 },
	);
	return {
		output,
		calls: () =>
			existsSync(calls)
				? readFileSync(calls, "utf8").trim().split("\n").map(JSON.parse)
				: [],
		run: (mode = "partition", extra = {}) =>
			spawnSync(
				"/bin/bash",
				[
					"-c",
					'export PWD=/workspace; source "$0" "$@"',
					resolve("scripts/ci/phases.sh"),
					mode,
				],
				{
					cwd: root,
					encoding: "utf8",
					env: {
						...process.env,
						PATH: `${bin}:${process.env.PATH}`,
						CI: "true",
						MIX_HOME: join(root, "mix"),
						HEX_HOME: join(root, "hex"),
						MIX_TEST_PARTITION: "2",
						CODEX_POOLER_TEST_RUN_NAMESPACE: "0123456789abcdef",
						CI_PARTITION_OUTPUT: output,
						CALLS: calls,
						...extra,
					},
				},
			),
	};
}

test("a hosted machine runs its complete weighted product and tooling partition once", (t) => {
	// Given one matrix index and a fresh database namespace.
	const f = fixture(t);
	// When the actual shared phase script executes with a command-boundary fixture.
	const result = f.run();
	// Then it keeps the full profile census and forwards the same partition identity to both profiles.
	assert.equal(result.status, 0, result.stderr + result.stdout);
	assert.deepEqual(
		f.calls().map(({ args }) => args),
		[
			["deps.get"],
			[
				"test.product",
				"--warnings-as-errors",
				"--max-cases",
				"8",
				"--partitions",
				"4",
			],
			[
				"test.tooling",
				"--warnings-as-errors",
				"--max-cases",
				"8",
				"--partitions",
				"4",
			],
		],
	);
	for (const call of f.calls()) {
		assert.equal(call.partition, "2");
		assert.equal(call.namespace, "0123456789abcdef");
	}
	assert.equal(
		(result.stdout.match(/test-fast: file durations partition 2\/4/g) || [])
			.length,
		2,
	);
	assert.ok(existsSync(join(f.output, "product.log")));
	assert.ok(existsSync(join(f.output, "tooling-files.tsv")));
});

test("static checks preserve the quality sequence without running test profiles", (t) => {
	// Given the separate static lane.
	const f = fixture(t);
	// When the shared checks run.
	const result = f.run("static");
	// Then every existing gate still runs in order.
	assert.equal(result.status, 0, result.stderr);
	assert.deepEqual(
		f.calls().map(({ args }) => args),
		[
			["quality.test_cleanup"],
			["deps.get"],
			["compile", "--warnings-as-errors"],
			["quality.xref"],
			["format", "--check-formatted"],
			["quality.security"],
			["quality.credo"],
			["quality.i18n"],
		],
	);
});

for (const result of ["Result: 0 passed", "Result: 2/3 passed", "no summary"]) {
	test(`a zero-exit profile cannot pass with ${result}`, (t) => {
		// Given a child process that exits zero without the required successful nonempty result.
		const f = fixture(t);
		// When the partition consumes the real output stream.
		const actual = f.run("partition", { PRODUCT_RESULT: result });
		// Then it fails before tooling can imply a complete partition pass.
		assert.notEqual(actual.status, 0);
		assert.match(actual.stderr, /no successful nonempty test result/);
		assert.equal(
			f.calls().filter(({ args }) => args[0] === "test.tooling").length,
			0,
		);
	});
}

test("a genuine product failure retains its code and skips subsequent tooling", (t) => {
	// Given a failed product command, even if it printed a positive-looking summary.
	const f = fixture(t);
	// When the profile pipeline finishes.
	const result = f.run("partition", { FAIL_PROFILE: "product" });
	// Then tee/phase logging cannot mask its failure.
	assert.equal(result.status, 23);
	assert.equal(
		f.calls().filter(({ args }) => args[0] === "test.tooling").length,
		0,
	);
});

test("a missing file-duration receipt fails the partition", (t) => {
	// Given successful test output without the required formatter export.
	const f = fixture(t);
	// When the partition validates its evidence.
	const result = f.run("partition", { MISSING_DURATIONS: "product" });
	// Then incomplete evidence is not a green profile.
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /file durations missing/);
});

test("invalid partition identity fails before dependencies or tests run", (t) => {
	// Given a matrix index outside the four-partition census.
	const f = fixture(t);
	// When the shared phase parses it.
	const result = f.run("partition", { MIX_TEST_PARTITION: "5" });
	// Then no Mix command is invoked.
	assert.notEqual(result.status, 0);
	assert.deepEqual(f.calls(), []);
});
