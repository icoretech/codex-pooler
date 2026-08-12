# Final review fix report

## Status

DONE_WITH_CONCERNS. All eight findings in `final-review-findings.md` were implemented as one coherent fix wave from baseline `d218479c15ad7dad83672c079d9f318e9f24268d`. Every changed-file, focused, static, documentation, and source-leak gate is green. The full suite has one pre-existing `CodexPooler.MixTasks.DevServerLifecycleTest` process-liveness failure: it failed at baseline, failed in isolation at baseline, and is the sole failure in both final full runs.

No deployment, live-key revocation, or other live-state change was performed.

## Root-cause trace and resolution

### 1. Fail-open public projection

The old projection subtracted a short denylist from arbitrary upstream maps and returned malformed JSON/SSE bytes unchanged. Nested response, item, tool, chat, error, usage, and event values therefore retained unknown provider data or wrong-typed containers. Collected response callers also ignored projection failure or preserved the upstream success status.

Resolution:

- Rebuilt `PublicProjection` around explicit supported response, event, item, content, tool, error, usage, model, image, Ollama, transcription, file, and usage-report schemas.
- Unknown/malformed collected JSON now becomes a local protocol-shaped 502; status-aware upstream errors are normalized from safe local fields.
- Reconstructed SSE blocks from their projected event/data only, including canonical `[DONE]`; comments, IDs, retry fields, extra data lines, unknown fields, and original framing are not relayed.
- Validated scalar/container types recursively and retained arbitrary data only in documented content-bearing locations such as text, tool arguments, filenames, image data, and tool output.
- Patched both `GatewayControllerHelpers` and the active `PublicGatewayResult` path, while keeping route-specific local Ollama, Anthropic, media, transcription, and completion normalizers out of the OpenAI projector.
- Added an out-of-band websocket source-validation result for the exact `response.failed` canonicalizer. Raw input is validated first; only the existing specialized terminal reconstruction may convert a hostile failure into a safe terminal, and that terminal remains projector-idempotent.

### 2. Native HTTP/WS stream fail-open behavior

`DownstreamStream` relayed non-SSE and oversized incomplete native bytes. `WebsocketCodec` returned JSON scalar/raw data, silently dropped malformed records, and did not latch terminal failure; downstream settlement could still report success. One typed iodata edge could also bypass binary projection.

Resolution:

- Native Codex HTTP streaming accepts only bounded, projected SSE; non-SSE, malformed, unknown, wrong-typed, oversized, improper, or excessively deep iodata latches a sanitized local failure and drops all subsequent source bytes.
- Iodata validation bounds size to 64 MiB, nesting to 128, and traversed nodes to 1,000,000 before flattening.
- Native SSE emits the projector-returned safe block rather than normalizing/emitting the original source.
- Websocket SSE/direct JSON now rejects scalars, malformed/unknown objects, and oversized incomplete input, emits exactly one local safe frame, and retains a failed-buffer latch.
- The runtime writer treats the latch as terminal failure; direct, owner-forwarded, and bridged paths settle request, attempt, and Codex turn failed exactly once and suppress duplicate terminal frames.

### 3. Raw turn-state disclosure and broken continuity

The old header allowlist exposed upstream `x-codex-turn-state`. Local continuity either forwarded or hashed the public value and did not consume a trusted session/assignment anchor on reconnect, especially for GET websocket upgrade and frame-scoped `response.create.client_metadata` state.

Resolution:

- Added encrypted `cpts_` capabilities using `Plug.Crypto.MessageEncryptor`, scoped to version, raw upstream value, Pool, API key, selected assignment, optional session, and expiry.
- Raw input is capped at 2,048 bytes and the resulting handle at 4,096 bytes.
- Authenticated POST, GET websocket upgrade, and per-frame metadata resolve scope/expiry/tamper before dispatch; only the upstream header or frame receives the exact raw value.
- Routing hard-pins the active assignment and fails closed if unavailable.
- Session start locks the exact reconnectable session by ID, Pool, API key, and compatible assignment; missing/mismatched anchors do not silently create a session.
- Owner pre-retarget and generic HTTP continuity consume the resolved session anchor, preserving owner/session/accounting continuity.
- Finalization/streaming mint only with the selected candidate context; the public handle remains the provenance value.

