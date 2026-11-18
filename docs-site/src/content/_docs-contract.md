# Public Docs Contract And Source Map

This private planning file is for docs authors. Keep it under an underscore-prefixed path so Starlight does not publish it as a public page.

## Audience And Scope

Write public docs for operators and client integrators who are setting up Codex Pooler. The public docs may explain setup, runtime surfaces, compatibility limits, and privacy boundaries. They must not become an operator runbook, incident log, internal architecture dump, or exhaustive Phoenix route listing.

Root static files in `docs-site/public`, such as `llms.txt`, `answers.md`, `pricing.md`, and `robots.txt`, are public docs too, served at the site root while the pages are served under `/docs`. Keep them short, extractable, public-safe, and consistent with the same route, credential, host, and privacy boundaries as the Starlight pages.

Use sentence case for H2 headings across public pages unless a proper noun or
fixed product name requires capitalization. Keep `llms.txt` as a deliberate
curated index: add a page only when it belongs in the declared primary or
discovery scope, then update its inventory check and matching review date.

## Client guide structure

Dedicated client guides use this section order, with sentence-case headings:

Use `Client on Codex Pooler` for the page title and a short `sidebar.label` containing only the client name. Use `Kilo Code` as the product name while preserving the `kilo` executable, config paths, and package identifiers. The Codex guide uses `Codex CLI / Desktop on Codex Pooler` at `/clients/codex-cli-desktop/`; retain the old `/clients/codex-cli/` route as a redirect and update internal links and discovery indexes to the canonical route.

1. A short introduction explaining what the client does, how people use it and what connecting it to Codex Pooler enables
2. An optional integration banner, after the introduction and before prerequisites
3. `Before you start`: link to the client's official installation/getting-started guide, reachable endpoint, Pool API key, and client-specific prerequisites
4. `Configure the connection`: config file or settings screen, credential setup, and the recommended configuration
5. `Choose a model`: selection, prefixes, roles, and client-specific context/output limits
6. `Verify the connection`: a client-side check, expected result, and matching Pooler request metadata
7. `Advanced configuration`, when needed: alternative providers, transports, migration, or optional features
8. `Operator MCP (optional)`, only when a supported client setup is documented
9. `Troubleshooting`, when there are concrete client-specific symptoms and remedies
10. `Compatibility notes`: client-specific limits and links to shared reference material

Keep installation instructions under prerequisites and file paths beside their configuration examples. Keep optional MCP blocks outside the primary model configuration; explain how to merge them into the same file. Do not add empty sections or imply MCP support merely to fill the outline.

Client guides are for ordinary users connecting a client, not for operators investigating protocol internals. Explain what to set, what the user sees and what to do when setup fails; link to operator or reference pages for decoder contracts, headers, catalog representations, accounting and other implementation details. Describe present behavior without release numbers, dated checks or upgrade narratives.

The Codex CLI / Desktop guide orders `Advanced configuration` as `HTTP/SSE provider`, `Existing session migration`, `Custom provider name`, `Model catalog discovery` and `Choose a model`, after `Verify the connection`. Its primary connection example already supplies the catalog URL; preserve both model subsection anchors. Keep each OS's migration commands together in one code block. Omit `Tool-output preservation` from this client guide, and keep the agent-update text directly under `Compatibility notes`, without its own heading, expandable block or `Optional:` prefix. Explain the trade-offs beside optional client settings.

Lead client introductions with the product and its workflow in two or three concrete sentences. Put provider ids, endpoint paths, config filenames, transport details and auth boundaries in the configuration or compatibility sections. Preserve client-specific limitations when moving them, and keep the introduction's claims within the capabilities documented and verified by the guide.

Keep `Before you start` concise and consistent: point to the official installation guide for OS-specific installers and runtime requirements instead of maintaining local `npm install`, `bun install`, or equivalent instructions. Then list the reachable Pooler URL and Pool API key/model prerequisites, adding only requirements specific to that client. Preserve existing installation anchors when removing standalone install subsections. The shared SDK reference keeps its separate cross-client structure.

Keep configuration paths aligned with the approved README examples: show macOS/Linux and native Windows defaults, distinguish WSL and installer-specific locations, and preserve custom home/profile overrides. Use portable filenames in code-block titles when the adjacent table supplies the full paths. Pair shell-specific setup and verification commands with PowerShell equivalents where native Windows is supported; label WSL-only procedures explicitly. Do not infer Windows paths by replacing `~` with `%USERPROFILE%`.

Use two-column OS/path tables with one operating system per row, following the Codex and Continue guides. For multiple files, group separate tables by purpose instead of placing long Unix and Windows paths side by side. Keep generic model-selection prose tied to models the reader's Pool serves; explicit model lists belong in copyable configuration examples.

Every configuration-file code block uses Expressive Code's explicit `title="path/to/file" frame="code"` metadata, including repeated optional snippets for the same file. Environment-file contents also use the editor frame; commands executed in a shell retain the terminal frame. Do not rely on inferred filename comments or invent filenames for UI settings, API responses, or SDK fragments. Use the same filename for snippets merged into one file and explain the merge in adjacent prose. The editor filename header is not an interactive tab; use Starlight Tabs only when readers must select between genuine alternatives.

Use one deployed configuration example and a short localhost substitution where the client supports it. Explain which process must reach the endpoint for server-mediated clients. Keep instructional screenshots beside the relevant step; optional integration banners use the existing approximately 3:1 format, with no placeholder when absent.

Preserve existing heading anchors when renaming or regrouping sections. The OpenAI-compatible SDK page remains a cross-client reference, not a dedicated client guide, and keeps its SDK and API-contract organization.

## Allowed Hosts

Use only these hosts in public examples:

- `http://localhost:4000`, only for local setup and local smoke examples
- `https://codex-pooler.example.com`, for deployed product examples
- `https://www.codex-pooler.com/docs`, for the public docs site canonical URL

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

`POST /v1/decisions` is explicitly unsupported and returns `404 unsupported_endpoint` after the shared API-key and Pool compatibility checks, before body parsing, decompression, admission, dispatch or accounting. The Decisions API requires OpenAI Platform API-key access; Codex subscription credentials cannot serve it. Do not describe Responses classification or generated probabilities as Decisions API compatibility.

OpenAI Responses remote MCP tool definitions are unsupported request shapes inside `POST /v1/responses`, not unsupported routes. This includes top-level `tools[type=mcp]` and nested `input[type=additional_tools].tools[type=mcp]`.

