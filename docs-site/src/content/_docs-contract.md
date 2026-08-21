# Public Docs Contract And Source Map

This private planning file is for docs authors. Keep it under an underscore-prefixed path so Starlight does not publish it as a public page.

## Audience And Scope

Write public docs for operators and client integrators who are setting up Codex Pooler. The public docs may explain setup, runtime surfaces, compatibility limits, and privacy boundaries. They must not become an operator runbook, incident log, internal architecture dump, or exhaustive Phoenix route listing.

Root static files in `docs-site/public`, such as `llms.txt`, `answers.md`, `pricing.md`, and `robots.txt`, are public docs too. Keep them short, extractable, public-safe, and consistent with the same route, credential, host, and privacy boundaries as the Starlight pages.

Use sentence case for H2 headings across public pages unless a proper noun or
fixed product name requires capitalization. Keep `llms.txt` as a deliberate
curated index: add a page only when it belongs in the declared primary or
discovery scope, then update its inventory check and matching review date.

## Allowed Hosts

Use only these hosts in public examples:

- `http://localhost:4000`, only for local setup and local smoke examples
- `https://codex-pooler.example.com`, for deployed product examples
- `https://docs.codex-pooler.com`, for the public docs site canonical URL

Do not use private hostnames, cluster names, pod names, tenant names, real account identifiers, raw OpenAI user subjects, real repository evidence paths, or private service URLs in public docs.

## Route Vocabulary

### `/backend-api`

Use `Codex backend compatibility route` for `/backend-api/codex/*`. This is an explicit authenticated Codex backend compatibility surface, not a wildcard proxy and not a general OpenAI SDK surface.

Allowed public claims:

- `GET /backend-api/codex/models` lists Codex backend models visible to the authenticated Pool
- `POST /backend-api/codex/responses` sends backend Responses requests through Pool routing and accounting
- `GET /backend-api/codex/responses` is backend websocket response-stream compatibility
- `POST /backend-api/codex/responses/compact` is backend compact compatibility
- `POST /backend-api/codex/images/generations` and `POST /backend-api/codex/images/edits` are explicit authenticated native image JSON proxy routes. On either exact route, any policy-authorized effective image model genuinely absent from the Pool catalog may use eligible visible host capacity while retaining its effective identifier. A catalog-present but invisible target remains invalid. This native behavior does not extend public `/v1` image support
- `/backend-api/codex/v1/*` routes are explicit backend aliases for clients that use `/backend-api/codex/v1` as a base URL
- `POST /backend-api/files` creates upstream-backed file metadata and returns an upstream upload URL
- `POST /backend-api/files/:file_id/uploaded` finalizes an upstream-backed file upload
- `POST /backend-api/transcribe` is backend audio transcription compatibility
- `GET /backend-api/wham/usage`, `GET /api/codex/usage`, and `GET /wham/usage` are usage routes

Do not describe Codex app-server helper routes as supported backend
compatibility. Codex Pooler is a model-provider runtime boundary, not an
account, analytics, thread-goal, memory, search, realtime, safety, identity, or
reset-credit proxy.

Pruned app-server helper candidates are not supported routes. Do not describe
their fixed HTML `404` as unconditional: ingress evaluates settings availability
and the runtime firewall first. An admitted or firewall-disabled request receives
the fixed `404`; a denial or unavailable settings state uses the corresponding
runtime ingress response instead.

### `/v1`

Use `OpenAI-compatible /v1 surface` only with the qualifier `narrow compatibility`. The `/v1` surface translates supported requests into Codex-compatible work, then sends them through the same Pool routing, limit checks, account selection, and accounting path. It is not full OpenAI API parity.

Allowed public claims:

- `GET /v1/models`
- `POST /v1/responses`
- `GET /v1/responses`, narrow Responses websocket compatibility only
- `POST /v1/chat/completions`
- `GET /v1/usage`
- `GET /v1/files`
- `POST /v1/files`
- `GET /v1/files/:file_id`
- `POST /v1/audio/transcriptions`
- `POST /v1/images/generations`
- `POST /v1/images/edits`

OpenAI Responses remote MCP tool definitions are unsupported request shapes inside `POST /v1/responses`, not unsupported routes. This includes top-level `tools[type=mcp]` and nested `input[type=additional_tools].tools[type=mcp]`.