### 4. Runtime ingress authentication ordering

Unsafe paths and thirteen pruned runtime helpers returned route-specific 400/404 responses before Pool API-key authentication, sometimes before the intended parser boundary.

Resolution:

- Preserved firewall first, then authenticate every runtime route before unsafe-path, pruned/unsupported-route, permission, decompression, parser, or controller work.
- Missing/invalid credentials receive the protocol-shaped 401; authenticated callers receive the fixed 400/404.
- Added raw HTTP and controller regressions proving malformed bodies are not parsed and upstream/accounting work is not started before authentication.

### 5. Anthropic count work outside admission

`/v1/messages/count_tokens` authenticated but performed validation and potentially expensive BPE counting without acquiring normal gateway admission.

Resolution:

- Wrapped validation/counting in `RouteClass.proxy_http()` admission.
- Preserved Anthropic error serialization.
- Tests prove overload rejects before tokenization and admission leases release on success and validation failure.

### 6. Provider signed file URLs exposed publicly

File create/finalize copied upstream signed upload/download URLs into public bodies. There was no local capability proxy, and public body reconstruction preserved arbitrary upstream siblings.

Resolution:

- Added encrypted `cpfc_` capabilities scoped to Pool, API key, file, assignment, identity, operation, declared bytes, provider URL, and expiry.
- Capabilities are at most 8,192 bytes, below the server request-line limit; local URLs are minted from the actual `conn.scheme/host/port`, never forwarded host or static Endpoint configuration.
- Public create/finalize bodies are freshly reconstructed exact schemas. Provider URLs and upstream extras are absent.
- Capability PUT/GET routes are bearer capabilities and therefore bypass Pool auth, but retain firewall and gateway admission. An optional presented Authorization header must match the embedded Pool/key scope.
- Upload bypasses the global JSON parser for exactly capability PUT, rejects content encoding, bounds `read_body` to declared bytes, spools to a private exclusive temp file, forwards server-side, and removes the file afterward.
- Download never redirects, validates provider response size, streams bounded bytes server-side, cancels invalid async responses, and never persists provider URL/content.
- Capability resolution verifies owned file record, operation-specific status, expiry, declared size, active API key, active Pool, assignment, and identity.
- Exact capability request paths are suppressed from both endpoint and completion logging. Error/log paths never interpolate the bearer or provider URL.

### 7. Public documentation private identifiers

The tracked docs-site authoring contract named exact private reasoning, transcription, and image identifiers even though the file was excluded from the built site.

Resolution:

- Replaced identifiers with role-based descriptions while retaining public `gemma3` and fixed `max` reasoning behavior.
- Updated compatibility contracts for auth ordering, opaque turn state, and local file capabilities.
- A tracked public README/docs-site scan has zero private-identifier matches. The approved internal `docs/superpowers` design/plan remains the private source of truth and is intentionally excluded from this public-source gate.

### 8. Broad compatibility and regression verification

Updated assertions that deliberately expected raw framing, raw custom siblings, signed URLs, raw turn state, or unauthenticated route absence. Existing content/tool execution, routing, retries, compaction, owner forwarding, accounting, cancellation, client compatibility, and usage semantics remain covered. Known public usage details remain; unknown nested details are removed.

## TDD red evidence

Focused tests were added before production changes and run against `d218479c`. The expected red failures were observed in these finding groups:

