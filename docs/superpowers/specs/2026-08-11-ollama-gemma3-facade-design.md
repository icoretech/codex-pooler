# Ollama `gemma3` Facade Design

Date: 2026-08-11

Status: Approved for implementation planning

## Summary

Codex Pooler will expose an authenticated, integrated compatibility facade whose
only public model identity is `gemma3`. Client-selected model and reasoning
values have no authority. Text, vision, and tool-capable work is dispatched
through the existing gateway as GPT-5.6 Sol with maximum reasoning effort.

The facade is implemented inside Codex Pooler rather than as a sidecar. This
keeps one execution path for account selection, health and quota filtering,
prompt-cache locality, session and file affinity, retries, accounting,
streaming, cancellation, and operator diagnostics.

The public disguise applies to protocol metadata and self-identification. The
operator plane remains truthful: authorized operators can inspect the real
effective model, selected assignment, reasoning policy, retries, and sanitized
upstream failure details.

## Goals

1. Advertise exactly one virtual model, `gemma3`, whenever a model is
   advertised.
2. Accept a missing model, `gemma3`, or any other client model name and ignore
   the supplied value.
3. Force every text, vision, and tool-capable reasoning request to
   `gpt-5.6-sol` with reasoning effort `max`.
4. Preserve the existing Codex Pooler gateway's routing, failover, caching,
   continuity, accounting, admission, and privacy behavior.
5. Support native Ollama, supported OpenAI-compatible routes, Codex-compatible
   routes, and the Ollama-style Anthropic Messages surface needed by Claude
   Code.
6. Require a valid Pool API key on every facade request.
7. Prevent client-visible protocol metadata, headers, errors, and stream
   envelopes from disclosing the effective model, provider, upstream account,
   or Pool assignment.
8. Fail closed rather than selecting another reasoning model.
9. Verify the facade with captured-upstream, differential, fault-injection,
   streaming, and real-client smoke tests before claiming Codex-level backend
   robustness.

## Non-goals

1. Reimplement the Codex CLI agent runtime. Codex CLI and Claude Code retain
   their own local tools, prompts, permission systems, compaction behavior, and
   session user experience.
2. Claim byte-for-byte or token-for-token equivalence between protocols.
3. Provide a mutable local Ollama model store.
4. Add embeddings, batch processing, or general Realtime API support where
   Codex Pooler does not already have an execution path.
5. Rewrite arbitrary assistant content merely because it contains words such
   as "OpenAI" or a GPT model name. Blind content replacement would corrupt
   code, documentation, and legitimate answers. The strict secrecy guarantee
   covers implementation metadata; a server-owned identity instruction covers
   model self-identification.
6. Hide the name of a compatibility protocol the caller explicitly chose. For
   example, a caller that requests `/backend-api/codex` necessarily knows the
   path contains `codex`; this does not authorize leaking an upstream model or
   account.

## Fixed persona and routing invariant

One authoritative module owns the immutable facade constants:

```text
public model:       gemma3
effective model:    gpt-5.6-sol
reasoning effort:   max
```

These values are server-owned and cannot be overridden by request fields,
headers, query parameters, API-key metadata, or protocol adapters.

The facade attaches a typed persona marker to `RequestOptions`. The marker
contains the public model identity and the fixed effective routing decision.
The raw client model value is not forwarded upstream and does not participate
in routing. Operator accounting records `gemma3` as the public/requested model
and the real model as the effective model.

Enforcement occurs twice:

1. The ingress adapter normalizes the request and installs the fixed target and
   reasoning decision before ordinary model validation.
2. A pre-dispatch invariant verifies the effective model and reasoning effort
   immediately before candidate selection and upstream work.

If the invariant fails, the request performs no upstream work.

API-key model and reasoning policies may further deny a request, but they may
never redirect it. An allow list that excludes `gpt-5.6-sol`, a conflicting
enforced model, or a reasoning ceiling below `max` produces a fail-closed
policy error. An unrestricted key or a policy agreeing with the fixed target is
accepted. Pool ownership, status, request limits, token limits, expiry, and
image-generation permission continue to apply normally.

If the authenticated Pool has no visible and eligible GPT-5.6 Sol assignment,
the public result is a protocol-shaped `gemma3` unavailable error. There is no
fallback to Terra, Luna, another GPT family, or a media model for reasoning.

## Architecture

The implementation adds a facade boundary around the existing execution
engine:

```text
authenticated client request
  -> protocol-specific decoder
  -> fixed persona normalization
  -> existing Gateway.execute / dispatch pipeline
  -> protocol-specific stream or response encoder
  -> persona redaction and response-header allowlist
```

There is no second router, account selector, cache, retry loop, or accounting
system. Protocol adapters produce the same internal Responses-shaped work used
by the current public compatibility layer.

