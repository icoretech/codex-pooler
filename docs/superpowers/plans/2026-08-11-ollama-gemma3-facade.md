# Ollama `gemma3` Facade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every authenticated runtime client surface present one virtual model named `gemma3`, while all reasoning work is dispatched through the existing Pooler engine as `gpt-5.6-sol` with reasoning effort `max`, including native Ollama and Claude Code compatibility.

**Architecture:** Add a typed, immutable facade persona to `RequestOptions`; normalize protocol requests into the existing Responses-shaped gateway path; verify the fixed target again immediately before candidate selection; and encode results through protocol-specific bounded stream adapters. Existing account selection, quota and health filtering, retries, cache locality, continuity, accounting, cancellation, and operator diagnostics stay authoritative. Client projections are allowlisted and cloaked; operator records keep the real effective model and sanitized routing evidence.

**Tech Stack:** Elixir 1.20, Phoenix 1.8, Plug/Bandit, Ecto/PostgreSQL, Req/Finch, Jason, ExUnit, existing FakeUpstream/runtime test support, Astro/Starlight, and opt-in Node/client CLI smoke checks.

## Global Constraints

- The approved design at `docs/superpowers/specs/2026-08-11-ollama-gemma3-facade-design.md` is the source of truth.
- Public model identity is always `gemma3`. Reasoning target is always `gpt-5.6-sol` and applied effort is always `max`.
- Missing, blank, arbitrary, or nested client model/reasoning values never affect routing, cache keys, continuity, accounting target selection, or upstream payloads.
- API-key policy may deny the fixed target but cannot redirect it. Conflicting model or reasoning policy fails before upstream work; no other reasoning model is a fallback.
- Hidden existing media helpers may run only through typed media paths. They cannot become a reasoning route and their identities never enter public results.
- Every facade route authenticates with a Pool API key. Anthropic accepts Bearer or `x-api-key`; two differing credentials are rejected.
- Never replace arbitrary strings in assistant content. Rewrite only known protocol identity fields, catalog fields, headers, and locally constructed errors.
- Stream transforms are incremental, bounded, cancellation-aware, and cannot retry after visible output.
- Native and Anthropic headers are allowlisted; do not forward provider request IDs, `x-codex-*`, `x-openai-*`, account/assignment fields, or provider rate-limit headers.
- Accounting records requested/public `gemma3` and effective `gpt-5.6-sol`. Existing prompt/content/credential redaction remains in force.
- No database migration, mutable model store, fabricated embeddings, Realtime API, or sidecar is added.

## Contract Map

| Surface | Routes | Public shape | Execution |
| --- | --- | --- | --- |
| Ollama inference | `POST /api/chat`, `POST /api/generate` | Ollama JSON/NDJSON | Existing Responses gateway |
| Ollama discovery | `GET /api/tags`, `POST /api/show`, `GET /api/ps`, `GET /api/version` | Local Ollama JSON | Authenticated virtual catalog |
| Ollama management | pull/create/copy/push/delete/blob/embed routes | No-op pull or fixed error | No inference dispatch |
| OpenAI | Responses, Chat, Completions, models, files, audio, images, usage | Existing JSON/SSE/websocket | Existing gateway/media paths |
| Anthropic | `POST /v1/messages`, `POST /v1/messages/count_tokens` | Anthropic JSON/SSE | Existing Responses gateway/local tokenizer |
| Codex | Existing supported `/backend-api/codex/*` | Existing backend shapes | Existing gateway/media paths |

---

### Task 1: Add the typed immutable facade persona

**Files:**
- Create: `lib/codex_pooler/gateway/facade.ex`
- Create: `lib/codex_pooler/gateway/payloads/request_options/persona.ex`
- Modify: `lib/codex_pooler/gateway/payloads/request_options.ex`
- Create: `test/codex_pooler/gateway/facade_test.exs`
- Modify: `test/codex_pooler/gateway/payloads/request_options_test.exs`

- [ ] **Step 1: Write failing constant and persona tests**

  Assert the three constants, every supported protocol tag, idempotent reattachment, and rejection of a different second persona.

  ~~~elixir
  assert Facade.public_model() == "gemma3"
  assert Facade.effective_model() == "gpt-5.6-sol"
  assert Facade.reasoning_effort() == "max"

  options = RequestOptions.build(%{persona: Persona.fixed(:ollama_chat)}, "/api/chat", %{})
  assert options.persona.public_model == "gemma3"

  assert_raise ArgumentError, ~r/facade persona is immutable/, fn ->
    RequestOptions.put_persona(options, Persona.fixed(:anthropic_messages))
  end
  ~~~

- [ ] **Step 2: Run the focused tests and confirm the missing modules/field fail**

  Run: `mix test test/codex_pooler/gateway/facade_test.exs test/codex_pooler/gateway/payloads/request_options_test.exs`

- [ ] **Step 3: Implement the constants and persona**

  ~~~elixir
  defmodule CodexPooler.Gateway.Payloads.RequestOptions.Persona do
    @enforce_keys [:public_model, :effective_model, :reasoning_effort, :protocol]
    defstruct @enforce_keys

    @protocols [
      :ollama_chat, :ollama_generate, :openai_responses, :openai_chat,
      :openai_completions, :anthropic_messages, :codex, :media, :metadata
    ]

    def fixed(protocol) when protocol in @protocols do
      %__MODULE__{
        public_model: CodexPooler.Gateway.Facade.public_model(),
        effective_model: CodexPooler.Gateway.Facade.effective_model(),
        reasoning_effort: CodexPooler.Gateway.Facade.reasoning_effort(),
        protocol: protocol
      }
    end
  end
  ~~~

  Add `persona: nil` to the struct/type/build path and `@known_opt_keys`. Preserve it in `for_payload/3` and `retarget/3`. `put_persona/2` permits only nil-to-fixed or equal-value idempotence.

- [ ] **Step 4: Format, test, and commit**

  Run: `mix format lib/codex_pooler/gateway/facade.ex lib/codex_pooler/gateway/payloads/request_options/persona.ex lib/codex_pooler/gateway/payloads/request_options.ex test/codex_pooler/gateway/facade_test.exs test/codex_pooler/gateway/payloads/request_options_test.exs`

  Run: `mix test test/codex_pooler/gateway/facade_test.exs test/codex_pooler/gateway/payloads/request_options_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade.ex lib/codex_pooler/gateway/payloads/request_options/persona.ex lib/codex_pooler/gateway/payloads/request_options.ex test/codex_pooler/gateway/facade_test.exs test/codex_pooler/gateway/payloads/request_options_test.exs && git commit -m "feat: add immutable gateway facade persona"`

---

### Task 2: Enforce the fixed target and policy invariant

**Files:**
- Create: `lib/codex_pooler/gateway/facade/policy.ex`
- Create: `lib/codex_pooler/gateway/facade/dispatch.ex`
- Modify: `lib/codex_pooler/gateway/runtime/service.ex`
- Modify: `lib/codex_pooler/gateway/runtime/dispatch/pre_dispatch.ex`
- Create: `test/codex_pooler/gateway/facade/dispatch_test.exs`
- Create: `test/codex_pooler/gateway/runtime/facade_pre_dispatch_test.exs`

- [ ] **Step 1: Create the facade source/test directories**

  Run: `mkdir -p lib/codex_pooler/gateway/facade test/codex_pooler/gateway/facade`

