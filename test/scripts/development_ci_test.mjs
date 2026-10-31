import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(
	new URL("../../.github/workflows/development.yml", import.meta.url),
	"utf8",
);

function job(id) {
	const start = workflow.indexOf(`\n  ${id}:\n`);
	assert.ok(start >= 0, `missing ${id} job`);
	const rest = workflow.slice(start + 1);
	const end = rest.slice(3).search(/\n {2}[a-z]+:\n/);
	return end < 0 ? rest : rest.slice(0, end + 3);
}

test("development receives branch pushes and explicit translation validation dispatches", () => {
	const triggers = workflow.split("\npermissions:")[0];
	assert.match(triggers, /^name: Development\n/);
	assert.match(triggers, /\n {2}push:\n {4}branches:\n {6}- '\*\*'/);
	assert.match(
		triggers,
		/'!release-please--branches--main--components--codex-pooler'/,
	);
	assert.match(
		triggers,
		/'!release-please--branches--main--components--codex-pooler--release-notes'/,
	);
	assert.deepEqual(
		[...triggers.matchAll(/^ {6}- '([^']+)'$/gm)].map((match) => match[1]),
		[
			"**",
			"!release-please--branches--main--components--codex-pooler",
			"!release-please--branches--main--components--codex-pooler--release-notes",
		],
	);
	assert.doesNotMatch(workflow, /github\.(actor|triggering_actor)/);
	assert.doesNotMatch(
		triggers,
		/pull_request|workflow_run|repository_dispatch|tags:/,
	);
	assert.match(triggers, /\n {2}workflow_dispatch:\n/);
	assert.doesNotMatch(workflow, /continue-on-error:\s*true/);
	assert.ok(
		workflow.includes(
			`group: "development-\${{ github.ref }}-\${{ github.ref == 'refs/heads/main' && startsWith(github.event.head_commit.message, 'chore(main): release codex-pooler ') && github.sha || 'latest' }}"`,
		),
	);
	assert.match(workflow, /cancel-in-progress: true/);
	assert.doesNotMatch(workflow, /queue: max/);
});

test("the canonical workflow distributes complete quality across hosted jobs before publication", () => {
	for (const [id, name] of [
		["tools", "CI tools"],
		["quality", "Quality"],
		["image", "Development image"],
		["gate", "Development gate"],
	]) {
		assert.match(job(id), new RegExp(`name: ${name}\\n`));
		assert.match(job(id), /github\.repository == 'icoretech\/codex-pooler'/);
		assert.match(job(id), /runs-on: ubuntu-26\.04/);
	}
	assert.doesNotMatch(workflow, /self-hosted|ci-amd64/);
	assert.match(job("checks"), /name: \$\{\{ matrix\.name \}\}/);
	assert.match(job("checks"), /lane: static\n\s+name: Static checks/);
	assert.match(job("checks"), /lane: dialyzer\n\s+name: Dialyzer/);
	assert.match(job("tests"), /name: Tests \$\{\{ matrix\.partition \}\}\/4/);
	assert.match(job("tests"), /partition: \[1, 2, 3, 4\]/);
	assert.match(
		job("tests"),
		/CI_LANE: partition-\$\{\{ matrix\.partition \}\}/,
	);
	for (const id of ["checks", "tests"]) {
		assert.match(job(id), /needs: tools\n/);
		assert.match(job(id), /fail-fast: false/);
		assert.match(job(id), /runs-on: ubuntu-26\.04/);
		assert.match(job(id), /run: bash scripts\/ci\/hosted\.sh run/);
		assert.match(
			job(id),
			/if: always\(\)\n\s+run: bash scripts\/ci\/hosted\.sh cleanup/,
		);
	}
	assert.match(job("quality"), /needs: \[tools, checks, tests\]\n/);
	assert.match(job("quality"), /if: always\(\) &&/);
	assert.match(job("image"), /needs: quality\n/);
	assert.match(job("gate"), /needs: \[quality, image\]\n/);
	assert.match(job("gate"), /if: always\(\) &&/);
	assert.equal((workflow.match(/persist-credentials: false/g) || []).length, 4);
	assert.match(workflow, /permissions:\n {2}contents: read\n/);
	assert.doesNotMatch(
		workflow,
		/contents: write|packages: write|id-token: write/,
	);
});

