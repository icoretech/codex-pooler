# Codex Pooler

Codex Pooler is a Phoenix application for the `codex-pooler` service. The OTP app is `codex_pooler`, the database names use the `codex_pooler_*` prefix, `CodexPooler.Pools` owns pool aggregate primitives, and `CodexPooler.Admin.PoolWorkflow` owns operator-facing pool create/edit orchestration across pools, upstreams, and access policy.

The Phoenix application includes Codex CLI backend compatibility routes, first-run bootstrap, login/session/password helpers, health/readiness checks, Prometheus metrics, Oban background jobs, and authenticated `/admin/*` operator LiveViews. Bootstrap, login, invite onboarding, and `/admin/*` are browser UI surfaces.

## Supported route surface

### Codex-only runtime API

These routes preserve the non-dashboard backend surface used by Codex clients. They require `Authorization: Bearer <api-key>`, except the usage routes can also accept a stored ChatGPT upstream `access_token` when paired with `chatgpt-account-id`.

- `GET /backend-api/codex/models`
- `GET /backend-api/codex/v1/models`, explicit alias for the backend models surface
- `POST /backend-api/codex/responses`
- `POST /backend-api/codex/v1/responses`, explicit alias for the backend responses surface
- `POST /backend-api/codex/responses/compact`
- `POST /backend-api/codex/v1/responses/compact`, compact alias for Codex clients configured with `/backend-api/codex/v1` as the backend base URL
- `POST /backend-api/codex/v1/chat/completions`, explicit alias that normalizes into the canonical backend responses pipeline
- `POST /backend-api/codex/images/generations`, backend-compatible Codex image proxy route for typed image-generation clients
- `POST /backend-api/codex/images/edits`, backend-compatible Codex image proxy route for typed image-edit clients
- `GET /backend-api/codex/responses`, websocket upgrade required. The route accepts upgrade/header `x-codex-turn-state` only as a legacy fallback; request-scoped turn state for each `response.create` frame travels in `response.create.client_metadata["x-codex-turn-state"]`, not websocket request headers. The route records persisted sessions and turns, and uses durable aliases plus owner leases for reconnect continuity.
- `GET /backend-api/codex/v1/responses`, websocket alias for Codex clients configured with `/backend-api/codex/v1` as the backend base URL
- `POST /backend-api/transcribe`, multipart audio transcription compatibility route that authenticates with bearer API keys and uses the fixed backend transcription model contract
- `POST /backend-api/files`, Codex backend JSON SAS create bridge that accepts `{file_name, file_size, use_case}` and returns upstream `{file_id, upload_url}`. `use_case` defaults to `codex`, multipart create is rejected, returned upload URLs must be public HTTPS direct-upload targets, upload bytes go directly to the upstream `upload_url`, and codex-pooler stores metadata only
- `POST /backend-api/files/:file_id/uploaded`, idempotently finalizes an owned backend upstream file upload
- `GET /api/codex/usage`
- `GET /wham/usage`
- `GET /backend-api/wham/usage`

The Codex backend surface is model-provider-only. It does not proxy Codex
app-server account, analytics, thread-goal, memory, search, realtime, safety, or
agent-identity helper routes. The usage routes above are read-only compatibility
reads; reset-credit consume operations are not supported.

### OpenAI v1 compatibility API

Use `https://codex-pooler.example.com/v1` as the OpenAI SDK base URL shape and send every request with `Authorization: Bearer sk-example-redacted`, replacing that value with an existing Pool API key at runtime. There is no anonymous, local, or CIDR-based bypass for `/v1`. Pool routing settings include `v1_compatibility_enabled`; it is enabled by default for new and backfilled pools, and disabling it makes `/v1` return an OpenAI-shaped compatibility-disabled error before gateway dispatch.

Supported and explicitly routed `/v1` endpoints are:

- `GET /v1/models`, returns policy-visible OpenAI-shaped model entries for the
  authenticated Pool key
- `GET /v1/usage`, returns sanitized API-key and Pool usage data from accounting read models
- `POST /v1/responses`, OpenAI Responses JSON and SSE through the shared gateway path
- `POST /v1/responses/compact`, authenticated compact compatibility route, currently a deterministic unsupported response because the backend compact primitive is Codex-specific
- `POST /v1/chat/completions`, chat completions translated to the Responses gateway path
- `GET /v1/files`, list owned file metadata
- `POST /v1/files`, multipart SDK file create through the upstream-backed file bridge
- `GET /v1/files/:file_id`, retrieve owned file metadata
- `GET /v1/files/:file_id/content`, ownership-checked deterministic unsupported response because codex-pooler stores metadata only
- `DELETE /v1/files/:file_id`, ownership-checked deterministic unsupported response because codex-pooler does not own upstream deletion
- `POST /v1/audio/transcriptions`, multipart transcription compatibility through the backend transcription gateway path
- `POST /v1/images/generations`, OpenAI image generation compatibility through Responses image-generation tooling
- `POST /v1/images/edits`, OpenAI image edit compatibility with transient multipart image inputs forwarded as Responses `input_image` content

Unsupported public `/v1` endpoints are routed only to return deterministic OpenAI-shaped errors before gateway admission or upstream dispatch:

- `POST /v1/images/variations`, deterministic unsupported endpoint response
- `POST /v1/embeddings`
- `POST /v1/batches`
- `POST /v1/moderations`
- `POST /v1/fine_tuning/jobs`
- `GET /v1/responses/:response_id`
- `POST /v1/responses/:response_id/cancel`
- `DELETE /v1/responses/:response_id`

Every unsupported endpoint in this list returns HTTP `404` with an
OpenAI-shaped error whose code is `unsupported_endpoint`. That is intentional
SDK behavior, not a missing Phoenix route, and it does not imply full OpenAI
API parity. The `/v1` surface is selected and narrow: only the routes listed
above are part of the public compatibility contract.

#### Prompt-cache routing locality

Pools have a default-on routing setting named
`prompt_cache_affinity_enabled`. When enabled, a supported nonblank
`prompt_cache_key` is used as transient typed routing input for stateless
routing locality over already-eligible upstream assignments. The key is not
kept in catch-all request options, isn't persisted raw, and isn't rendered in
logs, request metadata, attempt metadata, audits, admin pages, fixtures, docs,
or evidence.

The locality contract is routing-only. It doesn't add local prompt or response
cache storage, doesn't store per-key routing state, and doesn't promise that
the upstream provider will report a cache hit. Cache evidence remains limited
to upstream-reported cached input tokens in usage, request-log, and settlement
metadata. Routing-locality metadata may include safe strategy, status, count,
and fingerprint fields, but it must not be treated as provider cache evidence.

OpenAI-compatible requests may also forward upstream cache controls:
`prompt_cache_options` at request level and an explicit
`prompt_cache_breakpoint` on supported content parts. These values are
validated and preserved for the backend, are not Pool routing inputs, and do
not change the `prompt_cache_key` affinity contract. Whether a backend accepts
or applies them depends on the selected model and upstream account.

Prompt-cache locality can apply only to this exact allowlist:

- `POST /v1/responses`
- `POST /v1/chat/completions`
- `POST /backend-api/codex/responses`
- `POST /backend-api/codex/v1/responses`
- `POST /backend-api/codex/v1/chat/completions`

It doesn't apply to websocket `GET /backend-api/codex/responses`, compact
endpoints, files, audio, or images. Stronger routing continuity still wins
first, including file affinity, Codex session continuity, websocket owner or
session recovery, tool-result continuation context, and idempotency semantics
where those inputs are stronger than stateless locality.

#### Request compression

Pools have a default-off routing setting named
`request_compression_enabled`. When enabled, request compression may rewrite
upstream-bound Responses tool-output strings before dispatch. This is
request-side only. Codex Pooler does not store raw tool outputs, does not store
raw response bodies, and does not implement CCR/retrieval.

Supported rewrites are shape-based: valid JSON arrays and top-level JSON
objects are minified losslessly, git diffs are compacted around file/hunk
context, search/path-match output is grouped, and build/test/lint logs are
reduced around diagnostic and summary lines. When a test summary reports
failure/error counts, log compression keeps every discovered failure block or
skips the rewrite so missing failures are not hidden. Raw source code, HTML,
and ordinary prose stay pass-through unless a safe strategy exists for that
shape.
Search-result compression accepts classic `path:line[:column]: text` matches,
grouped heading output when a path-like heading has enough line matches below
it, and portable NUL-delimited output of the form `path\0line[:column]: text`.
Malformed NUL fragments and prose headings remain text/skip. Diff compression
requires a hunk header and accepts additions-only, deletions-only, replacement,
minimal unified, combined unified, and long-preamble diffs without requiring a
leading `diff --git` header. Ordinary prose with plus/minus lines stays
text/skip.

Exact-output tool results are protected before rewriting. Function tool outputs
for `Read`, `Glob`, `Grep`, `Write`, and `Edit` plus external retrieval outputs
stay byte-for-byte upstream-bound. Output-only function tool results fail closed
as protected when the tool name is unavailable. Safe metadata records aggregate
skip counts only.

Eligible request families are exact and route-aware:

- backend Responses: `POST /backend-api/codex/responses`
- backend `/v1/responses`: `POST /backend-api/codex/v1/responses`
- backend translated chat completions:
  `POST /backend-api/codex/v1/chat/completions`
- public `/v1/responses`: `POST /v1/responses`
- public translated chat completions: `POST /v1/chat/completions`
- compact backend routes: `POST /backend-api/codex/responses/compact` and
  `POST /backend-api/codex/v1/responses/compact`
- websocket `response.create` payloads on backend Responses websocket routes
  and the narrow public `GET /v1/responses` Responses websocket route

Multipart, file, audio, image, admin, MCP, usage, and other non-Responses routes
are ineligible. Public compact, `POST /v1/responses/compact`, remains
unsupported because it does not dispatch upstream.

The feature is fail-open. Scanner, tokenizer, strategy, compression, JSON
range, limit, and unexpected runtime errors preserve the original upstream
request body and attach sanitized `payload_compression` metadata. Safe status
values are `disabled`, `ineligible`, `compressed`, `no_change`, `skipped`, and
`error_passthrough`. Safe reason values include `pool_disabled`,
`route_ineligible`, `transport_ineligible`, `payload_kind_ineligible`,
`invalid_json`, `no_candidates`, `no_rewrites`, `below_min_bytes`,
`scanner_error`, `strategy_unavailable`, `tokenizer_unavailable`,
`token_count_failed`, `no_token_shrink`, `over_body_limit`,
`over_candidate_limit`, `compression_error`, `native_load_failed`, and
`rewritten`.

The compression path skips JSON request bodies over 1 MiB before scanning and
processes at most 50 output candidates per dispatch. Token counts use local,
in-process tokenizer data shipped with the application. No OpenAI request, local
model load, or payload persistence is part of token counting.

Request logs and admin projections may expose safe aggregate savings only. They
prefer saved token count plus token savings percent when token counts are
available, and fall back to saved bytes plus byte savings percent when token
counts are unavailable. `payload_compression` metadata must not include raw
outputs, prompts, response bodies, websocket frames, file bodies, credentials,
or raw idempotency keys.
Token savings can exceed byte savings because the local tokenizer, not raw
UTF-8 byte length, is the context-size signal.

#### Upstream websocket bridge

An eligible public `POST /v1/responses` streaming turn keeps its HTTP SSE
downstream contract and dispatches upstream over the continuity session's owner
websocket connection to reuse that connection's provider prompt-cache locality.
There is no Pool-level bridge toggle. Eligibility requires a public Responses
stream, websocket owner forwarding enabled, no attached websocket writer, and a
continuity session that is unpinned or pinned to the selected assignment.

The bridge buffers only `response.created`, `response.in_progress`,
`response.queued`, and `codex.rate_limits` before commitment. An unknown typed
event commits conservatively. A legacy typeless success commits as a completed
terminal while preserving its raw payload for backend surfaces. Any failure
before the first public event falls back to plain HTTP dispatch on the same
candidate and attempt with a single settlement. Once a hidden event has caused
the bridge handoff, a missing terminal cannot replay the turn over HTTP. After
visible output, an upstream death finalizes the request as failed.

Backend `POST /backend-api/codex/responses` SSE and backend Responses websocket
routes preserve `response.done` and legacy typeless success payloads. Public
`POST /v1/responses` SSE and `GET /v1/responses` websocket normalize successful
done/legacy terminals to `response.completed`. Only public POST SSE synthesizes
a sequence-valid `response.failed` when upstream ends without a terminal event;
public GET websocket retains its existing error/close behavior, and backend GET
or POST surfaces do not synthesize a terminal. Existing canonical transforms
for failure-coded incomplete, coded errors, `response.failed` without a nested
code, and typeless detail errors remain shared compatibility behavior.

Accounting records the transport split explicitly: the request keeps the
downstream `http_sse` transport, the attempt records `websocket` with
`upstream_websocket_bridge` and `upstream_transport` response metadata, and
`payload_compression` metadata describes the websocket envelope actually sent.
The submit task is crash-silent: owner failures during the blocking submit
call surface as scrubbed atom reasons and never copy the request payload or
authorization headers into crash logs.

Rolling deploys fail closed: native option-less owner attaches keep the
two-argument remote shape the previous release exports, while the bridge's
option-carrying attach uses the three-argument shape and falls back to HTTP
against an owner node still running the previous release.

#### SDK shape decision contract

The SDK compatibility corpus lives in
`test/fixtures/openai_compatibility/sdk_shapes/`. Fixtures are metadata-only
shape records for OpenAI Node `openai` `6.39.0`, OpenAI Python `openai`
`2.38.0`, Vercel `ai` `6.0.191`, and `@ai-sdk/openai` `3.0.65`. They record
package versions, endpoint paths, top-level keys, item types, content part
types, and tool-shape keys. They must never store raw SDK transport captures,
real prompts, credentials, headers, cookies, upload locations, file bytes,
audio bytes, image bytes, websocket frames, or raw upstream responses.

`MATRIX.md` is the maintainer decision ledger for those fixtures and the
SDK-probed unsupported routes. Each row must be exactly one of these decisions:

- `accept`, the request shape already matches the current compatibility boundary
- `translate`, the SDK shape is accepted and rewritten into a Codex-compatible
  upstream request
- `reject`, the shape fails locally with a deterministic OpenAI-shaped error
  before upstream dispatch
- `passthrough`, the narrow field or item is forwarded without codex-pooler
  taking ownership of the resulting upstream state

Current proven shape classes are:

- Responses text creation is translated from SDK Responses input into the
  shared gateway Responses path
- Chat Completions nested function tools and named tool choices are translated
  into flat Responses-compatible tool shapes
- Responses flat function tools are accepted only for the documented flat
  function shape with a nonblank name and map parameters
- Responses namespace tools are accepted only for the OpenAI Responses shape
  with nonblank namespace name and description values plus a non-empty nested
  list of function tools. Nested function tools may include `strict` and
  `defer_loading`, and named `tool_choice` can reference nested function names