Ordinary native and public Responses HTTP and websocket requests preserve an explicit client `max_output_tokens` in Full and Lite; `/v1` requires a positive integer. Chat maps `max_completion_tokens`, otherwise `max_tokens`, into the same field. Absent remains absent, key output policy remains an admission-estimate check, and explicit compaction retains its separate whitelist. Output-budget enforcement and `response.incomplete` with reason `max_output_tokens` belong to the provider; relay the provider outcome and measured usage without a Pooler counter, cancellation or cap-removing retry. Do not describe this as a per-response spend ceiling or a default client generation limit.

Direct public Responses HTTP and narrow websocket `response.create` accept the
map-shaped `allowed_tools` choice only in Full mode. It must use `auto` or
`required` mode with a nonempty list. Named `function` and `custom` members must
match undeferred direct top-level declarations of the same kind and name. The
only accepted type-only built-ins are `web_search` and `image_generation`, each
backed by a top-level declaration of that type. Preserve caller order and
duplicates. Do not extend this claim to Chat, backend Responses, namespaces,
additional tools, deferred declarations, aliases, remote MCP, Realtime, or broad
OpenAI tool parity. Malformed or undeclared Full choices reject before admission. Lite
rejects a valid map-shaped choice with `unsupported_parameter` on `tool_choice`.
Remote MCP declarations continue to reject on `tools`; an MCP member in an
`allowed_tools` choice rejects on `tool_choice`.

`metadata` is accepted on `/v1/responses`, the Responses websocket and Chat
Completions with the OpenAI API's shape and is never forwarded, stored or
echoed: the upstream refuses the parameter. Malformed values reject before
dispatch on `metadata` with the OpenAI API's codes. The `programmatic_tool_calling`
declaration is accepted only in Lite mode, where it is forwarded in the
manifest; Full rejects it before dispatch on `tools`, and a type-only
`tool_choice` naming it rejects in both modes. `web_search_preview` rejects
before dispatch in both modes and is never rewritten to `web_search`.

Direct `POST /v1/responses` and narrow Responses websocket `response.create`
accept exact top-level custom definitions and nested custom definitions in an
already-valid namespace. `functions` is the canonical Codex namespace
example, not a namespace-name restriction: every nonblank valid namespace uses
the same child contract. A custom definition requires exact `type=custom` and a
nonblank name; optional fields are description, boolean `defer_loading`, nullable
`allowed_callers` limited to `direct` or `programmatic`, and omitted, text,
`lark`, or `regex` grammar format. Namespace children are exact flat `function`
or `custom` definitions. Hosted, MCP, nested-namespace, malformed, and globally
colliding executable-name shapes are rejected before dispatch, and so is a
`tool_search` inside a namespace.

A top-level `tool_search` tool on direct `POST /v1/responses` and narrow
Responses websocket `response.create` accepts exactly `type`, `execution`
(`server` or `client`), `description`, and `parameters`; anything else rejects
before dispatch with `invalid_request` on `tools`. Replayed `tool_search_call` and
`tool_search_output` items are admitted in the provider's exact shape, and a
remote MCP tool among a replayed item's loaded tools rejects. A `tool_search`
inside a namespace or an `allowed_tools` choice rejects. The pairing rules
between `tool_search` and deferred tools stay with the provider: Full relays its
refusal and Lite does not enforce them.

An exact typed custom `tool_choice` resolves only a declared same-kind, same-name
custom definition, including an accepted namespace child. Full mode preserves
that choice. Lite preserves exact nonblank named function choices against its
`additional_tools` manifest, including translated Chat function choices; other
map-shaped choices still fail before upstream dispatch with `unsupported_parameter`
and `param: "tool_choice"`. Keep this separate from accepted custom-tool replay
input. Chat translates supported nested function/custom declarations and named
choices into the Responses subset. Provider execution availability remains
selected model and account dependent; smoke verification records metadata only.
Never claim broad OpenAI tool parity.

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

`web_search` accepts exactly `type`, `external_web_access`, `indexed_web_access`,
`filters`, `user_location`, `search_context_size` and `search_content_types`: the
keys the upstream accepts and released Codex serializes. Every other key rejects
before dispatch, including `index_gated_web_access`, an older Codex spelling the
upstream refuses and Codex Pooler does not rewrite. `indexed_web_access` is a boolean that requires `external_web_access: true`;
`user_location` is an object that requires `type` `approximate` and may add
nonblank string `country`, `region`, `city` and `timezone`; `search_context_size` is `low`,
`medium` or `high`; `search_content_types` is a nonempty list of `text` and
`image`. Accepted values forward unchanged and the same local-validation-only
wording applies. `web_search_preview` rejects before dispatch.

`agent_message` history items are accepted on `/v1/responses` only as plaintext
`input_text` content or as the exact sealed `NEW_TASK` or `MESSAGE` handoff the
native route recognizes. They forward unchanged in Full and Lite mode and every
other shape rejects before dispatch with `invalid_request` on `input`. Public
docs must not claim that Codex Pooler reads or validates the sealed content.

`web_search_call` history items are accepted on `/v1/responses` with the keys the
upstream validates: `type`, `id`, `status`, `action` and the optional passthrough
object. The action is `search` (`query`, `queries` and `sources`, a list of exact
`{"type": "url", "url": ...}` objects), `open_page` (`url`) or `find_in_page`
(`url`, `pattern`). An unknown key, a key of another action type, another action
type and a null in any field but the passthrough reject before dispatch with
`invalid_request` on `input`; the id the public stream names an item upstream sent
without one is dropped on replay. Public docs must not claim that Codex Pooler runs
or validates a search.

`image_generation_call` history items are accepted on `/v1/responses` with the keys
the upstream validates: `type`, `id`, `status`, `action`, `background`,
`output_format`, `quality`, `size`, `revised_prompt`, `result`, `encrypted_content`
and the optional passthrough object. `result` is a required nonblank string, `id`,
`status` and `encrypted_content` are nonblank strings or null, and the other fields
are strings or null; the values of `action`, `background`, `output_format` and
`quality` are left to the upstream, whose `invalid_value` rejection is relayed. An
unknown key, a missing or blank `result` and a wrong value type reject before
dispatch with `invalid_request` on `input`; the id the public stream names an item
upstream sent without one is dropped on replay. The reservation input estimate
counts the base64 image in `result` as one fixed image allowance, like an
`input_image`, and the image is never persisted. Public docs must not claim that
Codex Pooler generates, decodes or validates the image.

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
- `/v1/agents` and every path below it, any method: the beta Agents API, answered `404 unsupported_endpoint` naming the beta Agents API after the key and `/v1` compatibility checks and before the body is read
- `/v1/vaults` and every path below it, any method: the credential vaults of the beta Agents API, answered like `/v1/agents`
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
behavior remains unchanged. An incremental websocket compact with a nonblank
top-level `previous_response_id` stays on the current live upstream websocket
connection, reuses its matching generation and effective Full/Lite mode, and
collects provider frames before validation, one settlement, and result
adaptation. It never reconnects, retries, changes assignment, or falls back to
HTTP; a lost or mismatched connection returns the existing client-recovery
boundary. A no-anchor full-history compact, including one initiated from a
websocket client, remains the HTTP compact control.

