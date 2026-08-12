import Anthropic from '@anthropic-ai/sdk';
import { Ollama } from 'ollama';
import OpenAI from 'openai';

const publicModel = 'gemma3';
const rawBaseURL = process.env.FACADE_BASE_URL;
const apiKey = process.env.FACADE_POOL_API_KEY;

if (!rawBaseURL || !apiKey) {
  process.stderr.write('FACADE_BASE_URL and FACADE_POOL_API_KEY are required\n');
  process.exit(2);
}

let baseURL;

try {
  const parsed = new URL(rawBaseURL);
  if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password) {
    throw new Error('invalid URL');
  }
  baseURL = parsed.toString().replace(/\/$/, '');
} catch {
  process.stderr.write('FACADE_BASE_URL must be an http(s) URL without credentials\n');
  process.exit(2);
}

const ollama = new Ollama({
  host: baseURL,
  headers: { Authorization: `Bearer ${apiKey}` },
});

const openai = new OpenAI({
  apiKey,
  baseURL: `${baseURL}/v1`,
  maxRetries: 0,
  timeout: 120_000,
});

const anthropic = new Anthropic({
  apiKey,
  baseURL,
  maxRetries: 0,
  timeout: 120_000,
});

const tool = {
  name: 'inspect_fixture',
  description: 'Inspect a named local fixture',
  parameters: {
    type: 'object',
    properties: { path: { type: 'string' } },
    required: ['path'],
    additionalProperties: false,
  },
};

const privateTokens = [
  'gpt-5.6-sol',
  'facade-provider-private-sentinel',
  'facade-account-private-sentinel',
  'facade-assignment-private-sentinel',
  'facade-provider-request-id-sentinel',
  'facade-upstream-credential-sentinel',
];

function fail(label, message) {
  throw new Error(`${label}: ${message}`);
}

function assertCloaked(label, value) {
  const serialized = JSON.stringify(value);
  if (privateTokens.some((token) => serialized.includes(token)) || serialized.includes(apiKey)) {
    fail(label, 'private facade identity escaped');
  }
}

function assertModel(label, value) {
  if (value !== publicModel) {
    fail(label, `expected model ${publicModel}`);
  }
}

function assertText(label, value) {
  if (typeof value !== 'string' || value.length === 0) {
    fail(label, 'missing text output');
  }
}

function responseText(response) {
  if (typeof response.output_text === 'string' && response.output_text.length > 0) {
    return response.output_text;
  }

  return (response.output ?? [])
    .flatMap((item) => item.type === 'message' ? (item.content ?? []) : [])
    .filter((part) => part.type === 'output_text' && typeof part.text === 'string')
    .map((part) => part.text)
    .join('');
}

async function verifyOllama() {
  const text = await ollama.chat({
    model: publicModel,
    messages: [{ role: 'user', content: 'Reply with a short SDK smoke acknowledgement.' }],
    stream: false,
  });

  assertModel('ollama text', text.model);
  assertText('ollama text', text.message?.content);
  assertCloaked('ollama text', text);

  const toolResponse = await ollama.chat({
    model: publicModel,
    messages: [{ role: 'user', content: 'Use inspect_fixture for README.md if useful.' }],
    tools: [
      {
        type: 'function',
        function: {
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
        },
      },
    ],
    stream: false,
  });

  assertModel('ollama tool', toolResponse.model);
  assertCloaked('ollama tool', toolResponse);

  const stream = await ollama.chat({
    model: publicModel,
    messages: [{ role: 'user', content: 'Stream a short SDK smoke acknowledgement.' }],
    stream: true,
  });

  let terminalCount = 0;
  let textLength = 0;

  for await (const part of stream) {
    assertModel('ollama stream', part.model);
    assertCloaked('ollama stream', part);
    textLength += part.message?.content?.length ?? 0;
    if (part.done === true) terminalCount += 1;
  }

  if (terminalCount !== 1 || textLength === 0) {
    fail('ollama stream', 'missing text or unique terminal');
  }
}

async function verifyOpenAI() {
  const text = await openai.responses.create({
    model: publicModel,
    input: 'Reply with a short SDK smoke acknowledgement.',
  });

  assertModel('openai text', text.model);
  assertText('openai text', responseText(text));
  assertCloaked('openai text', text);

  const toolResponse = await openai.responses.create({
    model: publicModel,
    input: 'Use inspect_fixture for README.md if useful.',
    tools: [
      {
        type: 'function',
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
      },
    ],
  });

  assertModel('openai tool', toolResponse.model);
  assertCloaked('openai tool', toolResponse);

  const stream = await openai.responses.create({
    model: publicModel,
    input: 'Stream a short SDK smoke acknowledgement.',
    stream: true,
  });

  let completedCount = 0;
  let textLength = 0;
  let advertisedModel = false;

  for await (const event of stream) {
    assertCloaked('openai stream', event);
    if (typeof event.model === 'string') {
      assertModel('openai stream', event.model);
      advertisedModel = true;
    }
    if (typeof event.response?.model === 'string') {
      assertModel('openai stream', event.response.model);
      advertisedModel = true;
    }
    if (event.type === 'response.output_text.delta') textLength += event.delta?.length ?? 0;
    if (event.type === 'response.completed') completedCount += 1;
  }

  if (!advertisedModel || completedCount !== 1 || textLength === 0) {
    fail('openai stream', 'missing model, text, or unique completion');
  }
}

async function verifyAnthropic() {
  const text = await anthropic.messages.create({
    model: publicModel,
    max_tokens: 128,
    messages: [{ role: 'user', content: 'Reply with a short SDK smoke acknowledgement.' }],
  });

  assertModel('anthropic text', text.model);
  if (!text.content?.some((block) => block.type === 'text' && block.text.length > 0)) {
    fail('anthropic text', 'missing text output');
  }
  assertCloaked('anthropic text', text);

  const toolResponse = await anthropic.messages.create({
    model: publicModel,
    max_tokens: 128,
    messages: [{ role: 'user', content: 'Use inspect_fixture for README.md if useful.' }],
    tools: [
      {
        name: tool.name,
        description: tool.description,
        input_schema: tool.parameters,
      },
    ],
  });

  assertModel('anthropic tool', toolResponse.model);
  assertCloaked('anthropic tool', toolResponse);

  const stream = await anthropic.messages.create({
    model: publicModel,
    max_tokens: 128,
    messages: [{ role: 'user', content: 'Stream a short SDK smoke acknowledgement.' }],
    stream: true,
  });

  let stopCount = 0;
  let textLength = 0;
  let advertisedModel = false;

  for await (const event of stream) {
    assertCloaked('anthropic stream', event);
    if (event.type === 'message_start') {
      assertModel('anthropic stream', event.message.model);
      advertisedModel = true;
    }
    if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
      textLength += event.delta.text.length;
    }
    if (event.type === 'message_stop') stopCount += 1;
  }

  if (!advertisedModel || stopCount !== 1 || textLength === 0) {
    fail('anthropic stream', 'missing model, text, or unique message_stop');
  }
}

try {
  await verifyOllama();
  await verifyOpenAI();
  await verifyAnthropic();
  process.stdout.write('official SDK facade smoke passed: ollama openai anthropic\n');
} catch (error) {
  const label = error instanceof Error && error.message.includes(':')
    ? error.message.split(':', 1)[0]
    : 'client';
  process.stderr.write(`official SDK facade smoke failed: ${label}\n`);
  process.exitCode = 1;
}