- Vercel tool-output continuation is passthrough only for the semantic
  `previous_response_id` plus tool-output shape. Ordinary stale references,
  broad `item_reference` use, or previous-response anchors outside tool-result
  continuations are rejected locally
- Hermes-style chat `role: "tool"` continuation messages are accepted only as
  tool-result continuations and are translated to Responses
  `function_call_output` input items before local validation and dispatch
- Codex-native `custom_tool_call` replay with optional `namespace` and matching
  `custom_tool_call_output` is accepted only as stored replay input on
  `/v1/responses` HTTP and websocket compatibility. Executable custom tool
  definitions remain unsupported until separately proven
- Structured output supports strict local JSON Schema shapes, local `$defs` or
  `definitions` refs, root local `$ref`, and `$ref`-only nodes when the ref
  resolves. Remote, missing, malformed, circular, or non-map refs are rejected
- Reasoning effort, reasoning summary, and service tier values use explicit
  allowlists. Enforced API-key reasoning efforts currently allow `minimal`,
  `low`, `medium`, `high`, `xhigh`, `max`, and `ultra`; unsupported values are
  rejected before upstream dispatch
- Responses `truncation` accepts only `auto` and `disabled` for SDK
  compatibility, but the field is not forwarded upstream
- Multimodal input accepts transient inline or HTTPS image shapes, supported
  PDF or text file data URLs, Chat image URL translation, and supported Chat
  audio parts. File ids as image inputs, unsupported URI schemes, unsupported
  MIME types, malformed base64 media, and SDK-internal file URI shapes reject
  locally
- Built-in tools allow exact `web_search_preview` type-only passthrough,
  Codex-native `web_search` passthrough with required boolean
  `external_web_access` and optional boolean `index_gated_web_access` only when
  external web access is true, exact `image_generation` type-only passthrough,
  and the exact `/v1/images/*` translated `image_generation` shape. Other
  hosted web-search options, hosted tool families, deferred tools, MCP-like
  runtime tools, shell tools, code interpreter, file search, and unknown tool
  types reject locally
- Backend websocket tool-output continuation is covered on the canonical
  `/backend-api/codex/responses` websocket route. That evidence is separate
  from the narrow public `GET /v1/responses` Responses websocket compatibility
  route

#### `/v1` Responses continuation audit

This matrix records the current internal compatibility decision for
`previous_response_id`, `item_reference`, and tool-result continuation shapes on
`POST /v1/responses` and narrow `GET /v1/responses` Responses websocket
compatibility. It is not a claim of full OpenAI Responses parity. Every example
below is synthetic and metadata-only. Do not copy raw prompts, request bodies,
websocket frames, headers, bearer tokens, cookies, API keys, tool outputs, or
upstream payloads into docs or evidence.

Source context for the audit:

- Production triage for the reported selector found no bounded production
  `/v1/responses` failure evidence. The production image matched current main
  and the window had no non-success `/v1/responses` rows, so this is Branch B,
  no production repro evidence.
- Local OpenCode helper and native tool smoke reached local `/v1/responses`
  successfully, but the native smoke did not expose `previous_response_id` or
  `item_reference` in sanitized output. It proves the real OpenCode tool path
  reaches `/v1`, not that every continuation variant is accepted.
- OpenCode dev source at commit
  `b2a06351b545dbefa30181016696ca25110b2366` shows native HTTP and websocket
  Responses flows share the same core fields. Source-derived tests cover the
  relevant replay and tool-output shapes.
- Official OpenAI docs define `previous_response_id`, `function_call_output`,
  and `item_reference`, but broad `item_reference` resolvability through
  codex-pooler is still ambiguous. Treat that as backlog until tested against
  a real resolvable upstream state.

Accepted legacy histories may contain nonblank unprefixed response item IDs.
Before dispatch, both backend-Codex HTTP and Responses websocket payloads omit
an optional top-level item `id` unless its first underscore separates a
nonempty `<prefix>_<suffix>`. A bare `item_reference.id` is the required target
reference for the continuation contract and remains unchanged. Tool-result
`call_id` is a separate correlation field and also remains unchanged.

| Classification | Current contract | Evidence |
| --- | --- | --- |
| `accepted and tested` | Safe tool-result continuation is accepted when all anchors are present together: nonblank `previous_response_id`, valid bare `item_reference` id, and same-turn semantic tool-result context detected by `ToolResultShape`. The same rule is covered for HTTP and Responses websocket compatibility. Source-derived OpenCode replay shapes with assistant replay, reasoning summary, function call, and `function_call_output` are also accepted only through the narrow supported item validators. Codex-native `custom_tool_call` replay with optional `namespace` and matching `custom_tool_call_output` is accepted only through narrow validators, preserves namespace and internal turn metadata for upstream replay, and does not enable executable custom tool definitions. Structured `function_call_output.output` and Cline-style `tool-result` output values are forwarded unchanged as JSON values, including nested maps, lists, and long strings. Hermes-style chat `role: "tool"` continuation messages with `tool_call_id` or `call_id` are translated to `function_call_output` before validation. | `test/codex_pooler/gateway/openai_compatibility/core_test.exs`, `test/codex_pooler/gateway/openai_compatibility/continuation_test.exs`, `test/codex_pooler/gateway/payloads/tool_result_shape_test.exs`, `test/codex_pooler/mcp/redaction_test.exs`, and `test/codex_pooler_web/controllers/v1/responses_controller_test.exs` cover shared coercion, public HTTP dispatch, public websocket dispatch, call-id recovery, chat-style tool continuation translation, pass-through preservation, and metadata/projection redaction. |
| `currently rejected but upstream-valid` | Broader upstream-valid Responses item references remain rejected locally until codex-pooler proves ownership and resolvability. This includes stored-reasoning or provider-owned `item_reference` replay that official docs or OpenCode source may describe without a same-turn semantic tool-result anchor. It also includes broad item replay where OpenAI may resolve an item id upstream, but codex-pooler has not verified that the id is resolvable for the selected upstream account and Pool route. | Official docs and OpenCode dev source are the support. There is no local acceptance test yet, and no production repro evidence. Keep these shapes backlog, not accepted behavior. |
| `intentionally rejected as unsafe/malformed` | These variants reject before upstream dispatch: blank or missing `item_reference.id`, `item_reference` with extra payload-like fields, `item_reference` without `previous_response_id`, `previous_response_id` without semantic tool-output context, non-string or blank `previous_response_id`, and ordinary stale continuation that tries to carry only a new user message or string input. The rejection prevents stale ordinary anchors and payload-like replay from bypassing the narrow tool-result contract. | Shared coercion tests reject malformed neighbors and stale anchors, public HTTP tests confirm no upstream dispatch, public websocket tests return sanitized `invalid_request` errors, and `ToolResultShape` tests prove bare `item_reference` alone is not semantic tool-result context. |
| `unverified/backlog` | Full OpenAI Responses replay parity, broad `item_reference` resolvability, provider-executed tool approval references, stored reasoning references without same-turn local tool output, executable custom tool definitions, and deploy-level production verification for this audit remain unverified. A later task must add metadata-only fixtures, public-surface tests, and safe smoke evidence before moving any item into `accepted and tested`. | Backlog only. Do not document these as accepted, and do not claim production is fixed or verified by deploy from this task. |

All request logs, admin pages, docs, fixture entries, test evidence, and smoke
output for these shapes must stay metadata-only. They may include endpoint,
method, route class, status, SDK name, SDK version, item or content type names,
counts, sanitized error class, and request-log id. They must not include raw
prompts, file or media bytes, bearer tokens, cookies, auth JSON, multipart
bodies, raw upload URLs, websocket frames, raw idempotency keys, raw SDK
request bodies, raw command strings, raw tool file output, or long nested
tool-output values.

### Operations endpoints

These routes are operational surfaces, not Codex CLI backend compatibility routes.

- `GET /metrics`, Prometheus exposition backed by Phoenix Telemetry metrics, optionally protected by DB-managed metrics auth
- `POST /mcp`, stateless MCP Streamable HTTP JSON-RPC for metadata-only operator
  tools, authenticated by operator-owned bearer MCP tokens and gated by both the
  global Instance Settings MCP switch and the per-operator account MCP switch

### Authenticated instance-admin LiveViews

Admin pages require an authenticated local browser session whose password status is current. Operators with temporary or expired passwords remain on `/password/change-required` until the required password change completes. These pages are Phoenix LiveViews, not JSON APIs, and they are not part of the Codex CLI compatibility surface.

- `GET /admin/request-logs`, inspect request outcomes, denial codes, attempts, settlements, and sanitized routing metadata
- `GET /admin/pools`, signed-in default admin page for managing pool lifecycle and pool settings
- `GET /admin/upstreams`, admin page for importing upstream accounts, checking quota/debug state, creating pool-scoped invites, and pausing, reactivating, deleting, or refreshing upstream accounts without exposing token plaintext. Imports and invites create initial Pool assignments only.
- `GET /admin/api-keys`, create, edit, pause, resume, revoke, rotate, inspect API-key policy restrictions, and enable or disable Dashboard access; it is not a usage analytics surface
- `GET /admin/audit-logs`, inspect redacted security, operator, authentication, and request lifecycle audit events
- `GET /admin/alerts`, manage metadata-only Pool-scoped alert rules, email and webhook channels, and durable incidents through the same owner vs assigned-Pool authorization model as the rest of the admin UI
- `GET /admin/stats`, inspect Pool-scoped UTC usage, quota health, activity, and charted metadata without exposing payloads or secrets
- `GET /admin/jobs`, owner-only operations page for Oban job health, actionable attention buckets, URL-backed exploration, and sanitized job details
- `GET /admin/operators`, manage local operator accounts, temporary passwords, text credential email, and deactivation
- `GET /admin/system`, manage DB-backed instance settings, write-only metrics or SMTP secrets, signed-in operator SMTP test email, and public operator app URL settings
- `GET /admin/settings`, manage local theme preference, signed-in operator profile fields, and TOTP enrollment material

There is no `/api/admin/*` or `/dashboard/*` compatibility surface. Runtime
client compatibility routes under `/backend-api/*`, `/v1/*`,
`/api/codex/usage`, and `/wham/usage` stay separate from the browser admin UI.

### API-key Observatory browser surface

The API-key Observatory is a separate read-only browser surface. It does not
use operator authentication authority and is not a runtime compatibility or
data API. Its browser flow uses a dedicated opaque Observatory token cookie
alongside the shared signed Phoenix session cookie, which is renewed and used
only to carry the minimal LiveView handoff after operator session markers are
cleared. Its route contract is exactly:

- `GET /observatory/login`, dedicated password-style access form
- `POST /observatory/login`, CSRF-protected Pool API-key exchange
- `DELETE /observatory/logout`, dashboard-session deletion and cookie clear
- authenticated `live /observatory`, the key-local Observatory LiveView

`POST /observatory/login` accepts only the nested form field
`observatory[api_key]` and an empty query string. A non-empty query string is
rejected so a raw key cannot be submitted in a URL. Successful login deletes
any operator session markers, renews the signed `_codex_pooler_key` Phoenix
session, discards submitted parameters, sets the dedicated opaque
`_codex_pooler_observatory_token`, and redirects to `/observatory`. The
Observatory token cookie is `HttpOnly`, `SameSite=Lax`, path `/`, secure when
the endpoint is HTTPS, and has a 14-day absolute `max_age`. On the redirected
authenticated request, the Observatory plug validates that opaque token and
stores only the dashboard-session row id as a signed Phoenix session handoff;
the LiveView consumes that handoff without receiving the raw token.

The browser token is returned only at issuance. The database stores only its
SHA-256 hash, API-key id, timestamps, and the minimum lifecycle fields. Expired
rows are purged at issuance; issuance retains at most 10 active sessions per
key, removing the oldest overflow rows. There is no idle renewal. Logout
deletes the matching row, renews and clears the Phoenix session, and removes
the cookie.

The exchange succeeds only when the presented Pool API key is active, has
`dashboard_access: true`, is not expired, and belongs to an active Pool. All
ineligible cases use the same generic failure copy and timing path. The
authenticated LiveView receives only `@dashboard_principal`: canonical API-key
and Pool ids plus the display name and safe key prefix. It never receives the
raw Pool API key, browser token, operator scope, policy, or Pool record.

Runtime API-key permission, Dashboard access, and instance-admin login are
independent authorities. A key can be valid for runtime routes without being
eligible for the Observatory; Dashboard access does not grant `/admin/*`; and
an instance-admin browser session does not grant Observatory access.

Dashboard sessions are deleted in the same lifecycle transaction where
possible and an API-key-specific invalidation event is broadcast after commit.
Pause, revoke, delete, rotate, disabling Dashboard access, moving the key to a
different Pool, and disabling or archiving the Pool invalidate sessions. Pool
or key lifecycle updates may be initiated on any application node. The event
relay makes open LiveViews redirect promptly across nodes, but PostgreSQL is
the authority: request, mount, reconnect, manual refresh, and the 30-second
revalidation fallback authenticate the handoff again and fail closed if an
event is delayed or lost. Resuming a paused key does not recreate deleted
browser sessions.

The reporting boundary accepts only the authenticated dashboard principal and
one allowlisted window. It derives canonical `api_key_id` and `pool_id` from
the principal and rejects caller-supplied id overrides. Windows are fixed to
`1h` (12 five-minute buckets), `5h` (20 fifteen-minute buckets), `24h` (24
one-hour buckets), and `7d` (28 six-hour buckets), using a UTC second-truncated
exclusive upper bound. The read model returns summary, bucket, model, and
recent-outcome projections; a refresh is bounded to no more than eight SQL
queries, models and outcomes are limited to 12 rows, and reporting groups in
SQL rather than loading fact rows for Elixir aggregation.

The Observatory exposes only sanitized metadata: counts, token classes,
cached-input counts, settled or estimated cost labels, latency and throughput
distributions, safe model labels, endpoint classes, timestamps, status labels,
safe error classes, and at most 12 recent outcomes. It must not expose prompts,
completions, request or response bodies, file or media bytes, headers, cookies,
bearer credentials, raw idempotency keys, IPs, user agents, upstream
identities, Pool controls, other keys, or raw error text. Cached-input values
are upstream-reported accounting evidence, not a promise of provider cache
behavior; costs are reporting values, not invoices.

For query-plan verification, capture
`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` for all four Observatory projections
at representative volume. The plan must keep `api_key_id`, `pool_id`, and the
time predicate on `requests.admitted_at` and `ledger_entries.occurred_at`, use
the scope indexes `requests_api_key_pool_admitted_idx` and either
`ledger_entries_api_key_pool_settlement_occurred_idx` or
`ledger_entries_api_key_recorded_occurred_idx`, avoid sequential scans of
`requests` and `ledger_entries`, keep sorts bounded, and retain `LIMIT 12` for
model and outcome projections. The focused regression is
`mix test test/codex_pooler/accounting/observatory_query_plan_test.exs`.

#### Owner-only admin jobs contract

`/admin/jobs` is an owner-only global operations surface. Instance admins do not
receive global job rows, worker choices, hotspot labels, selected job state, or
reflected filter params. The page is read-only and does not expose retry,
cancel, discard, delete, pause, or reschedule controls.

