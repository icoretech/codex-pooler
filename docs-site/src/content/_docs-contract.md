# Public Docs Contract And Source Map

This underscore-prefixed authoring contract is removed from the built site. It still follows the repository's public-source rules and names private implementation roles only, never their identifiers.

## Audience And Scope

Public docs serve operators and client integrators deploying the immutable `gemma3` façade. They may explain setup, exact route support, Pool API-key authentication, protocol behavior, compatibility limits, privacy, and the separation between public identity and operator diagnostics.

Root files in `docs-site/public`, the repository README, examples, screenshots, and generated search/answer assets are public too. They must follow this contract.

Use sentence case for H2 headings across public pages unless a proper noun or
fixed product name requires capitalization. Keep `llms.txt` as a deliberate
curated index: add a page only when it belongs in the declared primary or
discovery scope, then update its inventory check and matching review date.

## Immutable Façade Contract

The public and private implementation roles are:

- public model: `gemma3`
- private reasoning target: a server-owned fixed target
- private reasoning effort: `max`
- fixed transcription helper: a non-selectable server helper
- fixed image helper: a non-selectable server helper

Public client-facing material may advertise or configure only `gemma3`. It must not name the private reasoning target, helper identifiers, provider, upstream account, assignment, or private endpoint. It may state that reasoning uses a server-owned fixed target at `max` and that dedicated media endpoints use non-selectable server helpers.

Every reasoning protocol normalizes documented client selectors before model/policy validation. A missing, public, or arbitrary client model cannot select a target. Client effort, reasoning, thinking-budget, or alias values cannot lower or replace the fixed policy. If the fixed target is not policy-authorized and routable, discovery is empty and inference fails closed; there is no model fallback.

Model identity projection is structural. Public docs must not claim arbitrary generated prose is rewritten. User/assistant text, filenames, and tool arguments remain application content.

## Allowed Hosts And Credentials

Use only:

- `http://localhost:4000` for local examples
- `https://codex-pooler.example.com` for deployed examples
- `https://docs.codex-pooler.com` for docs links

Use `<pool-api-key>` for runtime credentials and `<operator-mcp-token>` for MCP. Never publish real hosts, keys, tokens, cookies, callback URLs, account identifiers, subjects, assignments, raw request IDs, or private infrastructure names.

A Pool API key represents a Pool and authenticates supported `/api`, `/v1`, and `/backend-api` runtime routes. Anthropic routes accept `x-api-key` or bearer auth; if both are supplied, they must agree. All other façade routes use bearer auth. Upstream credentials are never client credentials.

The one runtime-auth exception is the single-purpose local file-capability URL returned by authenticated backend file create/finalize. `PUT` or `GET /file-capabilities/:capability` may be used without an Authorization header because signed-URL clients do not reliably preserve Pool headers. The opaque capability is itself a short-lived bearer credential bound to the active Pool, API key, owned file, operation, assignment, identity, declared bytes, and expiry. Any Authorization header that is supplied must authenticate the same Pool/API-key scope. The proxy rechecks current Pool, key, assignment, identity, and credential usability, resolves every provider A/AAAA address as public, connects to a validated pinned address while retaining the original TLS hostname, disables redirects, bounds bytes, and never exposes the provider URL. Capability paths and values must never be logged.

The root `/mcp` endpoint accepts only an operator-owned MCP bearer token. Do not imply Pool API keys or upstream credentials work there.

## Route Vocabulary

Use `Ollama-compatible façade` for `/api/*`, `Anthropic Messages adapter` for `/v1/messages*`, `OpenAI-compatible façade` for the remaining documented `/v1/*` routes, and `Codex backend compatibility` for `/backend-api/codex/*`.

Do not call any family a wildcard proxy or claim full Ollama, Anthropic, OpenAI, or Codex app-server parity. Prefer `bounded compatibility` to the obsolete generic phrase `narrow /v1 support`.

### Ollama-compatible façade

Supported:

- `POST /api/chat`
- `POST /api/generate`
- `GET /api/tags`
- `POST /api/show`
- `GET /api/ps`
- `GET /api/version`
- `POST /api/pull`, immutable no-op only for `gemma3` and `gemma3:latest`

Routed but unsupported:

- `POST /api/create`
- `POST /api/copy`
- `POST /api/push`
- `DELETE /api/delete`
- `GET`, `HEAD`, and `POST /api/blobs/:digest`
- `POST /api/embed`
- `POST /api/embeddings`

Do not claim local weights, downloads, a blob store, local inference, or embeddings. Discovery returns one `gemma3` model only when the fixed target is available.

### Anthropic Messages adapter

Supported:

- `POST /v1/messages`
- `POST /v1/messages/count_tokens`, bounded local estimate with no dispatch

Require `anthropic-version: 2023-06-01`. All other Anthropic API families are absent. Do not claim Claude model parity; Claude Code remains the local agent runtime and uses translated Messages traffic.

### OpenAI-compatible façade

Supported inference, catalog, and usage routes:

- `GET /v1/models`
- `GET /v1/models/gemma3`
- `POST /v1/responses`
- `GET /v1/responses`, bounded Responses websocket only
- `POST /v1/chat/completions`
- `POST /v1/completions`
- `GET /v1/usage`

Supported file/media routes:

- `GET /v1/files`
- `POST /v1/files`
- `GET /v1/files/:file_id`
- `POST /v1/audio/transcriptions`
- `POST /v1/images/generations`
- `POST /v1/images/edits`

Deterministic unsupported routes:

- `POST /v1/responses/compact`
- `GET /v1/files/:file_id/content`, after ownership checks
- `DELETE /v1/files/:file_id`, after ownership checks
- `POST /v1/images/variations`
- `POST /v1/content_provenance_checks`
- `POST /v1/embeddings`
- `POST /v1/batches`
- `POST /v1/moderations`
- `POST /v1/fine_tuning/jobs`
- `GET /v1/responses/:response_id`
- `POST /v1/responses/:response_id/cancel`
- `DELETE /v1/responses/:response_id`

`/v1/realtime` is absent. `GET /v1/responses` is not OpenAI Realtime. OpenAI remote MCP definitions are unsupported request shapes inside Responses and are not routed to `/mcp`.

### Codex backend compatibility

Supported:

- `GET /backend-api/codex/models`
- `GET /backend-api/codex/v1/models`
- `POST` and `GET /backend-api/codex/responses`
- `POST` and `GET /backend-api/codex/v1/responses`
- `POST /backend-api/codex/responses/compact`
- `POST /backend-api/codex/v1/responses/compact`
- `POST /backend-api/codex/v1/chat/completions`
- `POST /backend-api/codex/images/generations`
- `POST /backend-api/codex/images/edits`
- `POST /backend-api/files`
- `POST /backend-api/files/:file_id/uploaded`
- `PUT /file-capabilities/:capability`, single-purpose upload bearer returned by file create
- `GET /file-capabilities/:capability`, single-purpose download bearer returned by file finalize
- `POST /backend-api/transcribe`
- `GET /backend-api/wham/usage`
- `GET /api/codex/usage`
- `GET /wham/usage`

Do not document account, identity, analytics, thread/goal, memory, general search, realtime, or other app-server helpers as compatibility routes.

## Cache, Continuity, Retry, And Error Claims

Allowed cache claims:

- Codex Pooler does not cache completed responses for replay.
- OpenAI prompt-cache keys, translated Anthropic cache controls, and Ollama session IDs are converted into Pool/API-key-scoped one-way values before routing or dispatch.
- Raw façade cache/session values are not persisted or forwarded.
- Locality is a heuristic, not a provider cache-hit or cached-token guarantee.
- Existing Codex and opaque response/item continuity follow their bounded established paths.

Allowed stream/retry claims:

- retry can change assignments only before visible output
- after visible output, the request is never replayed
- translated streams emit at most one protocol-safe terminal failure
- incomplete frames and assembled tool arguments are bounded and never partially leaked
- JSON, NDJSON, SSE, and websocket protocols remain distinct and are not byte/token equivalent

Allowed error/header claims:

- public errors use the active protocol's shape and fixed safe server messages
- private model/provider/account/assignment/request identifiers and unsafe upstream messages are removed
- response headers use exact local allowlists; provider diagnostic and rate-limit headers are not relayed

## Operator Diagnostics And Privacy

Public clients see only `gemma3`. Authorized operator surfaces may truthfully retain metadata needed to route, reconcile, and diagnose real work: private target/helper identity, assignment, route, applied effort, attempt/retry outcome, status, safe error code, timing, quota, token counts, cache/compression summaries, and synthetic/local request references.

Do not retain or document raw prompts, completions, tool payloads, request/response bodies, file/audio/image bytes, websocket frames, raw provider payloads, Pool keys, upstream credentials, cookies, authorization codes, callback URLs, or raw façade affinity values.

This is `metadata-only logging`: bounded operational facts without content or credentials.

## Runtime ingress firewall contract

Public configuration may describe the runtime firewall only as an ingress policy
for runtime API families and `/mcp`. An empty allowlist disables the policy.
Forwarded-client configuration has exactly `peer`, `x_forwarded_for`, and
`x_real_ip` sources. The defaults are
`forwarded_client_ip_source = x_forwarded_for` and
`forwarded_proxy_depth = 0`; there is no mixed or fallback source selection.