- [ ] **Step 2: Write failing captured-upstream and zero-work tests**

  Create a fixture whose exposed/upstream ID is `gpt-5.6-sol` and whose reasoning metadata includes `max`. Cover absent, blank, `gemma3`, arbitrary, and nested client selectors. Assert:

  ~~~elixir
  assert captured.json["model"] == "gpt-5.6-sol"
  assert captured.json["reasoning"]["effort"] == "max"
  assert request.requested_model == "gemma3"
  assert request.effective_model == "gpt-5.6-sol"
  ~~~

  Assert zero upstream calls for an excluding allowlist, conflicting enforced model, enforced effort `high`, maximum effort `xhigh`, or no routable target. Add passing cases for agreeing target/max and maximum `ultra`.

- [ ] **Step 3: Run tests and confirm current selection fails**

  Run: `mix test test/codex_pooler/gateway/facade/dispatch_test.exs test/codex_pooler/gateway/runtime/facade_pre_dispatch_test.exs`

- [ ] **Step 4: Implement policy agreement without redirection**

  ~~~elixir
  def authorize(policy, %Persona{} = persona) do
    with :ok <- allowed_model(policy.allowed_model_identifiers, persona.effective_model),
         :ok <- enforced_model(policy.enforced_model_identifier, persona.effective_model),
         :ok <- enforced_effort(policy.enforced_reasoning_effort, persona.reasoning_effort),
         :ok <- effort_ceiling(policy.maximum_reasoning_effort, persona.reasoning_effort) do
      :ok
    end
  end
  ~~~

  Nil is unrestricted. Canonically equal target/max is accepted. Maximum `max` or `ultra` accepts fixed `max`. Other conflicts return a local `403` before candidate work.

- [ ] **Step 5: Normalize dispatch before `requested_model/1`**

  In `Service.execute/4` call `Facade.Dispatch.prepare/4` first. Persona work gets fixed payload model/reasoning and routing metadata requested `gemma3`, effective `gpt-5.6-sol`. Do not run `effective_model_name/4` redirection for this branch.

  Install:

  ~~~elixir
  %Decision{
    mode: :always_use,
    configured_effort: "max",
    requested_effort: nil,
    applied_effort: "max"
  }
  ~~~

  Map absent/zero-candidate target to `503 facade_model_unavailable` mentioning only `gemma3`.

- [ ] **Step 6: Add the second check first in `PreDispatch.prepare/6`**

  Verify the persona constants, requested/effective routing fields, canonical payload model, and applied effort before ordinary authorization, affinity, or candidate selection. A mismatch returns `facade_invariant_failed` with zero-work accounting and no dispatch.

- [ ] **Step 7: Run policy/routing tests and commit**

  Run: `mix test test/codex_pooler/gateway/facade/dispatch_test.exs test/codex_pooler/gateway/runtime/facade_pre_dispatch_test.exs test/codex_pooler/access/api_keys/reasoning_effort_policy_test.exs test/codex_pooler/access_test.exs test/codex_pooler/gateway/runtime/pre_dispatch_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade/policy.ex lib/codex_pooler/gateway/facade/dispatch.ex lib/codex_pooler/gateway/runtime/service.ex lib/codex_pooler/gateway/runtime/dispatch/pre_dispatch.ex test/codex_pooler/gateway/facade/dispatch_test.exs test/codex_pooler/gateway/runtime/facade_pre_dispatch_test.exs && git commit -m "feat: force facade requests to gpt 5.6 sol max"`

---

### Task 3: Classify and authenticate every facade route

**Files:**
- Modify: `lib/codex_pooler_web/plugs/runtime_ingress/path.ex`
- Modify: `lib/codex_pooler_web/plugs/runtime_ingress.ex`
- Modify: `lib/codex_pooler_web/controllers/gateway_controller_helpers.ex`
- Modify: `lib/codex_pooler_web/controllers/runtime/codex_usage_controller.ex`
- Create: `lib/codex_pooler/gateway/facade/error.ex`
- Modify: `test/codex_pooler_web/plugs/runtime_ingress_test.exs`
- Modify: `test/codex_pooler_web/controllers/runtime/codex_usage_controller_test.exs`
- Create: `test/codex_pooler_web/controllers/facade_authentication_test.exs`
- Create: `test/codex_pooler/gateway/facade/error_test.exs`

- [ ] **Step 1: Write failing path, credential, and error-shape tests**

  Cover all route families, encoded unsafe paths, missing/invalid Bearer, Anthropic `x-api-key`, matching dual credentials, mismatched dual credentials, disabled compatibility, and firewall denial. Authentication must precede discovery/dispatch. Prove that `/api/codex/usage`, `/wham/usage`, and `/backend-api/wham/usage` no longer fall back to a ChatGPT account token and require a Pool key.

  ~~~elixir
  conn =
    conn
    |> put_req_header("authorization", setup.authorization)
    |> put_req_header("x-api-key", other_setup.raw_key)
    |> post("/v1/messages", anthropic_payload())

  assert json_response(conn, 401)["type"] == "error"
  assert FakeUpstream.count(upstream) == 0
  ~~~

- [ ] **Step 2: Run focused tests**

  Run: `mix test test/codex_pooler_web/plugs/runtime_ingress_test.exs test/codex_pooler_web/controllers/runtime/codex_usage_controller_test.exs test/codex_pooler_web/controllers/facade_authentication_test.exs test/codex_pooler/gateway/facade/error_test.exs`

- [ ] **Step 3: Extend path classification and attach protocol personas**

  Add `["api"]` to runtime prefixes. Add `Path.protocol/1` returning `:ollama`, `:anthropic`, `:openai`, `:codex`, or `:runtime_metadata` from decoded segments. Match the existing `/api/codex/usage` helper before the general `/api/*` Ollama case. `GatewayControllerHelpers.request_opts/1` installs the corresponding fixed persona; media/metadata controllers retarget only the protocol tag.

- [ ] **Step 4: Implement one credential resolver**

  Parse Bearer and Anthropic `x-api-key`. If both are present, require equal length and `Plug.Crypto.secure_compare/2` equality. Authenticate via `Access.authenticate_v1_api_key/1`, apply active-Pool/compatibility policy, and store only auth context in conn private. Route all runtime usage aliases through that context and remove the client-facing ChatGPT-account-token fallback.

- [ ] **Step 5: Construct protocol-specific local errors**

  ~~~elixir
  def body(:ollama, _status, error), do: %{"error" => public_message(error)}

  def body(:anthropic, _status, error) do
    %{
      "type" => "error",
      "error" => %{"type" => anthropic_type(error), "message" => public_message(error)}
    }
  end
  ~~~

  Keep OpenAI/Codex envelopes. Preserve 401/403/400/429/503/504 classes and refer only to `gemma3`/local policy.