The first viewport is the operations overview, not a recency feed. It shows
classification-driven counts for active failures, retry pressure, stuck
executing work, and backlog pressure, then bounded hotspot summaries by worker,
queue, pool, account, and target context. Completed jobs are secondary healthy
context and do not create urgency.

The explorer is URL-backed and paginated. Supported query params are `state`,
`worker`, `queue`, `attention`, `target_kind`, `target_id`, `page`,
`show_completed`, and `job_id`. Invalid params are normalized to safe defaults
with visible warnings. Completed rows stay hidden by default; operators must set
`show_completed=true` or choose an allowed completed-state view to include them.
Pagination is deterministic and uses stable desktop and mobile row selectors
from the sanitized explorer projection.

Opening a row stores `job_id` in the URL and renders the detail drawer only when
that job is present on the current filtered page. Filter changes, pagination, or
refreshes that remove the selected job clear `job_id` and close the drawer. The
drawer is metadata-only. It may show the job id, worker, queue, state, health
classification, attempts, safe timestamps, sanitized target summary, and a
bounded sanitized failure summary. It must not render raw Oban `args`, raw
`meta`, raw `errors`, stack traces, prompts, request bodies, auth JSON, bearer
tokens, cookies, file names, websocket frames, or raw upstream payloads.

For local QA, `mix dev.seed full` signs in with
`dev-owner@example.com` / `dev-password-123` and creates deterministic `dev-*`
fake jobs for active failure, retry pressure, stuck executing, backlog pressure,
hotspot concentration, healthy completed context, cancelled context, and future
scheduled context. Synthetic jobs use the unconfigured `dev_seed_jobs` queue so
running local workers do not consume the QA rows while the owner inspects
`/admin/jobs`. The seed data is synthetic and must remain free of real customer,
host, prompt, token, cookie, or account data.

### Pool and invite frontend boundary

Pool creation and invite creation are intentionally not exposed as browser JSON APIs. Pool-scoped invite creation is an authenticated admin action on `/admin/upstreams`; the LiveView calls `CodexPooler.Access` directly with `@current_scope`.

Public invite acceptance remains `GET /onboarding/invites/:invite_token`. Hosted onboarding uses Codex device-code approval with automatic background polling. Hosted onboarding is device-code-only and exposes no hosted browser callback route.

Invite onboarding creates an initial Pool assignment for the inviting Pool. It does not permanently bind the upstream identity to that Pool. Later assignment changes happen by editing Pools in `/admin/pools`.

### Setup, auth, and status

- `GET /` redirects to `/bootstrap`, `/login`, or `/admin/pools` depending on bootstrap and session state
- `GET /bootstrap` renders the first-run owner form while bootstrap is pending
- `POST /bootstrap` creates the first owner and logs that user in
- `GET /bootstrap/status` returns `%{status: "ok", bootstrap: "pending" | "completed"}`
- `GET /login` renders the login form after bootstrap is complete
- `POST /login` creates a browser session
- `DELETE /logout` revokes the current browser session
- `GET /session` returns the current browser-session JSON, or 401 when missing
- `GET /session?optional=1` returns an unauthenticated JSON status instead of 401
- `POST /settings/password` changes the authenticated user's password and replaces the session
- `GET /password/change-required` renders the authenticated forced password-change form for operators using temporary credentials
- `GET /healthz` returns process health
- `GET /readyz` checks Postgres with `select 1`

Routes under `/backend-api/*`, `/v1/*`, `/api/codex/usage`, and `/wham/usage` are runtime compatibility routes for clients, not dashboard API routes.

### Metadata-only MCP contract

The MCP service is direct Phoenix code, not a community Elixir MCP framework. It
supports MCP protocols `2025-11-25` and `2025-06-18` on `/mcp` and is
stateless: no `MCP-Session-Id` is issued, POST carries one JSON-RPC message,
`notifications/initialized` returns HTTP 202 with an empty body, client JSON-RPC
responses are accepted with HTTP 202, and unsupported methods return a sanitized
JSON-RPC `method not found` error. GET, HEAD, DELETE, and OPTIONS are
route-visible; non-OPTIONS methods are not streaming endpoints and return the
documented method response. GET SSE remains unsupported and returns 405 in this
plan. If opencode needs GET SSE later, that requires a separate follow-up plan.

Every MCP POST must include `Content-Type: application/json`, `Accept:
application/json, text/event-stream`, and `Authorization: Bearer
<operator-mcp-token>`. `initialize` may omit `MCP-Protocol-Version`; when present,
it must be either `2025-11-25` or `2025-06-18`. Post-initialize requests may omit
`MCP-Protocol-Version` or use either supported header value. That no-header
post-initialize behavior is a deliberate stateless compatibility choice because
codex-pooler does not issue `MCP-Session-Id` and does not bind requests to a
server-side MCP session. The bearer value must be an MCP token generated from
`/admin/settings?tab=account`; Pool API keys, browser sessions, cookies, query
tokens, invite tokens, upstream tokens, basic auth, and custom headers are not
MCP authentication primitives.