The facade applies to runtime client surfaces:

- native Ollama `/api/*` routes described below;
- supported OpenAI-compatible `/v1/*` routes;
- Anthropic-compatible `/v1/messages` routes;
- supported `/backend-api/codex/*` runtime routes.

Browser administration, Observatory, background workers, audit records, and
operator diagnostics are not disguised.

## Native Ollama surface

### Inference

`POST /api/chat` supports:

- missing or arbitrary `model` values;
- messages with system, user, assistant, and tool roles;
- text and base64 image inputs;
- function tools and tool-call results;
- JSON mode and JSON-schema structured output;
- `stream` with Ollama newline-delimited JSON semantics;
- safe reasoning-summary presentation through `think` without allowing
  `think` to change the fixed reasoning effort.

`POST /api/generate` supports:

- `prompt`, `system`, `suffix`, and base64 images;
- JSON mode and JSON-schema structured output;
- `stream` with Ollama newline-delimited JSON semantics;
- generation limits that have an unambiguous Responses equivalent.

Ollama options with a safe, well-defined equivalent are translated. Local-only
options such as model keep-alive and local context allocation are accepted as
no-ops where real clients commonly send them. An option that would be
misleading or cannot be represented returns a deterministic Ollama-shaped
validation error rather than being silently reinterpreted.

### Discovery

- `GET /api/tags` returns either no models when the fixed target is not
  routable for the authenticated Pool, or exactly one virtual `gemma3` entry.
- `POST /api/show` ignores the requested name and returns virtual `gemma3`
  metadata and facade-supported capabilities.
- `GET /api/ps` returns only virtual `gemma3` state.
- `GET /api/version` returns an Ollama-compatible semantic version representing
  the implemented contract, without Pooler or upstream identity.

All discovery routes require Pool API-key authentication because discovery is
Pool-specific.

### Model management

`POST /api/pull` is a successful streaming or non-streaming no-op when used for
`gemma3`, so clients that pull before first use can continue.

Create, copy, push, delete, and blob-management operations return an
Ollama-shaped fixed-virtual-model error. They cannot add, rename, replace, or
remove `gemma3`.

Embedding routes return a stable unsupported error unless a separately
approved implementation adds a real embedding execution path. They must never
fabricate vectors from GPT text output.

## OpenAI-compatible and Codex-compatible surfaces

Existing supported routes retain their request and response shapes, including
Responses, Chat Completions, files, transcription, and image operations.
Facade normalization occurs before their current required-model checks, so the
client may omit `model`.

The compatibility work includes:

- `POST /v1/responses`;
- `GET /v1/responses` for the existing narrow websocket mode;
- `POST /v1/chat/completions`;
- `POST /v1/completions`, translated through Responses for legacy clients;
- `GET /v1/models`;
- `GET /v1/models/:model`;
- current supported files, audio, images, and usage routes;
- current supported `/backend-api/codex/*` runtime routes.

Model lists and model detail return one virtual `gemma3` model. Capability and
context metadata may describe the usable facade but must not contain an
effective model identifier, upstream account, provider, or assignment.

Public usage views preserve safe totals while relabeling model buckets as
`gemma3` and omitting upstream account or assignment dimensions.

Nested model selectors, including media and moderation selectors, are not
client-authoritative. Direct media operations use the same hidden specialist
tool paths that a Codex session would use. They do not provide a second
reasoning-model route and never expose their helper identity publicly.

## Anthropic Messages and Claude Code

Claude Code uses an Anthropic-format gateway rather than native Ollama chat.
The facade therefore implements:

- `POST /v1/messages` for JSON and Anthropic SSE streaming;
- `POST /v1/messages/count_tokens` using Pooler's local token-counting support;
- `Authorization: Bearer <pool-key>` and `x-api-key: <pool-key>` authentication;
- accepted `anthropic-version` and supported `anthropic-beta` headers;
- system prompts, multi-turn messages, text, images, tool definitions,
  `tool_use`, and `tool_result` blocks;
- supported tool-choice semantics;
- Anthropic stop reasons and token usage;
- cache-control blocks translated into existing explicit prompt-cache controls.

Any Claude model alias or full model name is ignored. JSON responses, SSE
`message_start`, and all other identity-bearing Anthropic events report
`gemma3`.

If both supported authentication headers are present, they must identify the
same Pool key. A mismatch is rejected rather than choosing one header by
precedence.

Reasoning remains GPT-5.6 Sol/max regardless of Anthropic thinking fields.
Thinking controls may request a safe summary presentation but cannot expose raw
private reasoning or reduce the effective effort.

Documentation will show Claude Code configured with the Pooler base URL, a Pool
API key, and `gemma3` as every default model alias used by the client.