- Projection/HTTP/SSE: adversarial root and nested sentinels survived, wrong-typed nested values remained, malformed/scalar/unknown bodies retained upstream 2xx or raw bytes, SSE comments/extra framing survived, and the active public raw-result path ignored projection failure.
- Native streaming/websocket: non-SSE and oversized native chunks were returned verbatim; malformed/scalar/unknown websocket input was dropped or relayed without a failed latch; lifecycle settlement remained successful.
- Turn state: raw upstream state was returned, cross-key/Pool isolation was absent, GET/frame-scoped handles were not resolved, and reconnect created/retargeted by the opaque string instead of exact session/assignment.
- Runtime ingress: unauthenticated unsafe/pruned routes returned 400/404 before auth and malformed bodies could reach later handling.
- Count admission: overload did not prevent tokenization and no count-token lease lifecycle existed.
- Files: provider URLs appeared in public JSON; no opaque lifecycle route existed; JSON content-type PUT was consumed by the parser; capability request paths were loggable; cross-scope/tamper/expiry/method/status/size cases were not enforceable.
- Docs: `rg` found exact private identifiers in `docs-site/src/content/_docs-contract.md`.
- Final source audit iodata regression: `mix test test/codex_pooler/gateway/runtime/streaming/downstream_stream_test.exs:379` returned 0/1 with a `FunctionClauseError` because the unprojected list reached `String.split/3`.

Representative red commands used the same focused files now listed in the green section, checked out against `d218479c` where necessary. The exact expected failure for each was the unsafe data/status/dispatch behavior named above; no production change was made until its focused regression was red.

## Changed files

Production changes span:

- `lib/codex_pooler/gateway/facade/{public_projection,turn_state,file_capability,error}.ex`
- native/public streaming, websocket codec/session/dispatch/socket modules
- request continuity, routing, session persistence, finalization metadata, and service modules
- runtime ingress/parser/controller/result helpers and router/endpoint
- files context, file controller, and file bridge transport
- Anthropic messages controller
- docs-site contract and compatibility matrix

Focused regression and compatibility updates span the corresponding changed files under `test/codex_pooler`, `test/codex_pooler_web`, and `test/support`. `git diff --stat` before the report showed 66 tracked files changed plus five new production/test files; this report is intentionally force-added because `.superpowers/sdd` is report-ignored.

## Green verification evidence

### Focused and changed-file tests

- Projection/ingress/count focused suite: green before the turn-state/file work.
- Core projection/route batch: `465 passed` (seed `633220`, 8.8s).
- Mapped HTTP/controller batch: `521 passed` (seed `606001`, 47.7s).
- Mapped websocket batch: `334 passed` (seed `547768`, 30.4s).
- Specialized hostile failure and mapped websocket slice: `32 passed, 58 excluded` (seed `42083`, 1.8s).
- Bounded nested/improper/deep iodata regressions: `2 passed, 42 excluded` (seed `650368`, 0.4s).
- Impacted stream/websocket batch after iodata fix: `492 passed` (seed `442910`, 33.6s).
- New-file unit/parser batch: `5 passed` (seed `873922`, 0.1s).
- Final changed plus untracked test ledger:

  `files=$( { git diff --name-only -- test; git ls-files --others --exclude-standard -- test | rg '_test\\.exs$'; } | rg '_test\\.exs$' | sort -u | tr '\\n' ' '); docker exec -w /workspace codex-pooler-facade-dev mix test $files`

  Result: `1211 passed` (seed `888543`, 72.2s).

### Full suite and baseline comparison

- Baseline at `d218479c`: `6345/6346 passed`; sole failure `CodexPooler.MixTasks.DevServerLifecycleTest` line 48 (`refute process_alive?(pid)`). The isolated baseline test also failed.
- Early post-wave full suite: `6383/6384 passed` (seed `918763`, 294.3s); same sole lifecycle failure.
- Final full suite after all production changes:

  `docker exec -w /workspace codex-pooler-facade-dev mix test`

  Result: `6384/6385 passed` (seed `181820`, 302.9s); same sole lifecycle failure, no wave-related failures.

### Static, docs, and audit gates