Direct `POST /v1/responses` and narrow Responses websocket `response.create`
accept exact top-level custom definitions and nested custom definitions in an
already-valid namespace. `functions` is the canonical Codex namespace
example, not a namespace-name restriction: every nonblank valid namespace uses
the same child contract. A custom definition requires exact `type=custom` and a
nonblank name; optional fields are description, boolean `defer_loading`, nullable
`allowed_callers` limited to `direct` or `programmatic`, and omitted, text,
`lark`, or `regex` grammar format. Namespace children are exact flat `function`
or `custom` definitions. Hosted, MCP, tool-search, nested-namespace, malformed,
and globally colliding executable-name shapes are rejected before dispatch.

An exact typed custom `tool_choice` resolves only a declared same-kind, same-name
custom definition, including an accepted namespace child. Full mode preserves
that choice. Lite mode rejects every map-shaped `tool_choice` before upstream
dispatch with `unsupported_parameter` and `param: "tool_choice"`. Keep this
separate from accepted custom-tool replay input. Chat does not accept executable
custom definitions or choices. Provider execution availability remains selected
model and account dependent; smoke verification records metadata only. Never
claim backend, Chat, or broad OpenAI tool parity.

For those accepted namespace children, public Responses HTTP, SSE, and direct or
owner-forwarded websocket output restore a missing or null `custom_tool_call`
`namespace` only when its exact name maps to one declared namespace custom tool.
An explicit provider namespace is preserved; flat, unknown, and non-unique names
remain unchanged rather than guessed.

Responses `function_call_output` replay has two closed forms over direct HTTP and
the narrow Responses websocket surface. A paired item requires a nonblank
`call_id`; its existing `output` form and paired-only legacy `result` form are
unchanged. A named standalone item requires a nonblank `name` and an `output`
field, permits `call_id` only when omitted or `null`, and permits `namespace`
only when omitted, `null`, or a nonblank string. Blank or non-string values and
standalone `result` reject before dispatch. Classification and debug summaries
remain metadata-only; this narrow replay contract does not add general API
parity or prove provider-live acceptance.

Assistant replay `output_text` may carry only exact `url_citation` annotations:
the map keys are `type`, `start_index`, `end_index`, `url`, and `title`, with
`type=url_citation`. Accepted values preserve order, exact values, explicit empty
lists, and omission. Malformed or unsupported annotation maps reject before
dispatch; do not call this generic annotation passthrough.

Narrow `GET /v1/responses` websocket `response.create` alone accepts optional
`stream_id`: a 1 through 256 byte string matching `^[A-Za-z0-9_.-]+$`. A valid
accepted value is echoed only on attributable Open Responses server events, is
stripped before upstream dispatch, and remains transient socket-turn state. It
is excluded from request options, persistence, accounting, logs, telemetry, and
metadata. Same-ID creates are FIFO. Different IDs are accepted and echoed but
remain conservatively serialized per connection, so public docs must never claim
cross-ID concurrency or fairness. `previous_response_id` remains independent
conversation lineage. Do not extend this field to REST `POST /v1/responses`,
native backend WebSockets, Chat, compact, batches, or response-output storage.

Direct public Responses may repair only a missing nested object or array type in
strict flat-function parameters with a typed object root and complete,
unambiguous structural evidence. This applies to top-level flat functions and
namespace-child flat functions over HTTP and narrow Responses websocket turns.
Do not extend the claim to a missing root type, explicit type values, refs,
definitions, combinators, annotations, unknown keywords, ambiguous or
incomplete evidence, structured outputs, Chat, the older nested `function`
wrapper shape, or backend routes. Public Responses and Chat reject malformed,
duplicate, or unsupported explicit type vocabulary. Strict schemas remain
outside non-strict lowering.

`web_search.filters` accepts only `allowed_domains` and `blocked_domains`. Each
supplied field is a list of 1 through 100 nonblank strings without leading-
whitespace, case-insensitive HTTP(S) schemes; the two fields may coexist.
Accepted values preserve order, case, duplicates, and bytes.
`external_web_access` is optional. Public docs must describe this as local
validation and forwarding only, never as a guarantee of upstream web search
availability or domain-filter enforcement.

### Service-tier vocabulary