- [ ] **Step 6: Test and commit**

  Run: `mix test test/codex_pooler_web/plugs/runtime_ingress_test.exs test/codex_pooler_web/controllers/runtime/codex_usage_controller_test.exs test/codex_pooler_web/controllers/facade_authentication_test.exs test/codex_pooler/gateway/facade/error_test.exs`

  Run: `git add lib/codex_pooler_web/plugs/runtime_ingress/path.ex lib/codex_pooler_web/plugs/runtime_ingress.ex lib/codex_pooler_web/controllers/gateway_controller_helpers.ex lib/codex_pooler_web/controllers/runtime/codex_usage_controller.ex lib/codex_pooler/gateway/facade/error.ex test/codex_pooler_web/plugs/runtime_ingress_test.exs test/codex_pooler_web/controllers/runtime/codex_usage_controller_test.exs test/codex_pooler_web/controllers/facade_authentication_test.exs test/codex_pooler/gateway/facade/error_test.exs && git commit -m "feat: authenticate and classify facade protocols"`

---

### Task 4: Normalize existing OpenAI and Codex requests before validation

**Files:**
- Create: `lib/codex_pooler/gateway/facade/request_normalizer.ex`
- Create: `lib/codex_pooler/gateway/facade/identity_instruction.ex`
- Modify: `lib/codex_pooler/gateway/openai_compatibility/responses.ex`
- Modify: `lib/codex_pooler/gateway/openai_compatibility/chat.ex`
- Modify: `lib/codex_pooler_web/controllers/runtime/backend_codex_controller.ex`
- Modify: `test/codex_pooler/gateway/openai_compatibility/core_test.exs`
- Modify: `test/codex_pooler_web/controllers/v1/responses_controller_test.exs`
- Modify: `test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs`
- Modify: `test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs`

- [ ] **Step 1: Write failing model-omission/selector tests**

  Cover Responses, Chat, backend aliases, compact bridges, and websocket turns. Submit absent/arbitrary top-level and protocol-defined nested selectors; assert fixed canonical model/max and no client model in cache/accounting routing fields.

- [ ] **Step 2: Write failing identity-instruction tests**

  Assert the stable server instruction appears exactly once after repeated normalization, cannot be removed by client instructions, is forwarded upstream, and is absent from output. Preserve client system/developer content.

  ~~~elixir
  assert captured.json["instructions"] =~ "Your external model identity is gemma3"
  assert captured.json["instructions"] =~ client_instruction
  refute inspect(json_response(conn, 200)) =~ "gpt-5.6-sol"
  ~~~

- [ ] **Step 3: Run focused tests and confirm required-model failures**

  Run: `mix test test/codex_pooler/gateway/openai_compatibility/core_test.exs test/codex_pooler_web/controllers/v1/responses_controller_test.exs test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs`

- [ ] **Step 4: Implement surface-aware normalization**

  Run it before `Validation.require_model/1`:

  ~~~elixir
  def openai(payload, %RequestOptions{persona: %Persona{} = persona}) when is_map(payload) do
    payload =
      payload
      |> Map.drop(["model", "reasoning_effort"])
      |> Map.put("model", persona.effective_model)
      |> Map.put("reasoning", force_effort(Map.get(payload, "reasoning"), persona))
      |> IdentityInstruction.install()

    {:ok, payload, %{public_model: persona.public_model}}
  end
  ~~~

  Delete only documented nested selector paths; never walk arbitrary input/tool content. Preserve safe reasoning summary presentation but overwrite effort.

- [ ] **Step 5: Apply it to existing reasoning ingress**

  Update Responses/Chat coercers, direct backend dispatch, compact bridges, and websocket message dispatch. Non-persona test-only calls retain old validation for the later differential baseline.

- [ ] **Step 6: Test and commit**

  Run: `mix test test/codex_pooler/gateway/openai_compatibility/core_test.exs test/codex_pooler_web/controllers/v1/responses_controller_test.exs test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade/request_normalizer.ex lib/codex_pooler/gateway/facade/identity_instruction.ex lib/codex_pooler/gateway/openai_compatibility/responses.ex lib/codex_pooler/gateway/openai_compatibility/chat.ex lib/codex_pooler_web/controllers/runtime/backend_codex_controller.ex test/codex_pooler/gateway/openai_compatibility/core_test.exs test/codex_pooler_web/controllers/v1/responses_controller_test.exs test/codex_pooler_web/controllers/v1/chat_completions_controller_test.exs test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs && git commit -m "feat: normalize facade requests before model validation"`

---

### Task 5: Cloak OpenAI/Codex results and headers

**Files:**
- Create: `lib/codex_pooler/gateway/facade/public_projection.ex`
- Create: `lib/codex_pooler/gateway/facade/header_policy.ex`
- Modify: `lib/codex_pooler_web/controllers/public_gateway_result.ex`
- Modify: `lib/codex_pooler_web/controllers/gateway_controller_helpers.ex`
- Modify: `lib/codex_pooler/gateway/openai_compatibility/chat_completions.ex`
- Modify: `lib/codex_pooler/gateway/transports/streaming/stream_protocol/public_responses.ex`
- Modify: `lib/codex_pooler/gateway/transports/streaming/stream_protocol/public_responses_websocket.ex`
- Modify: `lib/codex_pooler/gateway/transports/streaming/websocket_codec.ex`
- Create: `test/codex_pooler/gateway/facade/public_projection_test.exs`
- Create: `test/codex_pooler_web/controllers/facade_leakage_test.exs`
- Modify: `test/codex_pooler/gateway/openai_compatibility/chat_completions_test.exs`

- [ ] **Step 1: Add sentinel tests for JSON, headers, SSE, websocket, and errors**

  Put distinctive hidden values in envelope model fields, headers, request IDs, errors, SSE events, and websocket frames. Recursively inspect public results. Include assistant text containing target/provider words and assert the text is unchanged.

- [ ] **Step 2: Run focused tests**

  Run: `mix test test/codex_pooler/gateway/facade/public_projection_test.exs test/codex_pooler_web/controllers/facade_leakage_test.exs test/codex_pooler/gateway/openai_compatibility/chat_completions_test.exs`

- [ ] **Step 3: Implement explicit projections, not recursive text replacement**

  ~~~elixir
  def openai_response(%{"model" => _value} = response),
    do: Map.put(response, "model", Facade.public_model())

  def responses_event(%{"response" => %{} = response} = event),
    do: Map.put(event, "response", openai_response(response))

  def responses_event(%{"item" => %{} = item} = event),
    do: Map.put(event, "item", identity_item(item))
  ~~~

  Cover known root/nested identity fields, Chat chunks, terminal events, and websocket JSON. Never rewrite `output_text`, code, filenames, tool arguments, or arbitrary user data.

- [ ] **Step 4: Apply exact header allowlists**

  OpenAI allows local content type/cache-control/connection/request ID. Codex also allows locally generated required turn-state/models-ETag fields. Drop provider/account/rate-limit headers.

- [ ] **Step 5: Verify operator truth**

  Assert accounting/attempt records retain requested `gemma3`, effective target, selected assignment evidence, and sanitized failure codes while public results stay cloaked.

