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