For new public client configuration, document `priority` as the canonical
`service_tier` spelling. Document `fast` only as an accepted equivalent request
spelling. Backend `/backend-api/codex` relay routes preserve provider bytes,
frames, and service-tier vocabulary unchanged. The narrow `/v1` surface
translates supported request and response shapes, while any projected provider
`service_tier` value retains its literal provider vocabulary.

Document `ultrafast` separately from the `fast` and `priority` alias. It is
accepted only by direct `/v1/responses` JSON, SSE, and Responses WebSocket
requests when selected model metadata advertises it. Returned `ultrafast`
remains literal. Direct `/v1/chat/completions` rejects it. Upstream providers
control availability, access, and price, so do not promise a model, entitlement,
or price.

Routed public `/v1` endpoints that must be described as deterministic unsupported behavior:

- `POST /v1/responses/compact`, deterministic unsupported compact route before gateway dispatch
- `GET /v1/files/:file_id/content`, deterministic unsupported content read after ownership checks
- `DELETE /v1/files/:file_id`, deterministic unsupported delete after ownership checks

Unsupported public `/v1` routes that may be named as unsupported:

- `POST /v1/images/variations`
- `POST /v1/content_provenance_checks`, deliberately routed to deterministic OpenAI-shaped `unsupported_endpoint`
- `POST /v1/embeddings`
- `POST /v1/batches`
- `POST /v1/moderations`
- `POST /v1/fine_tuning/jobs`
- `GET /v1/responses/:response_id`
- `POST /v1/responses/:response_id/cancel`
- `DELETE /v1/responses/:response_id`
- `/v1/realtime` and OpenAI Realtime SDK websocket or session routes

Public `POST /v1/responses` compaction triggers require visible input followed
by exactly one final `compaction_trigger`. When documenting Vercel AI SDK,
require `@ai-sdk/openai` 4.0.42 or later for
`providerOptions.openai.compactionTrigger` serialization and retain the normal
`/v1/responses` route claim. Direct `POST /v1/responses/compact` remains
unsupported. Public compact replay documents only `type`, opaque nonblank
`encrypted_content`, and optional absent, binary, or null `id`; identical
normalized terminal items are emitted for collected JSON, public SSE, and narrow
Responses websocket completion. Native metadata and unknown fields are not a
public contract. Invalid upstream compact output is a sanitized `502`. Websocket
trigger turns retain outer `proxy_websocket` admission and receive nested
`proxy_compact` admission before compact execution. Legacy backend compact
behavior remains unchanged.

### API Key Observatory

The Observatory is a separate read-only browser surface for a single eligible
Pool API key. It is not part of the instance-admin session and it is not a
runtime compatibility API.

Allowed public claims:

- `GET /observatory/login` renders the access-key form
- `POST /observatory/login` exchanges an eligible Pool API key for a dashboard browser session
- `DELETE /observatory/logout` ends the dashboard browser session
- authenticated `GET /observatory` serves the key-local Observatory LiveView
- Dashboard access is a separate per-key capability and does not grant `/admin/*` access
- Observatory values are bounded, sanitized usage metadata for the authenticated key only

Do not document raw credentials in URLs, query strings, cookies, screenshots, or
client-side storage. Do not describe the Observatory as exposing Pool-wide
analytics, other keys, prompts, payloads, or administration controls.

### `/mcp`

Use `operator MCP endpoint` for `/mcp`. It is a root metadata-only, read-only operator endpoint. It is not under `/backend-api` or `/v1`.

Allowed public claims:

- `POST /mcp` is the JSON-RPC Streamable HTTP endpoint
- `GET /mcp` is routed but stateless SSE is unavailable today
- `OPTIONS /mcp` returns the allowed MCP methods
- MCP uses operator-owned bearer MCP tokens
- MCP does not accept Pool API keys, browser sessions, cookies, query tokens, invite tokens, upstream tokens, or custom headers as authentication
- MCP output is metadata-only and scoped by the operator's owner or assigned-Pool visibility
- `/mcp` is not used to execute or proxy OpenAI Responses remote MCP tools

## Glossary

