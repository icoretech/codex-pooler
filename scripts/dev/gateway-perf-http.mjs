#!/usr/bin/env node

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const rootDir = path.resolve(import.meta.dirname, "../..");
const SENTINEL_PROMPT = "SENTINEL_PROMPT_DO_NOT_LOG short status ping";
const MODEL = "gpt-5.4-mini";
const DRIVER_NAME = "gateway-perf-http";

const SCENARIOS = {
  "warmup-default": {
    route_family: "mixed",
    route_mix: ["backend", "backend", "v1_responses", "v1_chat_completions"],
    profile: "short-ok",
    concurrency: 1,
    duration_seconds: 60,
    phase: "warmup"
  },
  "baseline-1c": {
    route_family: "mixed",
    route_mix: ["backend", "backend", "v1_responses", "v1_chat_completions"],
    profile: "short-ok",
    concurrency: 1,
    duration_seconds: 60,
    phase: "measured"
  },
  "backend-short-10c": {
    route_family: "backend",
    route_mix: ["backend"],
    profile: "short-ok",
    concurrency: 10,
    duration_seconds: 120,
    phase: "measured"
  },
  "v1-short-10c": {
    route_family: "v1",
    route_mix: ["v1_responses", "v1_chat_completions"],
    profile: "short-ok",
    concurrency: 10,
    duration_seconds: 120,
    phase: "measured"
  },
  "mixed-short-10c": {
    route_family: "mixed",
    route_mix: ["backend", "backend", "v1_responses", "v1_chat_completions"],
    profile: "short-ok",
    concurrency: 10,
    duration_seconds: 120,
    phase: "measured"
  },
  "short-25c": {
    route_family: "mixed",
    route_mix: ["backend", "backend", "v1_responses", "v1_chat_completions"],
    profile: "short-ok",
    concurrency: 25,
    duration_seconds: 120,
    phase: "measured"
  },
  "long-10c": {
    route_family: "mixed",
    route_mix: ["backend", "backend", "v1_responses", "v1_chat_completions"],
    profile: "long-ok",
    concurrency: 10,
    duration_seconds: 300,
    phase: "measured"
  },
  "large-chunk-5c": {
    route_family: "mixed",
    route_mix: ["backend", "backend", "v1_responses", "v1_chat_completions"],
    profile: "large-chunk",
    concurrency: 5,
    duration_seconds: 300,
    phase: "measured"
  },
  "backend-timeout-5c": {
    route_family: "backend",
    route_mix: ["backend"],
    profile: "timeout",
    concurrency: 5,
    duration_seconds: 120,
    phase: "measured"
  },
  "disconnect-10c": {
    route_family: "mixed",
    route_mix: ["backend", "backend", "v1_responses", "v1_chat_completions"],
    profile: "disconnect-midstream",
    concurrency: 10,
    duration_seconds: 120,
    phase: "measured"
  }
};

const ROUTES = {
  backend: {
    route_family: "backend",
    path: "/backend-api/codex/responses",
    body: () => ({
      model: MODEL,
      input: [{ role: "user", content: [{ type: "input_text", text: SENTINEL_PROMPT }] }],
      stream: true
    })
  },
  v1_responses: {
    route_family: "v1_responses",
    path: "/v1/responses",
    body: () => ({
      model: MODEL,
      input: [{ role: "user", content: [{ type: "input_text", text: SENTINEL_PROMPT }] }],
      stream: true
    })
  },
  v1_chat_completions: {
    route_family: "v1_chat_completions",
    path: "/v1/chat/completions",
    body: () => ({
      model: MODEL,
      messages: [{ role: "user", content: SENTINEL_PROMPT }],
      stream: true
    })
  }
};