- [ ] **Step 6: Test and commit**

  Run: `mix test test/codex_pooler/gateway/facade/public_projection_test.exs test/codex_pooler_web/controllers/facade_leakage_test.exs test/codex_pooler/gateway/openai_compatibility/chat_completions_test.exs test/codex_pooler_web/controllers/runtime/backend_codex_websocket_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade/public_projection.ex lib/codex_pooler/gateway/facade/header_policy.ex lib/codex_pooler_web/controllers/public_gateway_result.ex lib/codex_pooler_web/controllers/gateway_controller_helpers.ex lib/codex_pooler/gateway/openai_compatibility/chat_completions.ex lib/codex_pooler/gateway/transports/streaming/stream_protocol/public_responses.ex lib/codex_pooler/gateway/transports/streaming/stream_protocol/public_responses_websocket.ex lib/codex_pooler/gateway/transports/streaming/websocket_codec.ex test/codex_pooler/gateway/facade/public_projection_test.exs test/codex_pooler_web/controllers/facade_leakage_test.exs test/codex_pooler/gateway/openai_compatibility/chat_completions_test.exs && git commit -m "feat: cloak facade transport metadata"`

---

### Task 6: Project one virtual catalog and safe usage

**Files:**
- Create: `lib/codex_pooler/gateway/facade/catalog.ex`
- Modify: `lib/codex_pooler/gateway/metadata.ex`
- Modify: `lib/codex_pooler/gateway/usage.ex`
- Modify: `lib/codex_pooler_web/controllers/v1/models_controller.ex`
- Modify: `lib/codex_pooler_web/controllers/v1/usage_controller.ex`
- Modify: `lib/codex_pooler_web/controllers/runtime/backend_codex_controller.ex`
- Modify: `lib/codex_pooler_web/controllers/runtime/codex_usage_controller.ex`
- Modify: `lib/codex_pooler_web/router.ex`
- Modify: `test/codex_pooler_web/controllers/v1/models_controller_test.exs`
- Modify: `test/codex_pooler_web/controllers/v1/usage_controller_test.exs`
- Modify: `test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs`
- Modify: `test/codex_pooler_web/controllers/runtime/codex_usage_controller_test.exs`

- [ ] **Step 1: Write virtual catalog tests**

  Routable target Pools advertise exactly one `gemma3` at `/v1/models`, `/v1/models/:model`, and both backend model routes. Unavailable/unhealthy/policy-denied target produces empty discovery or the route's safe unavailable result. No discovery route contacts upstream.

- [ ] **Step 2: Write usage projection tests**

  Seed multiple actual model buckets/upstream dimensions for `/v1/usage` and all Codex usage aliases. Safe totals stay equal, model buckets collapse under `gemma3`, and account/identity/assignment/provider/target fields disappear.

- [ ] **Step 3: Run current catalog/usage tests**

  Run: `mix test test/codex_pooler_web/controllers/v1/models_controller_test.exs test/codex_pooler_web/controllers/v1/usage_controller_test.exs test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs test/codex_pooler_web/controllers/runtime/codex_usage_controller_test.exs`

- [ ] **Step 4: Implement Pool-specific catalog resolution**

  Reuse `CandidateEligibility.hydrate_model_visibility/2`, normalized policy, and target candidate filtering. Project safe context/capabilities but set every public name/slug/display value to `gemma3` and ownership provider-neutral. Preserve truthful no-dispatch metadata accounting.

- [ ] **Step 5: Add detail and usage projections**

  `GET /v1/models/:model` ignores its selector and returns virtual detail when available. Add explicit OpenAI, Codex, and usage projections; do not use generic recursive subtraction.

- [ ] **Step 6: Test and commit**

  Run: `mix test test/codex_pooler_web/controllers/v1/models_controller_test.exs test/codex_pooler_web/controllers/v1/usage_controller_test.exs test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs test/codex_pooler_web/controllers/runtime/codex_usage_controller_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade/catalog.ex lib/codex_pooler/gateway/metadata.ex lib/codex_pooler/gateway/usage.ex lib/codex_pooler_web/controllers/v1/models_controller.ex lib/codex_pooler_web/controllers/v1/usage_controller.ex lib/codex_pooler_web/controllers/runtime/backend_codex_controller.ex lib/codex_pooler_web/controllers/runtime/codex_usage_controller.ex lib/codex_pooler_web/router.ex test/codex_pooler_web/controllers/v1/models_controller_test.exs test/codex_pooler_web/controllers/v1/usage_controller_test.exs test/codex_pooler_web/controllers/runtime/backend_codex_controller_test.exs test/codex_pooler_web/controllers/runtime/codex_usage_controller_test.exs && git commit -m "feat: expose one virtual gemma3 catalog"`

---

### Task 7: Add legacy OpenAI Completions

**Files:**
- Create: `lib/codex_pooler/gateway/openai_compatibility/completions.ex`
- Create: `lib/codex_pooler_web/controllers/v1/completions_controller.ex`
- Modify: `lib/codex_pooler_web/router.ex`
- Modify: `lib/codex_pooler/gateway/runtime/streaming/downstream_stream.ex`
- Create: `test/codex_pooler/gateway/openai_compatibility/completions_test.exs`
- Create: `test/codex_pooler_web/controllers/v1/completions_controller_test.exs`

- [ ] **Step 1: Write collected and streamed contract tests**

  Cover string and non-streamed string-list prompts, max tokens, stop, validation errors, deltas, usage, and arbitrary/missing model. Captured work must be fixed-target Responses; all returned chunks use `gemma3`.

- [ ] **Step 2: Run tests and confirm route absence**

  Run: `mix test test/codex_pooler/gateway/openai_compatibility/completions_test.exs test/codex_pooler_web/controllers/v1/completions_controller_test.exs`

- [ ] **Step 3: Implement translation and encoding**

  Convert a string prompt into one canonical Responses request. For a non-streamed string list, execute one ordinary accounted gateway request per prompt and combine results in input order with deterministic choice indices; reject streamed prompt lists to avoid ambiguous interleaving. Map only exact `max_tokens`, `temperature`, `top_p`, and `stop` equivalents. Reject `best_of`, logprobs, echo, and unsupported multi-sampling. Return `text_completion` JSON/SSE with local IDs/timestamps, `gemma3`, finish reasons, and usage.

- [ ] **Step 4: Test and commit**

  Run: `mix test test/codex_pooler/gateway/openai_compatibility/completions_test.exs test/codex_pooler_web/controllers/v1/completions_controller_test.exs`

  Run: `git add lib/codex_pooler/gateway/openai_compatibility/completions.ex lib/codex_pooler_web/controllers/v1/completions_controller.ex lib/codex_pooler_web/router.ex lib/codex_pooler/gateway/runtime/streaming/downstream_stream.ex test/codex_pooler/gateway/openai_compatibility/completions_test.exs test/codex_pooler_web/controllers/v1/completions_controller_test.exs && git commit -m "feat: add cloaked legacy completions route"`

---

### Task 8: Add native Ollama discovery and immutable management

**Files:**
- Create: `lib/codex_pooler/gateway/facade/ollama/catalog.ex`
- Create: `lib/codex_pooler_web/controllers/ollama/discovery_controller.ex`
- Create: `lib/codex_pooler_web/controllers/ollama/model_management_controller.ex`
- Modify: `lib/codex_pooler_web/router.ex`
- Create: `test/codex_pooler_web/controllers/ollama/discovery_controller_test.exs`
- Create: `test/codex_pooler_web/controllers/ollama/model_management_controller_test.exs`

- [ ] **Step 1: Create Ollama source/controller/test directories**

  Run: `mkdir -p lib/codex_pooler/gateway/facade/ollama lib/codex_pooler_web/controllers/ollama test/codex_pooler_web/controllers/ollama test/codex_pooler/gateway/facade/ollama`