## Request normalization

The normalizer runs before ordinary public compatibility validation:

1. Confirm the body is a valid object for the selected protocol.
2. Preserve only the client fields relevant to that protocol's response
   formatting and supported features.
3. Discard every top-level and nested client model selector.
4. Install the fixed effective model and a typed `always_use/max` reasoning
   decision.
5. Add a server-owned instruction that the assistant's external identity is
   `gemma3` and that internal routing or provider identity must not be
   disclosed.
6. Convert the protocol payload into the existing canonical Responses request.
7. Run API-key authorization against the fixed target.
8. Dispatch through the existing gateway.

The internal canonical payload may contain the real model because the upstream
protocol requires a routing target. That payload is never returned to the
client:

```json
{
  "model": "gpt-5.6-sol",
  "reasoning": {"effort": "max"}
}
```

The client is never required or permitted to construct this object.

## Response and stream normalization

Each protocol has a dedicated encoder over the common gateway result:

- Ollama non-streaming responses use Ollama JSON objects.
- Ollama streaming responses emit one complete NDJSON object per chunk and a
  terminal `done` object.
- OpenAI-compatible Responses and Chat Completions preserve their documented
  JSON/SSE shapes.
- Anthropic Messages emits the expected message/content-block SSE sequence.
- Codex-compatible routes preserve protocol-required transport behavior.

All identity-bearing `model` fields are replaced with `gemma3`, including
initial events, deltas, terminal events, tool-call envelopes, and collected
responses.

Facade response headers use per-protocol allowlists. Native Ollama and
Anthropic routes do not forward `x-codex-*`, `x-openai-*`, raw upstream request
IDs, account labels, assignment IDs, or provider-specific rate-limit headers.
Safe local correlation IDs may be exposed under protocol-neutral names.
Protocol-required Codex headers remain only on the caller-selected Codex
compatibility routes and contain locally generated opaque state, never provider
state.

Upstream error bodies are never passed through verbatim. A central facade error
mapper converts pre-stream errors into the selected protocol shape and removes
effective model, provider, account, assignment, endpoint, and credential
details. If a stream fails after headers or chunks have been sent, the adapter
uses the protocol's safe terminal-error behavior and never retries the request.

Operator logs retain sanitized true causes and effective routing metadata.
They continue to exclude prompt text, generated content, file/media content,
credentials, raw payloads, and raw provider responses.

## Caching and continuity

The facade uses current Pooler cache and continuity machinery rather than
introducing new storage.

- Internal cache identity uses the fixed effective model, not `gemma3`.
- Client-provided cache identifiers are namespaced by authenticated Pool and
  API key before they influence affinity.
- Existing OpenAI prompt-cache options and cache breakpoints continue to work.
- Anthropic cache-control blocks map to the same explicit cache controls.
- Native chat primarily uses the full submitted message history.
- An optional opaque `x-ollama-session-id` maps to existing session affinity;
  it never contains an upstream or provider identifier.
- Existing previous-response, websocket, file, and Codex-session continuity
  paths remain authoritative on their current surfaces.

Retries may occur only before downstream output begins. Once a response is
streaming, replay is prohibited to prevent duplicate text or duplicate tool
calls. Client disconnects propagate cancellation through the existing gateway
where supported.

## Security and privacy properties

1. Every facade route authenticates before catalog discovery or upstream work.
2. Client model and reasoning fields have no routing authority.
3. Conflicting server policy fails closed.
4. No fallback reasoning model is permitted.
5. Public error construction uses local allowlisted fields, not subtraction
   from arbitrary upstream objects.
6. Response headers use allowlists.
7. Stream transforms are incremental and bounded; they do not buffer an
   unbounded response merely to redact it.
8. The public identity instruction is server-owned and cannot be removed by a
   client request.
9. Operator truth and client disguise are separate typed projections of the
   same request; the client projection is never reused for accounting or
   routing.
10. Raw client model values are neither forwarded nor used as cache or session
    keys.

## Error behavior

Errors preserve meaningful status classes while hiding implementation details:

- `401` for missing or invalid Pool credentials;
- `403` for disabled compatibility, Pool policy, or permission denials;
- `400` for malformed or unsupported client protocol fields;
- `429` for Pool-key limits;
- `503` when virtual `gemma3` has no eligible fixed-target backend;
- `504` for safe timeout outcomes when no response has begun.

Native errors use Ollama-shaped bodies, Anthropic errors use Anthropic-shaped
bodies, and OpenAI/Codex errors use their corresponding compatibility shape.
Public messages refer only to `gemma3` and local policy concepts.

## Verification strategy

Implementation follows test-driven development. Tests are added at the narrowest
appropriate layer and then exercised through controller and end-to-end paths.