- `git diff --check` — PASS.
- `docker exec -w /workspace codex-pooler-facade-dev mix format --check-formatted` — PASS.
- `docker exec -w /workspace codex-pooler-facade-dev mix compile --warnings-as-errors` — PASS; final changed compilation: one file.
- `docker exec -w /workspace codex-pooler-facade-dev mix quality.xref` — PASS.
- `cd docs-site && npm ci` — PASS; 580 packages audited, 0 vulnerabilities.
- `cd docs-site && npm run check` — PASS; 11 files, 0 errors, 0 warnings, 0 hints; dashboard check 47 panels/schemaVersion 41/34 metrics; ingress docs contract PASS.
- `cd docs-site && npm run build` — PASS; 42 pages built.
- `for script in $(git ls-files '*.sh'); do bash -n "$script"; done` — PASS for 8 tracked scripts.
- `rg -n --hidden 'gpt-5\\.6-sol|gpt-4o-transcribe|gpt-image-1' README.md README.zh-CN.md docs-site/src docs-site/public` — expected no-match exit 1, treated as PASS; zero private identifiers in tracked public README/docs-site sources.

## Self-review

- Traced public response construction through both controller helpers and `PublicGatewayResult`; no facade raw-body branch falls back to untrusted data.
- Traced SSE through projection, stream protocol, downstream relay, websocket codec, runtime writer, socket/owner terminal latches, and final accounting.
- Traced turn state from response minting through HTTP/GET/frame ingress, upstream substitution, routing hard pin, session locking, owner retarget, and public provenance.
- Traced file URLs from provider create/finalize through local mint, router/parser/firewall/admission, owned record resolution, bounded server-side transfer, response reconstruction, and log suppression.
- Searched projection callers and raw/passthrough branches; passthrough remains only for non-facade or locally transformed route-specific shapes.
- Reviewed untracked files, diff whitespace, public identifier scope, and security-sensitive URL/token logging paths.
- Preserved arbitrary content/tool arguments/file names at their explicit content locations; tests include sentinel values proving envelope removal without recursive text rewriting.

## Commit

All production, test, documentation, and report changes are contained in one descriptive fix commit. Its final SHA is returned with this report because a commit cannot embed its own SHA without changing that SHA.

## Concerns

- The full suite is not completely green because the same unrelated `DevServerLifecycleTest` process-liveness failure exists at baseline and persists in isolation. All 1,211 changed/new tests pass, and every other full-suite test passes.
- No live provider/client smoke test, deployment, or live-key revocation was authorized in this fix wave. Root will handle post-review/live verification.

## Second review fix wave (frozen baseline `3f4cffca`)

### Status and scope

DONE_WITH_CONCERNS. The consolidated second review was applied as a new fix wave on frozen commit `3f4cffcad38df69a010978e392e615868804e5ce`. The wave closes every technically confirmed projection, native SSE, websocket turn-state, signed-file transport, capability-liveness, private-spool, and logging item. It preserves the documented headerless single-purpose file capability as the one authentication exception while binding it to active Pool, key, file, assignment, identity, operation, declared size, and expiry. Optional presented Pool authorization must match the capability scope.

No deployment, live-provider request, credential revocation, or other live-state change was performed.

### Confirmed findings and repairs

#### Strict public schemas

- Supported response families now validate required and nested protocol fields before projection. A wrong-typed identity, discriminator, list, object, enum, numeric, boolean, or nullable field produces a local projection failure instead of being silently deleted from an upstream 2xx.
- Exact nullable locations remain nullable; analogous map/list mutations fail. The audit covers chat, Responses envelopes, items, content, usage, models, files, Ollama, compaction, text completion, images, catalog/discovery, rate limits, file search, web search, code execution, reasoning, shell, MCP, patch, namespace, and moderation families.
- Arbitrary data remains only at explicit content-bearing locations such as text and tool arguments. Unknown envelope siblings are dropped, while malformed identity-bearing fields fail before upstream dispatch.
- Collected HTTP, SSE, direct websocket, and owner-forwarded websocket tests assert one local safe failure and failed request/attempt/turn settlement, with later source bytes suppressed.

#### Native SSE overflow and EOF