Direct opencode remote MCP clients can connect without `mcp-remote`, stdio
wrappers, OAuth, or a local proxy. Use an environment variable for the bearer
token and keep the raw value out of tracked config:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "codex_pooler": {
      "type": "remote",
      "url": "https://codex-pooler.icorete.ch/mcp",
      "oauth": false,
      "headers": {
        "Authorization": "Bearer {env:ICORETECH_CODEX_POOLER_MCP_KEY}"
      }
    }
  }
}
```

Direct Codex CLI Streamable HTTP MCP clients can use the native MCP server
configuration. The token is read from the named environment variable:

```toml
[mcp_servers.codex_pooler]
url = "https://codex-pooler.icorete.ch/mcp"
bearer_token_env_var = "ICORETECH_CODEX_POOLER_MCP_KEY"
```

The endpoint enforces the runtime ingress firewall and trusted-proxy semantics
before MCP authentication and tool dispatch. Empty allowlists disable the
firewall. Configured allowlists match the resolved client IP. Forwarded IP
headers are trusted only from configured trusted proxies; untrusted peers cannot
spoof an allowed client IP. The endpoint rejects compressed bodies, multipart
bodies, oversized bodies, unsupported content types, malformed JSON, batch
arrays, invalid ids, invalid params, protocol-version drift, and response/request
field mixing with sanitized errors that do not echo raw input.

Tools are read-only metadata presenters. `readOnlyHint: true` is only an MCP
annotation; the product contract is metadata-only/no-mutation enforced by the
allowlisted catalog and redaction wrapper. Tool output may expose bounded admin
metadata about Pools, upstreams, upstream quota snapshots, Pool API keys,
operators, invites, request logs, and audit logs. It must never expose raw
prompts, request/response bodies, multipart bodies, websocket frames, headers,
cookies, raw Pool API keys, MCP tokens, token hashes, invite URLs or tokens,
temporary passwords, TOTP or recovery secrets, upstream auth.json,
access/refresh tokens, upstream secrets, raw idempotency keys, raw emails, raw
IPs, or raw audit before/after blobs. For quota tools this also excludes
credentials, provider JSON, and raw metadata blobs.

MCP tool results use `structuredContent` as the stable machine contract.
`content[0].text` is concise operator display text and backwards-compatible text
for clients that don't read structured output. Text must not be treated as the
complete schema.

Quota metadata tools:

- `codex_pooler_list_upstream_quotas`, bounded discovery of sanitized persisted
  quota evidence for upstream accounts visible to the authenticated operator
- `codex_pooler_get_upstream_quota`, exact/detail lookup of sanitized persisted
  quota evidence for one visible upstream account

`codex_pooler_list_upstream_quotas` accepts `pool_id`, `status`,
`plan_family`, `freshness_status`, `routing_usable`, `limit`, and `offset`.
`pool_id` scopes output to accounts assigned to that visible Pool.
`freshness_status` accepts `fresh`, `stale`, and `unknown` and filters the
account-level `quota_summary.freshness_status`, not individual windows.
`routing_usable` accepts JSON `true` or `false` and filters
`quota_summary.routing_usable`, not individual windows. `plan_family` accepts
non-empty sanitized strings already present in upstream identity plan metadata.
Invalid enum values, invalid types, and blank `plan_family` are invalid params,
not empty results. Pagination is by account, deterministic, defaults to
`limit: 50`, caps `limit` at 100, and caps
`offset` at 10,000. Each account returns at most 50 quota windows and sets
`quota_summary.truncated: true` when more windows exist.

`codex_pooler_get_upstream_quota` accepts a required `selector` and reuses
upstream selector behavior: exact id, stored account id, label, or masked label.
It doesn't add arbitrary metadata search. Found responses use
`%{status: "ok", item: account_summary}`. Not-found responses use
`%{status: "not_found", item: nil, candidates: []}` and don't echo the raw
selector. Ambiguous responses use
`%{status: "ambiguous", item: nil, candidate_count: integer, candidates: [...]}`
with at most 10 masked candidates and no raw selector echo.

Quota account summaries include safe identity labels, status, plan family,
assignment summary, `quota_summary`, and `quota_windows`. Quota window values
are persisted evidence snapshots, not live provider state. The tools don't
refresh upstream usage data, enqueue jobs, call provider usage endpoints, create
accounting rows, or change routing/accounting state.

Quota field semantics:

| Field | Meaning | Nullable behavior |
| --- | --- | --- |
| `active_limit` | Persisted quota capacity for the window when known | `null` when no capacity evidence was observed |
| `credits` | Persisted remaining credits from quota evidence | `null` when no credit evidence was observed |
| `remaining_value` | Alias of persisted `credits` for compatibility with usage shapes | `null` when `credits` is `null`; never derived from `active_limit` or `used_percent` |
| `used_percent` | Numeric usage percent in `structuredContent`; readable text renders one decimal place | `null` when percent evidence is absent |
| `reset_at` | UTC ISO8601 reset timestamp supplied by trusted evidence | `null` or `unknown` when reset evidence is missing |
| `observed_at` | UTC ISO8601 time when the evidence was observed | `null` or `unknown` when observation time is missing |
| `freshness_status` | `fresh`, `stale`, or `unknown` for a window or account summary | `unknown` when no evidence exists or freshness can't be classified |
| `routing_usable` | Whether persisted evidence can currently contribute to routing eligibility | `false` for missing, stale, exhausted, resetless, reset-only, or unknown evidence |
| `routing_unusable_reason` | Primary reason routing can't use the evidence: `exhausted`, `reset_missing`, `stale`, or `unknown_evidence` | `null` when `routing_usable` is true |

Unknown and partial evidence stays explicit. Reset-only evidence may show
`reset_at` while numeric fields stay `null`, and it remains non-speculative.
Percent-only evidence may show `used_percent` while limits and credits stay
`null`. Stale evidence can remain useful for operator diagnosis, but it doesn't
refresh itself and shouldn't be read as current routing capacity.

Monthly account primary evidence keeps the same structured MCP shape as other
account primary quota rows. In `structuredContent`, the quota window remains
`quota_kind: "account_primary"` with `window_minutes: 43_200`. MCP text output
may describe the row concisely for operators, but clients must read the
structured fields rather than a human duration label. The monthly duration does
not imply a plan family, plan tier, static capacity, or remaining credits.

## Codex runtime contracts

Codex Pooler uses the Codex backend route family for the public runtime boundary.

### Effective catalog and Responses revision

The authenticated backend model catalog is the effective catalog visible to the
Pool API key after model routing eligibility, API-key policy, pricing metadata,
reasoning availability, and configured context-window overrides are projected.
Both `GET /backend-api/codex/models` and
`GET /backend-api/codex/v1/models` return the same effective body for the same
snapshot and attach a weak `ETag` derived from a deterministic canonical digest
of that body. A different effective body produces a different token; equivalent
effective bodies produce the same token regardless of object-key order.

Successful backend Responses streaming surfaces expose that same authenticated
catalog token as `X-Models-Etag`: on the HTTP SSE response headers for
`POST /backend-api/codex/responses` and its backend `/v1` alias, and on the
websocket upgrade headers for the corresponding `GET` routes. The value comes
from Codex Pooler's predispatch or pre-upgrade catalog snapshot, never from an
upstream ETag. It is absent from non-streaming backend JSON responses, compact
routes, public `/v1` routes, usage routes, unauthenticated requests, and
unrelated routes.

The token is a coherence signal, not a synchronous cache invalidation promise.
Across processes or replicas, treat catalog convergence as eventual: compare a
successfully returned Responses token with a later authenticated models token.
A denied or failed request does not prove that every client or replica has
refreshed its model cache.

### Pool-model serving modes

Model serving mode is owned by one Pool-model pair. Explicit `Lite` and `Full`
overrides are stored in shared PostgreSQL using the canonical exposed model id;
`Auto` is represented by the absence of an override row. An override survives
catalog churn, but it does not create a runtime model when no routable source
exists. Clients still see and request one model id. Their Pool API key, base
URL, and client configuration remain unchanged while Codex Pooler changes the
backend request.

`Auto` is recommended and resolves only from the sources that are routable for
the admitted request. Its truth table is exact:

- any routable source whose `use_responses_lite` value is literal JSON `true`
  makes the effective mode `Lite`
- literal `false`, missing values, malformed values, and non-map source entries
  do not count as Lite; if no routable source reports literal `true`, the result
  is `Full`
- when the per-source map is absent or not a map, only a literal-`true` legacy
  aggregate value can produce `Lite`; other aggregate values produce `Full`
- when the per-source map is present, the legacy aggregate is ignored
- zero routable sources means there is no runtime model, regardless of an
  override or aggregate value

The mode applies to both backend model catalog aliases; backend ordinary
Responses over HTTP, SSE, and websocket on the canonical and backend `/v1`
aliases; backend compact aliases; the backend chat-completions alias; and
supported public `/v1/responses` and `/v1/chat/completions` translation. Backend
compact uses the same snapshot and its compact-specific transformation. Public
`POST /v1/responses/compact` remains a deterministic `404 unsupported_endpoint`
without upstream dispatch. Public `GET /v1/models` is unchanged and exposes no
mode field.

Resolution happens once per HTTP request or websocket `response.create` turn.
The immutable configured/effective/source snapshot survives same-assignment
retry, cross-assignment failover, and owner/proxy forwarding. A later websocket
turn may resolve a newly saved mode. Assignment membership and candidate
eligibility never filter on `use_responses_lite`; the mode changes payload and
trusted marker behavior only.

Backend catalog `use_responses_lite` is the effective boolean for that
Pool-model snapshot. The backend models `ETag` hashes the final policy-visible
body after that projection, so changing effective mode changes the token when
the body changes. The public `/v1/models` body and its contract remain
unchanged.

Request `routing_metadata` and attempt `response_metadata` carry only the
bounded keys `model_serving_mode_configured`, `model_serving_mode`, and
`model_serving_mode_source`. Their values remain identical across retries and
never include request bodies, prompts, response bodies, frames, headers, or
credentials.

`Full` is an advanced override for ordinary Responses. It preserves the
client's `parallel_tool_calls` value and removes the Lite marker, but upstream
support is provider-dependent and may change or reject the request. Codex
Pooler does not silently downgrade. A terminal ordinary-Responses HTTP
failure under an explicit Full override retains the numeric upstream status and,
for the generic failure path, returns only the fixed server-owned error
`{"error":{"code":"server_error","message":"upstream request failed","type":"server_error"}}`.
Provider message, body, code, param, and extra fields are neither returned nor
copied into operator metadata. An upstream 4xx records the sanitized
`full_upstream_rejection` request/attempt error class; an ordinary 5xx remains
`upstream_status`. Auto, Lite, compact or unrelated routes, and established
model-unavailability compatibility responses retain their existing status and
body behavior. Recovery is an explicit operator change back to `Auto` or `Lite`
for a later request or turn.

This is database-backed runtime state, not a global deployment mode. There is
no serving-mode environment switch or Helm value.

### Backend Responses envelope

The final non-compact backend Responses request sent upstream always contains a
`reasoning` map and exactly one `reasoning.encrypted_content` entry in
`include`. Existing reasoning fields are preserved when the client supplies a
map. If the selected assignment explicitly reports that the reasoning-summary
parameter is unsupported, only `reasoning.summary` is removed. Missing or
malformed capability metadata keeps summary support enabled; legacy summary
metadata is preserved only when it is a literal boolean in the catalog.

This final-envelope normalization applies to regular backend Responses over
HTTP, SSE, and websocket dispatch, including the backend `/v1` aliases and
translated supported `/v1` traffic that reaches the backend Responses path. It
is idempotent after JSON serialization. Compact dispatch remains deliberately
narrow and is excluded from this non-compact envelope rule: compact payloads
keep their existing reasoning-context and parallel-tool normalization without
adding or rewriting the non-compact `reasoning` or `include` envelope.

### Sanitized upstream error parameter

When a decoded upstream error includes a valid parameter path, failed and
retryable-failed attempt detail may expose it as `upstream_error_param`. The
value is trimmed, limited to 160 bytes, and restricted to a field-name path with
optional dotted fields or bounded numeric indexes, such as
`reasoning.summary` or `input[0].content`.

The field is diagnostic detail only. Invalid or oversized values are omitted,
successful attempts do not expose it, and it is never a raw upstream error
message, rejected value, request body, response body, header, or stream frame.

### Assignment-specific model serving failover

For non-compact HTTP JSON, HTTP SSE, and backend/public Responses websocket
dispatch, Codex Pooler can move a request to a later assignment already present
in its precomputed route plan when the selected assignment reports one of two
exact model-unavailability families before downstream-visible output:

- structured error code `model_not_found`
- HTTP `404` plus `invalid_request_error` plus validated `param=model`, or the
  equivalent sanitized first-terminal stream failure, only when the selected
  assignment is an exact persisted source for the admitted model

The second family is provenance-gated because status, parameter, free-form
message, and plan label do not prove assignment-specific serving state. Generic
404s, missing provenance, `invalid_model`, and previous-response continuity
misses do not qualify. The requested model remains unchanged.

Direct HTTP must classify before returning its response. SSE must classify the
first complete terminal event before any visible event is written; comments,
keepalives, and internal rate-limit events do not count as visible output.
Websocket must classify a terminal failure before any response event is exposed
to the downstream socket. Once SSE or websocket output is visible, Codex Pooler
preserves and finalizes that terminal result without cross-assignment replay.

Only later candidates in the existing bounded route plan can be tried. File
affinity, `previous_response_id`, and an already-live direct or owner-forwarded
upstream websocket are hard pins. Session headers, accepted turn state,
same-model successful turns, and ordinary session assignment remain soft
ordering preferences and may fall through before output starts. Compact routes
are single-lane for this policy: they neither retry nor mutate assignment-model
health.

An accepted non-compact miss records persisted `upstream_model_unavailable`
circuit/demotion state for the exact assignment/model lane. An attempt is marked
`retryable_failed` and increments request retry count only when a later planned
candidate is actually dispatched. Successful usage belongs only to the
successful attempt. A final or hard-pinned miss remains the final failed attempt
and preserves its sanitized provider-shaped terminal result. Circuit thresholds,
bounded half-open probes, and successful-probe thresholds provide database-backed
recovery across replicas; serving health does not remove the model from the
Pool catalog.

The upstream account Routing panel is read-only persisted evidence. It separates
latest observed versus one-sync preserved discovery provenance from HTTP, SSE,
and Websocket serving-state signals. It does not call the provider, refresh the
catalog, mutate routing, or promise current availability. Request-log detail may
show assignment ids, validated upstream parameter evidence, and the internal
`upstream_model_unavailable` semantic. Accepted provider-family codes remain in
sanitized terminal or bounded smoke evidence unless an existing safe attempt
projection already carries them; raw messages, bodies, prompts, headers, tokens,
and frames remain excluded.

Codex Pooler is no longer a Codex app-server control surface. Configure Codex by
pointing `model_providers.*.base_url` at `/backend-api/codex`; do not point
`chatgpt_base_url` at Codex Pooler. Account helper calls, thread goals,
analytics posting, memory trace summaries, alpha search, raw realtime calls,
safety checks, agent identity JWKS, and reset-credit consume operations are
outside the supported runtime boundary.

`POST /backend-api/codex/responses` and `POST /backend-api/codex/responses/compact` dispatch through the shared gateway accounting path. Successful usage-bearing rows are priced when a matching pricing snapshot exists. Weekly-only probe requests may still reach upstream; an upstream HTTP 400 is recorded as an upstream validation or runtime error, not as quota denial.

Backend Responses requests strip upstream-unsupported OpenAI compatibility controls before dispatch: `max_output_tokens`, `prompt_cache_retention`, `safety_identifier`, `temperature`, and `top_p`. Policy and accounting checks still evaluate the original client payload before the sanitized upstream body is sent.

`GET /backend-api/codex/responses` is the backend Codex websocket route with durable session aliases, owner leases, duplicate-turn suppression, and optional owner-alive forwarding when clients provide stable turn ids. For each logical websocket request, the current request-scoped turn state is read from the `response.create` frame body at `response.create.client_metadata["x-codex-turn-state"]`; websocket request headers are not the current per-frame carrier. The upgrade/header value remains only a fallback for older clients. Owner-alive forwarding preserves the live upstream websocket by routing frames to the current owner app pod. It works only when owner-forwarding mode and app BEAM clustering are enabled together: `CODEX_POOLER_WEBSOCKET_OWNER_FORWARDING=true`, `app.websocketContinuity.ownerForwarding.enabled=true`, `clustering.enabled=true`, and `clustering.participants.app=true`.

Outbound upstream websocket proxy environment variables are unsupported by
default for the connection codex-pooler initiates from the app pod to the
upstream provider, unless real deployment evidence changes this policy. This
scope is outbound egress only. It is not a statement about clients connecting to
codex-pooler through Phoenix trusted-proxy handling, the runtime ingress
firewall, Kubernetes ingress, or supported client websocket upgrades. When an
upstream websocket upgrade completes with a non-101 response, codex-pooler keeps
the transport evidence internal and exposes sanitized failure semantics:
client-facing websocket errors use `upstream_request_failed`, request and
attempt metadata stay in the `upstream_stream_error` family, and raw upstream
headers or bodies must not be logged, persisted, or returned.

Owner death, owner drain, node loss, or stale ownership is a deterministic failure or interruption. Codex Pooler does not reconstruct, migrate, or replay a live upstream websocket session after the owner dies. During Kubernetes rollout or app drain, a graceful owner monitor exit is part of this interruption contract: it should classify as `owner_drained`, then either recover through bounded `owner_unavailable_takeover` for the same `<session-id>` or require the client to reconnect with full context. Owner-forwarding metadata stays metadata-only: no raw frames, prompts, bearer tokens, cookies, auth.json, upstream secrets, or raw idempotency keys are persisted.

### Owner retention and bridge attempt observability

`websocket_owner_idle_timeout_ms` is a DB-backed Instance Setting for the
post-detach lifetime of an owner with no active turn. Its default is 30 minutes
(`1_800_000` ms), with a 1- to 60-minute range (`60_000` through `3_600_000`
ms). It is separate from `websocket_idle_timeout_ms`, which controls
downstream websocket idle behavior and forwarded submit waits.

Each newly created or recovered owner reads the current cached setting on its
own node and captures that value at initialization. Live owners keep their
captured value; a settings change does not rewrite their idle timer. The idle
setting is not the lease TTL: a retained owner may continue renewing its DB
owner lease, while lease TTL and renewal cadence remain separate controls.
Lease renewal can use the current lease TTL, but it does not make a live
owner adopt a new idle timeout.

During a mixed release, a legacy owner that lacks the option uses the old
300-second (5-minute) fallback and may omit the new upstream connection
metadata. New or recovered owners use the current default, normally 30 minutes.
No-option native remote attach remains compatible with the `/2` call shape.
Only the bridge's guarded option-carrying attach uses `/3`; an old owner fails
that guarded call closed and the bridge falls back to HTTP before visible
output. To roll back, lower the setting for new owners first, then drain or
restart owners, or wait for owners with the prior captured value to expire.

Per node, use `resident owners ~= active owners + (detach/recovery rate * idle
timeout)` as a resource heuristic. Owner memory, upstream websocket state, file
descriptors, and active lease rows follow the resident-owner estimate. This is
not a hard capacity bound: concurrency limits simultaneous work, not distinct
session arrivals over time, so concurrency alone gives no finite churn bound.

Admin request-log detail may show the bounded
`upstream_websocket_connection` attempt object only. `lifecycle_id` identifies
the owner-side upstream session, `generation` starts at 1 and increments for
each successful upstream connection, `reused=true` means the same generation
served the request, and `reconnected=true` means a reusable connection failed
before response and was replaced transparently. A new lifecycle/generation 1
is initial connection; a higher generation with both flags false is key
replacement; a new owner/lease normally starts a new lifecycle and is owner
replacement, which must be correlated with bounded takeover/lease metadata.
Default projections, MCP output, and runtime responses omit this object. It
contains no raw frames, PIDs, node names, or socket handles.

For a committed public bridge, the request remains `http_sse` downstream while
the attempt is `websocket` with `upstream_websocket_bridge=true` and
`upstream_transport=websocket`. A pre-visible bridge failure keeps the attempt
on `http_sse`, omits bridge/connection metadata, and falls back to HTTP with one
settlement; a post-visible failure does not fall back. A stable lifecycle or
connection reuse is continuity evidence, not proof of a provider cache hit.
Use bounded settled cached-input totals split by canonical attempt transport
and session/follow-up position. Do not use raw frames, PIDs, node observations,
or socket inspection as a prerequisite for production diagnosis.

Planned Kubernetes rollout drain is app-local and bounded. The app `preStop`
hook writes the configured drain marker so `/readyz` returns unavailable, then
runs the local release RPC
`CodexPooler.Gateway.Transports.Websocket.RolloutDrain.drain_for_shutdown()`.
That drain flag refuses new websocket admission on the draining app process
while active owner-forwarded websocket work gets a bounded terminal drain
attempt. The chart default aligns `app.lifecycle.preStop.drainTimeoutSeconds`,
`app.lifecycle.preStop.sleepSeconds`, and
`app.terminationGracePeriodSeconds` so the drain RPC, final sleep, and SIGTERM
shutdown all fit inside the pod grace window.

The Helm chart keeps that runtime contract safe by default: `app.replicaCount`
defaults to `1`, and renders fail when operators set more than one app replica
without `app.websocketContinuity.allowUnsafeMultiReplica=true`. Task 9 wires
`app.websocketContinuity.ownerForwarding.enabled=true` to render
`CODEX_POOLER_WEBSOCKET_OWNER_FORWARDING=true` in app pods, but the unsafe
multi-replica guard stays active until Task 13 can relax it after Task 12 BEAM
and Kubernetes smoke evidence. BEAM clustering alone only handles PubSub and
LiveView fanout. Owner-forwarding without app BEAM clustering cannot reach a
remote owner pod.

Staged owner-forwarding smoke values:

```yaml
app:
  replicaCount: 2
  websocketContinuity:
    allowUnsafeMultiReplica: true
    ownerForwarding:
      enabled: true
clustering:
  enabled: true
  participants:
    app: true