main().catch((error) => {
  console.error(`${DRIVER_NAME}: ${sanitizeError(error)}`);
  process.exit(2);
});

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.help) {
    printHelp();
    return;
  }

  const scenarioName = required(args, "scenario", "--scenario");
  const scenario = SCENARIOS[scenarioName];
  if (!scenario) {
    throw new Error(`unknown --scenario ${scenarioName}; expected one of ${Object.keys(SCENARIOS).join(", ")}`);
  }

  const runId = required(args, "run-id", "--run-id");
  const baseURL = normalizeBaseURL(required(args, "base-url", "--base-url"));
  const apiKeyEnv = required(args, "api-key-env", "--api-key-env");
  const profileManifestPath = required(args, "profile-manifest", "--profile-manifest");
  const durationSeconds = positiveInteger(args["duration-seconds"] ?? scenario.duration_seconds, "--duration-seconds");
  const concurrency = positiveInteger(args.concurrency ?? scenario.concurrency, "--concurrency");
  const phase = String(args.phase ?? scenario.phase);
  const dryRun = Boolean(args["dry-run"]);

  const manifest = await readProfileManifest(profileManifestPath);
  const profile = manifest.get(scenario.profile);
  if (!profile) {
    throw new Error(`profile manifest ${profileManifestPath} does not include required profile ${scenario.profile}`);
  }

  const allowedStatuses = allowedStatusesFor(profile);
  const driverDir = path.join(rootDir, "tmp", "gateway-perf", runId, "driver");
  await mkdir(driverDir, { recursive: true });

  const apiKey = dryRun ? "dry-run" : requiredEnv(apiKeyEnv);
  const startedAt = new Date();
  const requests = dryRun
    ? dryRunRequests({ scenario, scenarioName, runId, phase, concurrency, allowedStatuses })
    : await runLoad({ scenario, scenarioName, runId, baseURL, apiKey, phase, durationSeconds, concurrency, profile });
  const finishedAt = new Date();

  const summary = buildSummary({
    runId,
    scenarioName,
    scenario,
    profile,
    phase,
    concurrency,
    startedAt,
    finishedAt,
    allowedStatuses,
    requests
  });

  const summaryPath = path.join(driverDir, "http-summary.json");
  await writeFile(summaryPath, `${JSON.stringify(summary, null, 2)}\n`);

  console.log(
    `${DRIVER_NAME}: wrote ${path.relative(rootDir, summaryPath)} requests=${summary.requests.length} success=${summary.success_count} failure=${summary.failure_count}`
  );

  if (summary.failure_count > 0) {
    process.exit(20);
  }
}

function parseArgs(argv) {
  const args = {};

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];

    if (token === "--help" || token === "-h") {
      args.help = true;
      continue;
    }

    if (token === "--dry-run") {
      args["dry-run"] = true;
      continue;
    }

    if (!token.startsWith("--")) {
      throw new Error(`unexpected argument ${token}`);
    }

    const name = token.slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`${token} requires a value`);
    }

    args[name] = value;
    index += 1;
  }

  return args;
}

function printHelp() {
  console.log(`Usage: node scripts/dev/gateway-perf-http.mjs --run-id <id> --base-url <url> --api-key-env <env> --profile-manifest <path> --scenario <name> --duration-seconds <n> --concurrency <n> --phase <phase> [--dry-run]\n\nRequired options:\n  --run-id             Output run id under tmp/gateway-perf/<run-id>/\n  --base-url           Codex Pooler or fake upstream base URL, for example http://127.0.0.1:4000\n  --api-key-env        Environment variable that contains the Pool API key\n  --profile-manifest   Profile manifest written by gateway-perf-fake-upstream\n  --scenario           ${Object.keys(SCENARIOS).join(", ")}\n  --duration-seconds   Load window; workers finish their in-flight request after the window closes\n  --concurrency        Number of concurrent worker loops\n  --phase              warmup, measured, cooldown, or another probe phase label\n\nOptional:\n  --dry-run            Validate scenario/manifest and write a metadata-only planned summary without traffic`);
}

function required(args, key, label) {
  const value = args[key];
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${label} is required`);
  }

  return value.trim();
}

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`set ${name}`);
  }

  return value;
}

function positiveInteger(value, label) {
  const parsed = Number.parseInt(String(value), 10);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${label} must be a positive integer`);
  }

  return parsed;
}

function normalizeBaseURL(value) {
  const url = new URL(value);
  url.pathname = url.pathname.replace(/\/+$/, "");
  url.search = "";
  url.hash = "";
  return url.toString().replace(/\/+$/, "");
}

async function readProfileManifest(manifestPath) {
  const absolutePath = path.resolve(rootDir, manifestPath);
  const decoded = JSON.parse(await readFile(absolutePath, "utf8"));
  if (!Array.isArray(decoded)) {
    throw new Error(`profile manifest ${manifestPath} must contain an array`);
  }

  return new Map(
    decoded.map((profile) => {
      if (!profile || typeof profile.name !== "string") {
        throw new Error(`profile manifest ${manifestPath} contains an entry without a name`);
      }

      return [profile.name, profile];
    })
  );
}