- The bounded incremental parser emits a dedicated opaque overflow marker even when complete blocks precede an oversized tail.
- Once emitted, the marker is a terminal parser state: later chunks cannot append raw residue or erase its exact identity.
- Same-chunk and fragmented valid-plus-overflow tails fail exactly once. Any nonempty native residue at clean EOF, including an under-limit fragment, also emits one safe terminal and settles request, attempt, and Codex turn failed.
- Complete valid native blocks remain visible before the terminal local failure; no raw malformed/oversized residue is relayed.

#### Websocket frame turn state

- Client-supplied frame continuity accepts only authenticated `cpts_` handles. Unknown raw strings, malformed metadata containers, cross-key handles, and tampered handles fail before dispatch, alias mutation, or session mutation in direct and owner-forwarded paths.
- Resolution restores the exact upstream raw token only in the upstream frame, applies the embedded active assignment hard pin, and consumes the exact embedded session anchor.
- Server-issued local websocket session markers remain internal and are stripped from upstream/public payloads and persistence. Reconnect tests mint through the real `TurnState` path and assert exact session and assignment continuity; stale raw-forward/register expectations were removed.

#### Signed file transport and capability liveness

- Every signed URL use validates syntax/scheme/port and resolves both A and AAAA. The whole answer set must be public; mixed public/private, private IPv6, malformed answers, and rebinding are rejected locally.
- The selected validated address is placed in the connection URL so the HTTP client cannot re-resolve the provider hostname. The original hostname remains the HTTP Host value and the explicit TLS verification/SNI hostname. Redirects and retries remain disabled, and resolution is repeated for each use.
- Deterministic resolver/adapter tests assert pinned-IP dispatch, original Host/hostname, mixed A/AAAA rejection, private rebind rejection before adapter invocation, and no fallback connection.
- Capability use-time resolution requires the owned operation-specific file state plus active/nonexpired API key, active Pool, active matching assignment and identity, present usable credential, exact declared size, and decryptable nonempty secret.
- Upload spooling creates a randomized private `0700` directory, then an exclusive `0600` file before body bytes are written. Body size and content encoding remain bounded/rejected at the controller boundary.
- Transport logs retain only a constant `transport_error` reason and safe class/context. Tests prove arbitrary reason, signed query, URL hostname, signature sentinel, and capability bearer do not appear in transport or request logs.
- The public contract explicitly documents the headerless capability exception and its scope/liveness restrictions; optional presented authorization must match.

### Second-wave TDD evidence

Each confirmed production change followed a focused red/green cycle:

- Projection/native SSE starting slice: `67/70 passed` before fixes; the malformed chat/nested-type and overflow cases were the expected failures. After strict schemas and overflow handling: `71/71 passed`, then the EOF lifecycle regression failed `0/1` with successful settlement before its repair and the expanded slice passed `73/73`.
- Frame-scoped state: arbitrary raw state initially dispatched (`0/1`); after the `cpts_`-only gate the focused test passed `1/1`, and the direct/owner marker slice passed `4/4`.
- DNS validation module: `0/4` before `SignedUrlTarget`; `4/4` after. Connection-boundary adapter tests were `0/2` before pin wiring and the combined resolver/connection slice passed `6/6` after.
- Capability liveness: `0/3` before active assignment/identity/key/credential checks; `3/3` after.
- Private spool: `0/1` before the module existed; `1/1` after creation-before-write permission enforcement.
- Transport secrecy: the new arbitrary-reason test was `0/1` because its signature sentinel appeared in the log; it passed `1/1` after constant-reason normalization.
- Schema mutation audit: the initial eight-family table exposed item, model, and file silent deletion; the fourteen-family follow-up exposed compaction, completion, image, catalog, rate-limit, caller, search, code, reasoning, shell, MCP, patch, and turn-ID cases. Both tables passed after exact validators. Nullable-versus-container and file-finalize mutations also failed before their exact validators and passed afterward.
- First changed/new ledger: `331/332 passed`; the remaining stale malformed-frame case exposed a list-valued metadata dispatch. After its fail-before-dispatch clause: `332/332 passed` (seed `0`). Auth/count regressions passed `146/146` (seed `0`).
- Expanded compatibility ledger initially passed `1228/1235`; the seven failures were intentional stale/exact-schema expectations (overflow residue, nullable namespace, moderation status, malformed numeric identity, and owner raw turn state). After exact fixes and minted-handle fixtures: `1238/1238 passed` (seed `0`, 77.1s).
- Final incremental overflow latch regression: `docker exec -w /workspace codex-pooler-facade-dev mix test test/codex_pooler/gateway/transports/sse_parser_incremental_test.exs:346 --seed 0` failed `0/1` because later chunks produced `overflow-marker <> raw`; after the terminal marker clause the full file passed `9/9` (seed `0`).