```

Planned local smoke entrypoint:

```bash
scripts/smoke/two-node-websocket-owner-smoke.sh
```

Owner-forwarded websocket error contract:

Owner-forwarded full-turn submit waits use the websocket/session budget for the
new websocket request, not the upstream receive timeout. That budget lets a
healthy long-running turn complete when the proxy pod forwards the submit to the
owner pod. Owner-control calls such as lookup, attach, detach, cancel, and
owner-state coordination stay on their short control budgets so topology or
cleanup failures surface quickly.

| Error | Contract boundary |
| --- | --- |
| `owner_unavailable` | No active reachable owner is available, or the topology cannot reach one. During downstream detach this is a cleanup and reachability signal that triggers bounded inline recovery for active in-progress leftovers. The client must reconnect with full context or start fresh. |
| `stale_owner` | The caller has an old owner token, lease, or downstream epoch. Old sockets cannot take back ownership. |
| `owner_forward_timeout` | The proxy timed out waiting for the owner. The remote operation has ambiguous execution state, so operators must not replay frames from evidence. |
| `owner_busy` | The owner is applying per-session backpressure or already processing work. Retry through the client protocol only. |
| `owner_drained` | A controlled owner drain or graceful rollout owner monitor exit interrupted the live upstream websocket. Active owner turns finalize request and attempt rows as failed with response status `499`, interrupt the turn and session, and release the owner lease with `owner_drained`. Late drain after success must not downgrade the succeeded request. Graceful rollout drain should not be described as Bandit or Thousand Island `** (stop) :owner_crashed`. |
| `owner_crashed` | The owner crashed abnormally. The live upstream websocket is lost and cannot be migrated. Treat true crash evidence, failed takeover, repeated churn, lifecycle recovery failure, owner exit persistence failure, or stuck `in_progress` rows as actionable. |

The request log status is the persisted `requests.status`. Owner lifecycle
errors can also appear as sanitized attempt or routing summaries while
finalization and recovery finish. That mixed request-log state means operators
should inspect the request row, latest attempt error code and response status,
Codex turn and session status, and owner lease release metadata before treating
the row as stuck. A failed request with `owner_drained` is terminal. An
`in_progress` request with an owner summary is active or pending cleanup until
the authoritative request status changes.

Recovered planned-rollout evidence has a narrow shape. `/readyz` is unavailable
after the marker or drain flag is set, new websocket admission is refused on the
draining app pod, active owner-forwarded websocket turns fail terminally as
`owner_drained`, and the planned deploy path does not produce `owner_crashed`.
The owner lease or routing metadata can record `owner_unavailable_takeover` with
sanitized release or source labels such as `<old-owner-instance>` and
`<new-owner-instance>`. The recovery is only normal when later requests for
`<session-id>` succeed with new `<request-id>` values and the same session does
not keep churning. Ordinary user socket closes remain `client_disconnected`;
unexpected owner exits remain `owner_crashed`.

Actionable evidence includes a true `owner_crashed`, a takeover failed event,
repeated `owner_unavailable_takeover` churn for the same `<session-id>`, stuck
`in_progress` request, attempt, or turn rows after recovery should have
finished, a lifecycle recovery failed event, or owner exit persistence failure.
Those cases are not safe by default and require operator investigation before
treating the websocket owner state as recovered. Operators should also compare
the rendered preStop drain timeout, preStop sleep, and pod termination grace
period before treating a truncated drain as a runtime classification failure.

Owner-exit persistence failure observability is metadata-only. Events identify
the operation, `codex_session_id`, sanitized reason class, owner exit reason, and
recovery hint. They must not include owner lease tokens, raw exception messages,
websocket frames, prompts, bearer tokens, cookies, auth.json, upstream secrets,
or raw idempotency keys. The recovery contract is one bounded inline pass for
active leftovers after owner reachability or persistence failure, using the same
interruption semantics as ordinary owner lifecycle cleanup.

Codex Pooler never infers stale-frame replay for unresolved continuations. If upstream reports `previous_response_not_found` or `invalid_previous_response_id`, client-visible compatibility stays in the safe stream-incomplete style, while sanitized internal attempt metadata preserves the upstream error evidence. Recovery is a full-context restart: the client sends the full input context for the next turn and omits `previous_response_id`, or sets it to `null`. Repeating the same stale anchor is not recovery, and a proxy cannot rebuild a delta-only websocket request from stored raw frames because raw frames and response bodies are not stored.

Pinned continuation recovery is split into two safe terminal cases. When a request tries to continue a pinned session whose selected upstream account needs revoked-refresh-token reauthentication, the gateway fails closed with HTTP status `503`, code `pinned_continuation_reauth_required`, `retryable: false`, `requires_new_upstream_session: true`, and recovery kind `restart_with_full_context`. That code is limited to the reauthentication case. Other hard-pinned recovery denials, including exhausted pinned quota, an unavailable Pool assignment, or an inactive upstream identity, use HTTP status `503`, code `pinned_continuation_unavailable`, `retryable: false`, `requires_new_upstream_session: true`, and the same recovery kind. This is not automatic failover, hidden detach, transparent reroute, server-side anchor stripping, or semantic migration of the continuation to another account. No upstream dispatch or fallback attempt should happen for a denied hard-pinned continuation. Soft-pinned session hints can still fall back to another eligible assignment.

Full visible context means the client-visible conversation state and tool results the client can safely send again. It does not mean replayed stored prompts, hidden server state, stored raw frames, response bodies, provider payloads, or any other data codex-pooler deliberately does not persist or expose.

HTTP surfaces carry this recovery class with `x-codex-recovery-kind: restart_with_full_context` plus the structured error body. Upgraded websocket surfaces carry the equivalent recovery metadata inside the error frame because post-upgrade recovery details are not HTTP response headers.

The client restart must remove these exact continuation anchors:

| Carrier | Remove |
| --- | --- |
| Body | `previous_response_id` |
| Headers | see list below |

Header anchors to remove:

1. `x-codex-previous-response-id`
2. `x-codex-turn-state`
3. `x-codex-window-id`
4. `x-codex-session-id`
5. `session-id`
6. `x-session-id`
7. `x-session-affinity`
8. `session_id`
9. `x-codex-conversation-id`

Backend regular HTTP Responses and compact routes forward approved metadata
headers to upstream: request-scoped `x-codex-turn-state`,
`x-codex-turn-metadata`, `x-codex-window-id`,
`x-codex-parent-thread-id`, `x-codex-installation-id`, and
`x-openai-subagent`. They also relay upstream `x-codex-turn-state` response
headers downstream. This applies to `/backend-api/codex/responses`,
`/backend-api/codex/v1/responses`, `/backend-api/codex/responses/compact`,
and `/backend-api/codex/v1/responses/compact`. Public `/v1/responses` and
websocket request headers do not forward this backend-only metadata lane; any
websocket request-scoped turn state stays in `response.create.client_metadata`.
Raw metadata values are not persisted in request logs, attempt metadata, audit
logs, sessions, or turns.

The operator action is to reauthenticate the pinned upstream account in `/admin/upstreams`, then have the client start again without those continuation anchors and with full visible context. Rotating a Pool API key, replaying hidden server evidence, or retrying the same stale anchors is not the recovery path.

`POST /backend-api/transcribe` is the backend transcription route. It accepts multipart audio, forces the backend transcription model contract, and records metadata only.

`POST /backend-api/codex/responses` accepts normal backend Responses traffic. When a JSON/SSE request contains exactly one terminal `compaction_trigger` input item with `stream: true`, Codex Pooler bridges the compact work through `/backend-api/codex/responses/compact`, strips the trigger plus `stream`, `include`, and compact-unsupported `store`, records compact endpoint/transport accounting, and returns backend Responses SSE with one encrypted compaction output item. Malformed trigger placement returns a sanitized `400` with `param: "input"` before upstream dispatch. Provider context-overflow failures follow the same no-hidden-replay boundary: Codex Pooler records sanitized request and attempt metadata, but it does not replay stored prompts, rebuild websocket frames, or synthesize a replacement request from hidden history. The recovery path is still client-side full-context restart or upstream-owned compaction behavior.

`POST /v1/responses` accepts OpenAI Responses JSON and streaming requests, then dispatches through the same gateway accounting path as backend Responses. System and developer input-message text is lifted into top-level `instructions`; existing top-level instructions come first, then lifted text in input order, while non-text residual content stays as sanitized user input. Previous-response tool-result continuations may include bare OpenAI `item_reference` input items of the shape `{type: "item_reference", id: "..."}` when `previous_response_id` is present and the same input contains semantic tool output such as `function_call_output`. Structured `function_call_output.output` values are forwarded upstream unchanged as JSON values; request logs, attempt metadata, admin projections, MCP projections, and gateway debug summaries expose only shape, counts, and hashed previews. Hermes-style chat `role: "tool"` input messages with `tool_call_id` or `call_id` are translated to `function_call_output` before local continuation validation. Responses item `metadata` maps, including `turn_id`, are preserved for native replay items and for translated chat-style assistant/tool replay items in the upstream request body, while local projections remain metadata-only.

Malformed references, references without `previous_response_id`, and references outside tool-result continuations are rejected before dispatch. OpenAI `truncation` accepts only `auto` and `disabled` locally for SDK compatibility, but it is stripped before upstream dispatch. OpenAI `reasoning.context` accepts only `auto`, `current_turn`, and `all_turns` after trimming and lowercasing; unknown, empty, or non-string values fail before dispatch with `param: "reasoning.context"`.

Streaming and websocket `/v1/responses` preserve ordinary OpenAI terminal incomplete responses as `response.incomplete` / `status: "incomplete"` when no embedded error is present, including `incomplete_details.reason` values such as `max_output_tokens` and `content_filter`. These delivered incomplete terminals settle as succeeded requests and use upstream usage for cost when usage is present; when usage is missing, they remain `usage_unknown` without invented settled cost. Failure-coded incomplete terminals, including context overflow, stale continuation anchors, `stream_incomplete`, retryable server overloads, or events with embedded error objects, are normalized to sanitized failure handling and remain failures/retries according to the same first-event visibility rules as `response.failed` and top-level `error`.

Streaming `/v1/responses` emits an early upstream `response.failed` or top-level `error` as the first public SSE event without synthetic success prefixes; non-stream failures remain OpenAI-shaped JSON errors. Public JSON errors and SSE terminal errors redact server-class/internal/upstream failures to message `upstream request failed`, type `server_error`, and a safe upstream code or `upstream_error`; explicit 4xx `invalid_request_error` validation details keep their message and param. `POST /v1/responses/compact` is authenticated and explicitly routed, but currently returns a deterministic OpenAI-shaped unsupported response because compact remains a Codex backend behavior, not a public OpenAI Responses API behavior. Responses retrieve, cancel, and delete routes are not implemented and return deterministic unsupported responses.

For public HTTP SSE, if upstream has already produced public Responses-visible data and then closes or interrupts before any Responses terminal event, Codex Pooler writes one sanitized terminal `event: response.failed` with `code: upstream_stream_error` before finalizing the request as a failed upstream stream interruption. That synthetic terminal is only a public `/v1/responses` HTTP SSE compatibility guard; backend raw Responses SSE and websocket streams are not rewritten, and raw upstream error text, prompt text, tool output, headers, cookies, and credentials are not copied into the terminal event or persisted metadata.

Public HTTP SSE attempts also persist one bounded stream summary under
`attempts.response_metadata->'public_openai_responses_stream'`. The map is
internal operator evidence only and contains only lifecycle flags and counters:
`schema_version`, `mode`, `created_seen`, `visible_seen`, `delta_count`,
`delta_bytes`, `text_done_count`, `text_done_bytes`, `item_done_count`,
`terminal_seen`, `terminal_kind`, `terminal_status`, `finish_class`,
`synthetic_terminal_sent`, `source_chunk_count`, `stream_bytes`, `relay_bytes`,
and `passthrough_seen`. The summary distinguishes completed terminal-only
streams, empty-output completions, failed or incomplete terminals, missing
terminals, passthrough fallback, and synthetic terminal failures without storing
raw prompts, completions, tool output, SSE frames, headers, cookies, bearer
values, response bodies, or content hashes.

`POST /v1/chat/completions` accepts OpenAI chat completions requests, translates supported messages and tools to the Responses gateway path, and returns OpenAI chat JSON or data-only chat streaming chunks. Responses payloads with `status: "incomplete"` and `incomplete_details.reason` equal to `content_filter` or `content-filter` map to chat `finish_reason: "content_filter"`; `max_output_tokens`, missing reasons, and other ordinary incomplete reasons stay `finish_reason: "length"` and settle as succeeded requests when the upstream terminal is not error-coded. Streaming early terminal failures return a first `data: {"error": ...}` chunk without an assistant role chunk or `[DONE]`; server-class/internal/upstream errors use the same public redaction shape as `/v1/responses`, while explicit client validation details remain visible. Late failures after output preserve the already-started stream behavior and are not retried.

Strict tool and structured-output schemas support local JSON Pointer `$ref` values that point into root `$defs` or legacy `definitions`. Local refs are resolved before strict node validation, so `$ref`-only schema nodes are valid when their targets resolve to schema objects. Remote refs, malformed refs, unresolved refs, non-map targets, and circular local refs are rejected before reservation or upstream dispatch with sanitized schema-error metadata.

Non-strict function tool schemas are lowered before local validation and
upstream dispatch on backend Responses HTTP, backend Responses websocket
`response.create`, and public `/v1/responses` compatibility paths. The lowering
scope is function tools only, including nested function tools inside accepted
namespace tools. It can convert boolean schemas, `const`, missing object or
array type markers, missing object `properties`, missing array `items`, and
unsupported JSON Schema keywords into the narrow supported schema shape while
preserving supported refs, definitions, and combinators recursively. Strict
function tools and strict structured-output schemas stay on the strict
validation path and are not made looser.

`GET /v1/models` and `GET /v1/usage` are metadata-only compatibility endpoints. Models are filtered by the authenticated API key policy. `/v1/models` returns OpenAI-shaped model-list entries and does not expose Codex-native context fields or backend-only `comp_hash`; when context metadata is available, `context_length` is the effective advertised window after safety policy. Clients that need Codex `context_window`, `max_context_window`, `auto_compact_token_limit`, or `comp_hash` should use `/backend-api/codex/models`. `context_window` is the effective advertised window for client budgeting, while `max_context_window` preserves the upstream or plan cap. Usage is read from existing accounting data and sanitized Pool quota evidence.

`GET /v1/files`, `POST /v1/files`, and `GET /v1/files/:file_id` expose owned file metadata for SDK compatibility. File bytes are transient on create and are uploaded to the upstream-backed bridge. Codex-pooler stores metadata only, so `GET /v1/files/:file_id/content` returns the deterministic unsupported contract after ownership checks. `DELETE /v1/files/:file_id` also returns deterministic unsupported after ownership checks.

`responses.input_file` is SDK-callable through the `/v1/files` file id path and preserves ownership plus upstream assignment affinity. Current real upstreams may still reject file completion with an upstream file lookup error, so SDK smoke output can mark `responses.input_file: ok (expected upstream file limitation)` only for that narrow parsed upstream limitation. Fake-upstream-backed local smoke proves the SDK call, routing, and sanitized error handling.

`POST /v1/audio/transcriptions` accepts OpenAI-style multipart audio requests, validates the OpenAI model contract, then dispatches through the same backend transcription route and metadata-only accounting path. Audio bytes and transcripts are not persisted or rendered in docs, request logs, or admin pages.

`POST /v1/images/generations` and `POST /v1/images/edits` accept OpenAI-style image requests and translate them into Responses image-generation tool calls. Image edit uploads are held only transiently for upstream dispatch as data URLs; request logs and admin pages stay metadata-only and do not expose prompts, filenames, image bytes, or generated image payloads. `POST /v1/images/variations` is intentionally unsupported and returns a deterministic OpenAI-shaped error without upstream dispatch.

`POST /backend-api/codex/images/generations` and `POST /backend-api/codex/images/edits` are backend-compatible Codex image proxy routes for upstream typed `ImagesClient` compatibility. They accept JSON request bodies and preserve the upstream response shape. Prompt, image, and base64 request or response bodies are not persisted or rendered in request logs or admin pages.

`POST /backend-api/files` plus `POST /backend-api/files/:file_id/uploaded` is the Codex backend JSON SAS create and finalize flow. No `model` field is required for `/backend-api/files`. JSON create accepts `{file_name, file_size, use_case}` and returns upstream `{file_id, upload_url}`. `use_case` defaults to `codex`, multipart create is rejected, returned upload URLs must be public HTTPS direct-upload targets without userinfo or localhost/private/reserved IP literals, upload bytes go directly to the upstream `upload_url`, codex-pooler stores metadata only, and request logs record safe route metadata only. Unsafe create responses are rejected as an upstream file bridge invalid response before a usable pending file row is created. Raw upload URLs are never logged or rendered.

`GET /api/codex/usage`, `GET /wham/usage`, and `GET /backend-api/wham/usage` return backend Codex usage for Codex clients and stored upstream-token usage probes. For pool API keys, the response is selected from the best currently routable upstream account in the pool so an exhausted account does not hide a usable one.

## Upstream workspace slots

Upstream identities are keyed by the stored ChatGPT account id plus the trusted workspace id. The canonical slot key is `(chatgpt_account_id, workspace_id)`. `workspace_label` and `seat_type` are display and diagnostic metadata only. They are never uniqueness keys, routing keys, or fallback selectors.

The legacy slot is the row where `workspace_id = nil`. There can be exactly one legacy null-slot identity for a given `chatgpt_account_id`, and it stays valid for accounts whose trusted auth evidence has no workspace id. Concrete workspace slots can coexist with the legacy row and with each other. For example, the same synthetic account `acct_123` can have a legacy null-slot row, a concrete `ws_alpha` row, and a concrete `ws_beta` row. Those rows are separate upstream identities with separate assignments, quota evidence, plan state, and encrypted secrets.

Import, invite completion, reconciliation, quota refresh, usage-token reads, and token refresh must prefer the exact `(chatgpt_account_id, workspace_id)` slot when trusted workspace evidence is present. A unique legacy row can be upgraded only when no concrete sibling exists. If account-id or email fallback would choose among multiple possible workspace slots, the operation refuses the selection instead of guessing. The sanitized conflict reason is `workspace_identity_mismatch`, and diagnostics use `legacy` or hashed `ws:<hash>` workspace refs instead of raw workspace ids.

Targeted relink has one narrow missing-workspace exception. If the provider omits `workspace_id` for a selected concrete identity, Codex Pooler may keep the selected slot only after account and subject validation pass, incoming plan and seat evidence are both present, and any already-stored plan or seat value does not conflict. The selected row's stored `workspace_id` and `workspace_label` remain authoritative, and stored non-nil `seat_type`, `plan_family`, and `plan_label` values win over incoming values. Older concrete rows with nil plan or seat metadata may backfill those nil fields from the accepted callback. This exception does not apply to unassigned linking, imports, reconciliation, callbacks with missing incoming plan/seat evidence, or callbacks that conflict with known stored plan/seat evidence.

Mismatch handling is a no-op for the wrong slot. A refresh or reconciliation payload that belongs to a different workspace must not update the stored plan family, seat type, quota windows, assignment health, token-refresh state, or encrypted secret ownership for the selected identity. The safe diagnostic location is `identity_conflict` metadata on the request, assignment, or job result, depending on which boundary saw the mismatch.

Out-of-scope parity is explicit. This implementation does not add a standalone probe endpoint for workspace slots, does not add a force-refresh feature, and does not add auth export UI or API parity. Operators should use `/admin/upstreams`, request logs, MCP metadata tools, and persisted quota evidence to inspect the current slot state without exporting raw auth JSON, tokens, workspace ids from real systems, prompts, or file bodies.

## Codex runtime state and lifecycle

File payloads are not stored locally. Database rows keep ownership, purpose, content type, byte count, status, finalization state, expiry, and upstream bridge affinity metadata. Request logs and admin pages show safe metadata only. They don't show raw file bodies, original sensitive filenames, prompts, images, audio, bearer tokens, auth headers, upstream tokens, cookies, raw upload URLs, secrets, or raw idempotency keys.

Default lifecycle values are 25 MiB maximum file size, 24 hour metadata TTL for unfinalized or expired file rows, 15 minute abandoned-upload cleanup cadence, 45 second durable bridge owner lease TTL, 15 second lease renewal cadence, and 24 hour expired-alias TTL. The `/backend-api/files` create call returns the upstream `file_id` plus `upload_url`, the client uploads bytes directly to that target, and the finalize call bridges completion back through the same upstream assignment. No public file-content read route is exposed.

Operators link OpenAI accounts or import Codex `auth.json` through the authenticated `/admin/upstreams` browser page. OpenAI OAuth is the preferred path for new operator-managed upstream accounts when browser authorization is practical. The auth.json import form parses the local JSON shape. Both paths store secret material only through encrypted upstream secret storage and render product labels plus `stored account id`. The selected Pool is an initial assignment target, not permanent ownership. The same upstream identity can have active assignments in multiple Pools at the same time. Later sharing or removal is managed from `/admin/pools`: attach the identity to the target Pool, then optionally edit the source Pool and remove it there. Don't paste raw `auth.json`, access tokens, refresh tokens, callback URLs, authorization codes, cookies, or local file paths into docs, tickets, evidence, or source files.

### OpenAI OAuth Upstream Linking

OpenAI OAuth upstream linking is an authenticated admin LiveView workflow.
Operators use `/admin/upstreams` to link a new upstream account to a selected
Pool, and `/admin/upstreams/:id` to relink or reconnect the exact upstream
identity shown in the cockpit. Relink checks the returned account and workspace
claims against the target identity before replacing encrypted credential
material.

The browser manual callback workflow is:

1. open the OAuth link or relink dialog
2. choose `Browser`
3. open the generated OpenAI authorization URL
4. complete OpenAI authorization in the browser
5. paste the resulting local callback URL back into the admin dialog
6. submit the callback form and wait for the success or safe error state
7. close the dialog after it reports that the account was linked or relinked

The local callback URL is consumed only by the already-authenticated admin
LiveView event, and there is no hosted OAuth callback route, no public
`/auth/callback`, and no `/api/admin/*` or dashboard JSON API for this workflow.
Route tests keep that boundary explicit.

Use the device-code fallback when browser authorization is not practical. The
dialog shows the user code and verification URL while the flow is pending, and
the LiveView polls only while the operator keeps the dialog open. Device-code
authorization must be enabled for Codex on the OpenAI account or workspace. If
device authorization is unavailable or denied, use the browser workflow or ask
the workspace admin to enable Codex device-code login.

Operators should never paste callback URLs, authorization codes, tokens, cookies,
raw auth.json, OpenAI provider payloads, or local credential files into docs,
tickets, logs, or evidence. The admin UI may show the one-time authorization URL
or device user code during a pending flow, but persisted flow summaries, audit
metadata, request logs, tests, and docs must stay metadata-only.

Safe OAuth troubleshooting codes:

| Code | Operator action |
| --- | --- |
| `invalid_callback_url` | Paste the full localhost callback URL from the browser address bar |
| `invalid_callback_origin` | Use only the `http://localhost:1455/auth/callback` URL produced by the OpenAI flow |
| `missing_state` | Restart the OAuth flow from the admin dialog |
| `duplicate_callback_param` | Restart the OAuth flow and paste the unedited callback URL |
| `missing_callback_result` | Restart the OAuth flow because the callback did not include a usable result |
| `provider_denied` | The OpenAI authorization was denied; restart only if the account should be connected |
| `invalid_state` | Restart from the current admin dialog; an old or unrelated callback was pasted |
| `expired_flow` | Start a new OAuth flow |
| `flow_not_pending` | Close the stale dialog state, start a fresh OAuth link or relink flow, and use the latest callback URL |
| `stale_flow` | A newer flow superseded this one; use the latest dialog state |
| `token_exchange_failed` | Retry once, then inspect OpenAI availability and sanitized provider status |
| `identity_mismatch` | Relink with the same OpenAI account and workspace shown in the cockpit |
| `identity_conflict` | Resolve the duplicate or ambiguous upstream identity before retrying |
| `unauthorized_pool` | Confirm the operator can manage the selected Pool |

## Verified Codex smoke boundary

The verified real client paths are:

- real Codex text through `scripts/dev/codex-smoke.sh --scenario text --runs 1` with `CODEX_SMOKE_MODEL=gpt-5.5`
- real Codex CLI image attachment through `scripts/dev/codex-smoke.sh --scenario image --runs 1` with `CODEX_SMOKE_MODEL=gpt-5.5`
- backend file bridge create, direct upload, finalize, and same-assignment `input_file.file_id` routing through `scripts/dev/codex-smoke.sh --scenario file-bridge --runs 1` with `CODEX_SMOKE_MODEL=gpt-5.5`
- websocket backend continuity only when the client path supports it, using `CODEX_SMOKE_SUPPORTS_WEBSOCKETS=true scripts/dev/codex-smoke.sh --scenario websocket --runs 1` with `CODEX_SMOKE_MODEL=gpt-5.5`

The image claim is specifically the real Codex CLI attachment path. Direct bare HTTP SSE requests containing `input_image` still return upstream HTTP 400 in the current live setup, even though codex-pooler accepts and dispatches the image-bearing request. Text-only models reject `input_image` before upstream dispatch with `unsupported_model_capability`.

The file claim is specifically the route-level bridge and routing contract. Supported file setup is `/backend-api/files` JSON create, direct `PUT` to the returned upstream upload URL, `/backend-api/files/:file_id/uploaded` finalize, then same-assignment routing for a later `input_file.file_id` request. Unsupported file paths are multipart `/backend-api/files` create and claiming arbitrary Codex CLI file upload response completion. Direct bare HTTP SSE completion with `input_file.file_id` is blocked today by upstream 404 file lookup, not by codex-pooler bridge affinity.

Dry-run or zero-run smoke modes only validate parser behavior, generated fixtures, and redaction shape. They aren't real smoke evidence.

## Runtime hardening settings

Codex runtime compatibility routes are protected by Phoenix Plug hardening before gateway dispatch. If the DB-managed firewall allowlist is empty, the firewall is off and current behavior is preserved. When it is set, client IPs must match an exact IP or CIDR entry. Forwarded headers such as `x-forwarded-for` and `x-real-ip` are trusted only when the immediate peer matches the DB-managed trusted proxy list; spoofed forwarded headers from untrusted peers are ignored.

Compressed JSON requests can use `gzip`, `deflate`, or `zstd` when the runtime supports Erlang's zstd module. Compression controls live in DB-managed Instance Settings. Compressed multipart uploads are not decoded by the ingress plug; image, audio, and file uploads use normal Phoenix multipart parsing plus route-specific size limits.

Enable gateway debug in Instance Settings only while diagnosing gateway payload normalization. It logs and stores safe metadata about continuation decisions, input item types, and hashed identifier previews; raw prompts, tool outputs, bearer tokens, upstream secrets, and request bodies are not logged or persisted.

HTTP JSON and HTTP SSE upstream transport failures persist compact attempt-level
diagnostics in `attempts.response_metadata->'transport_failure'` when the
failure is classified as `upstream_network_error` or otherwise reaches the
transport failure metadata path. That metadata is internal-only and bounded to
sanitized scalar fields such as `exception`, `reason_class`, `reason`, and
`phase`. Gateway debug mode may add payload-shape, continuity, and routing
summaries, but it is not required for the compact transport exception,
reason-class, reason, or phase diagnostics. Request-log list and table surfaces
must keep error columns short, for example `upstream_network_error`; detail and
debug surfaces may show the bounded per-attempt `transport_failure` object.

For public `/v1/responses` HTTP SSE diagnostics, correlate the request row, the
latest attempt, and the stream summary before using app or edge logs as the
primary truth. Filter by the public source endpoint and inspect only
metadata-only fields:

```sql
SELECT
  r.id AS request_id,
  r.correlation_id,
  r.admitted_at,
  r.completed_at,
  r.endpoint,
  r.request_metadata #>> '{openai_compatibility,source_endpoint}' AS source_endpoint,
  r.transport AS request_transport,
  r.status AS request_status,
  r.last_error_code AS request_error_code,
  a.attempt_number,
  a.transport AS attempt_transport,
  a.status AS attempt_status,
  a.network_error_code AS attempt_error_code,
  a.upstream_status_code,
  a.started_at AS attempt_started_at,
  a.completed_at AS attempt_completed_at,
  a.response_metadata #> '{public_openai_responses_stream}' AS stream_summary,
  a.response_metadata #>> '{public_openai_responses_stream,finish_class}' AS finish_class,
  a.response_metadata #>> '{public_openai_responses_stream,terminal_kind}' AS terminal_kind,
  a.response_metadata #>> '{public_openai_responses_stream,terminal_status}' AS terminal_status,
  a.response_metadata #>> '{public_openai_responses_stream,synthetic_terminal_sent}' AS synthetic_terminal_sent
FROM requests AS r
JOIN attempts AS a ON a.request_id = r.id
WHERE r.admitted_at >= now() - interval '2 hours'
  AND (
    r.endpoint = '/v1/responses'
    OR r.request_metadata #>> '{openai_compatibility,source_endpoint}' = '/v1/responses'
  )
  -- choose one exact selector:
  -- AND r.id = '<request-log-id>'::uuid
  -- AND r.correlation_id = '<correlation-id>'
ORDER BY r.admitted_at DESC, a.attempt_number ASC
LIMIT 100;
```

Treat Phoenix request_completed duration carefully for streaming routes: it
can represent the response handoff from Phoenix rather than the full downstream
stream lifetime. Use `requests.completed_at`, `attempts.completed_at`, and
Traefik edge duration to measure end-to-end stream lifetime, then use
`public_openai_responses_stream.finish_class`, `terminal_seen`,
`synthetic_terminal_sent`, `stream_bytes`, and `relay_bytes` to explain whether
Pooler saw and relayed a terminal stream.

Route-class admission uses local bulkheads for `proxy_http`, `proxy_control`, `proxy_stream`, `proxy_websocket`, `proxy_compact`, `file_upload`, `audio_transcription`, and `admin_browser`. Each class has DB-managed max concurrency, queue limit, and queue timeout fields. `proxy_control` remains a legacy class for historical request-log rows and settings continuity, but new runtime requests use the model-provider, file, audio, or admin classes. Updates affect future admission decisions, not in-flight work. Pre-admission failures such as body parsing, decompression, and multipart parsing can reject a request before route-class admission or upstream dispatch, so they should not be treated as evidence that a route-class bulkhead accepted or queued the request.

Backend audio transcription accepts multipart uploads and records metadata only. Reasoning effort `minimal` is normalized to `low` before upstream dispatch for affected routes. Client-facing `ultra` is accepted for backend Codex regular, compact, and websocket Responses dispatch, then rewritten to the backend-compatible `max` value before forwarding upstream.

Routing circuits are scoped by Pool, model, assignment, and route class. Circuit rows represent backend health, not API-key-local history. Defaults open a circuit after 3 failures, keep it open for 60 seconds, allow 1 half-open probe, and recover after 1 success. If no healthy eligible backend remains, the gateway returns deterministic `no_eligible_backend` without reserving work. Quota evidence failures still use `quota_evidence_unavailable` and remain fail-closed.

Circuit threshold, open-duration, half-open probe, and recovery success fields in `/admin/system` are advanced cached gateway controls. A saved change refreshes cached settings for future gateway decisions. These fields are not per-request live toggles and don't mutate in-flight requests, queued work, already-open streams, or existing circuit rows.

## Local setup

Prerequisites:

- `mise` with the repo tool versions installed
- Docker with Compose
- `helm` for chart rendering checks

Start or restart the full local dev loop:

```bash
make dev
```

`make dev` starts Postgres, creates and migrates the development database, imports the vendored OpenAI pricing feed, stops any prior Phoenix server for this checkout or port, and starts `mix phx.server` in the background. Logs are written to `tmp/dev-server.log`; use `make dev-logs` to follow them and `make dev-stop` to stop the server.

For manual setup, start the local Postgres service:

```bash
docker compose -f docker-compose.dev.yml up -d db
```

The Compose service is `db`, runs Postgres `18`, and maps host port `5433` to container port `5432`. Defaults are `postgres/postgres`, development database `codex_pooler_dev`, and test database `codex_pooler_test`; those local credentials are intentionally independent from production-style values in `.env`.

Install dependencies and prepare the development database:

```bash
mix setup
```

For a manual database setup path, use:

```bash
mix ecto.create
mix ecto.migrate
mix run priv/repo/seeds.exs
```

Start the Phoenix server:

```bash
mix phx.server
```

In dev/test, `priv/repo/seeds.exs` loads the compact development operator seed. On a fresh dev database, bootstrap is completed and the seeded owner can sign in at `/login` with `dev-owner@example.com` and `dev-password-123`. If a local database already has a non-dev owner, the seed leaves that owner unchanged and only ensures the dev operator examples. After login, use `/admin/pools` as the default admin workspace, `/admin/upstreams` for quota status and invite creation, and the other `/admin/*` pages for instance-admin operations.

## Pool routing semantics

Runtime routing is layered. Model policy, file affinity, compact support, quota evidence, route-class circuits, Codex session affinity, duplicate-turn checks, and accounting reservation all run before bridge ring planning chooses a shortlist. `bridge_ring_size` controls that shortlist and therefore retry breadth.

The persisted strategy keys are `bridge_ring`, `deterministic_rotation`, `least_recent_success`, and `quota_first`. `quota_first` orders already-eligible candidates by usable remaining quota before the rendezvous tie-breaker. Accounts without usable quota evidence are still removed before ordering, and reset time, usage weights, and capacity credits are not ranking inputs. Credits can qualify the narrow `credit_backed_probe` eligibility state, but they don't boost candidate ranking or change equal-remaining-quota tie behavior. `deterministic_rotation` is seed-based rotation, not live round robin. `least_recent_success` prefers assignments whose last successful attempt is oldest, with never-succeeded assignments first.

HTTP stickiness requires stable caller identity to be sticky across requests. If a request only has a generated per-request correlation id, `sticky_http_sessions` mostly records one-request affinity. Persisted websocket stickiness uses the stored Codex session id when a continuity session is attached and the previous assignment remains eligible.

Upstream-originated retryable HTTP JSON failures, pre-first-byte SSE failures, mid-stream SSE upstream failures, and websocket terminal/read failures demote the upstream and record route-class circuit failure. Stream failures after downstream-visible output and websocket failures don't retry to another upstream. Downstream client disconnects don't demote or circuit-fail the upstream.

Service tier routing treats `auto` and `default` as non-narrowing compatibility sentinels. They preserve client or API-key policy intent in sanitized metadata, but are omitted from upstream request JSON. Concrete service tiers such as `priority`, `flex`, or `scale` narrow routing to candidates that explicitly advertise that tier. If no eligible candidate advertises a concrete requested or enforced tier, the request fails closed before upstream dispatch.

## Pricing import and usage reporting

The vendored OpenAI pricing feed lives at `priv/pricing/openai/pricing.json`. Import it locally with:

```bash
mix pricing.import_openai
```

In a release shell or migration container, use the release-safe eval form:

```bash
bin/codex_pooler eval "CodexPooler.Catalog.import_openai_pricing_from_priv()"
```

The import reads the vendored file and populates supported token/default pricing rows in `pricing_snapshots`. Unsupported pricing shapes are skipped. Operators can pass a path to the mix task for local experiments, but production docs should stay anchored on the vendored file. In Kubernetes, the scheduler refreshes pricing hourly from the OpenAI pricing catalog URL in `/admin/system` Instance Settings. The default is `https://s3.icorete.ch/openai-json-pricing/pricing.json`, the public JSON object published by the Windmill OpenAI pricing job, and the worker resolves it when each job performs.

Pricing is usage/reporting only. Persisted costs are estimates for operator visibility, not upstream invoices and not enforcement. Successful usage-bearing rows are priced when a matching pricing snapshot exists. Failed upstream rows with no usage can remain `unpriced` by policy, even when the failure was an admitted upstream HTTP 400. Missing or unsupported pricing is shown as `unpriced`; it never blocks or denies requests. API-key policy remains request, token, quota, and routing only. API-key cost limits are not restored. Startup import and automatic historical repricing/backfill are out of scope.

## API-key policy surface

Use `/admin/api-keys` for advanced API-key work. It is the supported operator surface for creating, editing, rotating, pausing, resuming, revoking, deleting, and reviewing keys, plus enabling or disabling Dashboard access. It is a lifecycle/policy registry and does not show usage totals or charts. Use the key-local `/observatory` browser surface for per-key analytics, `/admin/stats` for Pool-level aggregates, and `/admin/request-logs` for individual sanitized request investigation.

Raw API keys are one-time secrets. The full key is shown only when a key is created or rotated. Later views show safe identifiers such as prefixes and fingerprints, never the full secret.

Operator policy controls include:

- model access modes: all models, selected or manual models, or deny all models
- enforced request attributes that can override model, reasoning effort, and service tier before dispatch
- request and token limits that are checked at reservation time, before upstream dispatch

Cost controls are intentionally not exposed in the API-key admin surface. Pricing is usage/reporting only, so the UI stays on request, token, quota, and routing signals for policy. API-key cost limits are not restored. Missing pricing appears as `unpriced` in usage views and does not deny requests.

## Bootstrap, Pools, and API-key creation

Bootstrap creates the first active owner account and records an active owner membership. It doesn't create a Pool or API key automatically.

For local development, keep the IEx path simple: create a Pool and a basic API key after signing in once or after bootstrap has completed. On a compact-seeded dev database, use the seeded owner email:

```elixir
alias CodexPooler.{Access, Accounts, Pools}
alias CodexPooler.Accounts.Scope

user = Accounts.get_user_by_email("dev-owner@example.com")
scope = Scope.for_user(user, Accounts.roles_for_user(user))
{:ok, pool} = Pools.create_pool(scope, %{slug: "default", name: "Default Pool"})
{:ok, %{raw_key: raw_key}} = Access.create_api_key(scope, pool, %{display_name: "local development"})
raw_key
```

Use the returned `raw_key` as `Authorization: Bearer <raw_key>` for Codex backend runtime calls. The raw key is only returned at creation time. For model policy, enforced request attributes, limits, rotation, pause, revoke, delete, and Dashboard access, use `/admin/api-keys` after login. For per-key usage, open `/observatory/login` with the currently valid raw key; for Pool-level usage, use `/admin/stats`.

Example API checks:

```bash
curl -fsS -H "Authorization: Bearer $CODEX_POOLER_API_KEY" http://localhost:4000/backend-api/codex/models
curl -fsS -H "Authorization: Bearer $CODEX_POOLER_API_KEY" http://localhost:4000/api/codex/usage
```

Codex response endpoints accept JSON payloads up to the runtime JSON body limit and forward through the gateway service:

```bash
curl -fsS \
  -H "Authorization: Bearer $CODEX_POOLER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"example-model","input":"hello"}' \
  http://localhost:4000/backend-api/codex/responses
```

Non-streaming upstream HTTP response bodies are bounded during collection. If
`content-length` or streamed bytes exceed the gateway cap, codex-pooler returns a
sanitized `upstream_response_too_large` 502, finalizes the attempt as failed,
records only response-size metadata, and does not retain the oversized body in
client responses, request logs, attempt metadata, docs, or admin evidence.
Streaming routes continue to use the existing stream-buffer guards.

### Codex CLI smoke test

The gateway distributes success-path requests across healthy assignments by rotating the eligible assignment list from the request correlation id before dispatch. This keeps retries deterministic for one request while allowing repeated Codex CLI calls to exercise more than one upstream account.

After creating a Pool, API key, active upstream identities with encrypted `access_token` secrets, active eligible assignments, fresh routing quota evidence, and one visible model whose `metadata["source_assignment_ids"]` contains those assignment ids, run:

```bash
export CODEX_POOLER_API_KEY='sk-example-redacted'
export CODEX_SMOKE_MODEL='gpt-test-model'
export CODEX_SMOKE_RUNS=6
scripts/dev/codex-smoke.sh
```

The script writes a minimal generated Codex config under `tmp/codex-smoke/codex-home/config.toml` and runs `ghcr.io/icoretech/codex-docker:0.132.0` against `http://host.docker.internal:4000/backend-api/codex` by default. Override `CODEX_SMOKE_BASE_URL`, `CODEX_SMOKE_IMAGE`, or `CODEX_SMOKE_PROMPT` when needed. Codex-device upstream identities default to the ChatGPT backend host for dispatch.

### OpenAI SDK smoke test

Use the official OpenAI Node and Python SDK smoke scripts after local Phoenix is running. By default, each script starts or reuses the local fake upstream, provisions an `openai-v1-smoke` Pool with `v1_compatibility_enabled=true`, creates a smoke API key, syncs the local catalog, seeds quota evidence, and records the selected models in ignored `tmp/openai-v1-smoke/setup.json`. Set `OPENAI_V1_SMOKE_SKIP_SETUP=true` only when you want to supply your own existing Pool key through `OPENAI_API_KEY`.

```bash
OPENAI_BASE_URL=http://127.0.0.1:4000/v1 node scripts/dev/openai-v1-node-smoke.mjs
OPENAI_BASE_URL=http://127.0.0.1:4000/v1 python scripts/dev/openai-v1-python-smoke.py
```

For external client documentation, the equivalent SDK base URL shape is `https://codex-pooler.example.com/v1` and the bearer key placeholder is `sk-example-redacted`. Don't paste real Pool API keys, upstream tokens, upload URLs, prompts, file bodies, audio, images, or SDK traces into docs or tickets.

Both scripts install or refresh the latest official `openai` SDK into the ignored `tmp/openai-v1-smoke/` workspace, keep Node lock metadata in `tmp/openai-v1-smoke/node/package-lock.json`, keep Python environment metadata in `tmp/openai-v1-smoke/python/requirements-lock.txt`, write sanitized runtime metadata under `tmp/openai-v1-smoke/metadata/`, and append exact SDK version lines to local evidence when they run.

Expected markers are:

- `models.list: ok`
- `responses.non_stream: ok`
- `responses.stream: ok`
- `chat.non_stream: ok`
- `chat.stream: ok`
- `files.create: ok`
- `files.retrieve: ok`
- `files.list: ok`
- `files.content: ok`
- `responses.input_file: ok`
- `audio.transcriptions: ok`
- `images.generations: ok`
- `images.edits: ok`
- `images.variations.unsupported: ok`

`files.content: ok` currently means the SDK observed the deterministic OpenAI-shaped `unsupported_endpoint` contract for `/v1/files/:id/content`, because codex-pooler stores file metadata only. `images.variations.unsupported: ok` likewise means the SDK observed the intentional deterministic unsupported response for `/v1/images/variations`.

Verify that multiple upstream identities were used:

```bash
mix ecto.setup # only on a fresh database
psql postgres://postgres:postgres@localhost:5433/codex_pooler_dev \
  -c "select upstream_identity_id, count(*) from attempts where status = 'succeeded' group by upstream_identity_id order by count(*) desc;"
```

## Quota evidence semantics

Routing prefers fresh, non-exhausted, reset-bearing quota evidence for the upstream account, requested model, and any additional limit family that applies to the request. Accounts with precise account-primary 5h evidence are tried before lower-confidence probe states. If an account only has usable weekly `604800` evidence and no account-primary 5h evidence, the gateway may use it as a `weekly_only_probe` candidate, then immediately learns from any `x-codex-*` headers, `codex.rate_limits` events, or reset-bearing errors returned by that runtime call.

Monthly-only account primary evidence is supported as an observed account quota
shape, not as a new persisted kind. Codex usage payloads can report
`primary_window.limit_window_seconds == 2_592_000` with `secondary_window == nil`.
That persists as the raw window shape `window_kind: "primary"` and
`window_minutes: 43_200`. Codex Pooler treats that exact account primary
duration as account-primary evidence when the row is fresh, reset-bearing,
non-expired, and not exhausted. Stale, resetless, expired, exhausted, or unknown
account-primary durations stay blocked through the existing unusable reason
semantics instead of becoming precise routing evidence.

Human-facing usage and admin surfaces label exact account primary `43_200` minute
evidence as `30d`, so it is not shown as `5h`. MCP stays structured as
`quota_kind: "account_primary"` plus `window_minutes: 43_200`; it does not add a
separate monthly human label to the machine contract. Codex Pooler does not infer
free, pro, team, or any other plan family from the duration alone. It also does
not define static monthly capacity tables, fabricate monthly capacity, or derive
remaining credits from `window_minutes`, `used_percent`, or reset time. Capacity
and credit fields stay `nil` unless trusted upstream evidence supplies them.

`credit_backed_probe` is a narrower probe state for account-scoped secondary weekly quota evidence. It applies only when that secondary weekly row is fresh, reset-bearing, unexpired, has `used_percent >= 100`, and has explicit positive `credits`. It doesn't apply to missing, zero, blank, invalid, negative, stale, resetless, expired, non-weekly, or non-account credit evidence. It is eligible but ordered after precise candidates and before `weekly_only_probe` candidates.

Explicit zero credits are known evidence, not missing evidence. `credits == 0` means zero remaining credits were observed and should stay distinct from `credits == nil`. Zero credits don't qualify for `credit_backed_probe`.

Credits don't override other exhausted quota scopes. Account primary 5h exhaustion, model-scoped exhaustion, upstream-model-scoped exhaustion, and additional or feature-limit exhaustion remain fail-closed before reservation or upstream dispatch even if positive account credits exist. Credits also aren't a `quota_first` ranking input; `quota_first` continues to rank already-eligible candidates by used-percent remaining quota, then the existing tie behavior.

Trusted quota evidence can come from Codex usage payloads that include reset fields, `x-codex-*` response headers with reset fields, `codex.rate_limits` stream events, and explicit reset-bearing rate-limit error payload fields when present. Weekly-only usage from Codex usage endpoints remains visible as display or secondary evidence, but weekly-only rows cannot create missing 5h, model, or additional resets. Do not infer reset times from labels, plan defaults, percent values, or window durations alone. Concurrent upstream pressure exclusion remains deferred and isn't part of the shipped quota semantics.

Assignment priming state is operator-facing metadata on the Pool assignment:

- `unknown`, reconciliation has been requested but no result is known yet
- `refreshing`, a reconciliation worker is checking the upstream account
- `known`, usable reset-bearing evidence exists for routing
- `weekly_only_probe`, usable weekly quota exists but account-primary 5h quota is unknown until upstream supplies runtime evidence. These requests are admitted as lower-confidence probes; if upstream returns HTTP 400, that row is an upstream error, not quota denial.
- `credit_backed_probe`, account-scoped secondary weekly quota is exhausted by used percent but has fresh reset-bearing unexpired evidence and explicit positive credits. This is eligible but lower-confidence than precise account-primary evidence.
- `resetless_unprimed`, only resetless or weekly-only display evidence is available
- `failed`, the refresh failed with a sanitized reason
- `stale`, reset-bearing evidence exists but is older than the freshness policy
- `expired`, reset-bearing evidence exists but its reset time has passed

The authenticated `/admin/upstreams` page is the supported debug surface for quota evidence. It shows each quota row source, precision/state, observed time, reset or missing-reset state, routing usability, priming summary, reconciliation summary, and recent quota refresh jobs. Routes under `/backend-api/*`, `/v1/*`, `/api/codex/usage`, and `/wham/usage` stay runtime compatibility routes for clients, not dashboard APIs.

## Quality gates

Run these non-destructive checks before changing release, chart, or operational docs:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix assets.deploy
docker compose config
docker build .
helm template codex-pooler ./charts/codex-pooler
```

The project also provides:

```bash
mix precommit
mix quality.credo
mix quality.dialyzer
mix quality.security
mix quality
mix coverage
mix six
```

`mix precommit` runs compile with warnings as errors, unused dependency checks, formatting, and tests in the test environment.
`mix coverage` runs the test suite through Six, which wraps Erlang's `:cover`, writes a structured coverage report, and enforces the current 83.0% minimum coverage floor. `mix six` runs the same coverage tool directly. Run coverage beside `mix precommit` and `mix quality` for larger gateway, auth, admin, or runtime-controller changes.
`mix quality.credo` runs Credo in strict mode, `mix quality.dialyzer` runs Dialyzer, `mix quality.security` runs Sobelow for medium-or-higher confidence security findings, and `mix quality` runs all three static-analysis gates together. `mix precommit` remains focused on compile, unused dependency, formatting, and tests; run `mix quality` beside it when changing application code or security-sensitive paths.

## Instance settings classification

The DB-backed instance settings migration starts from a static classification
contract in `CodexPooler.InstanceSettings.Classification`. The contract is
data-only: it doesn't read the database, application env, or process env. It
keeps one source of truth for what stays in boot/release configuration and what
moves to DB-managed Instance Settings.

| Bucket | Setting group | Reloadability and storage | Notes |
| --- | --- | --- | --- |
| `env_only_boot` | Database connection | boot-time environment | Ecto must connect before DB-backed settings can be read |
| `env_only_boot` | Phoenix endpoint | boot-time environment | Endpoint listener, URL, and signing/encryption roots stay release config |
| `env_only_boot` | Oban release role | boot-time environment | Web, worker, scheduler, and queue topology are fixed as child specs start |
| `env_only_boot` | DNS and BEAM topology | boot-time environment | Clustering topology is chosen before the application can load DB state |
| `env_only_boot` | App crypto roots | boot-time environment | Existing crypto roots remain env-only; DB-managed app secrets reuse the upstream secret root/version |
| `secret_env_only` | BEAM distribution cookie | boot-time secret environment | VM clustering secret is consumed by the release/VM, not by instance settings |
| `db_runtime_live` | Files, transcription, gateway diagnostics, streaming, upstream timeouts, model metadata, runtime ingress limits, continuity, and operator email | DB-backed live runtime settings | New runtime work can use the current typed settings snapshot |
| `db_runtime_cached` | Firewall/trusted proxies, bridge owner leases, circuit thresholds, route-class bulkheads, upstream Codex user-agent, MCP gate, pricing catalog, development guards, SMTP delivery | DB-backed cached runtime settings | New work sees updates after settings cache invalidation; existing in-flight work keeps its starting values |
| `db_requires_restart` | Reserved | DB-recorded, restart-required | Bucket exists for future operator-visible settings that cannot take effect live |
| `secret_encrypted_db` | SMTP password | encrypted DB secret | Cleartext is needed only at mail send/test time; persist ciphertext plus key version metadata and never render the raw value |
| `secret_hmac_db` | Metrics bearer token | HMAC DB secret | Store keyed HMAC digest, safe fingerprint, and key version; raw token is one-time input and unrecoverable afterward |

`/admin/system` SMTP testing sends a deterministic message to the signed-in operator's email address. The action uses the unsaved candidate form values, including write-only password input, and does not persist them. Blank write-only password input reuses the stored encrypted SMTP password when one exists. Successful automated delivery through the mailer test boundary is enough acceptance evidence; a manual inbox check is not required.

`Public operator app URL` is stored internally as `operator.login_base_url`. It is the external app root used by operator email builders, which append `/login` exactly once. Store the app root, such as `https://pooler.example.com`, not a URL that already ends in `/login`.

Intentionally excluded names include API key examples, deployment wrapper values,
development/test Postgres variables, browser CSP helper sources, invite public
origin, quota freshness/skew, Codex client version, upstream websocket keepalive,
and file bridge retry knobs.

## Production runtime

The Docker image builds a Phoenix release using `elixir:1.19.5-otp-28-slim` and runs it on `debian:trixie-slim`. The runtime command is:

```bash
/app/bin/codex_pooler start
```

Required production environment is limited to boot, release, topology, and
crypto values:

- `DATABASE_URL`, Ecto database URL
- `SECRET_KEY_BASE`, Phoenix signing and encryption secret
- `PHX_HOST`, public Phoenix host, defaults to `example.com` if unset
- `PHX_SERVER`, set to `true` for HTTP app pods
- `PORT`, HTTP port, defaults to `4000`
- `POOL_SIZE`, Ecto pool size, defaults to `10`
- `OBAN_MODE`, one of `web`, `worker`, `scheduler`, or `all`
- `OBAN_JOBS_QUEUE_LIMIT`, worker queue concurrency, defaults to `8`
- `ECTO_IPV6`, set to `true` or `1` to enable IPv6 socket options
- `DNS_CLUSTER_QUERY`, DNS cluster query used by `dns_cluster`
- `RELEASE_DISTRIBUTION`, set to `name` for Kubernetes DNS clustering
- `RELEASE_NODE`, unique BEAM node name for the pod
- `RELEASE_COOKIE`, shared Erlang distribution cookie for clustered release nodes, keep it in a secret store
- `ERL_AFLAGS`, optional Erlang VM flags; the Helm chart uses it to pin the distribution listen port when clustering is enabled
- `CODEX_POOLER_TOTP_ENCRYPTION_KEY`, TOTP secret encryption key
- `CODEX_POOLER_TOTP_KEY_VERSION`, TOTP key version, defaults to `v1`
- `CODEX_POOLER_UPSTREAM_SECRET_KEY`, upstream secret encryption key; must be 32 raw bytes or base64-encoded 32 bytes
- `CODEX_POOLER_UPSTREAM_SECRET_KEY_VERSION`, upstream secret key version, defaults to `v1`

Runtime controls are DB-managed Instance Settings. This includes file metadata
limits and cleanup, transcription upload limits, runtime ingress trust and
decompression limits, gateway debug, stream keepalives, upstream request
timeouts, model metadata, bridge leases, alias cleanup, route-class admission,
circuit thresholds, metrics auth, operator email base URL, and SMTP delivery.

Reloadability labels:

- live settings apply to new runtime work through the settings snapshot
- cached settings refresh after save through PubSub invalidation and cache reload
- existing bridge leases keep their stored expiry until renewed
- in-flight requests, already-open streams, and queued work keep the values they
  started with
- boot/release/topology/crypto env changes require a release restart

Secret handling:

- metrics auth stores only a keyed HMAC digest, safe fingerprint, and key version; the raw bearer value is one-time input and is not recoverable
- SMTP password stores encrypted ciphertext with key version metadata and is recovered only for mail send or test-email paths
- upstream account credentials continue to use encrypted upstream secret storage

`DNS_CLUSTER_QUERY` enables `DNSCluster` discovery, but it does not enable BEAM distribution by itself. Multi-replica Phoenix PubSub requires connected BEAM nodes with `RELEASE_DISTRIBUTION=name`, a unique `RELEASE_NODE` per pod, and the same secret `RELEASE_COOKIE` on every participating pod. Postgres stores durable data for sessions, logs, Oban, and accounting, but it does not distribute Phoenix PubSub messages between app replicas.

Realtime semantics for operators:

- Browser transport (`WebSocket` or `LongPoll`) describes how one admin browser reaches one Phoenix endpoint
- `LongPoll` is a supported degraded transport fallback, not a failure by itself
- Cross-replica LiveView/PubSub fanout requires BEAM clustering between pods; browser transport alone does not provide cross-node fanout
- Single-node local/dev operation works without clustering; realtime still works for events emitted in that running node
- In local/non-clustered multi-process workflows, cross-process invalidations are not guaranteed; use normal filter changes or refresh to pull latest persisted Postgres data

Generate a Phoenix secret with:

```bash
mix phx.gen.secret
```

## Migrations and releases

Normal application boot doesn't run migrations. Run release migrations explicitly:

```bash
bin/codex_pooler eval "CodexPooler.Release.migrate()"
```

The Helm chart renders a pre-install and pre-upgrade migration Job when `migrations.enabled=true`. That Job runs:

```bash
/app/bin/codex_pooler eval "CodexPooler.Release.migrate()"
```

Rollback support exists in the release module, but rolling back schema changes is a manual operator action that must target a specific repo and version.

## Oban modes

`OBAN_MODE` controls what each release process does:

- `web`, no queues and no Oban plugins. Use this for HTTP app pods
- `worker`, runs the `jobs` queue and no Oban plugins. Use this for worker pods
- `scheduler`, runs cron, Lifeline orphan rescue, and pruning plugins with no queues. Use this for scheduler pods
- `all`, runs both queues and the scheduler plugins. Use this for single-process deployments or local experiments

The production cron schedule currently enqueues account reconciliation every minute, token-refresh recovery every 15 minutes, catalog sync every 30 minutes, and daily rollup rebuild enqueue work at 00:17 UTC. Scheduled account reconciliation dedupes at upstream-identity level and selects one canonical active assignment per identity by `created_at, id`, so an identity shared across Pools does not create repeated scheduled jobs. Manual reconciliation, gateway-triggered refresh, account-link refresh, and assignment-activation priming remain assignment-specific. Scheduled and gateway reconciliation skip direct catalog sync work; the catalog scheduler owns recurring catalog sync. Successful gateway requests still enqueue a short-unique account reconciliation refresh so Codex quota headers and usage probes converge quickly without waiting for cron.
Successful upstream assignment edits on an active Pool also enqueue an immediate asynchronous Pool catalog sync with manual trigger semantics, so model source metadata can refresh without waiting for the next 30-minute catalog run. Runtime routing still applies eligibility checks, and in-flight requests or open streams keep the routing state they started with.

Scheduled token-refresh recovery is an auth-recovery path, not account reconciliation and not routing fallback. It runs every 15 minutes, selects `refresh_due` and cooled-down `refresh_failed` upstream identities that still have an active assignment in an active Pool, dedupes target refresh jobs by `upstream_identity_id`, skips fresh in-progress token-refresh metadata and incomplete target jobs, and enqueues metadata-only `TokenRefreshWorker` jobs. The ordinary `refresh_failed` cooldown remains 6 hours from sanitized token-refresh `finished_at` metadata or the identity row timestamp fallback.

Account reconciliation can enqueue immediate token-refresh recovery as a side effect after a retryable inline refresh failure. The reconciliation attempt still records quota/auth unavailability and can remain partial or discarded; the queued `TokenRefreshWorker` with `trigger_kind = account_reconciliation_recovery` is recovery work, not proof that reconciliation succeeded. Scheduled recovery, inline reconciliation recovery, and manual/admin refresh all leave terminal `reauth_required` rows to operator relink or reauth; they do not proactively refresh `active` identities, recover stale `refreshing` identities, retry terminal rows, or make token refresh globally enqueueable from the System Jobs card. Manual/admin refresh remains target-specific.

Worker retry and timeout policy is intentionally explicit. Minute-cadence account reconciliation jobs use one attempt because a failed refresh should be visible as failed work, not multiplied into a retry cascade. Catalog sync and rollup rebuild jobs are idempotent, lower-cadence maintenance work, so they retry a small number of times and rely on the next cron tick for continued recovery. Every worker defines `timeout/1` so a stuck upstream call, DB operation, or enqueue loop cannot inherit Oban's infinite execution default. Runtime cleanup also finalizes stale catalog sync and reconciliation markers so a hard timeout cannot leave operator state permanently `running` or `refreshing`.

## Helm deployment

Render the chart locally with:

```bash
helm template codex-pooler ./charts/codex-pooler
```

Default chart behavior:

- app deployment uses `OBAN_MODE=web`
- worker deployment uses `OBAN_MODE=worker`
- scheduler deployment uses `OBAN_MODE=scheduler`
- migration Job uses `OBAN_MODE=web` and runs the release migration command
- clustering is disabled by default; no `DNS_CLUSTER_QUERY`, `RELEASE_NODE`, `RELEASE_DISTRIBUTION`, `RELEASE_COOKIE`, headless cluster service, or distribution ports are rendered unless `clustering.enabled=true`
- owner-forwarding is disabled by default; `CODEX_POOLER_WEBSOCKET_OWNER_FORWARDING=true` is rendered only for app pods when `app.websocketContinuity.ownerForwarding.enabled=true`
- `app.websocketContinuity.ownerForwarding.enabled=true` requires `clustering.enabled=true` and `clustering.participants.app=true`
- with `app.replicaCount > 1`, the chart still requires `app.websocketContinuity.allowUnsafeMultiReplica=true` until owner-forwarding smoke evidence relaxes the staged guard
- app readiness probe calls `/readyz`
- app liveness probe calls `/healthz`
- secrets are referenced from `secrets.existingSecret` by default
- literal secret values are only rendered when `secrets.create=true` and values are supplied
- when clustering is enabled, app, worker, and scheduler pods participate by default through the shared `codex-pooler-cluster` headless service; migration jobs remain outside the BEAM cluster
- file storage, firewall, trusted proxy, decompression, media limit, bulkhead, circuit, metrics, operator email, model metadata, upstream timeout, and SMTP controls are DB-managed Instance Settings and are not rendered as chart env
- no upstream access token, Codex auth.json, bearer token, cookie, or raw API key is accepted as a chart value

Default secret keys expected by the chart:

- `database-url`
- `secret-key-base`
- `totp-encryption-key`
- `totp-key-version`
- `upstream-secret-key`
- `upstream-secret-key-version`

SMTP is configured in `/admin/system` after boot. Helm doesn't accept SMTP values or render SMTP password references. The password is encrypted with key version metadata and must not be written into chart values, docs, evidence, or tickets.

Clustering and owner-forwarding with an externally managed Erlang cookie secret:

```yaml
app:
  replicaCount: 2
  websocketContinuity:
    allowUnsafeMultiReplica: true
    ownerForwarding:
      enabled: true
clustering:
  enabled: true
  participants:
    app: true
  cookie:
    existingSecret: codex-pooler-cluster
    existingSecretKey: release-cookie
```

By default the chart derives `DNS_CLUSTER_QUERY` from the headless service FQDN, pins the Erlang distribution port to `9000`, exposes `4369` for EPMD, and renders pod-unique `RELEASE_NODE=codex_pooler@$(POD_IP)` values. The runtime DNSCluster resolver filters the current `POD_IP` out of discovered headless-service records so single-node deployments do not repeatedly try to connect to their own BEAM node. Keep the Erlang cookie identical for all participating app, worker, and scheduler pods. Use `clustering.participants.*` only when a role should intentionally stay outside PubSub/BEAM clustering. Websocket owner-forwarding specifically requires app pod participation, so worker or scheduler participation cannot replace `clustering.participants.app=true`. Remote owner target resolution also checks the connected node's `OBAN_MODE`; role-neutral worker or scheduler nodes are rejected before the owner-forwarding call is attempted.

See `RUNBOOK.md` for day-two operations, recovery, and incident procedures.