function allowedStatusesFor(profile) {
  const statuses = profile.allowed_statuses;
  if (!Array.isArray(statuses) || statuses.length === 0) {
    throw new Error(`profile ${profile.name} must include allowed_statuses`);
  }

  return statuses.map((status) => positiveInteger(status, `allowed_statuses for ${profile.name}`));
}

async function runLoad({ scenario, scenarioName, runId, baseURL, apiKey, phase, durationSeconds, concurrency, profile }) {
  const requests = [];
  const deadline = Date.now() + durationSeconds * 1000;
  let requestIndex = 0;

  async function worker() {
    while (Date.now() < deadline) {
      const index = requestIndex;
      requestIndex += 1;
      const routeKey = scenario.route_mix[index % scenario.route_mix.length];
      const request = await executeRequest({
        index,
        routeKey,
        scenarioName,
        runId,
        baseURL,
        apiKey,
        phase,
        profile,
        durationSeconds
      });
      requests.push(request);
    }
  }

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  return requests.sort((left, right) => left.index - right.index);
}

async function executeRequest({ index, routeKey, scenarioName, runId, baseURL, apiKey, phase, profile, durationSeconds }) {
  const route = ROUTES[routeKey];
  if (!route) {
    throw new Error(`unknown route key ${routeKey}`);
  }

  const started = performance.now();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), requestTimeoutMs(profile, durationSeconds));

  try {
    const response = await fetch(`${baseURL}${route.path}`, {
      method: "POST",
      signal: controller.signal,
      headers: requestHeaders({ apiKey, scenarioName, runId, phase, profileName: profile.name, route, index }),
      body: JSON.stringify(route.body())
    });

    const stream = await consumeEventStream(response, profile);
    const status = classifiedStatus(response.status, stream, profile);
    const durationMs = Math.round(performance.now() - started);
    const allowed = profile.allowed_statuses.includes(status);
    const success = allowed && status >= 200 && status < 300 && stream.terminal;

    return requestEntry({
      index,
      route,
      profileName: profile.name,
      phase,
      status,
      durationMs,
      outcome: success ? "success" : classifiedOutcome(status, stream, profile, allowed),
      errorClass: success ? null : classifiedErrorClass(status, stream, profile, allowed)
    });
  } catch (error) {
    const durationMs = Math.round(performance.now() - started);
    const aborted = error?.name === "AbortError";
    const status = aborted ? 504 : 0;
    const allowed = profile.allowed_statuses.includes(status);

    return requestEntry({
      index,
      route,
      profileName: profile.name,
      phase,
      status,
      durationMs,
      outcome: allowed && aborted ? "timeout" : "error",
      errorClass: aborted ? "timeout" : safeErrorClass(error)
    });
  } finally {
    clearTimeout(timeout);
  }
}

function requestHeaders({ apiKey, scenarioName, runId, phase, profileName, route, index }) {
  return {
    authorization: `Bearer ${apiKey}`,
    accept: "text/event-stream",
    "content-type": "application/json",
    "user-agent": "codex-pooler-gateway-perf-http/1",
    "x-gateway-perf-profile": profileName,
    "x-codex-pooler-perf-run-id": runId,
    "x-codex-pooler-perf-scenario": scenarioName,
    "x-codex-pooler-perf-profile": profileName,
    "x-codex-pooler-perf-phase": phase,
    "x-codex-pooler-perf-route-family": route.route_family,
    "x-codex-pooler-perf-request-index": String(index)
  };
}

async function consumeEventStream(response, profile) {
  const result = { terminal: false, failed: false, incomplete: false };

  if (!response.body) {
    result.terminal = response.status < 400;
    return result;
  }

  const decoder = new TextDecoder();
  let buffer = "";

  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, { stream: true });
    consumeBlocks(result, buffer, false);
    buffer = remainingBlock(buffer);
  }

  buffer += decoder.decode();
  consumeBlocks(result, buffer, true);

  if (response.status >= 200 && response.status < 300 && !result.terminal) {
    result.incomplete = profile.close_mode !== "clean_close" || true;
  }

  return result;
}

function consumeBlocks(result, buffer, final) {
  const blocks = buffer.split(/\r?\n\r?\n/);
  const completeBlocks = final ? blocks : blocks.slice(0, -1);

  for (const block of completeBlocks) {
    consumeBlock(result, block);
  }
}

function remainingBlock(buffer) {
  const parts = buffer.split(/\r?\n\r?\n/);
  return parts.at(-1) ?? "";
}