### Final second-wave verification

- Changed/new files after the final parser repair:

  `docker exec -w /workspace codex-pooler-facade-dev mix test test/codex_pooler/files/capability_resolution_test.exs test/codex_pooler/files/capability_spool_test.exs test/codex_pooler/files/signed_url_target_test.exs test/codex_pooler/gateway/facade/public_projection_test.exs test/codex_pooler/gateway/runtime/streaming/downstream_stream_test.exs test/codex_pooler/gateway/runtime/streaming/stream_lifecycle_test.exs test/codex_pooler/gateway/transports/file_bridge_test.exs test/codex_pooler/gateway/transports/sse_parser_incremental_test.exs test/codex_pooler/gateway/transports/stream_protocol_test.exs test/codex_pooler/gateway/transports/upstream_websocket_session_test.exs test/codex_pooler_web/controllers/facade_transport_leakage_test.exs test/codex_pooler_web/controllers/runtime/backend_codex_websocket_owner_forwarding_test.exs test/codex_pooler_web/controllers/runtime/backend_codex_websocket_test.exs test/codex_pooler_web/controllers/runtime/compatibility_contract_test.exs --seed 0`

  Result: `536 passed` (seed `0`, 35.9s).

- Final full suite:

  `docker exec -w /workspace codex-pooler-facade-dev mix test --seed 0`

  Result: `6409/6410 passed` (seed `0`, 297.5s). The sole failure is the same baseline `CodexPooler.MixTasks.DevServerLifecycleTest` line 48 process-liveness teardown exception already documented in the first wave. The first second-wave full run was `6408/6410`: it contained that baseline exception plus the stale incremental reference assertion; the final parser test/repair removed the latter.

- `git diff --check` — PASS.
- `docker exec -w /workspace codex-pooler-facade-dev mix format --check-formatted` — PASS.
- `docker exec -w /workspace codex-pooler-facade-dev sh -lc 'MIX_ENV=test mix compile --warnings-as-errors'` — PASS; one final changed file compiled.
- `docker exec -w /workspace codex-pooler-facade-dev mix quality.xref` — PASS.
- `cd docs-site && npm ci` — PASS; 580 packages audited, 0 vulnerabilities.
- `cd docs-site && npm run check` — PASS; 11 files, 0 errors/warnings/hints; dashboard and ingress contract checks pass.
- `cd docs-site && npm run build` — PASS; 42 pages built.
- `for script in $(git ls-files '*.sh'); do bash -n "$script"; done` — PASS for eight tracked scripts.
- `rg -n --hidden 'gpt-5\\.6-sol|gpt-4o-transcribe|gpt-image-1' README.md README.zh-CN.md docs-site/src docs-site/public` — expected no-match exit 1; zero private identifiers in tracked public sources.

### Second-wave concern

- The full suite remains `6409/6410`, not completely green, solely because the same unrelated dev-server lifecycle process-liveness teardown assertion failed on the original baseline and in both review waves. No façade/security regression failed in the final full run.
- DNS pinning, TLS hostname retention, proxy byte flow, and rebinding rejection are deterministically covered with injected resolvers/adapters. A real live provider signed-URL transfer was not authorized, so live provider DNS/TLS behavior remains a post-review smoke-test concern for root.
