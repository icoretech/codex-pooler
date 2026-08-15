import assert from "node:assert/strict";
import { createOpenAI } from "@ai-sdk/openai";
import { generateText } from "ai";

const baseURL = "https://contract-probe.invalid/v1";
const syntheticVisibleInput = String.fromCodePoint(120);
const cases = [
  { name: "true", compactionTrigger: true },
  { name: "false", compactionTrigger: false },
  { name: "omitted" },
];

const summaries = [];

for (const testCase of cases) {
  const captures = [];
  const provider = createOpenAI({
    apiKey: "contract-probe-key",
    baseURL,
    fetch: async (url, init) => {
      captures.push({ url: String(url), method: init?.method, body: String(init?.body) });

      return new Response(JSON.stringify({ error: { message: "synthetic rejection" } }), {
        status: 400,
        headers: { "content-type": "application/json" },
      });
    },
  });

  await assert.rejects(
    generateText({
      model: provider.responses("contract-probe-model"),
      prompt: syntheticVisibleInput,
      maxRetries: 0,
      providerOptions:
        testCase.compactionTrigger === undefined
          ? undefined
          : { openai: { compactionTrigger: testCase.compactionTrigger } },
    }),
  );

  assert.equal(captures.length, 1);

  const [capture] = captures;
  assert.equal(capture.url, `${baseURL}/responses`);
  assert.equal(capture.method, "POST");

  const body = JSON.parse(capture.body);
  const input = body.input;
  assert.ok(Array.isArray(input));
  assert.equal(input.length, testCase.compactionTrigger === true ? 2 : 1);

  const visibleInputIndexes = input.flatMap((item, index) =>
    item?.role === "user" &&
        Array.isArray(item?.content) &&
        item.content.some(
          (part) => part?.type === "input_text" && typeof part.text === "string" && part.text.length > 0,
        )
      ? [index]
      : [],
  );
  assert.deepEqual(visibleInputIndexes, [0]);

  const triggerIndexes = input.flatMap((item, index) =>
    item?.type === "compaction_trigger" ? [index] : [],
  );

  if (testCase.compactionTrigger === true) {
    assert.deepEqual(triggerIndexes, [input.length - 1]);
    assert.notEqual(input.at(-2)?.type, "compaction_trigger");
    assert.deepEqual(input.at(-1), { type: "compaction_trigger" });
  } else {
    assert.deepEqual(triggerIndexes, []);
  }

  summaries.push({
    case: testCase.name,
    method: capture.method,
    path: new URL(capture.url).pathname,
    calls: captures.length,
    visibleInputItems: visibleInputIndexes.length,
    terminalTrigger: triggerIndexes.length === 1 && triggerIndexes[0] === input.length - 1,
  });
}

console.log(JSON.stringify({ probe: "ai-sdk-responses-compaction-trigger", cases: summaries }));