function consumeBlock(result, block) {
  const lines = block.split(/\r?\n/);
  const event = lines.find((line) => line.startsWith("event:"))?.slice("event:".length).trim() ?? null;
  const dataLines = lines.filter((line) => line.startsWith("data:")).map((line) => line.slice("data:".length).trim());

  for (const data of dataLines) {
    if (data === "[DONE]") {
      result.terminal = true;
      continue;
    }

    if (data === "") {
      continue;
    }

    let decoded = null;
    try {
      decoded = JSON.parse(data);
    } catch (_error) {
      decoded = null;
    }

    const type = decoded?.type ?? event;
    if (type === "response.completed") {
      result.terminal = true;
    }

    if (type === "response.failed" || type === "error" || decoded?.error) {
      result.failed = true;
    }
  }
}

function classifiedStatus(httpStatus, stream, profile) {
  if (httpStatus >= 400) {
    return httpStatus;
  }

  if (stream.failed || profile.close_mode === "upstream_error") {
    return 502;
  }

  if (stream.incomplete && profile.close_mode === "client_disconnect") {
    return 499;
  }

  if (stream.incomplete) {
    return 502;
  }

  return httpStatus;
}

function classifiedOutcome(status, stream, profile, allowed) {
  if (!allowed) {
    return "unexpected_status";
  }

  if (status === 499 || profile.close_mode === "client_disconnect") {
    return "classified_disconnect";
  }

  if (status === 504 || profile.close_mode === "timeout") {
    return "timeout";
  }

  if (stream.failed || status >= 500) {
    return "upstream_failure";
  }

  return "failure";
}

function classifiedErrorClass(status, stream, profile, allowed) {
  if (!allowed) {
    return "unexpected_status";
  }

  if (status === 499 || profile.close_mode === "client_disconnect") {
    return "client_disconnect";
  }

  if (status === 504 || profile.close_mode === "timeout") {
    return "timeout";
  }

  if (stream.failed || status >= 500) {
    return "upstream_failure";
  }

  return "request_failed";
}

function requestTimeoutMs(profile, durationSeconds) {
  const profileDuration = Number(profile.first_event_delay_ms || 0) + Number(profile.inter_event_delay_ms || 0) * Number(profile.event_count || 0);
  const durationWindow = durationSeconds * 1000 + 5000;
  return Math.max(5000, Math.min(Math.max(profileDuration + 5000, durationWindow), 10 * 60 * 1000));
}

function requestEntry({ index, route, profileName, phase, status, durationMs, outcome, errorClass }) {
  return {
    index,
    route_family: route.route_family,
    route_path: route.path,
    profile: profileName,
    phase,
    status,
    duration_ms: durationMs,
    outcome,
    error_class: errorClass
  };
}

function dryRunRequests({ scenario, scenarioName, runId, phase, concurrency, allowedStatuses }) {
  return Array.from({ length: concurrency }, (_unused, index) => {
    const routeKey = scenario.route_mix[index % scenario.route_mix.length];
    const route = ROUTES[routeKey];

    return requestEntry({
      index,
      route,
      profileName: scenario.profile,
      phase,
      status: allowedStatuses[0],
      durationMs: 0,
      outcome: "dry_run",
      errorClass: null
    });
  });
}

function buildSummary({ runId, scenarioName, scenario, profile, phase, concurrency, startedAt, finishedAt, allowedStatuses, requests }) {
  const successful = requests.filter((request) => request.outcome === "success" || request.outcome === "dry_run");
  const failed = requests.filter((request) => !successful.includes(request));
  const durations = requests.map((request) => request.duration_ms).sort((left, right) => left - right);

  return {
    run_id: runId,
    scenario: scenarioName,
    route_family: scenario.route_family,
    profile: profile.name,
    phase,
    concurrency,
    started_at: startedAt.toISOString(),
    finished_at: finishedAt.toISOString(),
    success_count: successful.length,
    failure_count: failed.length,
    allowed_statuses: allowedStatuses,
    p95_duration_ms: percentile(durations, 95),
    requests
  };
}

function percentile(values, percentileRank) {
  if (values.length === 0) {
    return 0;
  }

  const index = Math.ceil((percentileRank / 100) * values.length) - 1;
  return values[Math.min(Math.max(index, 0), values.length - 1)];
}

function safeErrorClass(error) {
  if (error?.code) {
    return String(error.code).slice(0, 80);
  }

  if (error?.name) {
    return String(error.name).slice(0, 80);
  }

  return "request_error";
}

function sanitizeError(error) {
  return String(error?.stack || error?.message || error).replace(/Bearer\s+\S+/gi, "Bearer [redacted]");
}