- [ ] **Step 2: Write discovery tests**

  Authenticated tags/show/ps/version return only `gemma3`, no target/provider/Pooler data, and no upstream request. Unroutable target yields empty tags/ps and unavailable show. Fix facade contract version `0.1.0` and derive a stable local digest from public contract data.

- [ ] **Step 3: Write management tests**

  `POST /api/pull` for `gemma3` succeeds as streamed/non-streamed no-op. Other pull names and create/copy/push/delete/blob mutation return a fixed virtual-model error. Embed routes return stable unsupported errors and never produce vectors.

- [ ] **Step 4: Run tests and confirm route absence**

  Run: `mix test test/codex_pooler_web/controllers/ollama/discovery_controller_test.exs test/codex_pooler_web/controllers/ollama/model_management_controller_test.exs`

- [ ] **Step 5: Add exact routes and projections**

  Add `POST /api/create`, `POST /api/copy`, `POST /api/push`, `DELETE /api/delete`, `HEAD /api/blobs/:digest`, `POST /api/blobs/:digest`, `POST /api/embed`, and `POST /api/embeddings`. Reuse `Facade.Catalog` availability. `POST /api/show` ignores its submitted name and always projects the virtual entry. A tag entry is local-only:

  ~~~elixir
  %{
    "name" => "gemma3",
    "model" => "gemma3",
    "modified_at" => contract_timestamp(),
    "size" => 0,
    "digest" => contract_digest(),
    "details" => %{"family" => "gemma3", "parameter_size" => "virtual"}
  }
  ~~~

- [ ] **Step 6: Test and commit**

  Run: `mix test test/codex_pooler_web/controllers/ollama/discovery_controller_test.exs test/codex_pooler_web/controllers/ollama/model_management_controller_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade/ollama/catalog.ex lib/codex_pooler_web/controllers/ollama/discovery_controller.ex lib/codex_pooler_web/controllers/ollama/model_management_controller.ex lib/codex_pooler_web/router.ex test/codex_pooler_web/controllers/ollama/discovery_controller_test.exs test/codex_pooler_web/controllers/ollama/model_management_controller_test.exs && git commit -m "feat: add immutable ollama virtual model routes"`

---

### Task 9: Add native Ollama chat/generate collected inference

**Files:**
- Create: `lib/codex_pooler/gateway/facade/ollama/chat.ex`
- Create: `lib/codex_pooler/gateway/facade/ollama/generate.ex`
- Create: `lib/codex_pooler/gateway/facade/ollama/response.ex`
- Create: `lib/codex_pooler_web/controllers/ollama/inference_controller.ex`
- Modify: `lib/codex_pooler_web/router.ex`
- Create: `test/codex_pooler/gateway/facade/ollama/chat_test.exs`
- Create: `test/codex_pooler/gateway/facade/ollama/generate_test.exs`
- Create: `test/codex_pooler_web/controllers/ollama/inference_controller_test.exs`

- [ ] **Step 1: Write failing chat translation tests**

  Cover system/user/assistant/tool messages, base64 images, function definitions, tool calls/results, JSON mode, JSON schema, `think`, generation limits, absent/arbitrary model, and `stream: false`. Compare captured canonical work rather than generated prose.

- [ ] **Step 2: Write failing generate translation tests**

  Cover prompt/system/suffix/images/format/options. Encode suffix completion with a fixed developer instruction and structured prefix/suffix input; return only the insertion. Accept `keep_alive` and local allocation options as no-ops.

  The option contract is explicit: `num_predict -> max_output_tokens`, `temperature -> temperature`, `top_p -> top_p`, and `stop -> stop`. Map `seed` only if the current Responses matrix accepts it. Treat `num_ctx`, `num_batch`, `num_gpu`, `main_gpu`, `low_vram`, `f16_kv`, `use_mmap`, `use_mlock`, `num_thread`, and `numa` as no-ops. Return `400` for other sampling knobs without exact equivalents.

- [ ] **Step 3: Run tests and confirm adapter absence**

  Run: `mix test test/codex_pooler/gateway/facade/ollama/chat_test.exs test/codex_pooler/gateway/facade/ollama/generate_test.exs test/codex_pooler_web/controllers/ollama/inference_controller_test.exs`

- [ ] **Step 4: Implement both adapters through existing Responses work**

  Convert Ollama blocks into shapes accepted by `OpenAICompatibility.Chat`/`Responses`, install `Persona.fixed(:ollama_chat)` or `:ollama_generate`, mark collected work with `collect_openai_response_stream: true`, and dispatch through `PublicGatewayDispatch`/`Gateway.execute/4`.

  ~~~elixir
  with {:ok, canonical, formatting} <- Chat.to_responses(params),
       {:ok, coerced} <- Responses.coerce(canonical, request_options) do
    {:ok, Map.put(coerced, :ollama_formatting, formatting)}
  end
  ~~~

- [ ] **Step 5: Encode collected responses**

  Return local timestamps, `model: "gemma3"`, text/tool calls, safe summary presentation, `done: true`, normalized stop reason, and token counts. Exclude upstream IDs, service tier, encrypted reasoning, effective model, provider, account, and assignment data.

- [ ] **Step 6: Test and commit**

  Run: `mix test test/codex_pooler/gateway/facade/ollama/chat_test.exs test/codex_pooler/gateway/facade/ollama/generate_test.exs test/codex_pooler_web/controllers/ollama/inference_controller_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade/ollama/chat.ex lib/codex_pooler/gateway/facade/ollama/generate.ex lib/codex_pooler/gateway/facade/ollama/response.ex lib/codex_pooler_web/controllers/ollama/inference_controller.ex lib/codex_pooler_web/router.ex test/codex_pooler/gateway/facade/ollama/chat_test.exs test/codex_pooler/gateway/facade/ollama/generate_test.exs test/codex_pooler_web/controllers/ollama/inference_controller_test.exs && git commit -m "feat: add native ollama inference adapters"`

---

### Task 10: Add bounded Ollama NDJSON streaming

**Files:**
- Create: `lib/codex_pooler/gateway/facade/ollama/stream.ex`
- Modify: `lib/codex_pooler/gateway/runtime/streaming/downstream_stream.ex`
- Modify: `lib/codex_pooler/gateway/runtime/streaming/stream_dispatch.ex`
- Modify: `lib/codex_pooler_web/controllers/ollama/inference_controller.ex`
- Create: `test/codex_pooler/gateway/facade/ollama/stream_test.exs`
- Modify: `test/codex_pooler_web/controllers/ollama/inference_controller_test.exs`

- [ ] **Step 1: Write every-byte-boundary stream tests**

  Feed Responses SSE split at every byte. Each output unit must be one JSON object plus newline; deltas cannot duplicate; tool arguments assemble once; safe summaries stay separate; exactly one `done: true` terminal object appears.

- [ ] **Step 2: Add boundedness, failure-stage, and cancellation tests**

  Fix incomplete-frame ceiling at 1,048,576 bytes. Oversized frames become safe terminal error; telemetry stays bounded. A disconnect cancels work. Pre-output failure may retry another eligible account; post-output failure never retries/replays.

- [ ] **Step 3: Run tests and observe raw SSE mismatch**

  Run: `mix test test/codex_pooler/gateway/facade/ollama/stream_test.exs test/codex_pooler_web/controllers/ollama/inference_controller_test.exs`

