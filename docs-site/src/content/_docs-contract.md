# Public Docs Contract And Source Map

This private planning file is for docs authors. Keep it under an underscore-prefixed path so Starlight does not publish it as a public page.

## Audience And Scope

Write public docs for operators and client integrators who are setting up Codex Pooler. The public docs may explain setup, runtime surfaces, compatibility limits, and privacy boundaries. They must not become an operator runbook, incident log, internal architecture dump, or exhaustive Phoenix route listing.

Root static files in `docs-site/public`, such as `llms.txt`, `answers.md`, `pricing.md`, and `robots.txt`, are public docs too. Keep them short, extractable, public-safe, and consistent with the same route, credential, host, and privacy boundaries as the Starlight pages.

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

Routed public `/v1` endpoints that must be described as deterministic unsupported behavior:

- `POST /v1/responses/compact`, deterministic unsupported compact route before gateway dispatch
- `GET /v1/files/:file_id/content`, deterministic unsupported content read after ownership checks
- `DELETE /v1/files/:file_id`, deterministic unsupported delete after ownership checks

Unsupported public `/v1` routes that may be named as unsupported:

- `POST /v1/images/variations`
- `POST /v1/embeddings`
- `POST /v1/batches`
- `POST /v1/moderations`
- `POST /v1/fine_tuning/jobs`
- `GET /v1/responses/:response_id`
- `POST /v1/responses/:response_id/cancel`
- `DELETE /v1/responses/:response_id`
- `/v1/realtime` and OpenAI Realtime SDK websocket or session routes

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

## Source Map For Public Route Claims

Use these tracked sources as the source of truth for public route claims. Do not promote claims from ignored root `docs/` material or internal runbooks unless the claim is also present in a tracked source below.

| Public claim area | Tracked sources | Public-safe claim |
| --- | --- | --- |
| Root route split | `lib/codex_pooler_web/router.ex`, `test/codex_pooler_web/route_surface_test.exs` | `/backend-api`, `/v1`, `/mcp`, browser auth, admin LiveViews, usage, health, and metrics are separate route families |
| Backend Codex routes | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `/backend-api/codex/*` is explicit authenticated Codex backend compatibility, not wildcard proxy |
| Native backend image routes | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs` | Exact native image generation and edit routes may route any policy-authorized effective image model that is genuinely absent from the Pool catalog through eligible visible host capacity while preserving that effective identifier. Catalog-present invisible targets remain invalid, and this does not change public `/v1` image translation |
| Backend file bridge | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `/backend-api/files` stores metadata only and returns upstream upload or download URLs. Bytes are not stored locally |
| OpenAI-compatible `/v1` supported routes | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/route_surface_test.exs`, `test/codex_pooler_web/controllers/responses_terminal_compatibility_test.exs`, `test/codex_pooler_web/controllers/v1/route_auth_test.exs`, `test/codex_pooler_web/controllers/v1/responses_controller_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_bridge_terminal_test.exs`, `test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `/v1` is narrow authenticated compatibility, not full OpenAI parity. `GET /v1/responses` is narrow Responses websocket compatibility only. Public POST SSE alone synthesizes a sequence-valid sanitized `response.failed` when upstream ends without a terminal; public GET websocket keeps its error/close behavior. Public POST SSE and GET websocket normalize successful `response.done` or legacy typeless terminals to `response.completed`, while backend raw GET/POST surfaces preserve them. Both `POST /v1/responses` and `POST /v1/chat/completions` accept WAV, MP3, M4A, WebM, and OGG input audio with bounded decoded input |
| Catalog revision and Responses envelope | `lib/codex_pooler/gateway/metadata/codex_catalog.ex`, `lib/codex_pooler/gateway/payloads/payload_normalizer.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler/compatibility_matrix_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Backend model aliases share a deterministic policy-visible weak ETag; successful backend Responses streams expose that token in backend-only headers; final non-compact backend envelopes cover canonical, alias, and translated public Responses destinations while compact stays excluded; failed-attempt parameter detail is bounded and sanitized |
| OpenAI Responses request-shape rejections | `lib/codex_pooler/gateway/openai_compatibility/responses.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler/gateway/openai_compatibility/core_test.exs`, `test/codex_pooler_web/controllers/v1/responses_controller_test.exs`, `test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs` | OpenAI Responses remote MCP tool definitions are rejected before upstream dispatch in both top-level `tools` and nested `additional_tools.tools` locations |
| Unsupported `/v1` routes | `lib/codex_pooler_web/controllers/v1/unsupported_routes.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/v1/route_auth_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Explicit unsupported `/v1` routes return deterministic OpenAI-shaped unsupported endpoint errors before gateway dispatch |
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