Every forwarded source requires a trusted directly connected peer before its
header is used. `peer` accepts depth `0` and ignores forwarding headers.
`x_real_ip` accepts depth `0`, ignores XFF, and requires exactly one X-Real-IP
field. `x_forwarded_for` at depth `0` uses the bounded trusted-CIDR walk. At
depth `1..16`, select the numbered XFF entry from the right after duplicate XFF
field occurrences are combined in wire order. The directly connected peer
counts toward configured proxy depth, but is not an XFF entry.

Public docs may describe strict IP/CIDR parsing, a `503` when settings are
unavailable on cold start, websocket revocation after a locally applied
firewall update, and `codex_pooler_ingress_firewall_denied_count` with only
`scope` and `reason` labels. The bounded machine-readable denial reasons are
`settings_unavailable` and `websocket_revoked`. Do not publish raw forwarded
headers, client addresses, internal recovery steps, or unbounded reason data.

The source map is
`lib/codex_pooler_web/plugs/runtime_ingress/forwarded_client_ip.ex`,
`lib/codex_pooler_web/plugs/runtime_ingress/firewall.ex`,
`lib/codex_pooler/gateway/operational_settings/ip_rules.ex`,
`test/codex_pooler_web/plugs/runtime_ingress/forwarded_client_ip_test.exs`, and
`test/codex_pooler_web/controllers/runtime/backend_codex_websocket_test.exs`.

`/metrics` is outside the runtime firewall. It is open when no metrics bearer
is configured, bearer-protected when one is configured, and unavailable when
settings cannot be read. Do not imply the runtime firewall protects metrics.

## Compatibility Language

Public docs must say:

- `gemma3` is the only public model
- model and reasoning selection are server-owned
- adapters provide bounded protocol compatibility
- Codex CLI and Claude Code keep their own local agent runtimes
- protocol translation is not token-for-token equivalence
- arbitrary generated prose is not blindly rewritten
- unsupported routes fail explicitly instead of being guessed

Public docs must not claim:

- the façade is a local Ollama daemon
- it exposes a Claude model or full Anthropic API
- it is a full OpenAI API clone
- it proxies the complete Codex app server
- cache hits, uninterrupted sessions, or direct-service physical equivalence are guaranteed
- every operation uses the reasoning target when a dedicated media endpoint requires a fixed helper

## Source Map

| Claim | Tracked source |
| --- | --- |
| Fixed public/private identity and effort | `lib/codex_pooler/gateway/facade.ex`, `lib/codex_pooler/gateway/payloads/request_options.ex` |
| Normalize before validation and dispatch invariants | `lib/codex_pooler/gateway/facade/request_normalizer.ex`, `lib/codex_pooler/gateway/facade/dispatch.ex` |
| Catalog projection and availability | `lib/codex_pooler/gateway/facade/catalog.ex`, `lib/codex_pooler/gateway/facade/ollama/catalog.ex` |
| Response and header cloaking | `lib/codex_pooler/gateway/facade/public_projection.ex`, `lib/codex_pooler/gateway/facade/header_policy.ex`, `lib/codex_pooler/gateway/facade/error.ex` |
| Pool/key-scoped cache and session identity | `lib/codex_pooler/gateway/facade/affinity.ex` |
| Ollama adapters | `lib/codex_pooler/gateway/facade/ollama`, `lib/codex_pooler_web/controllers/ollama` |
| Anthropic Messages adapters | `lib/codex_pooler/gateway/facade/anthropic`, `lib/codex_pooler_web/controllers/anthropic/messages_controller.ex` |
| Public route list | `lib/codex_pooler_web/router.ex`, `test/codex_pooler_web/route_surface_test.exs` |
| Cross-protocol leakage and fault behavior | `test/codex_pooler_web/controllers/facade_*_test.exs`, `test/codex_pooler/gateway/facade` |
| Real client verification | `scripts/verification/facade`, `test/codex_pooler/facade/client_contract_test.exs` |

## Author Checklist

Before publishing:

1. Search public sources for private target/helper/provider/account/assignment identifiers.
2. Confirm every client model example is exactly `gemma3`.
3. Confirm runtime examples use Pool API keys, never upstream credentials.
4. Confirm MCP examples use only operator MCP tokens.
5. Match route tables against `router.ex` and controller behavior.
6. State media-helper, cache, continuity, retry, and local-agent-runtime boundaries truthfully.
7. Build the docs and run the façade contract, leakage, transport, and full application tests.