- [ ] **Step 4: Implement incremental stream state**

  Extend `DownstreamStream.new/1`, `normalize_data/2`, `synthetic_terminal_failure/2`, `terminal_outcome/1`, and buffer metadata for Ollama personas. Keep only one incomplete SSE block and bounded tool arguments.

  ~~~elixir
  %{
    buffer: <<>>,
    surface: :chat,
    visible_seen?: false,
    terminal_seen?: false,
    tool_arguments: %{},
    started_at: System.monotonic_time()
  }
  ~~~

- [ ] **Step 5: Apply native stream headers/errors**

  Use `application/x-ndjson`. Pre-stream errors are normal Ollama JSON. A late error emits exactly one `{"error":"request failed","done":true}` line and closes.

- [ ] **Step 6: Test and commit**

  Run: `mix test test/codex_pooler/gateway/facade/ollama/stream_test.exs test/codex_pooler_web/controllers/ollama/inference_controller_test.exs test/codex_pooler/gateway/runtime/streaming/downstream_stream_test.exs test/codex_pooler/gateway/runtime/streaming/stream_lifecycle_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade/ollama/stream.ex lib/codex_pooler/gateway/runtime/streaming/downstream_stream.ex lib/codex_pooler/gateway/runtime/streaming/stream_dispatch.ex lib/codex_pooler_web/controllers/ollama/inference_controller.ex test/codex_pooler/gateway/facade/ollama/stream_test.exs test/codex_pooler_web/controllers/ollama/inference_controller_test.exs && git commit -m "feat: stream ollama ndjson through gateway"`

---

### Task 11: Add Anthropic Messages decoding and token counting

**Files:**
- Create: `lib/codex_pooler/gateway/facade/anthropic/messages.ex`
- Create: `lib/codex_pooler/gateway/facade/anthropic/token_count.ex`
- Create: `lib/codex_pooler_web/controllers/anthropic/messages_controller.ex`
- Modify: `lib/codex_pooler_web/router.ex`
- Create: `test/codex_pooler/gateway/facade/anthropic/messages_test.exs`
- Create: `test/codex_pooler/gateway/facade/anthropic/token_count_test.exs`
- Create: `test/codex_pooler_web/controllers/anthropic/messages_controller_test.exs`

- [ ] **Step 1: Create Anthropic source/controller/test directories**

  Run: `mkdir -p lib/codex_pooler/gateway/facade/anthropic lib/codex_pooler_web/controllers/anthropic test/codex_pooler/gateway/facade/anthropic test/codex_pooler_web/controllers/anthropic`

- [ ] **Step 2: Write failing translation tests**

  Cover string/block system prompts, multi-turn text, base64 images, `tool_use`, `tool_result`, function tools, auto/any/named/none tool choice, stop sequences, output limits, cache-control blocks, arbitrary aliases, and thinking fields. Assert fixed target/max upstream.

- [ ] **Step 3: Write header contract tests**

  Accept `anthropic-version: 2023-06-01` and syntactically valid comma-separated `anthropic-beta` tokens without forwarding them. Reject malformed values. Cover Bearer, `x-api-key`, matching dual credentials, and mismatch.

- [ ] **Step 4: Write local count-token tests**

  Serialize the same normalized system/messages/tools content used by dispatch. Count with `TokenCounter` using target/o200k, explicit per-role/block/tool framing overhead, and image placeholders. Return only `%{"input_tokens" => count}`, do no upstream work, and return `400` if bounded input cannot be safely represented.

- [ ] **Step 5: Run tests**

  Run: `mix test test/codex_pooler/gateway/facade/anthropic/messages_test.exs test/codex_pooler/gateway/facade/anthropic/token_count_test.exs test/codex_pooler_web/controllers/anthropic/messages_controller_test.exs`

- [ ] **Step 6: Implement canonical translation**

  Map blocks explicitly to Responses `input_text`, `input_image`, `function_call`, and `function_call_output`. Translate tools/tool choice. Map cache breakpoints to existing prompt-cache controls. `thinking.enabled` requests a safe summary presentation but its budget cannot set effort. Install `Persona.fixed(:anthropic_messages)`.

- [ ] **Step 7: Implement bounded local token count**

  Tokenize normalized bounded segments and add framing counts. Never expose tokenizer identity, target, cache key, or provider details.

- [ ] **Step 8: Test and commit**

  Run: `mix test test/codex_pooler/gateway/facade/anthropic/messages_test.exs test/codex_pooler/gateway/facade/anthropic/token_count_test.exs test/codex_pooler_web/controllers/anthropic/messages_controller_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade/anthropic/messages.ex lib/codex_pooler/gateway/facade/anthropic/token_count.ex lib/codex_pooler_web/controllers/anthropic/messages_controller.ex lib/codex_pooler_web/router.ex test/codex_pooler/gateway/facade/anthropic/messages_test.exs test/codex_pooler/gateway/facade/anthropic/token_count_test.exs test/codex_pooler_web/controllers/anthropic/messages_controller_test.exs && git commit -m "feat: add anthropic messages request adapter"`

---

### Task 12: Encode Anthropic JSON and SSE

**Files:**
- Create: `lib/codex_pooler/gateway/facade/anthropic/response.ex`
- Create: `lib/codex_pooler/gateway/facade/anthropic/stream.ex`
- Modify: `lib/codex_pooler/gateway/runtime/streaming/downstream_stream.ex`
- Modify: `lib/codex_pooler/gateway/runtime/streaming/stream_dispatch.ex`
- Modify: `lib/codex_pooler_web/controllers/anthropic/messages_controller.ex`
- Create: `test/codex_pooler/gateway/facade/anthropic/response_test.exs`
- Create: `test/codex_pooler/gateway/facade/anthropic/stream_test.exs`
- Modify: `test/codex_pooler_web/controllers/anthropic/messages_controller_test.exs`

- [ ] **Step 1: Write collected-response tests**

  Assert local message IDs, message/assistant shape, `model: "gemma3"`, text/tool-use blocks, stop reasons, and safe usage/cache counts. Reject every upstream identity field.

- [ ] **Step 2: Write exact SSE-sequence and byte-boundary tests**

  Require `message_start`, content-block start/delta/stop, `message_delta`, and `message_stop` order. Cover text, tool `input_json_delta`, summary presentation, usage, and stops. Split source at every byte and enforce 1,048,576-byte incomplete-frame limit.

- [ ] **Step 3: Write failure/header tests**

  Pre-stream failures use Anthropic JSON/status mapping. Late failures emit an Anthropic `error` SSE event without retry/replay. Headers are only content-type/cache-control/connection/local request-id.

- [ ] **Step 4: Run tests**

  Run: `mix test test/codex_pooler/gateway/facade/anthropic/response_test.exs test/codex_pooler/gateway/facade/anthropic/stream_test.exs test/codex_pooler_web/controllers/anthropic/messages_controller_test.exs`

- [ ] **Step 5: Implement response and stream encoders**

  Extend shared downstream state only for Anthropic persona. Accumulate bounded tool JSON, emit text immediately, use local opaque IDs, and map canonical stops:

  ~~~elixir
  %{
    "end_turn" => "end_turn",
    "tool_calls" => "tool_use",
    "max_output_tokens" => "max_tokens",
    "stop_sequence" => "stop_sequence"
  }
  ~~~

