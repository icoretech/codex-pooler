import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createOpenAI } from "@ai-sdk/openai";
import { streamText } from "ai";
import { Effect } from "effect";
import { applyOpenCodeErrorAdapter } from "./opencode_error_adapter.generated.mjs";

const [mode, ssePath] = process.argv.slice(2);
assert.ok(mode === "pre-output" || mode === "post-output");
assert.ok(ssePath);

const sse = await readFile(ssePath, "utf8");
const events = parseEvents(sse);
validateSequence(events, mode);

let fetchCount = 0;
const requestedURLs = [];
const baseURL = "https://contract-probe.invalid/v1";

const provider = createOpenAI({
  apiKey: "contract-probe-key",
  baseURL,
  fetch: async (url) => {
    fetchCount += 1;
    requestedURLs.push(String(url));
    assert.equal(String(url), `${baseURL}/responses`);

    return new Response(sse, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    });
  },
});

const result = streamText({
  model: provider.responses("contract-probe-model"),
  prompt: "",
  maxRetries: 0,
  onError({ error }) {
    callbackErrors.push(error);
  },
});

const parts = [];
const callbackErrors = [];
let thrownError;

try {
  for await (const part of result.fullStream) parts.push(part);
} catch (error) {
  thrownError = error;
}

assert.equal(fetchCount, 1);
assert.deepEqual(requestedURLs, [`${baseURL}/responses`]);

const meaningfulTextParts = parts.filter(
  (part) => part.type === "text-delta" && typeof part.text === "string" && part.text.length > 0,
);

if (mode === "pre-output") {
  assert.equal(callbackErrors.length, 1);
  assertAPIError(callbackErrors[0]);
  assert.equal(thrownError, undefined);
  assert.equal(meaningfulTextParts.length, 0);
  assert.equal(
    parts.some((part) => part.type === "finish" && part.finishReason !== "error"),
    false,
  );
} else {
  assert.equal(thrownError, undefined);
  assert.ok(callbackErrors.length >= 1);
  const errorParts = parts.filter((part) => part.type === "error");
  assert.ok(errorParts.length >= 1);

  for (const errorPart of errorParts) {
    const adaptedError = await Effect.runPromise(Effect.flip(applyOpenCodeErrorAdapter(errorPart)));
    assert.strictEqual(adaptedError, errorPart.error);
  }

  assert.ok(callbackErrors.every((error) => errorParts.some((part) => part.error === error)));

  assert.ok(meaningfulTextParts.length >= 1);
  assert.ok(parts.indexOf(meaningfulTextParts[0]) < parts.indexOf(errorParts[0]));

  const terminal = events.at(-1);
  const invalidFixtures = [
    events.map((event, index) => (index === events.length - 1 ? omitSequence(event) : event)),
    events.map((event, index) =>
      index === events.length - 1 ? { ...event, sequence_number: 2 } : event,
    ),
    events.map((event, index) =>
      index === events.length - 1 ? { ...event, sequence_number: "3" } : event,
    ),
    events.map((event, index) =>
      index === events.length - 1 ? { ...event, sequence_number: -1 } : event,
    ),
    events.map((event, index) =>
      index === events.length - 1 ? { ...event, sequence_number: 3.5 } : event,
    ),
    events.map((event, index) =>
      index === events.length - 1 ? { ...event, sequence_number: Number.MAX_SAFE_INTEGER + 1 } : event,
    ),
    [...events.slice(0, -1), { ...terminal, type: "response.completed" }],
  ];

  assert.ok(invalidFixtures.every((fixture) => !sequenceValid(fixture, mode)));
}

function assertAPIError(error) {
  assert.equal(error?.name, "AI_APICallError");
  assert.equal(error?.statusCode, 500);
  assert.equal(error?.isRetryable, true);
  assert.equal(error?.message, "upstream request failed: stream interrupted before terminal response event");
}

function omitSequence(event) {
  const { sequence_number: _sequenceNumber, ...withoutSequence } = event;
  return withoutSequence;
}

function parseEvents(value) {
  return value
    .split("\n\n")
    .filter(Boolean)
    .map((block) => {
      const line = block.split("\n").find((entry) => entry.startsWith("data: "));
      assert.ok(line);
      return JSON.parse(line.slice("data: ".length));
    });
}

function validateSequence(parsed, expectedMode) {
  assert.equal(sequenceValid(parsed, expectedMode), true);
}

function sequenceValid(parsed, expectedMode) {
  const sequences = parsed.map((event) => event.sequence_number);
  if (sequences.length === 0) return false;

  for (const sequence of sequences) {
    if (!Number.isSafeInteger(sequence) || sequence < 0) return false;
  }

  for (let index = 1; index < sequences.length; index += 1) {
    if (sequences[index] <= sequences[index - 1]) return false;
  }

  if (parsed.at(-1)?.type !== "response.failed") return false;
  if (parsed.some((event) => event.type === "response.completed")) return false;

  if (expectedMode === "pre-output") return sequences.length === 1 && sequences[0] === 0;

  return (
    expectedMode === "post-output" &&
    sequences.length === 3 &&
    sequences[0] === 0 &&
    sequences[1] === 2 &&
    sequences[2] === 3
  );
}