- `Pool`: A routing and policy boundary that groups upstream account assignments and exposes stable Pool API keys to runtime clients
- `upstream`: A Codex account identity or assignment that Codex Pooler can route eligible work to
- `Pool API key`: A bearer credential used by runtime clients for `/backend-api` and `/v1` requests. It represents a Pool, not one upstream account
- `MCP token`: An operator-owned bearer credential used only for `/mcp`. It is separate from Pool API keys and browser sessions
- `subject reference`: A sanitized fingerprint of an upstream OpenAI user subject. Public docs may describe this reference, but must never include raw subject values
- `backend API`: The Codex backend compatibility surface rooted at `/backend-api`, especially `/backend-api/codex/*`
- `/v1`: The narrow OpenAI-compatible SDK surface rooted at `/v1`. It is compatibility over Codex routing, not full OpenAI parity
- `metadata-only logging`: Request, route, accounting, audit, and MCP records may keep identifiers, route names, counts, statuses, timings, model names, safe error codes, and sanitized summaries. They must not store or show raw payloads or credentials

## Placeholder Rules

Use placeholders that are clearly fake and generic:

- Hosts: `http://localhost:4000`, `https://codex-pooler.example.com`, `https://docs.codex-pooler.com`
- Pool API key placeholder: `<pool-api-key>` or `sk-example-redacted`
- MCP token placeholder: `<operator-mcp-token>`
- Account labels: `example-upstream`, `example-operator`, `example-pool`
- Email-like examples: `operator@example.com`
- Model ids: use documented sample ids only when the surrounding page explains that the Pool must expose them

Never include raw tokens, raw prompts, request bodies, response bodies, file bodies, audio bodies, image bodies, cookies, `auth.json`, access tokens, refresh tokens, raw idempotency keys, raw upload URLs, internal evidence snippets, internal logs, private hostnames, callback URLs, real account ids, raw OpenAI user subjects, or real user identifiers.

If a docs example needs an Authorization header, write `Authorization: Bearer <pool-api-key>` for runtime routes or `Authorization: Bearer <operator-mcp-token>` for `/mcp`.

## Unsupported-Feature Language

Use precise unsupported language:

- Say `Codex Pooler provides narrow OpenAI-compatible /v1 support for selected SDK routes`
- Say `It does not provide full OpenAI API parity`
- Say `OpenAI Realtime SDK websocket and session routes are not supported`
- Say `GET /v1/responses is narrow Responses websocket compatibility, not /v1/realtime support`
- Say `Codex Pooler does not proxy Codex app-server realtime helper routes`
- Say `unsupported /v1 routes return deterministic OpenAI-shaped unsupported endpoint errors when explicitly routed`
- Say `OpenAI Responses remote MCP tool definitions are unsupported request shapes inside POST /v1/responses, not unsupported routes`

Do not write `OpenAI-compatible` without a nearby qualifier when the page could imply full parity.

## Privacy Boundaries

Public docs may describe the metadata-only model, but must not quote private evidence or logs. Keep examples synthetic.

Safe fields to mention:

- Route family and endpoint path
- HTTP method and status class
- Pool label or placeholder
- Upstream label or placeholder
- Sanitized upstream subject reference or fingerprint
- Model name
- Request-log id only when synthetic
- Error code, retry count, duration, token count, and timestamp examples

Forbidden fields and examples:

- Raw prompts and completions
- Request bodies, response bodies, multipart bodies, websocket frames, file bytes, audio bytes, image bytes, data URLs, and transcripts
- Bearer tokens, Pool API keys, MCP tokens, cookies, access tokens, refresh tokens, `auth.json`, TOTP secrets, SMTP secrets, signing secrets, and raw idempotency keys
- Internal incident procedures, cluster names, pod names, private hostnames, real account identifiers, raw OpenAI user subjects, raw emails, and private IP addresses

The generic provider-error rule remains fixed redaction: `upstream request
failed` and `server_error`, with no provider body, parameter, or siblings. The
only public exception is an eligible direct `400` or `403`, or exact terminal
SSE or websocket failure, with code `misalignment_policy_violation`. It is
health-neutral and non-retryable. Public output may expose the exact code,
`invalid_request_error`, and a nonblank provider message or fixed safe fallback,
but never a provider parameter, body, or siblings. Durable records may retain
only the exact code, fixed accounting text, and bounded facts.

## Runtime ingress firewall contract