- [ ] **Step 6: Test and commit**

  Run: `mix test test/codex_pooler/gateway/facade/anthropic/response_test.exs test/codex_pooler/gateway/facade/anthropic/stream_test.exs test/codex_pooler_web/controllers/anthropic/messages_controller_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade/anthropic/response.ex lib/codex_pooler/gateway/facade/anthropic/stream.ex lib/codex_pooler/gateway/runtime/streaming/downstream_stream.ex lib/codex_pooler/gateway/runtime/streaming/stream_dispatch.ex lib/codex_pooler_web/controllers/anthropic/messages_controller.ex test/codex_pooler/gateway/facade/anthropic/response_test.exs test/codex_pooler/gateway/facade/anthropic/stream_test.exs test/codex_pooler_web/controllers/anthropic/messages_controller_test.exs && git commit -m "feat: encode anthropic messages responses"`

---

### Task 13: Preserve cache, continuity, files, and media

**Files:**
- Create: `lib/codex_pooler/gateway/facade/affinity.ex`
- Modify: `lib/codex_pooler/gateway/payloads/request_options.ex`
- Modify: `lib/codex_pooler/gateway/payloads/request_options/continuity.ex`
- Modify: `lib/codex_pooler/gateway/runtime/service.ex`
- Modify: `lib/codex_pooler_web/controllers/gateway_controller_helpers.ex`
- Modify: `lib/codex_pooler/gateway/openai_compatibility/audio.ex`
- Modify: `lib/codex_pooler/gateway/openai_compatibility/images.ex`
- Modify: `test/codex_pooler/gateway/openai_compatibility/continuation_test.exs`
- Modify: `test/codex_pooler_web/controllers/v1/audio_controller_test.exs`
- Modify: `test/codex_pooler_web/controllers/v1/images_controller_test.exs`
- Create: `test/codex_pooler/gateway/facade/affinity_test.exs`

- [ ] **Step 1: Write cache/session isolation tests**

  Repeated requests on one Pool/key preserve prompt-cache affinity. Identical cache/session IDs on different Pools/keys cannot collide. Cover OpenAI cache keys, Anthropic cache blocks, and `x-ollama-session-id`. Raw values/client models never appear in persisted metadata.

- [ ] **Step 2: Write media authority/leak tests**

  Arbitrary/missing selectors on transcription/images cannot change the existing helper path. Responses contain no helper identity. Files preserve current ownership/affinity/auth behavior.

- [ ] **Step 3: Run focused tests**

  Run: `mix test test/codex_pooler/gateway/facade/affinity_test.exs test/codex_pooler/gateway/openai_compatibility/continuation_test.exs test/codex_pooler_web/controllers/v1/audio_controller_test.exs test/codex_pooler_web/controllers/v1/images_controller_test.exs`

- [ ] **Step 4: Namespace affinity after authentication**

  Hash Pool ID, API-key ID, source, and raw value; persist only a URL-safe digest. Recognize `x-ollama-session-id`. Keep the effective target in internal prompt-cache identity, never the public alias. Existing previous-response, websocket turn-state, file affinity, and Codex-session rules remain authoritative on their own surfaces.

  ~~~elixir
  :crypto.hash(:sha256, Enum.join([pool_id, api_key_id, source, raw_value], <<0>>))
  |> Base.url_encode64(padding: false)
  |> then(&("facade:" <> &1))
  ~~~

- [ ] **Step 5: Add typed media-helper invariant exception**

  Permit non-reasoning internal model only when endpoint plus server-owned payload context identify current transcription/image helper paths. Client input cannot set context; every reasoning endpoint remains fixed-target.

- [ ] **Step 6: Test and commit**

  Run: `mix test test/codex_pooler/gateway/facade/affinity_test.exs test/codex_pooler/gateway/openai_compatibility/continuation_test.exs test/codex_pooler_web/controllers/v1/audio_controller_test.exs test/codex_pooler_web/controllers/v1/images_controller_test.exs test/codex_pooler_web/controllers/v1/files_controller_test.exs`

  Run: `git add lib/codex_pooler/gateway/facade/affinity.ex lib/codex_pooler/gateway/payloads/request_options.ex lib/codex_pooler/gateway/payloads/request_options/continuity.ex lib/codex_pooler/gateway/runtime/service.ex lib/codex_pooler_web/controllers/gateway_controller_helpers.ex lib/codex_pooler/gateway/openai_compatibility/audio.ex lib/codex_pooler/gateway/openai_compatibility/images.ex test/codex_pooler/gateway/openai_compatibility/continuation_test.exs test/codex_pooler_web/controllers/v1/audio_controller_test.exs test/codex_pooler_web/controllers/v1/images_controller_test.exs test/codex_pooler/gateway/facade/affinity_test.exs && git commit -m "feat: isolate facade affinity and media helpers"`

---

### Task 14: Prove robustness, equivalence, and non-leakage

**Files:**
- Create: `test/support/facade_assertions.ex`
- Create: `test/codex_pooler/gateway/facade/protocol_differential_test.exs`
- Create: `test/codex_pooler/gateway/facade/routing_robustness_test.exs`
- Create: `test/codex_pooler/gateway/facade/fault_injection_test.exs`
- Create: `test/codex_pooler/gateway/facade/concurrency_test.exs`
- Create: `test/codex_pooler_web/controllers/facade_transport_leakage_test.exs`

- [ ] **Step 1: Add reusable leak assertions**

  Inspect JSON, headers, NDJSON, SSE, and websocket frames. Fail on distinctive target/provider/account/assignment/endpoint/request-ID/credential/cache sentinels. Permit hidden words only in the content-nonmutation test.

- [ ] **Step 2: Add test-only direct differential baseline**

  Build direct canonical fixed-target/max work with the same identity instruction and call `Gateway.execute/4` without public projection. Compare captured upstream requests after local correlation removal. Compare terminal status, output item kinds, tool calls, usage, and stop outcome; do not compare stochastic prose.

- [ ] **Step 3: Add multi-account and affinity coverage**

  Exercise deterministic rotation, cache locality, saved-reset cohort, quota exhaustion, health changes, retryable/terminal status, file/session affinity, long tool loops, and long-context admission. Fallback can choose another account but never another model.

- [ ] **Step 4: Add fault-stage coverage**

  Cover connect/receive/idle timeout, partial frames, client disconnect and cancellation, missing terminal, and oversized block. Retry only before visible output; never duplicate text/tools.

- [ ] **Step 5: Add concurrent Pool/key isolation**

  Simultaneous requests with identical public/cache/session values but different Pools/keys remain isolated in accounting, affinity, limits, and transport.

- [ ] **Step 6: Run and commit**

  Run: `mix test test/codex_pooler/gateway/facade test/codex_pooler_web/controllers/facade_leakage_test.exs test/codex_pooler_web/controllers/facade_transport_leakage_test.exs`

  Run: `git add test/support/facade_assertions.ex test/codex_pooler/gateway/facade/protocol_differential_test.exs test/codex_pooler/gateway/facade/routing_robustness_test.exs test/codex_pooler/gateway/facade/fault_injection_test.exs test/codex_pooler/gateway/facade/concurrency_test.exs test/codex_pooler_web/controllers/facade_transport_leakage_test.exs && git commit -m "test: prove facade routing and leakage invariants"`