Native backend RemoteCompactionV2 transport classification reads only the
request-side nested `compaction.implementation=responses_compaction_v2` marker;
unrelated additive turn metadata is ignored, and returned compaction-item
metadata is a separate normalization contract. Harness applicability is
bounded: Codex `rust-v0.153.3` at peeled commit
`b1a547b1f73ce86205d9222ac19cff334b3b7a2e` is the native V2 classifier
authority, backed by the two sanitized fixtures under
`test/fixtures/codex/rust-v0.153.3-b1a547b1f73ce86205d9222ac19cff334b3b7a2e/`,
and its case is commit-blocking; OMP `18.0.4` uses a distinct V2/configured-direct-
fallback adapter; OpenCode covers HTTP and websocket replay only; Hermes has no
independent native classifier authority; Pi native remote compaction is
unverified and not applicable to the native classifier gate.

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

- Hosts: `http://localhost:4000`, `https://codex-pooler.example.com`, `https://www.codex-pooler.com/docs`
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
- Say `the beta Agents API under /v1/agents and /v1/vaults is not supported, so the OpenAI Node client.beta.agents helpers do not work through Codex Pooler`; never describe an Agents function definition, a session tool result or a typed final result as translated, and never say the generic /v1/files route enables Agents environment files or artifacts

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
`test/codex_pooler_web/controllers/runtime/backend_codex_websocket/socket_lifecycle_test.exs`.

## Error type classification

Public docs may state that every error Codex Pooler itself authors carries an
`error.type` that classifies retryability from an enumerated code vocabulary
rather than a default, and that the same classification applies to HTTP error
bodies on `/v1/*` and `/backend-api/codex/*` and to error frames on
`GET /v1/responses`: owner-lifecycle and overload codes and any other
server-side failure use `server_error`, an HTTP `429` Codex Pooler authors uses
`rate_limit_error`, and a replaced or stale downstream and genuine request
rejections use `invalid_request_error`. Docs may state that a `5xx` response or
frame is never typed `invalid_request_error`. Do not publish the internal
owner-lifecycle code list, owner identifiers, lease tokens, or frame contents,
and do not describe how an error map's internal `retryable` field is treated.

The source map for this claim is
`lib/codex_pooler/gateway/error_classification.ex`,
`lib/codex_pooler/gateway/websocket/adapter.ex`,
`lib/codex_pooler_web/controllers/gateway_controller_helpers.ex`,
`lib/codex_pooler/gateway/transports/websocket/owner_error_vocabulary.ex`,
`test/codex_pooler/gateway/error_classification_test.exs`,
`test/codex_pooler/gateway/websocket/adapter_test.exs`,
`test/codex_pooler_web/controllers/gateway_controller_helpers_test.exs`,
`test/codex_pooler_web/codex_responses_socket_owner_liveness_discard_test.exs`,
and `test/support/compatibility_matrix.ex`.

## Metrics and operator-session boundaries

Monitoring guides live under `monitoring/`, in a dedicated sidebar group after Deployment. Separate collection setup, dashboard use, runtime interpretation, PromQL recipes and logs. Keep the legacy `/operators/monitoring/` page hidden from navigation/search with its old heading anchors linking to the new guides; retain the existing dashboard JSON download URL. Update the curated llms inventory when adding or moving primary monitoring pages.