Public configuration may describe the runtime firewall only as an ingress policy
for runtime API families and `/mcp`. It may say that an empty allowlist disables
the policy, forwarded-client configuration has exactly `peer`,
`x_forwarded_for`, and `x_real_ip` sources, and the defaults are
`forwarded_client_ip_source = x_forwarded_for` with `forwarded_proxy_depth = 0`.
It must not describe an implicit, mixed, or fallback source selection.

Every forwarded source requires a trusted directly connected peer before its
header is used. `peer` accepts depth `0` and ignores forwarding headers.
`x_real_ip` accepts depth `0`, ignores XFF, and requires one X-Real-IP field.
`x_forwarded_for` at depth `0` uses the bounded trusted-CIDR walk. At depth
`1..16`, the documented position is the numbered XFF entry from the right after
duplicate field occurrences are combined in wire order. The directly connected
peer counts toward configured proxy depth, but is not an XFF entry.

Public docs may describe strict IPv4/IPv6 and CIDR parsing, the cold settings
`503` response, websocket revocation after a locally applied firewall update,
and `codex_pooler_ingress_firewall_denied_count` with only `scope` and `reason`
labels. Do not publish raw forwarded header values, client addresses, internal
recovery steps, or unbounded reason data.

The machine-readable denial reasons for those two operational outcomes are
`settings_unavailable` and `websocket_revoked`. They are bounded diagnostic
terms, not client-address or forwarding-header data.

The source map for this claim is
`lib/codex_pooler_web/plugs/runtime_ingress/forwarded_client_ip.ex`,
`lib/codex_pooler_web/plugs/runtime_ingress/firewall.ex`,
`lib/codex_pooler/gateway/operational_settings/ip_rules.ex`,
`test/codex_pooler_web/plugs/runtime_ingress/forwarded_client_ip_test.exs`, and
`test/codex_pooler_web/controllers/runtime/backend_codex_websocket_test.exs`.

## Metrics and operator-session boundaries

`/metrics` is outside the runtime firewall. Public operator docs may describe
only its three states: **open** when no metrics bearer is configured,
**bearer-protected** when one is configured, and **unavailable** when settings
cannot be read and the endpoint fails closed. Do not imply that the runtime
firewall protects metrics.

The System page may be described as showing only the signed-in operator's
current active, unexpired browser-session IP. It is not a session inventory and
must not expose other-session provenance.

## Source Map For Public Route Claims

Use these tracked sources as the source of truth for public route claims. Do not promote claims from ignored root `docs/` material or internal runbooks unless the claim is also present in a tracked source below.