### Fixed-target proofs

- Capture every upstream request from native Ollama, OpenAI, Anthropic, and
  Codex routes.
- Assert the effective model is exactly `gpt-5.6-sol`.
- Assert the effective reasoning effort is exactly `max`.
- Cover missing, blank, `gemma3`, arbitrary, and nested client model values.
- Prove conflicting key policies and unavailable target assignments perform
  zero upstream work.
- Prove no route falls back to another reasoning model.

### Protocol conformance

- Ollama chat and generate, streaming and collected JSON.
- Tools, tool results, images, structured output, and safe thinking summaries.
- Tags, show, running models, version, and pull no-op.
- OpenAI Responses, Chat Completions, legacy Completions, model list/detail,
  files, audio, images, and current websocket support.
- Anthropic Messages JSON/SSE, system prompts, vision, tool loops, stop reasons,
  usage, cache controls, and token counting.

### Robustness and fault injection

- Multiple-account routing and prompt-cache affinity.
- Quota exhaustion, saved-reset behavior, account health changes, retryable
  upstream statuses, and terminal statuses.
- Timeouts before and after streaming begins.
- Client disconnect and cancellation.
- Partial NDJSON/SSE frames and chunk boundaries split at every relevant byte
  boundary.
- Long tool loops and long-context requests.
- File and session affinity.
- Concurrent requests using different Pool keys.

### Leakage checks

Fixtures use distinctive fake effective model, provider, account, assignment,
endpoint, and request identifiers. Tests recursively inspect:

- JSON responses;
- response headers;
- NDJSON chunks;
- SSE events;
- websocket frames;
- pre-stream and late-stream errors.

The public projections must contain only `gemma3` in identity-bearing fields
and none of the distinctive hidden values. Operator projections must retain the
safe effective-routing evidence needed for debugging.

### Differential and client tests

- Send semantically equivalent requests through a test-only direct gateway
  baseline that bypasses public persona projection and through the facade, then
  compare captured canonical upstream work and normalized terminal outcomes
  rather than stochastic generated text. The public Codex route is not the
  baseline because it is itself subject to the facade.
- Run native Ollama-compatible SDK smoke tests.
- Run the OpenAI SDK against `/v1` without a client model where the SDK permits
  omission, and with arbitrary names where it requires one.
- Run Codex CLI against the cloaked Codex-compatible surface with `gemma3` and
  verify catalog negotiation, streaming, tool execution, interruption,
  continuation, and supported compaction behavior.
- Run Claude Code with every configured model alias set to `gemma3` and verify
  repository reads, file edits, shell tools, multi-turn tool use, interruption,
  continuation, and a long-session cache path.

Codex-level backend robustness is not claimed until these gates pass.

## Documentation and rollout

Documentation will provide:

- authenticated curl examples for native Ollama;
- OpenAI SDK configuration;
- Claude Code environment and model-alias configuration;
- the fixed-model and max-reasoning guarantee;
- supported and intentionally unsupported endpoint tables;
- cache, continuity, and error semantics;
- a warning that operators retain truthful internal diagnostics.

Rollout is fail closed. A deployment may start while a particular Pool lacks an
eligible target assignment, but that Pool advertises no model and cannot
dispatch facade inference until GPT-5.6 Sol is routable. Existing database data
does not need to be rewritten solely to disguise the facade; incompatible
existing API-key policies are surfaced to operators and denied at runtime.

## Acceptance criteria

The work is complete only when:

1. All approved routes are implemented and authenticated.
2. Only `gemma3` is publicly advertised or returned as a model identity.
3. Captured upstream reasoning requests prove GPT-5.6 Sol/max on every protocol.
4. No client model or reasoning field can change the effective decision.
5. Existing routing, caching, continuity, accounting, and privacy tests remain
   green.
6. New conformance, fault-injection, leak, differential, and client smoke tests
   pass.
7. Documentation includes working Ollama, OpenAI, and Claude Code examples.
8. The implementation has been reviewed for protocol correctness, data leaks,
   and regression risk.

## Current reference contracts

- OpenAI GPT-5.6 model guidance:
  <https://developers.openai.com/api/docs/guides/latest-model>
- OpenAI GPT-5.6 Sol capabilities:
  <https://developers.openai.com/api/docs/models/gpt-5.6-sol>
- Ollama native API introduction:
  <https://docs.ollama.com/api/introduction>
- Ollama OpenAI compatibility:
  <https://docs.ollama.com/api/openai-compatibility>
- Ollama Anthropic compatibility:
  <https://docs.ollama.com/api/anthropic-compatibility>
- Anthropic Claude Code gateway configuration:
  <https://docs.anthropic.com/en/docs/claude-code/llm-gateway>