Verify monitoring claims against `Telemetry.prometheus_metrics/0`, `Telemetry.RoleCoverage`, the metrics controller, memory sampler and the public chart. Keep direct and relayed event coverage explicit, use `max` for shared relay gauges, and distinguish current lifecycle metadata from a complete transition history. A quiet graph is not proof that an event never happened. Give each PromQL expression a purpose, collector requirements and interpretation; use one runnable expression per block.

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
| Explicit client output budgets | `lib/codex_pooler/gateway/payloads/payload_normalizer.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses.ex`, `lib/codex_pooler/gateway/openai_compatibility/chat.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/v1/output_limit_forwarding_test.exs`, `test/codex_pooler_web/controllers/v1/api_key_output_budget_characterization_test.exs` | Ordinary native/public Responses preserves explicit `max_output_tokens` in Full/Lite across HTTP and websocket, including the public HTTP bridge and owner forwarding. Chat aliases retain their precedence, absence adds no cap, the key policy remains admission-only and compaction remains separate. Provider incomplete terminals retain measured usage without a Pooler counter, cancellation or cap-removing retry. |
| Root route split | `lib/codex_pooler_web/router.ex`, `test/codex_pooler_web/route_surface_test.exs` | `/backend-api`, `/v1`, `/mcp`, browser auth, admin LiveViews, usage, health, and metrics are separate route families |
| Lens model-name evidence | `lib/codex_pooler/accounting/request_logs/model_history.ex`, `lib/codex_pooler/accounting/model_observation.ex`, `lib/codex_pooler/gateway/runtime/streaming/model_declaration_observer.ex`, `lib/codex_pooler_web/live/admin/pages/lens_live.ex`, `test/codex_pooler/accounting/model_history_test.exs`, `test/codex_pooler_web/live/admin/pages/lens_live_test.exs`, `test/codex_pooler_web/live/admin/pages/request_logs_served_model_live_test.exs` | `/admin/lens` is a scoped, metadata-only operator page. It compares first reported versus sent model names and tracks differing names within one attempt, including a later return to the first name. Counts are attempt-based, overlapping signals count once in affected groups, missing/older recording stays informational, and provider-reported names do not independently prove model identity or quality. |
| Runtime ingress firewall and limits | `lib/codex_pooler_web/plugs/runtime_ingress.ex`, `lib/codex_pooler_web/plugs/runtime_ingress/path.ex`, `lib/codex_pooler_web/plugs/runtime_ingress/forwarded_client_ip.ex`, `lib/codex_pooler_web/plugs/runtime_ingress/firewall.ex`, `test/codex_pooler_web/plugs/runtime_ingress_test.exs`, `test/codex_pooler_web/plugs/runtime_ingress/path_test.exs`, `test/codex_pooler_web/plugs/runtime_ingress/forwarded_client_ip_test.exs` | Runtime and MCP ingress use one decoded path view, one settings snapshot, and one bounded client-IP resolution. Trusted forwarding is right-to-left and fail-closed for malformed or over-bound runtime/MCP input; non-runtime routes retain the peer. Compressed JSON and the four exact image actions are guarded before body parsing. |
| Metrics and current-session status | `lib/codex_pooler_web/controllers/operations/metrics_controller.ex`, `lib/codex_pooler_web/live/admin/components/pages/system/page_components/metrics.ex`, `lib/codex_pooler_web/live/admin/pages/system_live.ex`, `test/codex_pooler_web/live/admin/pages/system_live_test.exs` | `/metrics` has separate open, bearer-protected, and unavailable fail-closed states outside the runtime firewall. The System page shows only the signed-in operator's current active, unexpired browser-session IP. |
| OpenAI incidents status feed | `lib/codex_pooler_web/router.ex`, `lib/codex_pooler_web/live/admin/pages/incidents_live.ex`, `lib/codex_pooler_web/live/admin/read_models/open_ai_incidents_read_model.ex`, `test/codex_pooler_web/route_surface_test.exs`, `test/codex_pooler_web/live/admin/pages/incidents_live_test.exs` | `/admin/incidents` is an authenticated, read-only admin LiveView that presents bounded OpenAI status incident metadata, preserves the last known good projection during feed failures, and exposes no incident mutation controls or admin JSON route. |
| Pruned app-server helper candidates | `lib/codex_pooler_web/plugs/runtime_ingress/path.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/plugs/runtime_ingress_test.exs` | Pruned helper candidates remain unsupported and preserve their fixed `404` only after settings and firewall admission; they never authenticate, parse a body, dispatch upstream work, reserve capacity, or create accounting. |
| Backend Codex routes | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler/compatibility_matrix_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_compaction_trigger_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_compaction_failure_test.exs` | `/backend-api/codex/*` is explicit authenticated Codex backend compatibility, not wildcard proxy. On either backend Responses websocket alias, an exact final compaction trigger enters nested compact admission and returns exactly `response.output_item.done` then `response.completed` on success. An incremental trigger with a nonblank top-level anchor is connection-bound: it uses the current live matching upstream websocket generation in the same effective Full/Lite mode, records canonical compact accounting with websocket request/attempt transport, collects before validation/settlement/adaptation, and never retries or falls back. A no-anchor full-history compact remains the HTTP control. Buffered collection and semantic V2 collection selected only by request-side nested `compaction.implementation=responses_compaction_v2` preserve request-scoped turn state, accept unrelated additive metadata, permit an ordinary same-socket follow-up, and expose only the bounded `compaction_bridge` request-log diagnostic. Returned compaction-item normalization remains separate from request classification. |
| Native backend image routes | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs` | Exact native image generation and edit routes may route any policy-authorized effective image model that is genuinely absent from the Pool catalog through eligible visible host capacity while preserving that effective identifier. Catalog-present invisible targets remain invalid, and this does not change public `/v1` image translation |
| Pool API key lifecycle on open Responses websockets | `lib/codex_pooler/access/api_keys/runtime_authorization.ex`, `lib/codex_pooler/access/api_keys.ex`, `lib/codex_pooler/access/api_keys/policies/policy_update.ex`, `lib/codex_pooler_web/codex_responses_socket.ex`, `lib/codex_pooler/gateway/transports/websocket/response_processed.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs`, `test/codex_pooler/access/api_key_runtime_authorization_lifecycle_test.exs`, `test/codex_pooler/gateway/transports/response_processed_test.exs`, `test/codex_pooler_web/codex_responses_socket_api_key_lifecycle_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_api_key_revocation_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_api_key_lifecycle_revocation_test.exs` | Pause, revoke, key delete, expiry, and Pool disable, archive, or delete block new authentication and close open Responses websockets with `1008 api key is no longer active`; moving a key to another Pool closes the websockets opened under its previous Pool the same way. The cluster event only prompts the close; a durable check of the key row, its revocation generation (which a move advances), its expiry, and its Pool refuses the next frame, including a `response.processed` acknowledgement, when the event is missed. An idle socket rechecks at the key's expiry time. Only work admitted before the change drains, with no separate deadline. |
| Native websocket close after an upstream connection close | `lib/codex_pooler/gateway/transports/websocket/upstream_websocket_session.ex`, `lib/codex_pooler/gateway/transports/websocket/upstream_websocket_session/close_diagnostics.ex`, `lib/codex_pooler/gateway/transports/websocket/websocket_owner_session.ex`, `lib/codex_pooler_web/codex_responses_socket.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket/upstream_close_downstream_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_owner_forwarding/upstream_close_downstream_test.exs` | On the native `GET /backend-api/codex/responses` websocket and its `/backend-api/codex/v1/responses` alias, when the upstream connection that produced the client's last completed response closes between two requests, Codex Pooler closes the idle client websocket with `1001 upstream connection closed`; the Codex client then sends its next request in full on a new websocket. A request that reaches the socket before the close is decided keeps the existing `previous_response_not_found` refusal before dispatch. A revoked key keeps its `1008` close, and the public `GET /v1/responses` websocket is not closed this way |
| Websocket close after its owner exits | `lib/codex_pooler_web/codex_responses_socket.ex`, `lib/codex_pooler/gateway/websocket/downstream_session.ex`, `lib/codex_pooler/gateway/websocket.ex`, `lib/codex_pooler/gateway/transports/websocket/websocket_owner_forwarder.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_owner_forwarding/owner_loss_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_owner_forwarding/remote_owner_loss_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_owner_forwarding/owner_crash_after_send_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_owner_forwarding/remote_owner_crash_after_send_test.exs` | With owner forwarding, a websocket follows its session's owner on this replica or another: an owner crash closes it `1011 websocket owner crashed` at once, and the turn the socket was waiting on is never handed to another owner: it is recorded `owner_crashed` with no usage recorded, and the client's resend on a new websocket is served once; a drained or stopped owner closes an idle native websocket `1001 websocket owner is draining`, after which the Codex client sends its next request in full on a new websocket; a native websocket that receives a frame first, and the public `GET /v1/responses` websocket, stay open and their next request is served by a new owner |
| Native websocket upstream failure answers | `lib/codex_pooler/gateway/runtime/dispatch/websocket_attempt.ex`, `lib/codex_pooler/gateway/runtime/finalization/websocket.ex`, `lib/codex_pooler/gateway/runtime/dispatch/http_auth_refresh.ex`, `lib/codex_pooler/gateway/transports/streaming/stream_protocol/error_codes.ex`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket/auth_refresh_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_owner_forwarding/auth_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket/committed_close_settles_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket/connect_failover_route_health_test.exs` | On the native `/backend-api/codex/responses` websocket, a connection failure, a refused handshake or a close moves the turn to the next eligible account only before its request is written to the upstream websocket. A handshake `401` is refreshed first, and when the refresh cannot retry the turn moves on as well; with no other account eligible the client gets one wrapped error event with status `503`, code `upstream_unauthorized` and the message `upstream authentication failed; retry the request`, the answer HTTP gives. Once the request is written, a connection that closes or fails before any response frame settles the turn on that account with `502` and code `upstream_request_failed`, and the turn does not move to another account. An authorization failure the provider reports in a response frame is relayed as its own terminal |
| Provider validation refusals on the websocket | `lib/codex_pooler/gateway/runtime/finalization/provider_refusal_message.ex`, `lib/codex_pooler/gateway/runtime/finalization/metadata.ex`, `lib/codex_pooler/gateway/runtime/finalization/validation_rejection.ex`, `lib/codex_pooler/gateway/websocket/adapter.ex`, `lib/codex_pooler/gateway/openai_compatibility/public_response.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler/compatibility_matrix_test.exs`, `test/codex_pooler/gateway/runtime/finalization/provider_refusal_message_test.exs`, `test/codex_pooler/gateway/runtime/finalization/metadata_test.exs`, `test/codex_pooler/gateway/websocket/adapter_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_provider_validation_relay_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket/final_refusal_resend_test.exs` | A provider `400` validation refusal reaches the client with the code and field path the HTTP answer of the same fault carries, on the HTTP routes and on the websocket. The Codex backend's websocket sends it as a wrapped error with the HTTP message as text and no code and no param, in the wording `Invalid response.create payload: <message>` or `[<Schema>] [<path>] [<kind>] <message>`, chosen per connection; Codex Pooler reads the code and the field path from that text (the kind `invalid_enum_value` reads as `invalid_value`) for the public `/v1` websocket, a streaming `/v1` request carried over the websocket, and the native websocket. A code or param the frame carries is never replaced, text outside the measured templates is not read and keeps the generic answer, an `Invalid value` text names no field so its `param` is `null`, and the provider message is never forwarded. `Unsupported tool type: <type>` is not relayed on either transport: the failed attempt keeps the type as a bounded identifier or its fingerprint |
| Native content-filter guided retry | `lib/codex_pooler/accounting/native_content_filter_retry.ex`, `lib/codex_pooler/accounting/client_retry.ex`, `lib/codex_pooler/gateway/runtime/dispatch/content_filter_retry_pin.ex`, `lib/codex_pooler/gateway/runtime/dispatch/content_filter_binding_refusal.ex`, `lib/codex_pooler/gateway/runtime/duplicate_turn_telemetry.ex`, `test/codex_pooler_web/controllers/runtime/backend_codex_content_filter_retry_test.exs` | A native `/backend-api/codex/responses` turn, over HTTP SSE or websocket, that ends with `response.incomplete` and an `incomplete_details.reason` of `content_filter` admits one resend after the client has received that terminal: the Codex client's guided retry. Every other resend of that turn is answered `409 duplicate_turn` before any upstream dispatch, accounting reservation or request row. The guided retry is served as a new request linked to the filtered one, within 30 seconds of its settlement and only on the account that served the filtered response; the client's retry of a guided retry that failed there stays on that account too. When routing excludes that account the answer is the retryable `503 no_eligible_backend`, with a `Retry-After` when an open circuit excluded it, and the client's next retry within the same 30 seconds is served once the account is eligible. A guided retry that dispatch refuses because its account binding does not hold is answered `409 duplicate_turn` as an admitted request whose row records status `409` and the error code `invalid_content_filter_retry_binding`, and the duplicate-turn counter does not count it |
| Content-filter retry credential binding | `lib/codex_pooler/accounting/native_content_filter_retry.ex` (`bound_credential?/3`), `lib/codex_pooler/upstreams/lifecycle/credential_fencing.ex` (`same_credential_since?/2`), `lib/codex_pooler/upstreams/auth/token_refresh.ex`, `test/codex_pooler/accounting/native_content_filter_retry_test.exs`, `test/codex_pooler/upstreams/credential_lineage_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_content_filter_retry_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_content_filter_refresh_peer_test.exs` | A token refresh of the account keeps the guided content-filter retry on it; a credential the operator links, imports or relinks for the account, or a pause or reactivation of the account, after the filtered response refuses the retry with `409 duplicate_turn`. Admission refuses it before the retry is linked and writes no request row; a binding found broken only when dispatch creates the attempt answers the same `409 duplicate_turn` for an admitted request whose row records `invalid_content_filter_retry_binding` |
| Backend file bridge | `lib/codex_pooler_web/router.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `/backend-api/files` stores metadata only and returns upstream upload or download URLs. Bytes are not stored locally |
| OpenAI-compatible `/v1` supported routes | `lib/codex_pooler_web/router.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/normalization.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/validation.ex`, `lib/codex_pooler/gateway/payloads/compaction_trigger.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/route_surface_test.exs`, `test/codex_pooler_web/controllers/responses_terminal_compatibility_test.exs`, `test/codex_pooler_web/controllers/v1/route_auth_test.exs`, `test/codex_pooler_web/controllers/v1/responses_controller_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_programmatic_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_bridge_terminal_test.exs`, `test/codex_pooler_web/controllers/v1/responses_streamed_terminal_output_test.exs`, `test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `/v1` is narrow authenticated compatibility, not full OpenAI parity. `POST /v1/responses` and narrow Responses websocket turns accept exactly one final `compaction_trigger` after visible input; malformed placement rejects before dispatch, and direct `POST /v1/responses/compact` remains unsupported. For narrow Responses websocket turns, an incremental trigger with a nonblank top-level anchor stays on the current live matching upstream websocket generation in the same effective Full/Lite mode, collects before one validation/settlement/adaptation path, and never retries or falls back; a no-anchor full-history compact remains the HTTP control. OpenAI-compatible HTTP SSE synthesizes route-specific terminals when a visible stream ends without an upstream terminal: `POST /v1/responses` emits a sequence-valid sanitized `type: "error"` event, while `POST /v1/chat/completions` and its translated backend alias emit one nested `data: {"error":{...}}` chunk with no top-level `type` or following `[DONE]`. Public SSE treats absent, blank, and whitespace-only event labels identically while rejecting nonblank event/data mismatches. Ordinary incomplete public Responses SSE blocks are capped at 8 MiB so single large provider events can finish decoding; structurally recognizable terminal candidates may retain up to 64 MiB so split large terminals can finish decoding. Crossing the applicable cap emits one bounded sanitized error and relays no source bytes. Direct and accepted owner-forwarded public Responses websockets drop malformed JSON and JSON non-object provider frames without advancing sequence state. Native backend raw Responses streams and websocket surfaces do not synthesize these terminals. Public POST SSE and GET websocket normalize successful `response.done` or legacy typeless terminals to `response.completed`, while backend raw GET/POST surfaces preserve them. A completed or incomplete terminal whose upstream output is empty or absent carries, on public POST SSE and the GET websocket in Full and Lite, the items the stream delivered in `response.output_item.done`, in `output_index` order with their ids; a non-empty output and backend raw surfaces relay the upstream terminal as sent. Both `POST /v1/responses` and `POST /v1/chat/completions` accept WAV, MP3, M4A, WebM, and OGG input audio with bounded decoded input |
| Public Responses tool completion | `lib/codex_pooler/gateway/transports/streaming/stream_protocol/public_responses_tool_completion.ex`, `lib/codex_pooler/gateway/transports/streaming/stream_protocol/public_responses.ex`, `lib/codex_pooler/gateway/transports/streaming/stream_protocol/public_responses_websocket.ex`, `lib/codex_pooler/gateway/transports/websocket/upstream_websocket_session.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler/gateway/transports/public_responses_tool_completion_test.exs`, `test/codex_pooler_web/controllers/v1/responses_sse_tool_integrity_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_tool_integrity_test.exs` | On public Responses SSE and the narrow Responses websocket, an announced function or custom-tool call completes only with a correlated `response.output_item.done` whose status is `completed` or absent. A `response.completed` after an unfinished call becomes one sanitized `server_error` terminal; a provider `response.incomplete` keeps its own outcome. A tool the client fails or cancels belongs in the next request's tool output item. |
| `/v1` websocket compaction refused for a usage limit | `lib/codex_pooler/gateway/runtime/dispatch/websocket_attempt.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler/compatibility_matrix_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_compaction_usage_limit_test.exs`, `test/codex_pooler_web/controllers/runtime/partition_held_back_quota_refusal_test.exs` | A `GET /v1/responses` websocket compaction that can run only on the connection holding its anchor, and that the provider refuses with its usage limit, is answered with the usage limit of the account that holds the anchor even while another account could serve a new request: an `error` event with `"status": 429`, `usage_limit_reached`, `quota_exhausted`, `resets_at`, `resets_in_seconds` and `headers.retry-after`. A native websocket compaction in the same case gets the retryable `503 pinned_continuation_unavailable` when another account can serve or its return is unknown, and the Pool's usage limit when every compatible account is exhausted |
| Hosted-shell Responses history replay | `lib/codex_pooler/gateway/openai_compatibility/responses/input/hosted_shell.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/normalization.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/validation.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler/compatibility_matrix_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `/v1/responses` and narrow Responses websocket turns accept only the documented closed-key `shell_call` and `shell_call_output` history subset. This is replay/relay compatibility: it does not execute commands, accept shell tool declarations, accept local-shell or remote MCP history, accumulate command indexes, enforce call/output pairing or ordering, or claim broad hosted-tool parity. The five hosted-shell stream event types preserve the existing public sequence and websocket stream-id adaptations only; command and output data stay transient and metadata-only |
| Catalog revision and Responses envelope | `lib/codex_pooler/gateway/metadata/codex_catalog.ex`, `lib/codex_pooler/gateway/payloads/payload_normalizer.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler/compatibility_matrix_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Backend model aliases share a deterministic policy-visible weak ETag from one selected canonical capability family. Reasoning-level-only variants advertise the routable family's stable union and remain inside a native turn's canonical allowance; after quota and circuit eligibility, routing prefers an eligible assignment that lists the effective known effort without changing that ETag or crossing another capability family. Backend Codex catalog-driven turns use the selected family, while translated OpenAI Responses capacity includes all valid canonical assignments after concrete request compatibility. Successful backend Responses streams expose the token in backend-only headers; final non-compact backend envelopes cover canonical, alias, and translated public Responses destinations while compact stays excluded; failed-attempt parameter detail is bounded and sanitized |
| Codex catalog entries left out | `lib/codex_pooler/gateway/metadata/codex_model_decode_contract.ex`, `lib/codex_pooler/gateway/metadata/catalog_representation.ex`, `lib/codex_pooler/gateway/metadata/codex_catalog.ex`, `lib/codex_pooler/gateway/metadata.ex`, `test/codex_pooler/gateway/metadata/codex_model_decode_contract_test.exs`, `test/codex_pooler/gateway/metadata/catalog_representation_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_catalog_decode_contract_test.exs` | For Codex clients covered by the decoder contract, read from the Codex `User-Agent` with a prerelease counted by its whole version, the served catalog is checked entry by entry and an entry that release cannot decode is left out, so the client keeps every other Pool model. Each omission logs a `codex catalog entry left out` warning that names the Pool, the model and the field paths. Clients outside that contract, `/v1/models` and clients whose `User-Agent` is not a Codex build's receive the catalog unchecked |
| Held-back canonical partition re-check | `lib/codex_pooler/gateway/runtime/dispatch/partition_fallback.ex`, `lib/codex_pooler/gateway/runtime/dispatch/pre_dispatch.ex`, `lib/codex_pooler/gateway/runtime/service.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler/compatibility_matrix_test.exs`, `test/codex_pooler/gateway/runtime/pre_dispatch_test.exs`, `test/codex_pooler_web/controllers/runtime/partition_held_back_quota_refusal_test.exs` | On the Codex backend routes, before a Pool-wide quota refusal, Codex Pooler checks once, with the same quota rules and a fresh read of any quota older than the freshness window, the accounts it kept out of the request because they advertise the model with a different catalog shape, and moves the request to one that has quota; when none has, the earliest reset covers them too. A compaction that has to stay on its WebSocket connection, a request hard-pinned to its account by session continuity or a file affinity, and a request whose selected partition refused for a reason other than quota are not moved |
| Saved-reset redemption once per request | `lib/codex_pooler/gateway/routing/route_filtering.ex`, `lib/codex_pooler/gateway/runtime/dispatch/partition_fallback.ex`, `lib/codex_pooler/gateway/routing/saved_reset_auto_redeem.ex`, `lib/codex_pooler/gateway/routing/candidate_eligibility/usage_limit.ex`, `test/codex_pooler/gateway/routing/account_denial_auto_redeem_invariance_test.exs`, `test/codex_pooler_web/controllers/runtime/saved_reset_retry_refilter_test.exs` | Request-driven automatic redemption spends at most one saved reset per request, whichever trigger redeems it. Once a request's routing records a redeemed reset, pending verification or confirmed, none of its later route filterings, the retry over its remaining accounts and the check of the accounts it first left out included, runs a saved-reset scan or redeems another reset. A refusal of such a request stays the retryable `503` without a reset time, because the redeemed account's return is not known |
| OpenAI Responses request-shape rejections | `lib/codex_pooler/gateway/openai_compatibility/responses.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler/gateway/openai_compatibility/core_test.exs`, `test/codex_pooler_web/controllers/v1/responses_controller_test.exs`, `test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs` | OpenAI Responses remote MCP tool definitions are rejected before upstream dispatch in both top-level `tools` and nested `additional_tools.tools` locations |
| OpenAI Responses custom tools and strict repair | `lib/codex_pooler/gateway/openai_compatibility/responses.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/tool_search.ex`, `lib/codex_pooler/gateway/openai_compatibility/chat.ex`, `lib/codex_pooler/gateway/payloads/strict_schema.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler/gateway/openai_compatibility/core_test.exs`, `test/codex_pooler/gateway/payloads/strict_schema_repair_test.exs`, `test/codex_pooler_web/controllers/v1/responses_controller_test.exs`, `test/codex_pooler_web/controllers/v1/responses_tool_search_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_programmatic_test.exs`, `test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Direct public Responses HTTP and narrow websocket turns accept exact custom definitions top-level or in any already-valid nonblank namespace; `functions` is the canonical example, not a restriction. Full resolves exact same-kind custom choices from either location, while Lite rejects map-shaped choices before dispatch. Hosted, MCP, nested-namespace, malformed, and global executable-name collision shapes, and a `tool_search` inside a namespace, remain excluded; a top-level `tool_search` tool and its replayed items are accepted. Separately, strict flat-function parameters may receive only structurally proven missing nested object or array types. Chat custom tools and strict repair, structured-output repair, root repair, refs/definitions/combinators, backend routes, and broad OpenAI tool parity remain excluded |
| Responses declaration-backed allowed tools | `lib/codex_pooler/gateway/openai_compatibility/responses.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler/gateway/openai_compatibility/core_test.exs`, `test/codex_pooler_web/controllers/v1/responses_controller_test.exs`, `test/codex_pooler_web/controllers/v1/responses_websocket_programmatic_test.exs`, `test/codex_pooler/compatibility_matrix_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Direct public Responses HTTP and narrow websocket `response.create` accept `allowed_tools` only in Full mode, with direct declaration backing. Named `function` and `custom` members require undeferred same-kind, same-name direct top-level declarations. The only accepted type-only built-ins are `programmatic_tool_calling`, `web_search_preview`, `web_search`, and `image_generation`, each requiring a matching top-level declaration. Full preserves order and duplicates; malformed or undeclared choices reject before admission. Lite rejects a valid map-shaped choice with `unsupported_parameter` on `tool_choice`. Top-level remote MCP declarations reject on `tools`, while MCP allow-list members reject on `tool_choice`. Chat, backend Responses, namespaces, additional tools, deferred declarations, aliases, Realtime, and broad OpenAI tool parity remain excluded |
| Pool-model serving modes (Auto, Lite, Full) | `lib/codex_pooler/pools/model_serving_mode.ex`, `lib/codex_pooler/pools/model_serving_modes.ex`, `lib/codex_pooler/pools/model_serving_override.ex`, `lib/codex_pooler/gateway/payloads/payload_normalizer.ex`, `lib/codex_pooler/gateway/payloads/request_options/routing.ex`, `lib/codex_pooler/gateway/transports/upstream_dispatch.ex`, `lib/codex_pooler/gateway/metadata/canonical_model_source.ex`, `lib/codex_pooler/gateway/routing/model_metadata.ex`, `lib/codex_pooler/gateway/runtime/finalization/metadata.ex`, `lib/codex_pooler/accounting/metadata.ex`, `test/codex_pooler/pools/model_serving_mode_test.exs`, `test/codex_pooler/pools/model_serving_modes_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_websocket/catalog_model_serving_test.exs` | A serving mode belongs to one Pool and one canonical exposed model id and never changes the route, model id, credentials, response shape, transport choice, routing eligibility, context window, or accounting. Auto selects Lite only on a literal `true` from a routable catalog source, otherwise Full; explicit `lite`/`full` record source `override`. Lite rewrites the outgoing valid request: top-level `tools` and `instructions` move into leading `additional_tools` and developer message `input` items, `parallel_tool_calls` becomes `false`, `reasoning.context` becomes `all_turns`, `input_image` `detail` is dropped, and Codex Pooler owns the Lite marker (HTTP header, or the websocket `client_metadata` key) in both directions. The rewrite is idempotent. On native non-compact backend Responses routes, both modes reject a present non-list `input` or `tools` before dispatch with `invalid_request`; narrow `/v1` string input is normalized before serving-mode handling. Lite rejects map-shaped `tool_choice` before dispatch with `unsupported_parameter`. `GET /backend-api/codex/models` reports `use_responses_lite` as the effective mode; `GET /v1/models` carries no serving-mode field. The mode is an immutable per-request or per-`response.create`-turn snapshot |
| OpenAI Responses web-search tool keys and domain filters | `lib/codex_pooler/gateway/openai_compatibility/responses.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler/gateway/openai_compatibility/core_test.exs`, `test/codex_pooler/gateway/openai_compatibility/responses_web_search_tool_test.exs`, `test/codex_pooler_web/controllers/v1/responses_web_search_tool_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | `web_search` accepts exactly `type`, `external_web_access`, `indexed_web_access`, `filters`, `user_location`, `search_context_size` and `search_content_types`, the keys the upstream accepts (every other key, `index_gated_web_access` included, is refused `400 unknown_parameter` by the provider in Full and Lite, so it rejects locally and is never rewritten). `indexed_web_access` requires `external_web_access: true`; `user_location` requires `type` `approximate` and may add nonblank string `country`, `region`, `city`, `timezone`; `search_context_size` is `low`, `medium` or `high`; `search_content_types` is a nonempty list of `text` and `image`. `web_search.filters` accepts only optional `allowed_domains` and `blocked_domains` lists, each bounded to 1 through 100 nonblank strings without leading-whitespace, case-insensitive HTTP(S) schemes. Both lists may coexist and accepted values are forwarded unchanged. `external_web_access` is optional. This is local validation and forwarding, not an upstream availability or enforcement guarantee |
| Responses multi-agent mailbox history replay | `lib/codex_pooler/gateway/openai_compatibility/responses/input/agent_message.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/normalization.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/validation.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler/gateway/openai_compatibility/responses_agent_message_test.exs`, `test/codex_pooler_web/controllers/v1/responses_agent_message_test.exs` | `/v1/responses` accepts `agent_message` input items only as a plaintext item (`author`, `recipient`, nonempty `input_text` content, optional `id` and passthrough) or as the exact sealed `NEW_TASK` or `MESSAGE` handoff the native route recognizes (`ContinuityPayload.v2_encrypted_handoff?/1`: one `input_text` envelope naming recipient and sender, then one nonblank `encrypted_content`), forwarded unchanged in Full and Lite mode (the provider reads both forms in a stateless request). Every other shape, other encrypted `agent_message` variants included, rejects before dispatch with `invalid_request` on `input` instead of being filtered. The ciphertext is never read, validated or persisted |
| Responses hosted web search history replay | `lib/codex_pooler/gateway/openai_compatibility/responses/input/web_search_call.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/normalization.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/validation.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler/gateway/openai_compatibility/responses_web_search_call_test.exs`, `test/codex_pooler_web/controllers/v1/responses_web_search_call_test.exs` | `/v1/responses` accepts `web_search_call` input items with exactly the keys the upstream validates (`type`, `id`, `status`, `action`, the optional passthrough object; action `search` with `query`, `queries`, `sources`, `open_page` with `url`, `find_in_page` with `url` and `pattern`) and forwards them unchanged in Full and Lite mode. Unknown keys, cross-variant keys, an unknown action type and a null in any field but the passthrough reject before dispatch with `invalid_request` on `input`; the public fallback id (`web_search_call` or `web_search_call_<n>`) is dropped on replay. Search queries and sources are never persisted |
| Responses hosted image generation history replay | `lib/codex_pooler/gateway/openai_compatibility/responses/input/image_generation_call.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/normalization.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses/input/validation.ex`, `lib/codex_pooler/accounting/pricing/resolution/image_projection.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler/gateway/openai_compatibility/responses_image_generation_call_test.exs`, `test/codex_pooler_web/controllers/v1/responses_image_generation_call_test.exs`, `test/codex_pooler/accounting/image_projection_test.exs`, `test/codex_pooler/accounting/image_reservation_test.exs` | `/v1/responses` accepts `image_generation_call` input items with exactly the keys the upstream validates (`type`, `id`, `status`, `action`, `background`, `output_format`, `quality`, `size`, `revised_prompt`, `result`, `encrypted_content`, the optional passthrough object) and forwards them unchanged in Full and Lite mode. `result` is a required nonblank string; `id`, `status` and `encrypted_content` are nonblank strings or null; the other fields are strings or null, with the values of `action`, `background`, `output_format` and `quality` left to the upstream's relayed `invalid_value`. Unknown keys, a missing or blank `result` and wrong value types reject before dispatch with `invalid_request` on `input`; the public fallback id (`image_generation_call` or `image_generation_call_<n>`) is dropped on replay. The reservation input estimate counts the base64 image as one fixed image allowance, not as text, and it is never persisted |
| Refused top-level Responses request fields | `lib/codex_pooler/gateway/openai_compatibility/matrix.ex`, `lib/codex_pooler/gateway/openai_compatibility/responses.ex`, `lib/codex_pooler/gateway/openai_compatibility/validation.ex`, `test/codex_pooler/gateway/openai_compatibility/core_test.exs`, `test/codex_pooler_web/controllers/v1/responses_refused_request_fields_test.exs` | `/v1/responses` recognizes `background`, `background_options`, `context_management`, `conversation`, `image`, `max_tool_calls`, `prompt` and `top_logprobs` and rejects each before upstream dispatch with `400 unsupported_parameter` and the field in `param`, over HTTP and in a Responses websocket `response.create`; a top-level field outside the adapter's field matrix is rejected the same way. None is forwarded or silently dropped. Public docs must not claim Codex-backed support for background processing windows, continuation priority, server-side compaction, conversations, prompt templates or request-level image compression |
| Unsupported `/v1` routes | `lib/codex_pooler_web/controllers/v1/unsupported_routes.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/v1/route_auth_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Explicit unsupported `/v1` routes return deterministic OpenAI-shaped unsupported endpoint errors before gateway dispatch |
| Exact policy-error exception | `lib/codex_pooler/gateway/transports/misalignment_policy_violation.ex`, `lib/codex_pooler/gateway/openai_compatibility/public_response.ex`, `test/support/compatibility_matrix.ex`, `test/codex_pooler_web/controllers/misalignment_policy_violation_http_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Only eligible direct `400` or `403`, and exact terminal SSE or websocket, `misalignment_policy_violation` errors are health-neutral and non-retryable. Public output keeps the exact code, `invalid_request_error`, and a nonblank message or fixed safe fallback, while parameters, bodies, and siblings remain excluded. Durable records keep the exact code, fixed accounting text, and bounded facts. Generic provider errors remain redacted |
| Beta Agents family refusal | `lib/codex_pooler_web/controllers/v1/unsupported_routes.ex`, `lib/codex_pooler_web/plugs/runtime_ingress.ex`, `test/support/compatibility_matrix.ex`, `test/fixtures/openai_compatibility/sdk_shapes/MATRIX.md`, `test/codex_pooler_web/controllers/v1/agents_unsupported_test.exs`, `test/codex_pooler_web/plugs/runtime_ingress_test.exs`, `test/codex_pooler_web/controllers/v1/route_auth_test.exs`, `test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs` | Every method and depth under `/v1/agents` and `/v1/vaults` answers `404 unsupported_endpoint` with the message `Unsupported OpenAI /v1 endpoint: the beta Agents API is not supported`, matched on the decoded path at a whole segment, after the firewall, the bearer key check and the Pool `/v1` compatibility gate and before body parsing, decompression, dispatch or accounting; the Codex backend serves no Agents route, and an Agents function definition is an ordinary Responses function tool |
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