| Public claim area | Tracked sources | Public-safe claim |
| --- | --- | --- |
| Root route split | `lib/codex_pooler_web/router.ex`, `test/codex_pooler_web/route_surface_test.exs` | `/backend-api`, `/v1`, `/mcp`, browser auth, admin LiveViews, usage, health, and metrics are separate route families |
| Runtime ingress firewall and limits | `lib/codex_pooler_web/plugs/runtime_ingress.ex`, `lib/codex_pooler_web/plugs/runtime_ingress/path.ex`, `lib/codex_pooler_web/plugs/runtime_ingress/forwarded_client_ip.ex`, `lib/codex_pooler_web/plugs/runtime_ingress/firewall.ex`, `test/codex_pooler_web/plugs/runtime_ingress_test.exs`, `test/codex_pooler_web/plugs/runtime_ingress/path_test.exs`, `test/codex_pooler_web/plugs/runtime_ingress/forwarded_client_ip_test.exs` | Runtime and MCP ingress use one decoded path view, one settings snapshot, and one bounded client-IP resolution. Trusted forwarding is right-to-left and fail-closed for malformed or over-bound runtime/MCP input; non-runtime routes retain the peer. Compressed JSON and the four exact image actions are guarded before body parsing. |
| Metrics and current-session status | `lib/codex_pooler_web/controllers/operations/metrics_controller.ex`, `lib/codex_pooler_web/live/admin/components/pages/system/page_components/metrics.ex`, `lib/codex_pooler_web/live/admin/pages/system_live.ex`, `test/codex_pooler_web/live/admin/pages/system_live_test.exs` | `/metrics` has separate open, bearer-protected, and unavailable fail-closed states outside the runtime firewall. The System page shows only the signed-in operator's current active, unexpired browser-session IP. |
| Pruned app-server helper candidates | `lib/codex_pooler_web/plugs/runtime_ingress/path.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/plugs/runtime_ingress_test.exs` | Pruned helper candidates remain unsupported and preserve their fixed `404` only after settings and firewall admission; they never authenticate, parse a body, dispatch upstream work, reserve capacity, or create accounting. |
| Backend Codex routes | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `/backend-api/codex/*` is explicit authenticated Codex backend compatibility, not wildcard proxy |
| Native backend image routes | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs` | Exact native image generation and edit routes may route any policy-authorized effective image model that is genuinely absent from the Pool catalog through eligible visible host capacity while preserving that effective identifier. Catalog-present invisible targets remain invalid, and this does not change public `/v1` image translation |
| Backend file bridge | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `/backend-api/files` stores metadata only and returns upstream upload or download URLs. Bytes are not stored locally |
| OpenAI-compatible `/v1` supported routes | `lib/codex_pooler_web/router.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/normalization.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/validation.ex`, `lib/codex_pooler/gateway/payloads/compaction_trigger.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/route_surface_test.exs`, `test/codex_pooler_web/controllers/responses_terminal_compatibility_test.exs`, `test/codex_pooler_web/controllers/v1/route_auth_test.exs`, `test/codex_pooler_web/controllers/v1/responses_controller_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_programmatic_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_bridge_terminal_test.exs`, `test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `/v1` is narrow authenticated compatibility, not full OpenAI parity. `POST /v1/responses` and narrow Responses websocket turns accept exactly one final `compaction_trigger` after visible input and bridge it through compact accounting to the ordinary backend Responses upstream endpoint; malformed placement rejects before dispatch, and direct `POST /v1/responses/compact` remains unsupported. OpenAI-compatible HTTP SSE synthesizes route-specific terminals when a visible stream ends without an upstream terminal: `POST /v1/responses` emits a sequence-valid sanitized `type: "error"` event, while `POST /v1/chat/completions` and its translated backend alias emit one nested `data: {"error":{...}}` chunk with no top-level `type` or following `[DONE]`. Public SSE treats absent, blank, and whitespace-only event labels identically while rejecting nonblank event/data mismatches. Ordinary incomplete public Responses SSE blocks are capped at 8 MiB so single large provider events can finish decoding; structurally recognizable terminal candidates may retain up to 64 MiB so split large terminals can finish decoding. Crossing the applicable cap emits one bounded sanitized error and relays no source bytes. Direct and accepted owner-forwarded public Responses websockets drop malformed JSON and JSON non-object provider frames without advancing sequence state. Native backend raw Responses streams and websocket surfaces do not synthesize these terminals. Public POST SSE and GET websocket normalize successful `response.done` or legacy typeless terminals to `response.completed`, while backend raw GET/POST surfaces preserve them. Both `POST /v1/responses` and `POST /v1/chat/completions` accept WAV, MP3, M4A, WebM, and OGG input audio with bounded decoded input |
| Hosted-shell Responses history replay | `lib/codex_pooler/gateway/openai_compatibility/responses/input/hosted_shell.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/normalization.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/validation.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler/compatibility_matrix_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `/v1/responses` and narrow Responses websocket turns accept only the documented closed-key `shell_call` and `shell_call_output` history subset. This is replay/relay compatibility: it does not execute commands, accept shell tool declarations, accept local-shell or remote MCP history, accumulate command indexes, enforce call/output pairing or ordering, or claim broad hosted-tool parity. The five hosted-shell stream event types preserve the existing public sequence and websocket stream-id adaptations only; command and output data stay transient and metadata-only |
| Catalog revision and Responses envelope | `lib/codex_pooler/gateway/metadata/codex_catalog.ex`, `lib/codex_pooler/gateway/payloads/payload_normalizer.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler/compatibility_matrix_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Backend model aliases share a deterministic policy-visible weak ETag from one selected canonical partition. Backend Codex catalog-driven turns use that selected partition, while translated OpenAI Responses capacity includes all valid canonical assignments after concrete request compatibility. Successful backend Responses streams expose the token in backend-only headers; final non-compact backend envelopes cover canonical, alias, and translated public Responses destinations while compact stays excluded; failed-attempt parameter detail is bounded and sanitized |
| OpenAI Responses request-shape rejections | `lib/codex_pooler/gateway/openai_compatibility/responses.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler/gateway/openai_compatibility/core_test.exs`, `test/codex_pooler_web/controllers/v1/responses_controller_test.exs`, `test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs` | OpenAI Responses remote MCP tool definitions are rejected before upstream dispatch in both top-level `tools` and nested `additional_tools.tools` locations |
| OpenAI Responses custom tools and strict repair | `lib/codex_pooler/gateway/openai_compatibility/responses.ex`, `lib/codex_pooler/gateway/openai_compatibility/chat.ex`, `lib/codex_pooler/gateway/payloads/strict_schema.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler/gateway/openai_compatibility/core_test.exs`, `test/codex_pooler/gateway/payloads/strict_schema_repair_test.exs`, `test/codex_pooler_web/controllers/v1/responses_controller_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_programmatic_test.exs`, `test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Direct public Responses HTTP and narrow websocket turns accept exact custom definitions top-level or in any already-valid nonblank namespace; `functions` is the canonical example, not a restriction. Full resolves exact same-kind custom choices from either location, while Lite rejects map-shaped choices before dispatch. Hosted, MCP, tool-search, nested-namespace, malformed, and global executable-name collision shapes remain excluded. Separately, strict flat-function parameters may receive only structurally proven missing nested object or array types. Chat custom tools and strict repair, structured-output repair, root repair, refs/definitions/combinators, backend routes, and broad OpenAI tool parity remain excluded |
| Pool-model serving modes (Auto, Lite, Full) | `lib/codex_pooler/pools/model_serving_mode.ex`, `lib/codex_pooler/pools/model_serving_modes.ex`, `lib/codex_pooler/pools/model_serving_override.ex`, `lib/codex_pooler/gateway/payloads/payload_normalizer.ex`, `lib/codex_pooler/gateway/payloads/request_options/routing.ex`, `lib/codex_pooler/gateway/transports/upstream_dispatch.ex`, `lib/codex_pooler/gateway/metadata/canonical_model_source.ex`, `lib/codex_pooler/gateway/routing/model_metadata.ex`, `lib/codex_pooler/gateway/runtime/finalization/metadata.ex`, `lib/codex_pooler/accounting/metadata.ex`, `test/codex_pooler/pools/model_serving_mode_test.exs`, `test/codex_pooler/pools/model_serving_modes_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_test.exs` | A serving mode belongs to one Pool and one canonical exposed model id and never changes the route, model id, credentials, response shape, transport choice, routing eligibility, context window, or accounting. Auto selects Lite only on a literal `true` from a routable catalog source, otherwise Full; explicit `lite`/`full` record source `override`. Lite rewrites the outgoing valid request: top-level `tools` and `instructions` move into leading `additional_tools` and developer message `input` items, `parallel_tool_calls` becomes `false`, `reasoning.context` becomes `all_turns`, `input_image` `detail` is dropped, and Codex Pooler owns the Lite marker (HTTP header, or the websocket `client_metadata` key) in both directions. The rewrite is idempotent. On native non-compact backend Responses routes, both modes reject a present non-list `input` or `tools` before dispatch with `invalid_request`; narrow `/v1` string input is normalized before serving-mode handling. Lite rejects map-shaped `tool_choice` before dispatch with `unsupported_parameter`. `GET /backend-api/codex/models` reports `use_responses_lite` as the effective mode; `GET /v1/models` carries no serving-mode field. The mode is an immutable per-request or per-`response.create`-turn snapshot |
| OpenAI Responses web-search domain filters | `lib/codex_pooler/gateway/openai_compatibility/responses.ex`, `test/codex_pooler/gateway/openai_compatibility/core_test.exs` | `web_search.filters` accepts only optional `allowed_domains` and `blocked_domains` lists, each bounded to 1 through 100 nonblank strings without leading-whitespace, case-insensitive HTTP(S) schemes. Both lists may coexist and accepted values are forwarded unchanged. `external_web_access` is optional. This is local validation and forwarding, not an upstream availability or enforcement guarantee |
| Unsupported `/v1` routes | `lib/codex_pooler_web/controllers/v1/unsupported_routes.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/v1/route_auth_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Explicit unsupported `/v1` routes return deterministic OpenAI-shaped unsupported endpoint errors before gateway dispatch |
| Exact policy-error exception | `lib/codex_pooler/gateway/transports/misalignment_policy_violation.ex`, `lib/codex_pooler/gateway/openai_compatibility/public_response.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/misalignment_policy_violation_http_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Only eligible direct `400` or `403`, and exact terminal SSE or websocket, `misalignment_policy_violation` errors are health-neutral and non-retryable. Public output keeps the exact code, `invalid_request_error`, and a nonblank message or fixed safe fallback, while parameters, bodies, and siblings remain excluded. Durable records keep the exact code, fixed accounting text, and bounded facts. Generic provider errors remain redacted |
| Realtime exclusion | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/route_surface_test.exs`, `test/codex_pooler_web/controllers/v1/route_auth_test.exs` | `/v1/realtime` and OpenAI Realtime SDK websocket or session routes are not supported |
| MCP endpoint | `lib/codex_pooler_web/router.ex`, `test/codex_pooler_web/route_surface_test.exs`, `test/codex_pooler_web/controllers/mcp_contract_test.exs`, `test/codex_pooler_web/controllers/mcp_controller_test.exs` | `/mcp` is a root metadata-only, read-only operator endpoint using operator MCP bearer tokens, not Pool API keys or browser sessions |
| API Key Observatory | `lib/codex_pooler_web/router.ex`, `lib/codex_pooler_web/controllers/observatory/login_controller.ex`, `lib/codex_pooler_web/plugs/observatory_auth.ex`, `lib/codex_pooler_web/observatory_auth.ex`, `lib/codex_pooler/access/dashboard_sessions.ex`, `lib/codex_pooler/accounting/usage/observatory.ex`, `test/codex_pooler_web/route_surface_test.exs`, `test/codex_pooler_web/controllers/browser/observatory_login_controller_test.exs`, `test/codex_pooler/access/api_key_dashboard_sessions_test.exs`, `test/codex_pooler/accounting/observatory_contract_test.exs`, `test/codex_pooler_web/live/observatory_live_test.exs` | `/observatory` is a separate key-local read-only browser surface using an eligible Pool API key, a dedicated opaque dashboard token, and a minimal signed LiveView handoff; it does not grant runtime or `/admin/*` authority and exposes only bounded sanitized usage metadata |
| Upstream identity linking | `lib/codex_pooler/upstreams/lifecycle/identity_lifecycle.ex`, `lib/codex_pooler/upstreams/token_linking.ex`, `lib/codex_pooler/upstreams/auth/codex_auth.ex`, `lib/codex_pooler/upstreams/auth/codex_auth_json.ex`, `lib/codex_pooler_web/live/admin/read_models/upstream_accounts_read_model.ex`, `lib/codex_pooler_web/live/admin/read_models/upstream_cockpit_read_model.ex`, `test/codex_pooler/upstreams/oauth_browser_linking_test.exs`, `test/codex_pooler/upstreams/oauth_device_linking_test.exs`, `test/codex_pooler/upstreams/oauth_relink_test.exs`, `test/codex_pooler/upstreams_test.exs`, `test/codex_pooler_web/live/admin/pages/upstreams_live_test.exs`, `test/codex_pooler_web/live/admin/pages/upstream_cockpit_live_test.exs` | OAuth links, relinks, and auth.json imports can use an OpenAI user subject, when returned, to separate same-account and same-workspace upstream credentials. Public docs may mention only sanitized subject references or fingerprints, never raw subjects |
| Privacy and redaction | `README.md`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs`, `test/codex_pooler_web/controllers/mcp_contract_test.exs`, `test/codex_pooler_web/controllers/mcp_controller_test.exs` | Public docs must keep prompts, bodies, bearer tokens, cookies, `auth.json`, upstream secrets, and private identifiers out of examples and evidence |

## Author Checklist

Before publishing or editing a public page:

1. Check every route claim against the source map above
2. Use only allowed hosts and placeholders
3. Include narrow `/v1` compatibility language when mentioning OpenAI SDKs
4. Keep Codex app-server helper routes outside the supported runtime surface
5. Keep `/mcp` token language separate from Pool API key language
6. Remove raw payloads, secrets, callback URLs, raw OpenAI user subjects, private hosts, and internal evidence from examples
7. If the route claim isn't in the tracked sources above, don't publish it yet