test("hosted caches restore only toolchain and compatible lane bytes, with source-specific refresh keys", () => {
	const toolsKey = `pooler-tools-v2-\${{ runner.os }}-\${{ runner.arch }}-\${{ hashFiles('scripts/ci/Dockerfile') }}`;
	assert.ok(job("tools").includes(`key: ${toolsKey}`));
	assert.match(job("tools"), /uses: actions\/cache@v6/);
	for (const id of ["checks", "tests"]) {
		const lane = job(id);
		assert.match(lane, /uses: actions\/cache\/restore@v6/);
		assert.ok(lane.includes(`key: ${toolsKey}`));
		assert.match(lane, /path: \$\{\{ runner\.temp \}\}\/pooler-cache/);
		assert.match(
			lane,
			/name: Prepare CI tools image\n\s+id: tools\n\s+run: bash scripts\/ci\/hosted\.sh tools/,
		);
		assert.ok(
			lane.indexOf("id: tools") < lane.indexOf("- name: Restore lane cache"),
		);
		const cache = lane.slice(
			lane.indexOf("- name: Restore lane cache"),
			lane.indexOf("- name: Run"),
		);
		assert.equal(
			(cache.match(/steps\.tools\.outputs\.runtime_identity/g) ?? []).length,
			2,
		);
		assert.equal((cache.match(/hashFiles\('mix\.lock'\)/g) ?? []).length, 2);
		assert.doesNotMatch(cache, /hashFiles\('scripts\/ci\/Dockerfile'/);
		assert.match(
			lane,
			/key: pooler-lane-v2-.*\$\{\{ env\.CI_LANE \}\}-\$\{\{ github\.sha \}\}/,
		);
		assert.match(
			lane,
			/restore-keys: \|\n\s+pooler-lane-v2-.*\$\{\{ env\.CI_LANE \}\}-\n/,
		);
		assert.doesNotMatch(
			lane.split("- name: Run")[0],
			/path:.*(?:workspace|source\.tar|snapshot|docker\/config)/,
		);
	}
	const image = job("image");
	assert.match(
		image,
		/CI_IMAGE_CACHE_DIR=\$RUNNER_TEMP\/pooler-image-cache.*GITHUB_ENV/,
	);
	assert.match(image, /path: \$\{\{ env\.CI_IMAGE_CACHE_DIR \}\}/);
	assert.match(image, /key: pooler-image-v2-.*\$\{\{ github\.sha \}\}/);
	for (const [, reference] of workflow.matchAll(/uses: (\S+)/g)) {
		assert.match(reference, /@v\d+$/);
	}
});

test("only the main publishing step receives registry secrets and artifacts survive cleanup", () => {
	for (const id of ["checks", "tests"]) {
		const lane = job(id);
		assert.doesNotMatch(lane, /secrets\./);
		const artifact = lane.slice(lane.indexOf("- name: Save lane evidence"));
		const paths = artifact
			.split("          path: |\n")[1]
			.split("          if-no-files-found:")[0]
			.trim()
			.split("\n")
			.map((line) => line.trim());
		assert.deepEqual(
			paths,
			["source.json", "receipt.json", "*.log", "*.tsv"].map(
				(name) =>
					`tmp/ci-results/github-\${{ github.run_id }}-\${{ github.run_attempt }}-\${{ env.CI_LANE }}/${name}`,
			),
		);
		assert.doesNotMatch(artifact, /snapshot|source\.tar|\/source\//);
		assert.ok(
			lane.indexOf("Remove owned lane resources") <
				lane.indexOf("Save lane evidence"),
		);
	}
	const image = job("image");
	const branch = image.slice(
		image.indexOf("- name: Build development branch"),
		image.indexOf("- name: Build and publish main"),
	);
	assert.match(branch, /if: github\.ref != 'refs\/heads\/main'/);
	assert.doesNotMatch(branch, /secrets\./);
	const publish = image.slice(
		image.indexOf("- name: Build and publish main"),
		image.indexOf("- name: Remove owned image"),
	);
	assert.match(publish, /if: github\.ref == 'refs\/heads\/main'/);
	assert.match(publish, /secrets\.ICORETECH_REGISTRY_USER/);
	assert.match(publish, /secrets\.ICORETECH_REGISTRY_PASSWORD/);
	assert.match(
		image,
		/if: always\(\)\n\s+run: bash scripts\/verification\/development-image\.sh cleanup/,
	);
	assert.match(
		image,
		/path: tmp\/ci-results\/github-\$\{\{ github\.run_id \}\}-\$\{\{ github\.run_attempt \}\}\/image\*/,
	);
	assert.ok(
		image.indexOf("Remove owned image") < image.indexOf("Save image evidence"),
	);
});

test("the quality aggregate rejects failed, skipped, cancelled and incomplete matrices", () => {
	const script = job("quality")
		.split("        run: |\n")[1]
		.split("\n")
		.map((line) => line.replace(/^ {10}/, ""))
		.join("\n");
	for (const tools of ["success", "failure", "cancelled", "skipped", ""]) {
		for (const checks of ["success", "failure", "cancelled", "skipped", ""]) {
			for (const tests of ["success", "failure", "cancelled", "skipped", ""]) {
				const result = spawnSync("bash", ["-c", script], {
					env: {
						...process.env,
						TOOLS_RESULT: tools,
						CHECKS_RESULT: checks,
						TESTS_RESULT: tests,
					},
					encoding: "utf8",
				});
				assert.equal(
					result.status,
					[tools, checks, tests].every((value) => value === "success") ? 0 : 1,
					`${tools}/${checks}/${tests}: ${result.stderr}`,
				);
			}
		}
	}
});

test("the actual aggregate shell rejects every failed, skipped, cancelled or incomplete prerequisite", () => {
	const script = job("gate")
		.split("        run: |\n")[1]
		.split("\n")
		.map((line) => line.replace(/^ {10}/, ""))
		.join("\n");
	for (const quality of ["success", "failure", "cancelled", "skipped", ""]) {
		for (const image of ["success", "failure", "cancelled", "skipped", ""]) {
			const result = spawnSync("bash", ["-c", script], {
				env: { ...process.env, QUALITY_RESULT: quality, IMAGE_RESULT: image },
				encoding: "utf8",
			});
			assert.equal(
				result.status,
				quality === "success" && image === "success" ? 0 : 1,
				`${quality}/${image}: ${result.stderr}`,
			);
		}
	}
});