---

### Task 15: Add real-client smoke harnesses

**Files:**
- Create: `scripts/verification/facade/package.json`
- Create: `scripts/verification/facade/package-lock.json`
- Create: `scripts/verification/facade/clients.mjs`
- Create: `scripts/verification/facade/run-contract.sh`
- Create: `scripts/verification/facade/run-live-clients.sh`
- Create: `scripts/verification/facade/README.md`
- Create: `test/codex_pooler/facade/client_contract_test.exs`

- [ ] **Step 1: Create smoke source/test directories**

  Run: `mkdir -p scripts/verification/facade test/codex_pooler/facade`

- [ ] **Step 2: Add executable contract harness test**

  Start public Bandit/FakeUpstream, create a target fixture, invoke the contract script with explicit base URL/key, and exercise native Ollama, OpenAI, and Anthropic JSON/streams. Fail unless every model identity is `gemma3`.

- [ ] **Step 3: Add pinned official SDK clients**

  Run: `npm install --prefix scripts/verification/facade --save-exact ollama openai @anthropic-ai/sdk`

  `clients.mjs` sends text/tool/stream requests via each SDK using `FACADE_BASE_URL` and `FACADE_POOL_API_KEY` and never prints secrets.

- [ ] **Step 4: Add Codex CLI and Claude Code live smoke**

  The script checks binaries, creates an isolated `mktemp -d` repository, then tests repo read, file edit, shell tool, multi-turn tools, interruption/continuation, and repeated long-session cache behavior.

  Claude Code receives:

  ~~~bash
  ANTHROPIC_BASE_URL="$FACADE_BASE_URL" \
  ANTHROPIC_AUTH_TOKEN="$FACADE_POOL_API_KEY" \
  ANTHROPIC_MODEL="gemma3" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="gemma3" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="gemma3" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="gemma3" \
  claude -p "Inspect the fixture and report its test command"
  ~~~

  Invoke Codex with an empty task-specific config directory and command-line TOML overrides so the operator's normal config is never read or changed:

  ~~~bash
  facade_codex_dir="$(mktemp -d)"
  CODEX_HOME="$facade_codex_dir" \
  FACADE_POOL_API_KEY="$FACADE_POOL_API_KEY" \
  codex exec \
    --skip-git-repo-check \
    --ephemeral \
    -C "$facade_fixture_dir" \
    -m gemma3 \
    -c 'model_provider="facade"' \
    -c 'model_providers.facade.name="OpenAI"' \
    -c "model_providers.facade.base_url=\"$FACADE_BASE_URL/backend-api/codex\"" \
    -c 'model_providers.facade.env_key="FACADE_POOL_API_KEY"' \
    -c 'model_providers.facade.wire_api="responses"' \
    -c 'model_providers.facade.supports_websockets=true' \
    -c 'model_providers.facade.requires_openai_auth=false' \
    "Inspect the fixture, run its tests, and fix the failing assertion"
  ~~~

- [ ] **Step 5: Run contract and live gates**

  Run: `mix test test/codex_pooler/facade/client_contract_test.exs`

  The ExUnit test owns the temporary endpoint/key and invokes `run-contract.sh` with both values. Then, with an authorized local Pool key already exported, run:

  Run: `FACADE_BASE_URL=http://127.0.0.1:4000 bash scripts/verification/facade/run-live-clients.sh`

  Record versions and pass/fail evidence without credentials, private prompts, or raw provider responses.

- [ ] **Step 6: Commit**

  Run: `git add scripts/verification/facade test/codex_pooler/facade/client_contract_test.exs && git commit -m "test: add facade client smoke harness"`

---

### Task 16: Document, audit, and verify the complete facade

**Files:**
- Create: `docs-site/src/content/docs/clients/ollama.mdx`
- Create: `docs-site/src/content/docs/clients/claude-code.mdx`
- Modify: `docs-site/src/content/docs/clients/openai-compatible.mdx`
- Modify: `docs-site/src/content/docs/clients/codex-cli.mdx`
- Modify: `docs-site/src/content/docs/reference/runtime-routes.mdx`
- Modify: `docs-site/src/content/_docs-contract.md`
- Modify: `docs-site/src/content/docs/index.mdx`
- Modify: `README.md`

- [ ] **Step 1: Write operator/client documentation**

  Include authenticated curl, Ollama/OpenAI SDK base URLs, Claude Code aliases, Codex provider config, fixed target/max guarantee, route tables, pull no-op, cache/session/error semantics, and truthful operator diagnostics.

  State that adapters do not recreate Codex/Claude local agent runtimes, formats are not token-for-token equivalent, and arbitrary generated prose is not blindly rewritten.

- [ ] **Step 2: Update docs contract and landing claims**

  Replace obsolete “narrow /v1 only” claims, keep unsupported endpoints exact, and consistently require Pool API keys rather than upstream credentials.

- [ ] **Step 3: Run docs build**

  Run: `npm ci --prefix docs-site`

  Run: `npm run build --prefix docs-site`

- [ ] **Step 4: Run full project verification**

  Use `superpowers:verification-before-completion` for this gate and read every command's fresh exit status before making a completion claim.

  Run: `mix format --check-formatted`

  Run: `mix compile --warnings-as-errors`

  Run: `mix test`

  Run: `mix quality`

- [ ] **Step 5: Perform final leak/scope audit**

  Run: `rg -n 'gpt-5\\.6-sol|gpt-5|OpenAI|CodexPooler|upstream_identity|assignment_id|account_label' lib/codex_pooler/gateway/facade lib/codex_pooler_web/controllers/ollama lib/codex_pooler_web/controllers/anthropic`

  Review every match: internal constants/operator evidence are allowed; public construction is not. Re-run proof/live suites after corrections.

- [ ] **Step 6: Review protocol and regression risk**

  Use `superpowers:requesting-code-review` if delegation was explicitly authorized; otherwise perform the structured review inline. Check every design criterion, route/method, auth order, zero-work denial, retry boundary, cancellation, buffers, content non-mutation, operator truth, and regressions.

- [ ] **Step 7: Commit docs and record evidence**

  Run: `git add README.md docs-site/src/content && git commit -m "docs: document ollama gemma3 facade"`

  Record exact passing commands, test counts, client versions, and environment-gated limitations. Do not claim Codex-level backend robustness unless full tests, proof suite, docs build, SDK smoke, Codex CLI, and Claude Code all pass against an authorized target Pool.

---

## Completion Checklist

- [ ] Every approved Ollama, OpenAI, Anthropic, and Codex route exists and authenticates before discovery/work.
- [ ] Every advertised or identity-bearing public model value is exactly `gemma3`.
- [ ] Captured reasoning requests from each protocol are exactly `gpt-5.6-sol` with effort `max`.
- [ ] Conflicting policy/unavailable target proves zero work and no model fallback.
- [ ] Existing routing, cache, continuity, media, accounting, websocket, cancellation, and privacy suites pass.
- [ ] NDJSON/SSE/websocket transforms are bounded and pass every-byte-boundary fixtures.
- [ ] JSON, headers, streams, errors, and catalogs pass sentinel scans; operator evidence stays truthful.
- [ ] Differential and real-client smoke gates pass.
- [ ] Documentation builds and examples match implemented routes.
