defmodule CodexPooler.CompatibilityMatrix do
  @moduledoc """
  Machine-readable Codex compatibility contract matrix for regression tests.

  Rows intentionally describe the current compatibility contract so regression
  tests can keep supported behavior pinned.
  """

  @required_categories ~w(
    route
    auth
    error
    multipart
    streaming
    ownership
    overload
    degraded
  )a

  @features [
    %{
      slug: :files,
      status: :supported,
      current: :backend_file_bridge,
      categories: [:route, :auth, :error, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/files"},
        %{method: :post, path: "/backend-api/files/:file_id/uploaded"}
      ],
      future_routes: [],
      fixture: :file_upload,
      contract: "backend file routes use JSON SAS create and finalize, return upstream file_id plus upload_url, reject OpenAI /v1/files multipart semantics, and store metadata only"
    },
    %{
      slug: :backend_transcription,
      status: :supported,
      current: :fixed_backend_transcription_model,
      categories: [:route, :auth, :multipart, :ownership],
      routes: [%{method: :post, path: "/backend-api/transcribe"}],
      future_routes: [],
      fixture: :backend_transcription,
      contract: "backend transcription should force the backend transcription model and preserve safe multipart fields"
    },
    %{
      slug: :backend_image_proxy_surface,
      status: :supported,
      current: :explicit_authenticated_backend_image_proxy_routes,
      categories: [:route, :auth, :error, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/images/generations"},
        %{method: :post, path: "/backend-api/codex/images/edits"}
      ],
      future_routes: [],
      fixture: :backend_image_proxy_surface,
      contract: "backend image generation and edit routes are explicit authenticated JSON proxy routes under /backend-api/codex/images; on either exact native route, any policy-authorized effective image model genuinely absent from the Pool catalog may use eligible visible host capacity while preserving that effective identifier exactly, but catalog-present invisible targets remain invalid; image-specific prompt and source fields stay intact, and the native routes remain distinct from the public /v1 image translator surface"
    },
    %{
      slug: :backend_models_etag,
      status: :supported,
      current: :policy_visible_body_digest,
      categories: [:route, :auth, :error, :ownership],
      routes: [
        %{method: :get, path: "/backend-api/codex/models"},
        %{method: :get, path: "/backend-api/codex/v1/models"}
      ],
      future_routes: [],
      fixture: :backend_models_etag,
      canonical_partition: %{
        source: "assignment_scoped_pristine_source_metadata",
        identity: "canonical_capability_family_digest_after_provenance_presentation_and_reasoning_variant_removal",
        digest_excluded_hints: [
          "default_reasoning_level",
          "default_service_tier",
          "description",
          "visibility"
        ],
        shell_type: %{
          equivalent_known_values: ["default", "local", "shell_command", "unified_exec"],
          digest_value: "shell_command",
          disabled: "separate_partition",
          non_collapsing_values: ["unknown", "missing", "malformed"]
        },
        anchor_order: ["created_at", "assignment_id"],
        selection_rank: [
          "quota_routable_member_count_desc",
          "partition_member_count_desc",
          "anchor_created_at_asc",
          "anchor_assignment_id_asc"
        ],
        selection: "largest_quota_routable_partition",
        selection_fallback: "largest_partition_when_none_routable",
        reasoning_variants: %{
          stable_catalog_projection: "routable_capability_family_reasoning_union",
          canonical_allowance: "all_reasoning_variants_in_quota_selected_capability_family",
          native_turn_selection: "post_eligibility_assignment_advertising_effective_known_effort",
          non_reasoning_capability_boundary: "never_crossed",
          no_advertiser_fallback: "quota_selected_partition",
          circuit_state_input: false
        },
        quota_routing: %{
          snapshot: "one_shared_candidate_identity_snapshot",
          classification: "independent_per_model",
          input: "quota_evidence_only"
        },
        api_key_policy_stage: "post_selection_admission_and_projection",
        new_turn_capacity: %{
          backend_codex_catalog_driven: "selected_partition_only",
          translated_openai_responses: "all_valid_canonical_assignments"
        },
        pinned_continuation: %{
          valid_canonical_hard_pin: "may_cross_partition",
          malformed_or_retired_source: "unavailable"
        },
        selected_partition_exhaustion: %{
          accounting_disposition: "zero_work",
          upstream_dispatch: false
        },
        malformed_hard_pin: %{
          error_code: "pinned_continuation_unavailable",
          accounting_disposition: "zero_work",
          upstream_dispatch: false
        }
      },
      contract: "backend model aliases return the same policy-visible native catalog body and deterministic weak ETag from the canonical pristine-source capability family selected by quota-routable member count, total member count, then the oldest created_at plus assignment id anchor, falling back to the largest family when none is routable, so the catalog body and ETag can change when the preferred family changes; reasoning-level-only variants inside that quota-selected capability family advertise the union from its quota-routable assignments and remain inside the native turn's canonical allowance, after which the established post-quota and post-circuit reasoning preference selects an eligible assignment that lists the effective known effort; this never crosses another capability family, changes the stable catalog body, or lets an ineligible advertiser hide a healthy fallback; when no eligible assignment lists the effort every effective candidate remains upstream-authoritative; shell_type values default, local, shell_command, and unified_exec are equivalent for partitioning, disabled is separate, and unknown, missing, or malformed values do not silently collapse, while the selected anchor's raw shell_type remains served; quota routing reads one shared candidate-identity snapshot and classifies it independently per model; API-key policy decides admission and projection before assignment selection and never clamps the request; backend Codex catalog-driven new turns use the selected capability family, while translated OpenAI Responses capacity includes all valid canonical assignments after concrete request compatibility; valid canonical hard pins may continue on their pinned partition; selected-family exhaustion and malformed-source hard pins fail before accounting or upstream work; cache coherence across processes or replicas is eventual after a successful Responses token is observed; the version in a Codex build's User-Agent (a first-party codex originator, or any originator, including one with a slash or longer than 64 bytes, followed by the Codex platform block) selects the instructions representation, and the catalog fetch and every Responses turn select it with the same function from that one header, so a turn's x-models-etag always names the ETag its own client's catalog fetch received; the client_version query value is ignored and the catalog response carries vary: user-agent; 0.148.0 or newer drops the mirrored base_instructions from an entry whose model_messages.instructions_template is a string, while older, 0.147.0, absent, or unparsable versions and every non-Codex agent receive the entry verbatim, and the ETag is the digest of the representation actually served; a client whose whole version is inside the window the Codex catalog decoder was verified against (0.154.0 through 0.156.1, including prereleases that report one of those whole versions) receives the decode_checked representation: the template-only entries minus every entry that client would fail to decode, because one such entry makes it discard the whole catalog; a left-out model is not advertised to that client but stays routable, and each omission is logged as codex catalog entry left out with the Pool id, the model slug and the failing field paths only"
    },
    %{
      slug: :backend_responses_etag,
      status: :supported,
      current: :predispatch_catalog_snapshot,
      categories: [:route, :auth, :error, :streaming, :ownership, :degraded],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses", transport: "http_sse"},
        %{method: :post, path: "/backend-api/codex/v1/responses", transport: "http_sse"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :get, path: "/backend-api/codex/v1/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :backend_responses_etag,
      contract: "backend Responses HTTP SSE response headers expose x-models-etag equal byte-for-byte to the exact authenticated backend models ETag from the request snapshot, including when the turn routes within a reasoning-variant capability family represented by that catalog's stable routable-family union; websocket upgrade headers retain the same backward-compatible connection-opening value, while each accepted backend websocket turn emits an authoritative codex.response.metadata x-models-etag from that turn's current predispatch snapshot; the value is never relayed from upstream and is excluded from backend JSON, compact, public /v1, usage, unauthenticated, and unrelated routes; a native websocket replay re-emits the original turn's preserved snapshot value, provider codex.response.metadata events are relayed after the Pooler event with x-models-etag removed, and consumers must take the ETag only from metadata events that carry it; the value names the instructions representation the same client's catalog fetch received, selected by the same function from the same header as that catalog fetch: the package version after the originator in the request User-Agent"
    },
    %{
      slug: :pool_model_serving_modes,
      status: :supported,
      current: :pool_model_pair_request_or_turn_snapshot,
      categories: [:route, :error, :streaming, :ownership, :degraded],
      routes: [
        %{family: :backend_models, method: :get, path: "/backend-api/codex/models"},
        %{family: :backend_models, method: :get, path: "/backend-api/codex/v1/models"},
        %{
          family: :ordinary_responses,
          method: :post,
          path: "/backend-api/codex/responses",
          transport: :http_sse
        },
        %{
          family: :ordinary_responses,
          method: :post,
          path: "/backend-api/codex/v1/responses",
          transport: :http_sse
        },
        %{
          family: :ordinary_responses,
          method: :get,
          path: "/backend-api/codex/responses",
          transport: :websocket
        },
        %{
          family: :ordinary_responses,
          method: :get,
          path: "/backend-api/codex/v1/responses",
          transport: :websocket
        },
        %{
          family: :compact,
          method: :post,
          path: "/backend-api/codex/responses/compact"
        },
        %{
          family: :compact,
          method: :post,
          path: "/backend-api/codex/v1/responses/compact"
        },
        %{
          family: :ordinary_responses,
          method: :post,
          path: "/backend-api/codex/v1/chat/completions"
        },
        %{
          family: :public_ordinary_responses,
          method: :post,
          path: "/v1/responses"
        },
        %{
          family: :public_ordinary_responses,
          method: :get,
          path: "/v1/responses",
          transport: :websocket
        },
        %{
          family: :public_ordinary_responses,
          method: :post,
          path: "/v1/chat/completions"
        }
      ],
      future_routes: [],
      fixture: :pool_model_serving_modes,
      contract: "Auto, Lite, and Full belong to one Pool-model pair while clients keep one exposed model id and their existing Pool API key and configuration. Auto is the recommended literal-true catalog decision; a resolved mode is immutable for one HTTP request or websocket response.create turn across retry, failover, and owner forwarding. Backend catalog ETags, compact transformation, and bounded accounting metadata follow that snapshot. Public /v1/models, unsupported public compact, assignment eligibility, and Helm/environment configuration remain unchanged. Full is an advanced ordinary Responses override: a terminal HTTP failure returns a server-owned message, relaying only the sanitized rejection type, code, and param already persisted as attempt metadata for the same non-429 4xx window, and the fixed server_error body when no sanitized type exists. Auto, Lite, Full relay the same bounded supported-values list from persisted attempt metadata. That message names the relayed param and code with the same constructor the non-Full relay uses; a non-rate-limit 4xx records upstream_status without raw upstream text, exactly as the same rejection does under Auto or Lite, because the resolved serving mode is carried by the routing metadata on the request and the attempt and is never encoded in the error code; a 429 records upstream_rate_limited, an ordinary 5xx remains upstream_status, and Pooler never silently downgrades. Auto, Lite, compact or unrelated routes, and established model-miss responses remain unchanged."
    },
    %{
      slug: :backend_responses_envelope,
      status: :supported,
      current: :final_noncompact_backend_envelope,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/v1/responses"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :get, path: "/backend-api/codex/v1/responses", transport: "websocket"},
        %{method: :post, path: "/backend-api/codex/v1/chat/completions"},
        %{method: :post, path: "/v1/responses", translation: "backend_responses"},
        %{
          method: :get,
          path: "/v1/responses",
          transport: "websocket",
          translation: "backend_responses"
        },
        %{
          method: :post,
          path: "/v1/chat/completions",
          translation: "backend_responses"
        }
      ],
      future_routes: [],
      fixture: :backend_responses_envelope,
      contract: "the final noncompact backend Responses envelope always has a reasoning map and exactly one reasoning.encrypted_content include after selected summary-capability normalization across backend, backend-alias, and translated public Responses surfaces; compact routes remain excluded and preserve their existing narrow shape"
    },
    %{
      slug: :upstream_error_param,
      status: :supported,
      current: :sanitized_failed_attempt_detail,
      categories: [:error, :ownership, :degraded],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :upstream_error_param,
      contract: "upstream_error_param is a bounded allowlisted field-path value projected on failed-attempt detail only; invalid values and successful attempts are omitted, with never raw upstream error messages or values projected"
    },
    %{
      slug: :terminal_failure_diagnostics,
      status: :supported,
      current: :bounded_terminal_failure_attempt_detail,
      categories: [:error, :ownership, :degraded],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :terminal_failure_diagnostics,
      contract: "terminal failure diagnostics project bounded upstream_error_code, stream_terminal_type, compaction_invalid_reason, and upstream_error_param only on failed and retryable_failed attempt detail; collector reasons use a closed vocabulary and degrade to invalid_compaction when unlisted, while compact-adaptation reasons are invalid_json or missing_encrypted_content; these are metadata-only and never public response fields; strict ASCII identifiers through 80 bytes remain cleartext, while malformed control invalid-UTF8 or overlong identifiers fingerprint; malformed successful and historical rows omit them, and raw provider messages, bodies, and frames are never projected"
    },
    %{
      slug: :rejection_metadata,
      status: :supported,
      current: :bounded_non_429_4xx_rejection_metadata,
      categories: [:error, :ownership, :degraded],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :rejection_metadata,
      contract: "non-429 HTTP 4xx rejection metadata is extracted from a bounded private streaming drain or the bounded materialized body, projected only on failed-attempt detail, and publishes bounded code, type, param, message-presence, and message-byte facts without raw provider bodies or messages"
    },
    %{
      slug: :upstream_validation_rejection_relay,
      status: :supported,
      current: :bounded_allowlisted_validation_rejection_relay,
      categories: [:error, :streaming],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/v1/responses"},
        %{method: :post, path: "/backend-api/codex/v1/chat/completions"},
        %{method: :post, path: "/v1/responses"},
        %{method: :post, path: "/v1/chat/completions"}
      ],
      future_routes: [],
      fixture: :upstream_validation_rejection_relay,
      contract: "an ordinary Responses or Chat HTTP request whose upstream answers HTTP 400 with a direct error object of type invalid_request_error and an allowlisted parameter-validation code, or with a detail body that is exactly `Unsupported parameter: ` followed by a bounded field path (read as unsupported_parameter with that param, which is how the Codex backend refuses previous_response_id on HTTP), relays type, code, a bounded field-path param or null, and a Pooler-authored message built from code and param, never the provider message, which for unsupported_value and invalid_value may append at most 12 identifier-shaped supported values taken only from a strictly shaped trailing provider list with every earlier quoted value, including the rejected value, excluded; translated Chat Completions map the param back to the Chat field the client sent only for renames the adapter performs and the Pooler-authored message names that same Chat field under Lite and Full alike; a native streaming request receives that native JSON error envelope, served as application/json even when the upstream 400 carried no content-type, instead of an empty body while a materialized native body keeps its existing passthrough, and public /v1 Responses and Chat Completions receive the same OpenAI error object; Auto, Lite, Full relay the same bounded supported-values list from persisted attempt metadata. Any other native HTTP 400 on an ordinary Responses route (no code, another code or type, any other detail body) answers, streaming or not, the Pooler-authored error built from the sanitized code, param and type only, with the upstream code or invalid_request, instead of an empty streaming body or the provider body. A native HTTP refusal with another final 4xx on an ordinary Responses route (402 to 499 except 408 and 429; a credential 403 is refreshed before it) answers that error with status 400 under every serving mode, its message naming the upstream status, because the Codex client retries every other status; the request and attempt keep the upstream status. Every other status, compact routes, model-unavailability and misalignment projections, and websocket frames keep their existing behavior, while accounting codes, retries, routing health, and metrics are unchanged"
    },
    %{
      slug: :pooler_authored_error_type,
      status: :supported,
      current: :classified_from_code_vocabulary_and_status,
      categories: [:error, :route, :overload, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/responses/compact"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :post, path: "/backend-api/files"},
        %{method: :post, path: "/v1/responses", translation: "backend_responses"},
        %{
          method: :get,
          path: "/v1/responses",
          transport: "websocket",
          translation: "backend_responses"
        }
      ],
      future_routes: [],
      fixture: :pooler_authored_error_type,
      contract: "every error envelope Codex Pooler authors itself, on the HTTP relay and on the websocket surface alike, takes its error type from one shared classification rather than from a per-renderer default: an enumerated code vocabulary decides first, so owner-lifecycle and overload codes carry server_error even at status 409 where owner_busy is backpressure and stale_owner is a lease that moved, while a replaced or stale downstream and a disconnected client carry invalid_request_error; a code outside that vocabulary takes its class from its status, so a 429 carries rate_limit_error, a 5xx carries server_error, and only a remaining 4xx carries invalid_request_error; an error map retryable field is never consulted, because it states that Codex Pooler will not route around the failure rather than that the caller must change the request; a compile-time guard fails the build when an owner error code is added without a class; the runtime ingress plug, the native previous-response-not-found canonical event, and the relayed upstream parameter-validation rejection author their envelopes through the same classification instead of naming a type; and the net invariant on both surfaces is that a 5xx response or frame is never typed invalid_request_error, while provider error objects relayed whole keep the type the provider wrote"
    },
    %{
      slug: :backend_fast_service_tier,
      status: :supported,
      current: :canonical_priority_routing_alias,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/v1/responses"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :get, path: "/backend-api/codex/v1/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :backend_responses_envelope,
      contract: "backend Responses HTTP and websocket routes canonicalize binary client or enforced service_tier fast to upstream priority, compare advertised fast and priority as equivalent without rewriting catalog metadata, preserve every other backend tier value or type, and relay provider bytes, frames, and service-tier vocabulary unchanged"
    },
    %{
      slug: :responses_chat,
      status: :supported,
      current: :proxied_json_and_sse,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/v1/responses"},
        %{method: :post, path: "/v1/chat/completions"}
      ],
      future_routes: [],
      fixture: :responses_chat,
      programmatic_tool_calling_contract: "closed-world Responses programmatic-tool calling rejects remote MCP and unrelated hosted tools and makes no full OpenAI parity claim",
      hosted_shell_history_contract: "closed-key hosted-shell history replay accepts only shell_call and shell_call_output input items without executing commands or enabling shell tool declarations, local shell, remote MCP, SDK command-index accumulation, or broad hosted-tool parity",
      contract: "Responses and chat completions proxy JSON/SSE through the shared gateway accounting path; chat completions use messages when present and fall back to top-level input only when messages is absent or empty, with omitted fallback instructions defaulting to a blank string; /v1/responses and translated /v1/chat/completions accept client service_tier fast as canonical upstream priority while retaining existing invalid-tier rejection, preserve literal provider service_tier output, and include a Chat stream tier only on chunks emitted after observation without buffering or rewriting earlier chunks; translated Chat custom definitions and named choices use the official nested wrapper, flatten into the supported Responses subset, and restore completed or streamed custom calls without parsing free-form input as JSON; /v1/responses and translated /v1/chat/completions accept prompt_cache_options and supported content-part prompt_cache_breakpoint controls as public input, while account-backed egress omits both explicit controls and preserves prompt_cache_key; Pool affinity remains exclusively keyed by prompt_cache_key; request-shaped additional_tools input items are preserved as non-executable input, never merged into executable tools, and never used to satisfy tool_choice; OpenAI Responses remote MCP tool definitions are rejected before upstream dispatch in both top-level tools and nested additional_tools.tools locations; Responses namespace tool definitions are accepted only for non-empty namespace name/description values and exact flat function or executable custom namespace children; Responses truncation accepts auto and disabled locally but is not forwarded upstream; terminal compaction_trigger backend payloads on either backend Responses alias retain the final trigger, classify streamed compaction from the request trigger independently of client declarations while ignoring unrelated additive metadata and never inspecting returned compaction items, dispatch streamed Responses compaction to /backend-api/codex/responses with compact accounting on /backend-api/codex/responses/compact, force store false, omit include and prompt_cache_options, set upstream stream true for Responses compaction triggers, and adapt the compact result to backend Responses SSE; returned compaction-item normalization preserves only schema-backed string replay identity and drops other compact-result fields; direct compact aliases preserve their canonical legacy /backend-api/codex/responses/compact upstream route while omitting store, stream, and the trigger; malformed trigger placement is rejected before dispatch; public /v1/responses HTTP and Responses websocket turns accept exactly one final compaction_trigger after visible input, dispatch it through the same streamed compact bridge with compact accounting and ordinary backend Responses upstream routing, and adapt the result as public Responses JSON, SSE, or websocket events; public /v1/responses/compact remains unsupported and public /v1 Responses accepts encrypted compaction output replay items from prior remote compaction turns; native fallback provider unsupported requires an admitted failed /backend-api/codex/responses/compact request with last_error_code upstream_status, response status 404, and a matching failed attempt with upstream status 404, while local route, auth, routing, or model failures are not capability evidence; backend regular HTTP Responses and compact routes forward approved metadata headers, including request-scoped x-codex-turn-state, x-codex-window-id, x-openai-memgen-request, x-codex-guardian, and x-codex-inference-call-id, and relay upstream x-codex-turn-state response headers downstream, while public /v1 and websocket request-header lanes do not; context-overflow recovery stays client/upstream-owned with no server-side hidden replay, no server-side memory tool injection, no client store=false-to-true override policy, and no stored prompt/frame reconstruction; Hermes assistant replay may include safe assistant status metadata; OpenClaw assistant replay drops thinking metadata and normalizes text before upstream dispatch; public /v1/responses and /v1/chat/completions accept exactly five lowercase input_audio labels (wav=>audio/wav, mp3=>audio/mpeg, m4a=>audio/mp4, webm=>audio/webm, ogg=>audio/ogg), apply a 52,428,800 decoded-byte maximum and a 69,905,068 non-whitespace encoded-byte precheck, canonicalize backend input_audio to an audio_url data URL after accepted ASCII whitespace normalization, reject malformed/empty/unsupported/oversized input as sanitized invalid_request without dispatch or accounting, honor configured request-envelope rejection before adapter checks, and keep audio metadata-only outside dispatch; safe OpenAI Responses fields, prompt-cache locality, SDK-control rejection, and backend-only control stripping stay scope-specific"
    },
    %{
      slug: :response_body_cap,
      status: :supported,
      current: :bounded_non_streaming_upstream_body,
      categories: [:error, :degraded, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/v1/responses"},
        %{method: :post, path: "/v1/responses"},
        %{method: :post, path: "/v1/chat/completions"},
        %{method: :post, path: "/backend-api/transcribe"}
      ],
      future_routes: [],
      fixture: :response_body_cap,
      contract: "non-streaming upstream HTTP response bodies are collected through a bounded reader, fail closed as upstream_response_too_large when the content-length or streamed bytes exceed the limit, do not retain oversized body bytes in client responses, request logs, attempt metadata, docs, or admin evidence, and leave streaming routes on their existing stream-buffer guards"
    },
    %{
      slug: :backend_v1_alias_surface,
      status: :supported,
      current: :explicit_authenticated_backend_alias_routes,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :get, path: "/backend-api/codex/v1/models"},
        %{method: :get, path: "/backend-api/codex/v1/responses"},
        %{method: :post, path: "/backend-api/codex/v1/responses"},
        %{method: :post, path: "/backend-api/codex/v1/responses/compact"},
        %{method: :post, path: "/backend-api/codex/v1/chat/completions"}
      ],
      future_routes: [],
      fixture: :backend_v1_alias_surface,
      contract: "backend /backend-api/codex/v1 aliases are explicit authenticated backend routes for models, responses, websocket responses, compact, and chat completions, preserve generic backend API-key auth, proxy to the canonical backend gateway paths, allow prompt-cache routing locality only on POST responses and chat completions aliases, keep the chat alias fallback limited to top-level input only when messages is absent or empty, and the translated chat alias emits the nested server_error terminal after visible output when the upstream stream ends without a terminal"
    },
    %{
      slug: :usage_alias_meter_identity,
      status: :supported,
      current: :alias_equivalent_current_meter_lists,
      categories: [:route, :auth, :ownership],
      routes: [
        %{method: :get, path: "/api/codex/usage"},
        %{method: :get, path: "/wham/usage"},
        %{method: :get, path: "/backend-api/wham/usage"}
      ],
      future_routes: [],
      fixture: :usage_alias_meter_identity,
      contract: "the three authenticated Codex usage aliases return schema-equivalent deterministic current usage lists; dynamically stale additional rows are omitted, unknown rows remain, distinct canonical meters may repeat the legacy quota_key without cross-meter window pairing, no freshness or raw identity fields extend the wire shape, and request logs retain the exact alias endpoint with metadata-only usage facts"
    },
    %{
      slug: :websocket_continuity,
      status: :supported,
      current: :persisted_session_turns,
      categories: [:route, :auth, :streaming, :ownership, :degraded],
      routes: [%{method: :get, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :websocket_turn,
      contract: "backend websocket continuity persists sessions and turns with sticky routing affinity, uses response.create.client_metadata x-codex-turn-state as per-frame request-scoped turn state with the upgrade/header value only as fallback, and is excluded from prompt-cache routing locality; strict native turn-identity precedence validates client_metadata.turn_id, canonical client metadata, turn_id, then request_id without falling through a present invalid source, retaining only an opaque SHA-256 semantic key and full claim key derived under the turn's claim scope, an HMAC of Pool, API key and client thread when the turn metadata names a thread and the Codex session otherwise, so one thread keeps its key across the sessions and windows of that key while another key or thread never shares it;a same active non-cancelled replay is suppressed without new work, while a cancelled predecessor with a different valid native identity can enter one bounded cancellation handoff with a one-second soft boundary and five-second absolute boundary, then starts only after matching fenced readiness; cancelled equal, noncancelled different, missing, public, non-native, and response.processed reconnect candidates fail bounded busy, while generate:false prewarm stays local, row-free, and neutral; predecessor, replacement, and later turn each settle exactly once, replacement uses a new connection generation, and the later turn reuses it; mixed-release behavior is identity-aware only when both current proxy and owner support the control path, a current proxy fails before accounting against a previous owner, and older callers retain their legacy behavior; no hidden automatic replay occurs; native anchor, compact, and final frames share one semantic client turn but create three distinct accounting lifecycles on one physical websocket generation; a first full-history compact uses the ordinary durable turn claim, while mid-turn compact and final transitions require a one-shot owner capability plus sealed runtime proof and can never be authorized by payload shape or client metadata alone; rejected capability frames create no rows, upstream calls, saved-reset probe or redeem activity, retry, replay, or fallback; public /v1 never inherits the native owner capability or proof and retains its existing replay, bridge, byte, and terminal-shape semantics; an unresolved previous-response alias retains the current authenticated runtime and emits no owner-outage error; successful native turns register hashed previous-response aliases independent of retained-body completeness; a native websocket continuation marked from its final upstream payload may use only its reused upstream connection, while a fresh or reconnected connection emits the exact previous_response_not_found client retry signal before upstream payload send so only a later explicit full request may use that replacement connection; the same signal answers a Lite marked continuation on its reused connection when the last response completed there was served in Full, because a Lite anchored request carries no tool manifest or instructions message and a context opened under Full holds neither, while a Full continuation on a Lite-served context is sent because it carries its tools and instructions at top level; a mid-stream upstream death after visible output authors exactly one native type:error frame with status 502, wire code upstream_request_failed, and the pinned message upstream request failed, carrying no terminal event, no sequence_number, and no socket close so the same socket serves later turns; an owner-forwarded native turn instead delivers the owner's single relayed status-502 server_error frame and the socket authors no second error frame for that turn, so a native turn reaches the client with at most one error frame while a success terminal followed by a settlement failure still receives its error frame; every frame authored through the shared websocket error envelope classifies its error type from the same enumerated code vocabulary the HTTP relay uses instead of a catch-all default, so owner-lifecycle and overload codes carry error type server_error while a replaced or stale downstream carries invalid_request_error, and a code outside that vocabulary follows its status class alone, carrying rate_limit_error at 429 and server_error at any 5xx whatever the reason declares about its own retryability, defaulting independently to status 500 when its reason has no status and to wire code websocket_request_failed with error type server_error when its reason has no code and message; public /v1 terminal masking and shape remain unchanged; a native backend websocket response.create turn uses the upstream websocket whether its stream flag is true or omitted and never falls back to the HTTP Responses endpoint, an explicit stream false is rejected before admission, accounting, or upstream work with status 400 wire code invalid_request and param stream because the provider websocket rejects it, and a websocket turn without a websocket upstream path fails closed before reservation with one type:error frame carrying status 500 and wire code websocket_transport_required; model streaming-capability checks in pre-dispatch and candidate eligibility treat every websocket turn as streaming, so a stream-less websocket turn on a non-streaming model receives the same local 400 unsupported_model_capability param stream rejection as stream true"
    },
    %{
      slug: :duplicate_turn_fence,
      status: :supported,
      current: :shared_opening_turn_claim_cross_transport,
      categories: [:route, :auth, :error, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/responses/compact"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :get, path: "/backend-api/codex/v1/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :duplicate_turn_fence,
      duplicate_turn: %{
        executable_fields: [
          :advanced_http_resume,
          :claim_by_request_kind,
          :known_gaps,
          :partial_http_tool_retry,
          :payload_independent_claims,
          :public_error
        ],
        documentary_fields: [
          :bare_claim_request_kinds,
          :continuation_discriminator,
          :diagnostics,
          :disposition_scope,
          :metadata_sources,
          :refusal_dispositions,
          :unfenced
        ],
        public_error: %{
          status: 409,
          code: "duplicate_turn",
          transports: ["http_json", "http_sse", "websocket"]
        },
        advanced_http_resume: %{
          predecessor_transport: "http_sse",
          predecessor_error: "client_disconnected",
          predecessor_claim_arm: "post_compaction_resume",
          successor_prefix: "codex-request-retry:",
          requires_input_prefix_match: true,
          requires_delivered_output_receipt_match: true,
          identical_retry_refused: true
        },
        partial_http_tool_retry: %{
          predecessor_transport: "http_sse",
          predecessor_error: "upstream_stream_error",
          claim_arms: ["opening", "tool_continuation"],
          partial_tools: ["custom_tool_call", "function_call"],
          retry_limit: 1,
          retry_window_seconds: 30,
          completed_item_retry: false,
          requires_exact_request: true,
          requires_complete_observation: true
        },
        claim_by_request_kind: %{
          turn: %{shape: "bare_payload_independent_codex_turn_claim", prefix: "codex-turn:"},
          tool_result_continuation: %{
            shape: "payload_scoped_request_claim",
            prefix: "codex-request:"
          },
          compaction: %{shape: "payload_scoped_request_claim", prefix: "codex-request:"},
          post_compaction_resume: %{
            shape: "compaction_anchored_resume_claim",
            prefix: "codex-resume:"
          },
          prewarm: %{shape: "kind_scoped_request_claim", prefix: "codex-kind:"},
          memory: %{shape: "kind_scoped_request_claim", prefix: "codex-kind:"}
        },
        payload_independent_claims: [:turn, :post_compaction_resume],
        disposition_scope: "predecessor_row_transport",
        continuation_discriminator: "shared_native_turn_continuation_predicate",
        metadata_sources: ["body_client_metadata", "request_header"],
        bare_claim_request_kinds: ["turn"],
        unfenced: [
          "translated_v1_request",
          "non_native_route",
          "missing_codex_session",
          "absent_turn_metadata",
          "malformed_turn_metadata",
          "absent_request_kind",
          "unknown_request_kind",
          "contradictory_repeated_turn_metadata_header"
        ],
        refusal_dispositions: [
          "unsupported_claim",
          "missing_predecessor",
          "authorization_changed",
          "active_predecessor",
          "terminal_predecessor",
          "entitlement_present",
          "retry_expired",
          "chain_exhausted",
          "invalid_predecessor",
          "anchor_unavailable"
        ],
        diagnostics: %{
          http_stage: "native_http_turn_claim",
          websocket_stage: "websocket_turn_claim",
          http_label: "native http replay rejection",
          websocket_label_unchanged: true,
          claim_key_payload_or_frame: false
        },
        known_gaps: %{
          tool_result_continuation_grown_body_retry_fenced: false,
          compaction_changed_body_retry_fenced: false
        }
      },
      contract: "409 duplicate_turn is a public runtime response on both transports. Two payload-independent claims are shared across native HTTP and websocket: the request that opened a native Codex turn takes the bare codex-turn claim, and a post-compaction resume takes codex-resume derived from the turn plus the latest compaction pivot. An HTTPS fallback of either shape therefore meets the same resend policy instead of buying a second upstream dispatch. The websocket compaction bridge retains its own transport-specific claim ordering. One turn id covers every request made about a turn, so the claim depends on which request of the turn it is. The opening request takes the bare claim so a rebuilt longer retry body still names the same turn. A tool-result continuation and an HTTP compaction each take their own payload-scoped claim. Remote compaction replaces the session history and the compaction output item is pushed last, so every later turn of that session carries it; what follows the last recognized pivot decides the ordinary-turn claim. A user message after it is a turn's opening request, which keeps the bare claim, unless that claim is already held by a request of the turn, native HTTP or websocket, that it is further along than (the same latest compaction pivot, or none, and strictly more user messages after it, or a pivot the holder did not end on, both recorded beside its full-history progress digest): the released client drains user input steered into a running turn into the same turn under the same turn id, right after a mid-turn compaction included, so such a request is claimed as a steered continuation under codex-resume derived from the turn and that digest, and its own identical or rebuilt resend is refused. Nothing after it is the request that resumes the turn from that compaction, named by the turn and an opaque digest of only the latest compaction pivot and by nothing else in the body. A native HTTP resume that delivered completed output items and then ended client_disconnected can accept exactly one rebuilt successor only when the new input strictly extends the predecessor input, the prefix HMAC matches the predecessor request witness, and the suffix HMAC matches the bounded receipt of output_item.done items actually written downstream; the successor uses codex-request-retry, while altered, absent, or identical suffixes stay duplicate_turn without new rows or dispatch; a suffix that adds a user message is a steered continuation, not a suffix of that resume. A tool result after the compaction pivot is a tool-result continuation. A prewarm or memory request carrying the turn id takes a payload-scoped claim in a domain named by its kind, so it is clear of the turn and an identical resend of it is still refused. The canonical x-codex-turn-metadata document is preferred from the request body and falls back to the header, and the declared request kind is compared after trimming and case folding. Not claimed at all, keeping the generated correlation id: a translated /v1 request, a non-native route, a missing Codex session, an absent or malformed document, an absent or unknown request kind, and a repeated x-codex-turn-metadata header whose copies disagree. Every refusal fails closed through one disposition vocabulary, and only a predecessor that already bought provider output refuses a resend unless it is the proven advanced HTTP resume above. The resend policy is scoped by the predecessor row's transport. A zero-output provider failure and an unfinished predecessor are served, and so are a turn and its own compaction in either order, the request that resumes the turn from a compaction in every arrangement of the compacted history, a tool continuation of that resume, a prewarm or memory alongside the turn sharing its id, and the same turn id under a different session. The chain that steps over zero-output predecessors is bounded at sixteen hops and falls open to a generated id past the bound rather than refusing. Native HTTP refusals log their own stage and label with the transport field set, the websocket line is unchanged, and no line carries a claim key, payload, or frame. Two claims remain unfenced against a changed retry body because they are payload-scoped by construction: a tool-result continuation whose body has grown, on both transports, and an HTTP compaction resent with a changed body. On the websocket the same steered request rides the connection that produced the turn's last response, anchored on it with only the items added since; a native frame anchored on the response a request of its own turn completed on that socket is a later request of the turn, since an opener is sent before its turn produced any response, and takes the same steered codex-resume claim, derived from the full-history progress the socket carries forward from the request that produced that response (payload-scoped only when the socket holds no progress for it), waiting behind that request's settlement, so its identical resend is still refused while the next turn's opener, anchored on the previous turn's response, keeps the bare claim. A websocket request records its full-history progress digest on its row, read directly from an unanchored frame and carried forward on its socket for an anchored one, so the same steer sent as full history on another socket after its connection closed, or over HTTPS after the session fell back, is claimed as that steered continuation, and every form of one steer meets the others. One shape is deliberately refused rather than served: a single turn id reused across a user message when the turn's opener recorded no progress position, a row written before these releases or a websocket opener anchored on a response its socket held no progress for, which the fence cannot tell from a rebuilt retry of that opener. A full-history resend of the opener that is not further along, fewer user messages after the same pivot or its pivot gone, is that opener again with trimmed history and is refused, never generated twice. An identical native HTTP compaction resend is chained as one successor with its own single settlement, because the released client resends a remote compaction only when it never read its completion and three refusals fail the turn. Each native HTTP claim shape carries its own wire prefix except the tool-result continuation and the compaction, which share codex-request:"
    },
    %{
      slug: :reasoning_minimal,
      status: :supported,
      current: :normalized_to_low,
      categories: [:route, :auth, :ownership],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :reasoning_minimal,
      contract: "minimal reasoning is rewritten to low before upstream dispatch"
    },
    %{
      slug: :reasoning_none,
      status: :supported,
      current: :passed_through,
      categories: [:route, :auth, :ownership],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :reasoning_none,
      contract: "none reasoning is accepted and forwarded unchanged before upstream dispatch; it stays unchanged even when the selected model catalog does not list none, because the upstream accepts none on some models whose catalogs omit it and no catalog field identifies the models that reject it"
    },
    %{
      slug: :reasoning_ultra,
      status: :supported,
      current: :normalized_to_max,
      categories: [:route, :auth, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/responses/compact"}
      ],
      future_routes: [],
      fixture: :reasoning_ultra,
      contract: "client-facing ultra reasoning is accepted and rewritten to backend-compatible max before backend Codex regular and compact upstream dispatch; when the selected model catalog lists known reasoning levels without max, ultra is instead rewritten to the highest listed level other than none and minimal on backend HTTP, compact, and websocket dispatch, unknown levels keep max, and the safe reasoning snapshot names the rewrite ultra_to_<level> from the fixed targets max, xhigh, high, medium, and low"
    },
    %{
      slug: :api_key_reasoning_availability,
      status: :supported,
      current: :pre_reservation_three_mode_policy,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :get, path: "/backend-api/codex/models"},
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :post, path: "/backend-api/codex/responses/compact"},
        %{method: :post, path: "/backend-api/codex/v1/responses"},
        %{method: :get, path: "/backend-api/codex/v1/responses", transport: "websocket"},
        %{method: :post, path: "/backend-api/codex/v1/responses/compact"},
        %{method: :post, path: "/backend-api/codex/v1/chat/completions"},
        %{method: :post, path: "/v1/responses"},
        %{method: :get, path: "/v1/responses", transport: "websocket"},
        %{method: :post, path: "/v1/chat/completions"}
      ],
      future_routes: [],
      fixture: :api_key_reasoning_availability,
      contract: "API keys derive unrestricted, allow_up_to, or always_use reasoning policy from their configured fields. Unrestricted preserves omission and current accepted explicit values. Allow_up_to accepts known values through its ceiling and the selected model's effective known levels, resolves omission from the permitted default or highest permitted known value, and rejects above-ceiling, unknown, custom, or empty-intersection requests before reservation or upstream work without clamping. Always_use preserves legacy exact enforcement regardless of metadata membership. Denials are status 400 reasoning_effort_not_allowed with message reasoning effort is not available for this API key and param reasoning.effort for Responses/backend/compact or reasoning_effort for Chat; model_not_allowed is status 400 invalid_request_error with param model (feature api_key_terminal_policy_denials). Upgraded response.create frames receive the same existing error frame after upgrade, not an upgrade rejection. Backend model metadata keeps the selected pristine entry with every advertised level and default whatever the policy (the policy changes only model membership there), models remain visible, and public /v1/models remains unchanged. minimal and ultra are evaluated before their backend low and max rewrites."
    },
    %{
      slug: :api_key_reservation_policy_refusals,
      status: :supported,
      current: :window_429_request_cap_400,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :post, path: "/v1/responses"},
        %{method: :get, path: "/v1/responses", transport: "websocket"},
        %{method: :post, path: "/v1/chat/completions"}
      ],
      future_routes: [],
      fixture: :api_key_reservation_policy_refusals,
      contract: "an API key policy refusal at the reservation keeps the wire code api_key_policy_limit_exceeded and the Pooler's own message on every transport, is marked as a Pooler policy denial so public /v1 never redacts it, and takes its status from what refused it: a window (max_requests_per_minute, max_tokens_per_day, max_tokens_per_week) that the request fits once the window moves answers 429 rate_limit_error, with a retry hint taken from the window's own boundary (60 s for the minute window, the seconds until the next 00:00 UTC for the daily window, none for the trailing week) sent as the HTTP Retry-After header and as the websocket error event's headers retry-after, plus HTTP x-should-retry false when the window frees no sooner than a minute; a per-request estimate cap (max_input_tokens_per_request, max_output_tokens_per_request), and a daily or weekly token window whose max is below the request's own estimate, which no later window admits either, answer 400 invalid_request_error with no hint; the refused request row records the status the client received; with owner forwarding on or off the same request gets the same answer, including a chained client-retry successor refused by the key's own policy, which records its refused row under a correlation that holds no request claim; a refusal made before a request's durable claim never takes that claim, so the same request resent once the cause is gone is served instead of meeting 409 duplicate_turn"
    },
    %{
      slug: :api_key_terminal_policy_denials,
      status: :supported,
      current: :deterministic_denials_400,
      categories: [:route, :auth, :error, :streaming],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :post, path: "/backend-api/codex/images/generations"},
        %{method: :post, path: "/backend-api/codex/images/edits"},
        %{method: :post, path: "/v1/responses"},
        %{method: :get, path: "/v1/responses", transport: "websocket"},
        %{method: :post, path: "/v1/chat/completions"}
      ],
      future_routes: [],
      fixture: :api_key_terminal_policy_denials,
      contract: "an API key policy denial that no resend of the same request can pass answers 400 invalid_request_error on every route and transport, because the released Codex client ends the turn on a 400 while it resends a 403 five times and then falls back from websocket to HTTPS for the session: model_not_allowed (the key's allowed or enforced model excludes the requested one, as the Codex backend answers 400 for a model the account cannot serve) with param model and the Pooler's own message, and the per-request estimate caps and token windows below the request's own estimate of feature api_key_reservation_policy_refusals; the refused request row records 400; image_generation_disabled stays 403 because it is answered only on the HTTP image routes, which the released client's HTTP layer and image tool never resend on a 4xx; api_key_policy_malformed stays 403 because the request is not at fault; OpenAI SDKs retry neither 400 nor 403"
    },
    %{
      slug: :exhausted_pool_usage_limit,
      status: :supported,
      current: :terminal_429_usage_limit_reached,
      categories: [:route, :error, :streaming, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :post, path: "/v1/responses"},
        %{method: :get, path: "/v1/responses", transport: "websocket"},
        %{method: :post, path: "/v1/chat/completions"}
      ],
      future_routes: [],
      fixture: :exhausted_pool_usage_limit,
      contract: "when routing excludes every candidate of a Pool because its quota is exhausted and every exhausted window carries a reset still ahead, the refusal is the provider's own terminal answer for an exhausted account: 429 with error.type usage_limit_reached, the Pooler's code quota_exhausted and message, resets_at (epoch seconds) and resets_in_seconds for the soonest reset among the exhausted windows of every candidate (the listed windows do not say which one binds: a refused model meter marks all its windows exhausted, and a 100% account window stays listed next to a model-meter block; an account the provider reports blocked advises the soonest fresh reset of its exhausted account windows, or of all its fresh account windows when none reads exhausted), the HTTP Retry-After header and the websocket error event's headers retry-after in seconds, plus HTTP x-should-retry false when the wait exceeds 60 s; the released Codex client ends the turn on it and names the reset, the OpenAI SDKs stop; public /v1 renders it unredacted; with owner forwarding on or off the same request gets the same answer, in Full and Lite; the refused request row records 429; the answer stays the retryable 503 (quota_exhausted or quota_evidence_unavailable) when any candidate's return time is unknown (stale, resetless or missing evidence, a pending saved-reset probe, a provider-blocked account with no fresh reset-bearing account window) or when an open circuit removed a candidate before quota classification; the reset is advice, because an auto-redeemed saved reset can bring an account back sooner; a provider usage-limit 429 on the last eligible candidate (nothing left to fail over to) whose body names a reset still ahead (resets_at, else resets_in_seconds) gets the same terminal answer, advising the soonest of the provider's reset and the returns of the Pool's other candidates (each exhausted, workspace-denied or refused earlier in the request with a known reset; any other candidate without a known return keeps the relayed answer), on native HTTP (streaming or not) and every /v1 HTTP route, the provider's message, plan_type and other body fields never relayed, and the request row and attempt keeping the provider 429 and upstream_rate_limited; the same refusal sent as the upstream websocket's wrapped 429 frame before output reaches the native and public /v1 websockets as the wrapped terminal 429 event with headers retry-after and the Pool's advice (a sibling with no known return keeps the retryable frame); a streaming /v1 turn bridged onto the upstream websocket that meets that frame before output moves to another eligible candidate or answers the same terminal HTTP 429; on native routes a turn whose selected canonical partition's last candidate refuses with a provider usage limit before output moves once to a held-back partition that can serve the model now (the next request's partition selection), and when none can, the terminal answer's advice counts the held-back partition too; without such a reset, or when another candidate's return is not known, /v1 (HTTP and the upstream websocket bridge, Full and Lite) answers the redacted 429 rate_limit_error with Retry-After when an open circuit of another candidate bounds the wait, the public /v1 websocket the same error as an error event with headers retry-after, and the native websocket the classified wrapped 429 native HTTP relays; a retryable 503 of a Pool with a circuit-blocked candidate (the quota 503 next to an open circuit, or no_eligible_backend when circuits removed every candidate) carries Retry-After, and the websocket error event headers retry-after, with the seconds until the earliest such circuit admits a probe (an open circuit's next_probe_at, a saturated half-open circuit's probe going stale), clamped to 1..60, never with x-should-retry, also on the redacted /v1 answer, on the file route, and when a circuit refuses the last candidate at dispatch after route filtering admitted it"
    },
    %{
      slug: :reasoning_context,
      status: :supported,
      current: :openai_sdk_literal_normalization,
      categories: [:route, :auth, :error, :ownership],
      routes: [%{method: :post, path: "/v1/responses"}],
      future_routes: [],
      fixture: :reasoning_context,
      contract: "OpenAI Responses reasoning.context accepts SDK literals auto, current_turn, and all_turns after trimming and lowercasing, forwards accepted values through the Responses adapter, and rejects unknown or non-string context values before upstream dispatch"
    },
    %{
      slug: :unsupported_upstream_fields,
      status: :supported,
      current: :rejected_or_stripped_by_scope,
      categories: [:route, :auth, :ownership],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :unsupported_upstream_fields,
      contract: "OpenAI compatibility rejects known SDK request controls that cannot be translated locally and strips backend-only upstream-unsupported controls before dispatch"
    },
    %{
      slug: :api_key_websocket_revocation,
      status: :supported,
      current: :durable_api_key_epoch_fence,
      categories: [:auth, :error, :streaming, :ownership],
      routes: [
        %{
          method: :get,
          path: "/backend-api/codex/responses",
          transport: :websocket
        },
        %{
          method: :get,
          path: "/backend-api/codex/v1/responses",
          transport: :websocket
        },
        %{method: :get, path: "/v1/responses", transport: :websocket}
      ],
      future_routes: [],
      fixture: :api_key_websocket_revocation,
      contract: "pausing, revoking or deleting a Pool API key, its expiry, moving it to another Pool, and disabling, archiving or deleting its Pool close existing Responses websockets, all but the move block new authentication, and a pool-scoped event only prompts closure; a newer-epoch pause or revoke event latches directly, key delete, key edit and Pool status or delete events reread durable authorization, an edit that changes the key's Pool or expiry broadcasts to both Pools even when it submits an unchanged status, an event- or expiry-prompted reread that meets a database error retries with backoff while the socket stays open, and an idle socket rereads at the key's expiry; the locked durable key row, its captured revocation epoch, which a Pool move advances, its expiry against the database clock and its Pool status remain authoritative when relay is missed or delayed, refuse a key that no longer exists with the captured epoch, and authorize response.processed before any upstream forward; claim, replay-intent and reservation refusals latch revocation, queued and later work is dropped, only pre-admitted work drains and settles once before the fixed 1008 close, legacy epochless events reread durable authorization, resume or re-enable requires a fresh connection, and firewall revocation semantics remain unchanged"
    },
    %{
      slug: :firewall,
      status: :supported,
      current: :explicit_forwarded_client_policy,
      categories: [:route, :auth, :error, :ownership],
      routes: [
        %{family: :backend_codex, method: :get, path: "/backend-api/codex/models"},
        %{family: :backend_codex, method: :post, path: "/backend-api/codex/responses"},
        %{
          family: :backend_codex,
          method: :get,
          path: "/backend-api/codex/responses",
          transport: :websocket
        },
        %{family: :backend_files, method: :post, path: "/backend-api/files"},
        %{
          family: :backend_files,
          method: :post,
          path: "/backend-api/files/:file_id/uploaded"
        },
        %{family: :backend_transcribe, method: :post, path: "/backend-api/transcribe"},
        %{family: :codex_usage, method: :get, path: "/api/codex/usage"},
        %{family: :wham_usage, method: :get, path: "/wham/usage"},
        %{family: :backend_wham_usage, method: :get, path: "/backend-api/wham/usage"},
        %{family: :public_v1, method: :get, path: "/v1/models"},
        %{family: :public_v1, method: :post, path: "/v1/responses"},
        %{family: :public_v1, method: :get, path: "/v1/responses", transport: :websocket},
        %{family: :mcp, method: :post, path: "/mcp"}
      ],
      future_routes: [],
      fixture: :firewall,
      contract: "firewall checks are path-gated to runtime compatibility routes, use one explicit forwarded-client source with x_forwarded_for/depth 0 defaults, require a trusted immediate peer before any selected forwarding header, resolve duplicate XFF fields in wire order, fail cold settings with 503 while warm nodes keep last-known-good enforcement, revoke already-open websocket clients after local policy application without admitting new work, and expose one bounded denial counter with only scope and reason labels"
    },
    %{
      slug: :pruned_runtime_helper_firewall,
      status: :supported,
      current: :firewall_before_fixed_absence,
      categories: [:route, :error],
      routes: [],
      future_routes: [],
      fixture: :pruned_runtime_helper_firewall,
      contract: "pruned runtime helper routes enforce runtime settings availability and firewall policy before preserving their fixed unauthenticated HTML 404 response, without body parsing, upstream dispatch, reservation, or accounting side effects"
    },
    %{
      slug: :decompression,
      status: :supported,
      current: :bounded_compressed_json,
      categories: [:route, :error, :overload],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :compressed_request,
      contract: "request decompression accepts bounded gzip, deflate, and zstd JSON while compressed multipart stays unsupported"
    },
    %{
      slug: :bulkheads,
      status: :supported,
      current: :local_route_class_admission,
      categories: [:overload, :degraded],
      routes: [
        %{method: :get, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/responses/compact"}
      ],
      future_routes: [],
      fixture: :bulkhead_overload,
      contract: "bulkheads isolate HTTP proxy, websocket, compact, media, file, and operator lanes"
    },
    %{
      slug: :database_unavailable,
      status: :supported,
      current: :retryable_503_before_dispatch,
      categories: [:error, :degraded],
      routes: [
        %{method: :get, path: "/backend-api/codex/models"},
        %{method: :get, path: "/backend-api/codex/responses", transport: :websocket},
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/v1/responses"}
      ],
      future_routes: [],
      fixture: :database_unavailable,
      contract: "a transient database failure (unreachable or stalled pool, PostgreSQL connection, shutdown, start-up, resource or cancellation condition) during runtime authentication, request preparation, the websocket turn claim, the websocket replay intent read or inside the reservation transaction (retry successor claims included) answers a retryable 503 service_unavailable with a server_error type and no database detail (an error event on the websocket), records no denied request, reserves nothing and sends nothing upstream"
    },
    %{
      slug: :degraded_routing,
      status: :supported,
      current: :bridge_ring_fallback,
      categories: [:route, :error, :ownership, :degraded],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :degraded_routing,
      quota_evidence: %{
        normal_authority: "fresh_reset_bearing_windows",
        lower_priority_fallback: "provider_attested_windowless_availability",
        operator_or_sku_gate: false,
        synthetic_window_or_reset: false
      },
      contract: "degraded routing demotes failed bridge candidates and records sanitized routing metadata; fresh reset-bearing quota windows remain normal authority, while a fresh current-credential provider-attested availability observation with no account-window evidence is a distinct lower-priority routeable state; blocked, unknown, stale, credential-mismatched, malformed, or applicable model/additional-limit evidence fails closed with the existing 503 errors, without an operator or SKU gate and without fabricating a quota window or reset"
    },
    %{
      slug: :strict_schema_validation,
      status: :supported,
      current: :pre_reservation_rejection,
      categories: [:route, :auth, :error, :ownership],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :strict_schema_rejection,
      contract: "strict structured-output schemas are validated before reservation or upstream dispatch"
    },
    %{
      slug: :public_strict_schema_object_roots,
      status: :supported,
      current: :public_pre_dispatch_object_root_rejection,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :post, path: "/v1/responses"},
        %{method: :get, path: "/v1/responses", transport: "websocket"},
        %{method: :post, path: "/v1/chat/completions", translation: "backend_responses"},
        %{
          method: :post,
          path: "/backend-api/codex/v1/chat/completions",
          translation: "backend_responses"
        }
      ],
      future_routes: [],
      fixture: :public_strict_schema_object_roots,
      contract: "strict schemas on public Responses HTTP and websocket, public Chat, and the translated backend Chat alias require a direct concrete object root before dispatch or accounting; omitted, primitive, array, singleton-array, nullable-union, root-ref, root-anyOf, and object-plus-root-anyOf roots are rejected, while nested supported constructs, both definition dialects, non-strict schemas, direct Responses nested repair, and native backend Responses behavior remain unchanged"
    },
    %{
      slug: :unsupported_input_image_reference,
      status: :supported,
      current: :pre_reservation_rejection,
      categories: [:route, :auth, :error, :ownership],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}, %{method: :post, path: "/v1/responses"}, %{method: :post, path: "/v1/chat/completions"}],
      future_routes: [],
      fixture: :unsupported_input_image_reference,
      contract: "Responses input_image.file_id references are forwarded unchanged on every serving mode (Lite removes only the detail hint), and one the Pool bridged pins the request to the assignment holding the file like input_file; Codex sediment:// file URIs and unsupported URL schemes such as http:// and file:// used as input_image.image_url values are rejected before reservation or upstream dispatch. Public /v1/responses forwards input_image.detail from message and tool-output images alike on a Full model and Lite removes it, as native requests do; a null detail is dropped from message and tool-output images alike (the native client never sends one), and a detail outside low, high, auto and original is refused on every serving mode with 400 invalid_value on the provider's field path (input[i].output[j].detail or input[i].content[j].detail, indexed on the input as the client sent it) before reservation or upstream dispatch. Public /v1/chat/completions carries image_url.detail into the rebuilt input_image detail under the same rules (Full forwards it, Lite removes it, null is absent) and refuses a value outside that enum on every serving mode with 400 invalid_value on the Chat field path (messages[i].content[j].image_url.detail) before reservation or upstream dispatch. Public /v1/chat/completions also carries image_url parts of a role tool message into the rebuilt function_call_output as input_image under the same detail rules, and still refuses a file part in a tool message. The Pooler extension shapes that hold a Chat-style image inside a tool result carry image_url.detail under the same rules: an image_url part of a /v1/responses role tool item becomes a tool-output input_image and is refused at input[i].content[j].image_url.detail, and a Cline tool-result image on /v1/chat/completions is refused at messages[i].content[j].output[k].image_url.detail (or .detail for an input_image part)"
    },
    %{
      slug: :first_event_stream_retry,
      status: :supported,
      current: :pre_first_event_retry,
      categories: [:route, :auth, :error, :streaming, :ownership, :degraded],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :first_event_stream_retry,
      contract: "transient SSE failures may retry only before the client sees output, message, tool, or delta events"
    },
    %{
      slug: :request_compression,
      status: :supported,
      current: :pool_gated_request_side_payload_rewrite,
      categories: [:route, :auth, :error, :streaming, :ownership, :degraded],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/v1/responses"},
        %{method: :post, path: "/backend-api/codex/v1/chat/completions"},
        %{method: :post, path: "/v1/responses"},
        %{method: :post, path: "/v1/chat/completions"},
        %{method: :post, path: "/backend-api/codex/responses/compact"},
        %{method: :post, path: "/backend-api/codex/v1/responses/compact"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :get, path: "/backend-api/codex/v1/responses", transport: "websocket"},
        %{method: :get, path: "/v1/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :request_compression,
      contract: "Request compression is Pool-gated by request_compression_enabled, request-side only, fail-open to the original upstream request when scanning, token counting, rewriting, or limits fail, and metadata-only through safe payload_compression request-log metadata; eligible routes are backend Responses, backend /v1 Responses/chat aliases, public /v1 Responses/chat translations, backend compact routes, and backend or narrow public websocket response.create dispatches; protected exact-output function tool outputs for Read, Glob, Grep, Write, Edit, WebSearch, WebFetch, web_search, web_fetch, and external retrieval are skipped before rewriting with aggregate-only skip counts; output-only function tool results fail closed as protected when their tool name is unavailable; recognized same-frame command-backed file reads use bounded cat, nl, head, tail, sed-print-only, or nl-to-sed-print-only grammar and remain byte-exact before output range lookup or content detection; function and native local-shell producers and outputs resolve only through their declared same-frame identifiers, and duplicate, cross-kind, or conflicting identifiers preserve the original output; malformed or unrecognized commands retain existing behavior; search-result compression covers classic path-line matches, grouped heading matches, and portable NUL-delimited matches, diff compression covers hunk-based additions-only, deletions-only, replacement, minimal unified diffs, combined unified diffs, and long-preamble diffs, log-output compression preserves every failure block when a summary reports failure/error counts, and valid JSON object or array spans embedded in ordinary prose are minified losslessly while surrounding bytes, quoted JSON-looking text, malformed spans, and over-limit span sets remain unchanged; ordinary prose without eligible embedded JSON remains outside diff/search/log compression shapes; public /v1/responses/compact remains unsupported with no upstream compact dispatch or compression eligibility"
    },
    %{
      slug: :upstream_websocket_bridge,
      status: :supported,
      current: :owner_websocket_cache_bridge,
      categories: [:route, :auth, :error, :streaming, :ownership, :degraded],
      routes: [%{method: :post, path: "/v1/responses"}],
      future_routes: [],
      fixture: :upstream_websocket_bridge,
      owner_protocol: %{
        submission: "versioned_data_only",
        callback_construction: "owner_node_only",
        incompatible_remote_owner: "reject_before_owner_lookup_or_upstream_submission",
        native_result: "existing_owner_unavailable_error",
        previsible_bridge_result: "fail_closed_without_resubmission"
      },
      observability: %{
        format_status: "bounded_lifecycle_and_boolean_projection",
        opaque_transient_inspection: true,
        payload_disclosure: false,
        authorization_disclosure: false
      },
      contract: "the upstream websocket bridge applies only to public /v1/responses streaming turns with websocket owner forwarding enabled, no attached websocket writer, and a continuity session that is unpinned or pinned to the selected assignment; the downstream contract stays HTTP SSE while the turn dispatches over the session's owner websocket as a cache-locality heuristic, never a cache guarantee; the bridge commits on the first client-rendered content event, on any unknown event fail-closed, on any structurally valid terminal, or at its bounded pre-content buffer caps and commit deadline, buffering lifecycle envelopes, item and part adds, and internal codex.* events until then; after any accepted websocket payload, complete silence through the bounded preflight, a pre-content peer close, TCP cut, receive timeout, pong timeout, or missing terminal fails once without HTTP fallback or automatic replay because zero downstream content does not prove zero provider work; a private owner barrier delays settlement of a terminal-bearing result until its terminal frame is delivered, and a committed terminal-delivery timeout fails once without HTTP fallback or automatic replay; timeout diagnostics move through one atomic one-shot metadata handoff and remain health-neutral; invalidation preserves the owner lifecycle, so the next explicit turn reconnects at generation plus one and a later healthy turn reuses that generation; persisted leases provide two-node owner forwarding, fencing, transfer, and takeover; after visible output an upstream death finalizes the request as failed instead of synthesizing an empty success; a provider refusal the upstream websocket sends before any content as its wrapped error frame with a 4xx status other than 429 (except the websocket-retry codes websocket_connection_limit_reached and previous_response_not_found) answers the public client with the same HTTP status and OpenAI error body as the HTTP path and records the same rejection fields on the websocket attempt, without HTTP resubmission; a turn anchored on previous_response_id is bound to its owner connection, because the provider resolves the anchor only on the connection that produced it: on a fresh connection the owner refuses it before its response.create with the codeless 400 the provider answers there, and that refusal or the provider's own Invalid previous_response_id refusal on a reused connection answers the public client 400 previous_response_not_found with param previous_response_id and a Pooler-authored message naming the requirement, while a public /v1/responses request anchored on previous_response_id that is not bridged (not streaming, owner forwarding off, or a session pinned to another assignment) is answered with the same error before any upstream call; websocket owner submission is versioned and data-only, and callbacks are built only on the owner node; incompatible remote legacy protocol submission fails before owner lookup or upstream submission without hidden HTTP resubmission; format_status/1 and opaque transient inspection protect crash and status observability from payload and authorization disclosure; websocket_owner_idle_timeout_ms controls post-detach owner retention with a 1_800_000 ms default and 60_000..3_600_000 ms bounds, is captured node-locally by each new or recovered owner, and does not change existing owners; the attempt-only upstream_websocket_connection namespace contains exactly lifecycle_id, generation, reused, and reconnected; the attempt records transport websocket plus upstream_websocket_bridge and upstream_transport metadata while the request keeps the downstream http_sse transport, and payload_compression metadata describes the websocket envelope actually sent; the submit task surfaces owner failures as scrubbed atom reasons without copying payload or authorization into crash logs; option-carrying bridge attaches fail closed without resubmission against owner nodes still running the previous release while option-less native attaches keep the two-argument remote shape and previous-release owners retain legacy five-minute behavior without connection metadata"
    },
    %{
      slug: :image_generation_permission,
      status: :supported,
      current: :pool_gated_image_generation_permission,
      categories: [:route, :auth, :error],
      routes: [
        %{method: :post, path: "/backend-api/codex/images/generations"},
        %{method: :post, path: "/backend-api/codex/images/edits"},
        %{method: :post, path: "/v1/images/generations"},
        %{method: :post, path: "/v1/images/edits"}
      ],
      future_routes: [],
      fixture: :image_generation_permission,
      contract: "image generation and edits are Pool-gated by allow_image_generation (default on) after runtime authentication and before request parsing or upstream dispatch; disabled Pools receive a deterministic 403 image_generation_disabled error"
    },
    %{
      slug: :responses_allowed_tools,
      status: :supported,
      current: :declaration_backed_full_mode_choice,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :post, path: "/v1/responses"},
        %{method: :get, path: "/v1/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :responses_allowed_tools,
      contract: "direct public Responses HTTP and websocket response.create accept an exact type=allowed_tools choice only in Full mode, with mode auto or required and a nonempty ordered tools list; named function and custom entries must resolve to undeferred direct top-level same-kind declarations, while type-only programmatic_tool_calling, web_search_preview, web_search, and image_generation entries require a declared top-level tool of the same type; order and duplicates are forwarded unchanged after only the existing tool-definition schema lowering; malformed or undeclared Full choices fail before admission or accounting, valid Lite choices create one rejected Request without Attempts or Ledger rows, top-level MCP declarations retain the tools error while MCP allow-list members use the tool_choice error, and Chat, native backend Responses, namespaces, additional_tools, deferred tools, aliases, unsupported entries, Realtime, and broad OpenAI tool parity remain excluded"
    },
    %{
      slug: :responses_executable_custom_tools,
      status: :supported,
      current: :responses_and_chat_custom_tool_admission,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :post, path: "/v1/responses"},
        %{method: :get, path: "/v1/responses", transport: "websocket"},
        %{method: :post, path: "/v1/chat/completions"}
      ],
      future_routes: [],
      fixture: :responses_executable_custom_tools,
      contract: "direct public Responses HTTP and websocket response.create accept executable custom tools with an exact nonblank name, optional description and defer_loading, nullable direct/programmatic allowed_callers, and omitted, text, lark-grammar, or regex-grammar input format; the same exact custom definition is accepted as a child of a nonblank namespace with a nonempty tool list alongside exact flat function children; translated Chat Completions accepts the official nested custom definition with nonblank name and optional description or format plus the official nested named custom choice, flattens both into the Responses request, and projects completed JSON and streamed custom_tool_call input back into the Chat custom shape without parsing free-form input as JSON; an exact typed custom choice resolves only a declared custom tool of the same name and kind, including a namespace child, is preserved in Full mode, and is rejected before upstream dispatch in Lite mode with unsupported_parameter for tool_choice; that Lite rejection is serving-mode driven and covers any map-shaped tool_choice on any lane dispatching to backend Responses, including translated Chat choices, while string choices such as auto remain accepted in both modes; executable names are collision-free across flat functions, namespace children, and custom tools; malformed and unrelated tool families remain rejected, custom replay is a separate input-item contract, provider execution availability depends on the selected model and upstream account, and no broad OpenAI tool parity is claimed"
    },
    %{
      slug: :backend_agent_v2_handoffs,
      status: :supported,
      current: :canonical_encrypted_agent_handoff_preservation,
      categories: [:route, :streaming, :ownership],
      routes: [
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :get, path: "/backend-api/codex/v1/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :backend_agent_v2_handoffs,
      contract: "backend Codex websocket response.create preserves canonical encrypted agent v2 NEW_TASK and MESSAGE handoffs only when the item contains exactly one input_text protocol envelope followed by one nonempty encrypted_content part, author and recipient are /morpheus or /root paths with lowercase-letter, digit, or underscore child segments, and the envelope task name and sender exactly match recipient and author; other encrypted agent_message variants remain filtered, assistant encrypted replay remains preserved, and durable request or attempt metadata never stores the encrypted payload"
    },
    %{
      slug: :multi_agent_product_certification,
      status: :supported,
      current: :pinned_full_mode_v1_v2_stage_classification,
      categories: [:route, :streaming, :ownership],
      routes: [
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :get, path: "/backend-api/codex/v1/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :multi_agent_product_certification,
      contract: "pinned Codex source certification uses distinct source-valid Full-mode lanes: gpt-5.5 resolves v1 through feature fallback, while gpt-5.6-terra resolves v2 through the explicit feature override and is also the direct-control model; preflight requires an authenticated Full catalog snapshot and absent HTTP and websocket Lite markers; live-text and DoneClaim verdicts remain staged, opaque v2 encrypted arguments are classified as instruction_observation_missing when no permitted resolved-instruction source exists, and the native Pooler websocket writer preserves a structural child output_text delta byte-for-byte without a production transport change"
    },
    %{
      slug: :function_tool_schema_lowering,
      status: :supported,
      current: :non_strict_function_tool_schema_lowering,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/codex/v1/responses"},
        %{method: :get, path: "/backend-api/codex/responses", transport: "websocket"},
        %{method: :get, path: "/backend-api/codex/v1/responses", transport: "websocket"},
        %{method: :post, path: "/v1/responses"},
        %{method: :get, path: "/v1/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :function_tool_schema_lowering,
      contract: "backend Responses HTTP and websocket response.create lower and remove encrypted markers only for ordinary top-level non-strict function tool schemas while preserving every decoded top-level namespace tool term exactly; public /v1 Responses HTTP and websocket recursively lower nested namespace function tools before local validation or upstream dispatch; lowering converts boolean schemas and const values into supported schema shapes, infers missing object or array structure, drops unsupported JSON Schema keywords, preserves supported refs/definitions/combinators recursively, and never weakens strict function tools or strict structured-output schemas"
    },
    %{
      slug: :direct_responses_strict_schema_repair,
      status: :supported,
      current: :nested_missing_type_repair,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [
        %{method: :post, path: "/v1/responses"},
        %{method: :get, path: "/v1/responses", transport: "websocket"}
      ],
      future_routes: [],
      fixture: :direct_responses_strict_schema_repair,
      contract: "direct public Responses HTTP and websocket response.create may repair only a missing nested object or array type in top-level strict flat-function parameters or strict flat-function children of accepted namespaces when structural evidence is complete and unambiguous; the parameters root, explicit type values, refs, definition tables, combinators and their descendants, annotations, unknown keywords, ambiguous or incomplete evidence, strict structured outputs, Chat, the older nested function wrapper shape, and backend routes are not repaired; public Responses and Chat reject malformed, duplicate, or unsupported explicit type values globally before generic strict validation; strict function tools and strict structured-output schemas remain excluded from non-strict lowering"
    },
    %{
      slug: :v1_supported_surface,
      status: :supported,
      current: :authenticated_openai_compatibility,
      categories: [:route, :auth, :error, :multipart, :streaming, :ownership],
      routes: [
        %{method: :get, path: "/v1/models"},
        %{method: :get, path: "/v1/responses"},
        %{method: :post, path: "/v1/responses"},
        %{method: :post, path: "/v1/responses/compact"},
        %{method: :post, path: "/v1/chat/completions"},
        %{method: :get, path: "/v1/usage"},
        %{method: :get, path: "/v1/files"},
        %{method: :post, path: "/v1/files"},
        %{method: :get, path: "/v1/files/:file_id"},
        %{method: :get, path: "/v1/files/:file_id/content"},
        %{method: :delete, path: "/v1/files/:file_id"},
        %{method: :post, path: "/v1/audio/transcriptions"},
        %{method: :post, path: "/v1/images/generations"},
        %{method: :post, path: "/v1/images/edits"}
      ],
      future_routes: [],
      fixture: :v1_supported_surface,
      contract:
        "Images accepts gpt-image-2.5-flare and gpt-image-2.5-sunburst alongside legacy identifiers, sends basic generation and edits to native Codex Images with the requested image model, routes masked edits through eligible Full Responses hosts with an explicit image tool choice and rejects masks before dispatch/accounting when no Full host is available, accepts GPT Image 2.5 dated snapshots, xhigh/max quality and bounded custom dimensions without promising provider adherence, and restricts configurable input_fidelity to gpt-image-1/1.5; " <>
          "Audio transcription accepts gpt-transcribe only as a caller alias for canonical gpt-4o-transcribe, accepts decoded keywords and languages as ordered non-empty string lists with duplicates preserved, omits empty lists, forwards exact repeated keywords[] and languages[] names, rejects malformed lists by field, removes detected languages from public output, stores no raw audio or decoded list values after auth-before-multipart, and makes no alias catalog, model-discovery, detected-language-output, or full OpenAI Audio parity claim; " <>
          "OpenAI-compatible /v1 routes are default-on for pools, require bearer API-key auth, return OpenAI-shaped errors without anonymous local or CIDR bypasses, include narrow GET /v1/responses Responses websocket compatibility only, exclude broad /v1/realtime routes, keep POST /v1/responses/compact routed only to deterministic unsupported_endpoint with no upstream compact dispatch, reject OpenAI Responses remote MCP tool definitions before upstream dispatch in both top-level tools and nested additional_tools.tools locations with OpenAI-shaped invalid_request errors, consume continuity headers using the documented local precedence without forwarding session-id, x-session-id, or x-session-affinity upstream, synthesize the upstream session-id header on POST /v1/responses and POST /v1/chat/completions as UUID v5 of the fixed Pooler namespace over a non-empty prompt_cache_key of at most 512 bytes without persisting or logging the derived value, fail closed for pinned /v1/responses continuations whose upstream account needs revoked-refresh-token reauthentication with the shared restart_with_full_context recovery guidance, allow prompt-cache routing locality only on POST responses and chat completions, accept Codex-native Responses web_search hosted tool shapes with boolean access flags while keeping web_search_preview type-only, accept Responses truncation auto and disabled locally without forwarding it upstream, lift Responses system/developer input-message text into top-level instructions, treat absent, blank, and whitespace-only public SSE event labels identically before event/data type precedence while rejecting nonblank mismatches, emit early public streaming terminal errors without synthetic success prefixes, emit a sanitized type:error terminal with wire code server_error while accounting records upstream_stream_error when POST /v1/responses SSE has already exposed public Responses data and an ordinary upstream interruption occurs before a Responses terminal event, cap ordinary incomplete public Responses SSE blocks at 8 MiB so single large provider events such as reasoning items with encrypted content can finish decoding while allowing structurally recognizable terminal candidates up to 64 MiB so split large terminals can finish decoding, and emit that same bounded local terminal immediately when the applicable cap is crossed while dropping the source block and later frames, accounting records owner_drained while the emitted wire frame is byte-identical to the ordinary synthetic terminal when a committed websocket-bridge turn is aborted by rollout drain after its drain budget or when a rollout drain interrupts an in-flight deferred HTTP SSE stream, each settling exactly once with response status 499, an interrupted turn and a released reservation, fail precommit drains without hidden HTTP resubmission once submission is ambiguous, keep client disconnect and non-drain interruption mappings unchanged, limit synthetic SSE terminals to OpenAI-compatible HTTP SSE surfaces, drop malformed and JSON non-object provider frames on direct and accepted owner-forwarded GET /v1/responses without advancing public websocket state, emit the existing websocket type:error envelope with status 502 and wire code server_error when an owner-forwarded GET /v1/responses per-call turn is interrupted after committed public output while accounting records upstream_stream_error, never synthesize that interruption for pre-visible owner-forwarded turns, preserve native backend raw Responses streams and all other websocket behavior, and preserve bridge complete-block behavior, redact server-class/internal/upstream public /v1 errors while preserving invalid_request_error validation details, preserve safe machine-readable codes for redacted public OpenAI-compatible Responses terminal failures in nested response.error through low-level public SSE normalization and the runtime streaming relay, keep top-level error code-aligned when Pooler emits one, map Responses content_filter/content-filter incomplete reasons to chat finish_reason content_filter while other incomplete reasons remain length, forward structured tool-result/function_call_output payloads unchanged, translate chat-style role=tool continuation messages and Hermes assistant tool-call replays into Responses function_call/function_call_output input items before validation, accept safe Hermes assistant replay status values, drop known OMP function_call replay status fields before validation, translate OpenClaw assistant thinking replays before validation, accept narrow Codex custom tool replay with custom_tool_call.namespace preservation and matching custom_tool_call_output, accept executable custom definitions directly on Responses and through the official translated Chat wrapper, and keep chat input fallback, Responses additional_tools support narrow and non-executable, and Responses namespace-tool support narrow. Public /v1 admits closed-key hosted-shell history replay for shell_call and shell_call_output but does not execute commands or accept shell tool declarations, local shell, or remote MCP. For genuine upstream Responses terminal failures, the public `/v1` surface constructs a named-field `response.failed` projection, excludes unknown event, response, error, and usage siblings, validates the response id, projects bounded usage counters, and empties or nulls content-bearing response fields. It preserves a trimmed upstream error code only when it is at most 80 bytes and matches `^[A-Za-z0-9_.-]+$`, redacts every other code value to `upstream_error`, replaces upstream message text with `upstream request failed`, and upstream type text — including clean values — is replaced with `server_error`. Top-level and nested errors are sanitized independently without copying either location to the other, and clients must treat `error.code` as an open string. Public /v1 Responses SSE and websocket events relay no provider event header objects: the top-level headers object and the nested response.headers object are dropped from every relayed event, terminal or not, while native websocket turns with a Pooler snapshot keep projecting only the native response controls. A public /v1/responses SSE terminal that closes a response the upstream never opened is preceded by the Responses stream grammar: a response.created snapshot carrying the terminal response id, created_at and model with an empty output list, then every terminal output item announced in output order with output_item.added, message content parts with output_text delta and done events addressed by item_id, output_index and content_index, and output_item.done; nothing is synthesized once the upstream relayed an output item or a text delta, and reasoning content is never surfaced as output text. A public output item the upstream sent without an id carries its own call_id when it has one; otherwise it carries the fallback id <type>_<output_index>; replayed as /v1 Responses input, a message or compaction item whose id is exactly its own type's fallback id, a reasoning item with nonblank encrypted content and such an id, or a function_call, custom_tool_call, shell_call or shell_call_output item whose id equals its own call_id reaches the upstream without an id, while provider ids and every other id are forwarded unchanged. The public /v1/responses SSE relays only the public Responses stream vocabulary, response.* events, the error terminal and keepalive, on either upstream transport; backend-internal events such as codex.* controls and the upstream websocket's responsesapi.websocket_timing are dropped before sequence numbering. The public GET /v1/responses websocket relays the same vocabulary, response.* events and the error event, on direct and owner-forwarded turns, and drops codex.* controls, responsesapi.* events and typeless non-terminal frames before sequence numbering. A provider refusal the upstream websocket sends as its wrapped error frame with a 4xx status other than 429 (except websocket_connection_limit_reached and previous_response_not_found) reaches a public GET /v1/responses websocket client as the websocket error event with that status and the error object a streaming POST /v1/responses answers over HTTP under the default projection (the relayed parameter-validation rejection, otherwise the redacted upstream error with code upstream_status), and the websocket attempt records the same rejection fields; a 429, a 5xx and those two codes keep the masked response.failed."
    },
    %{
      slug: :v1_unsupported_public_surface,
      status: :supported,
      current: :openai_shaped_unsupported_route_contract,
      categories: [:route, :auth, :error],
      routes: [
        %{method: :post, path: "/v1/images/variations"},
        %{method: :post, path: "/v1/content_provenance_checks"},
        %{method: :post, path: "/v1/embeddings"},
        %{method: :post, path: "/v1/batches"},
        %{method: :post, path: "/v1/moderations"},
        %{method: :post, path: "/v1/fine_tuning/jobs"},
        %{method: :get, path: "/v1/responses/:response_id"},
        %{method: :post, path: "/v1/responses/:response_id/cancel"},
        %{method: :delete, path: "/v1/responses/:response_id"}
      ],
      future_routes: [],
      fixture: :v1_unsupported_public_surface,
      contract: "unsupported OpenAI public routes are explicitly routed only to return deterministic OpenAI-shaped 404 errors before gateway admission or upstream dispatch"
    }
  ]

  @fixtures %{
    file_upload: %{
      json: %{"file_name" => "fixture-upload.txt", "file_size" => 24, "use_case" => "codex"}
    },
    backend_transcription: %{
      fields: %{"prompt" => "synthetic backend glossary"},
      filename: "fixture-backend-audio.wav",
      content_type: "audio/wav",
      bytes: "synthetic backend wav bytes"
    },
    backend_image_proxy_surface: %{
      auth: "required_bearer_api_key",
      default_enabled: true,
      route_class: "proxy_http",
      routes: [
        "/backend-api/codex/images/generations",
        "/backend-api/codex/images/edits"
      ],
      json: %{
        "model" => "gpt-image-2",
        "prompt" => "synthetic backend image proxy request"
      }
    },
    backend_models_etag: %{
      header: "etag",
      digest_input: "policy_visible_native_catalog_body",
      digest: "sha256_deterministic_canonical_json",
      format: "weak_cp_models_v1",
      aliases_share_exact_body_and_token: true,
      cache_coherence: "eventual_after_successful_responses_token",
      instructions_representation: %{
        selector: "codex_build_user_agent",
        template_only_since: "0.148.0",
        template_only: "base_instructions_dropped_when_instructions_template_is_a_string",
        verbatim: "older_0_147_0_or_non_codex_user_agent",
        etag_input: "served_representation",
        vary_header: "user-agent",
        client_version_query: :ignored,
        decode_checked: %{
          window: {"0.154.0", "0.156.1"},
          window_version: "whole_version_prereleases_included",
          body: "template_only_minus_entries_the_client_cannot_decode",
          left_out_model: %{advertised: false, routable: true},
          operator_log: "codex catalog entry left out",
          log_fields: ["pool_id", "model", "fields"]
        },
        turn_selector: "codex_build_user_agent"
      }
    },
    backend_responses_etag: %{
      header: "x-models-etag",
      equals: "authenticated_backend_models_etag",
      http_json: :excluded,
      http_sse: %{surface: :response_header, authority: :request_snapshot},
      websocket: %{
        upgrade: %{surface: :response_header, authority: :backward_compatible_connection_open},
        turn: %{
          surface: :codex_response_metadata_event,
          authority: :current_turn_snapshot,
          event_type: "codex.response.metadata"
        }
      },
      snapshot_lifetime: %{
        http: :request,
        websocket: :response_create_turn,
        retry: :preserve,
        native_replay: :preserve,
        owner_forwarding: :preserve,
        next_websocket_turn: :reresolve
      },
      upstream_etag_relay: false,
      representation_selector: "user_agent_package_version",
      provider_metadata_event: %{
        order: :after_pooler_event,
        x_models_etag: :removed,
        consumer_etag_source: :metadata_event_carrying_x_models_etag
      },
      included_routes: [
        "/backend-api/codex/responses",
        "/backend-api/codex/v1/responses"
      ],
      excluded_surfaces: [
        "backend_json",
        "backend_compact",
        "public_v1",
        "usage",
        "unauthenticated",
        "unrelated_routes"
      ]
    },
    pool_model_serving_modes: %{
      persistence: %{
        scope: :pool_model_pair,
        shared_store: :postgres,
        persisted_modes: [:lite, :full],
        auto_representation: :row_absence,
        canonical_model_id: true,
        survives_catalog_churn: true,
        client_visible_model_ids: 1
      },
      auto_truth_table: %{
        any_routable_source_literal_true: :lite,
        all_routable_source_values_false_missing_or_malformed: :full,
        source_map_present_ignores_legacy_aggregate: true,
        absent_or_non_map_source_map_with_legacy_aggregate_literal_true: :lite,
        absent_or_non_map_source_map_with_other_aggregate_value: :full,
        zero_routable_sources: :no_runtime_model
      },
      snapshot_lifetime: %{
        http: :request,
        websocket: :response_create_turn,
        retry: :preserve,
        cross_assignment_failover: :preserve,
        owner_forwarding: :preserve,
        next_websocket_turn: :reresolve
      },
      catalog_etag: %{
        backend_field: "use_responses_lite",
        backend_value: :effective_boolean,
        digest_scope: :final_policy_visible_body,
        public_v1_models: :unchanged
      },
      accounting: %{
        request_namespace: "request_metadata",
        request_nested_namespace: "routing",
        attempt_namespace: "response_metadata",
        keys: [
          "model_serving_mode_configured",
          "model_serving_mode",
          "model_serving_mode_source"
        ],
        retry_snapshot: :identical,
        raw_payload_fields: false
      },
      compact: %{
        backend_uses_snapshot: true,
        backend_transforms_payload: true,
        public_path: "/v1/responses/compact",
        public_status: 404,
        public_error_code: "unsupported_endpoint",
        public_upstream_dispatch: false
      },
      public_v1_exclusions: %{
        models_mode_fields: false,
        models_body_changed: false,
        compact_supported: false
      },
      assignment_eligibility: %{
        use_responses_lite_candidate_filter: false,
        membership_contract: :unchanged
      },
      configuration: %{
        client_api_key: :unchanged,
        client_model_id: :unchanged,
        client_configuration: :unchanged,
        global_env_switch: false,
        helm_value: false
      },
      full_rejection_diagnostic: %{
        error_code: "upstream_status",
        applies_to: :explicit_full_ordinary_responses_http_non_rate_limit_4xx_rejection,
        error_code_varies_by_serving_mode: false,
        serving_mode_diagnostic_source: :request_and_attempt_routing_metadata,
        rate_limit_error_code: "upstream_rate_limited",
        ordinary_5xx_error_code: "upstream_status",
        upstream_status_retained: true,
        client_error: %{
          "code" => "invalid_request",
          "message" => "upstream rejected parameter tools.defer_loading (invalid_request)",
          "param" => "tools.defer_loading",
          "type" => "invalid_request_error"
        },
        client_error_message_source: :relayed_code_and_param_and_persisted_supported_values,
        client_error_message_matches_non_full_relay: true,
        supported_values_suffix_relayed: true,
        supported_values_source: :persisted_bounded_attempt_metadata,
        client_error_without_sanitized_rejection_type: %{
          "code" => "server_error",
          "message" => "upstream request failed",
          "type" => "server_error"
        },
        relayed_sanitized_rejection_fields: [:type, :code, :param],
        relayed_rejection_code_fallback_by_type: %{
          "invalid_request_error" => "invalid_request"
        },
        relay_window: :rejection_metadata_status,
        provider_message_forwarded: false,
        unchanged_client_response_scopes: [
          :auto,
          :lite,
          :compact_and_unrelated_routes,
          :established_model_miss
        ],
        silent_downgrade: false,
        raw_upstream_error_text: false
      }
    },
    backend_responses_envelope: %{
      noncompact: %{
        reasoning: "map",
        encrypted_include: "reasoning.encrypted_content",
        encrypted_include_count: 1,
        summary_capability: "selected_assignment_literal_false_removes_summary",
        idempotent_after_json_round_trip: true
      },
      compact: %{
        applies_noncompact_envelope: false,
        preserves_existing_shape: true
      }
    },
    upstream_error_param: %{
      field: "upstream_error_param",
      source: "decoded_upstream_error_envelope",
      projection: "failed_attempt_detail_only",
      max_bytes: 160,
      allowed_shape: "field_name_or_index_path",
      invalid_or_successful_attempt: "omitted",
      raw_error_message_or_value: "never_projected"
    },
    terminal_failure_diagnostics: %{
      fields: ~w(upstream_error_code stream_terminal_type compaction_invalid_reason upstream_error_param),
      projection: "failed_and_retryable_failed_attempt_detail_only",
      readable_identifier: "strict_ascii_80_bytes_or_less_cleartext",
      malformed_identifier: "sha256_12",
      invalid_or_successful_or_historical_attempt: "omitted",
      raw_provider_message_body_or_frame: "never_projected"
    },
    rejection_metadata: %{
      fields: [
        "rejection_error_code",
        "rejection_error_type",
        "rejection_error_param",
        "rejection_message_present",
        "rejection_message_bytes",
        "rejection_supported_values_state",
        "rejection_supported_values"
      ],
      source: "private_stream_drain_then_materialized_body",
      projection: "failed_attempt_detail_only",
      max_body_bytes: 65_536,
      token_max_bytes: 80,
      param_max_bytes: 160,
      message_bytes_max: 1_024,
      accepted_shape: "direct_string_key_error_map",
      invalid_shapes: "omitted",
      raw_error_message_or_body: "never_projected"
    },
    upstream_validation_rejection_relay: %{
      upstream_status: 400,
      error_type: "invalid_request_error",
      codes: ~w(
        unsupported_value
        invalid_value
        unsupported_parameter
        missing_required_parameter
        invalid_type
        string_above_max_length
      ),
      source: "private_stream_drain_then_materialized_body",
      relayed_fields: ~w(type code param message),
      param: "bounded_field_path_or_null",
      message: "pooler_authored_from_code_and_param",
      full_supported_values_example: %{
        "error" => %{
          "type" => "invalid_request_error",
          "code" => "unsupported_value",
          "param" => "reasoning.effort",
          "message" => "upstream rejected parameter reasoning.effort (unsupported_value); supported values: low, medium, high"
        }
      },
      supported_values: %{
        codes: ~w(unsupported_value invalid_value),
        serving_modes: ~w(auto lite full),
        source: "strict_trailing_provider_list",
        token_pattern: "[A-Za-z0-9_.-]{1,32}",
        max_values: 12,
        message_max_bytes: 2_048,
        rejected_or_earlier_quoted_values: "excluded",
        unparseable: "omitted",
        persisted_as: "rejection_supported_values",
        states: ~w(present none unparseable),
        state_absent_when: "code_outside_value_oriented_pair_or_rejection_not_admitted",
        relayed_under_explicit_full_override: true
      },
      chat_param: "client_field_for_adapter_renames_else_upstream_path",
      provider_message_forwarded: false,
      native_streaming_body: "native_json_error_envelope",
      native_materialized_body: "native_json_error_envelope",
      native_non_relayable_400_body: "pooler_refusal_error_from_sanitized_tokens",
      native_final_4xx_refusal: %{answered_status: 400, statuses: "402..499 except 408 and 429", message_names_upstream_status: true, serving_modes: :all, recorded_status: :upstream},
      public_v1_body: "openai_error_object",
      unsupported_parameter_detail: %{
        detail: "Unsupported parameter: <bounded field path>",
        relayed_code: "unsupported_parameter",
        param: "field_path_from_detail",
        other_detail_text: "not_relayed",
        persisted_detail_class: "unsupported_parameter",
        observed_for: "previous_response_id_on_http"
      },
      unchanged_scopes: [
        :non_400_status,
        :non_allowlisted_code,
        :non_invalid_request_error_type,
        :detail_body,
        :compact_routes,
        :model_unavailable,
        :misalignment_policy_violation,
        :websocket_frames
      ],
      accounting_error_code: "upstream_status",
      retry: false,
      routing_health: :unchanged
    },
    pooler_authored_error_type: %{
      authority: "CodexPooler.Gateway.ErrorClassification",
      surfaces: ["http_relay", "runtime_ingress", "websocket"],
      vocabulary_overrides: %{
        server_error: [
          "owner_busy",
          "owner_crashed",
          "owner_drained",
          "owner_forward_timeout",
          "owner_forwarding_disabled",
          "owner_unavailable",
          "server_error",
          "server_is_overloaded",
          "stale_owner",
          "upstream_stream_error",
          "upstream_websocket_terminal_delivery_timeout",
          "websocket_request_failed"
        ],
        invalid_request_error: [
          "client_disconnected",
          "duplicate_downstream",
          "stale_downstream"
        ]
      },
      status_classes: %{
        "429" => "rate_limit_error",
        "5xx" => "server_error",
        "other_4xx" => "invalid_request_error"
      },
      retryable_field_consulted: false,
      exhaustiveness_guard: "compile_time_over_owner_error_vocabulary",
      invariant: "no_5xx_typed_invalid_request_error",
      relayed_provider_error_objects: "unchanged"
    },
    responses_chat: %{
      routes: ["/v1/responses", "/v1/chat/completions"],
      public_format_to_mime: %{
        "wav" => "audio/wav",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "webm" => "audio/webm",
        "ogg" => "audio/ogg"
      },
      decoded_max_bytes: 52_428_800,
      encoded_non_whitespace_max_bytes: 69_905_068,
      backend_audio_shape: %{
        type: "input_audio",
        field: "audio_url",
        value: "data:<canonical-mime>;base64,<canonical-data>"
      },
      accepted_ascii_whitespace: %{
        byte_values: [9, 10, 13, 32],
        ignored_during_decode: true,
        ignored_for_encoded_limit: true,
        canonical_reencoding: "no_ascii_whitespace"
      },
      failure_behavior: %{
        rejected_inputs: [
          "malformed_base64",
          "empty_data",
          "unsupported_format",
          "oversized_decoded_data"
        ],
        response: %{status: 400, code: "invalid_request", param: "input"},
        upstream_dispatch: false,
        accounting_rows: false
      },
      ingress_envelope_precedence: %{
        evaluation_order: ["configured_request_envelope", "audio_adapter"],
        may_reject_before_adapter: true,
        exact_decoded_limit_scope: "adapter_boundary"
      },
      privacy: %{
        mode: "metadata_only",
        raw_audio_persisted: false,
        raw_base64_logged: false,
        raw_data_url_exposed: false,
        safe_summary_fields: ["type", "canonical_mime", "decoded_bytes", "sha256"]
      },
      prompt_cache_routing: %{
        setting: "prompt_cache_affinity_enabled",
        default_enabled: true,
        mode: "stateless_locality_over_already_eligible_assignments",
        typed_input: "prompt_cache_key",
        locality_key_material: "trimmed_sha256_hash",
        privacy: "raw_key_not_persisted_hash_only_locality",
        provider_cache_evidence: "upstream_cached_input_tokens_only"
      },
      upstream_prompt_cache_controls: %{
        request_options_field: "prompt_cache_options",
        content_breakpoint_field: "prompt_cache_breakpoint",
        breakpoint_mode: "explicit",
        routing_input: false,
        accepted_public_surfaces: ["/v1/responses", "/v1/chat/completions"],
        account_backed_upstream_payload: %{
          omitted_fields: ["prompt_cache_options", "prompt_cache_breakpoint"],
          preserved_fields: ["prompt_cache_key"]
        },
        public_response_headers: %{downgrade_marker: :absent}
      },
      service_tier_boundary: %{
        ultrafast: %{
          accepted_surfaces: [
            %{method: :post, path: "/v1/responses", transport: "http_json"},
            %{method: :post, path: "/v1/responses", transport: "http_sse"},
            %{method: :get, path: "/v1/responses", transport: "responses_websocket"}
          ],
          candidate_metadata: %{
            required: true,
            advertised_fields: ["service_tiers", "additional_speed_tiers"],
            required_literal: "ultrafast",
            eligible_candidates: "only_exact_ultrafast_advertisements"
          },
          literal_vocabulary: %{
            returned_service_tier: "ultrafast",
            accounting_fields: [
              "requested_service_tier",
              "actual_service_tier",
              "service_tier"
            ]
          }
        },
        chat_completions: %{
          method: :post,
          path: "/v1/chat/completions",
          accepted: false,
          rejection: %{
            status: 400,
            code: "invalid_request",
            param: "service_tier",
            upstream_dispatch: false
          }
        },
        fast_priority_alias: %{
          client_literal: "fast",
          upstream_literal: "priority",
          unchanged: true
        }
      },
      chat_input_fallback: %{
        messages_precedence: "non_empty_messages",
        fallback_when: ["messages_absent", "messages_empty"],
        fallback_source: "input",
        default_instructions: "blank_string"
      },
      additional_tools_input_item: %{
        shape: "request_input_item",
        required: ["type", "role", "tools"],
        optional: ["id"],
        role: "developer",
        executable: false,
        merges_into_tools: false,
        satisfies_tool_choice: false,
        unsupported_nested_tool_types: ["mcp", "tool_search"]
      },
      remote_mcp_tools: %{
        supported: false,
        locations: ["tools", "input.additional_tools.tools"],
        error_code: "invalid_request",
        dispatch: false
      },
      namespace_tool: %{
        shape: "top_level_namespace_tool",
        required: ["type", "name", "description", "tools"],
        namespace_name: "nonblank",
        nested_tool_types: ["function", "custom"],
        nested_function_optional: ["strict", "defer_loading"],
        nested_custom_required: ["type", "name"],
        nested_custom_optional: ["description", "defer_loading", "allowed_callers", "format"],
        nested_custom_formats: ["omitted", "text", "grammar_lark", "grammar_regex"],
        nested_custom_allowed_callers: ["direct", "programmatic"],
        nested_custom_allowed_callers_null: true,
        excluded_nested_tool_types: ["hosted", "mcp", "namespace", "tool_search"],
        satisfies_tool_choice: true,
        executable_name_collision_scope: "global"
      },
      programmatic_tool_calling: %{
        input_items: %{
          program: %{
            required: ["type", "id", "call_id", "code", "fingerprint"],
            exact_keys: true
          },
          program_output: %{
            required: ["type", "id", "call_id", "result", "status"],
            exact_keys: true,
            statuses: ["completed", "incomplete"]
          },
          function_call: %{
            encrypted_function_args: %{
              accepted: ["omitted", "null", "string_list"],
              preserved: ["omitted", "null", "empty_list", "ordered_string_list"],
              rejected: ["scalar", "map", "mixed_list", "non_string_list"],
              durable_metadata: "omitted"
            },
            caller: %{
              types: ["direct", "program"],
              program_requires: ["caller_id"],
              direct_forbids: ["caller_id"]
            }
          },
          function_call_output: %{
            paired: %{
              call_id: "required_nonblank_string",
              output: "required",
              name: ["omitted", "null", "nonblank_string"],
              namespace: ["omitted", "null", "nonblank_string"],
              legacy_result: "accepted"
            },
            standalone: %{
              call_id: ["omitted", "null"],
              name: "required_nonblank_string",
              namespace: ["omitted", "null", "nonblank_string"],
              output: "required",
              legacy_result: "rejected"
            },
            classifier_debug_privacy: %{
              classifier: "exact_named_function_call_output_only",
              collected_call_id: "nil_without_synthetic_identifier",
              debug_summary: "metadata_only",
              raw_output_name_anchor_or_request_body: "not_stored"
            },
            caller: %{
              types: ["direct", "program"],
              program_requires: ["caller_id"],
              direct_forbids: ["caller_id"]
            }
          }
        },
        hosted_tool: %{type: "programmatic_tool_calling", exact_keys: ["type"]},
        tool_choice: %{type: "programmatic_tool_calling", exact_keys: ["type"]},
        function_options: %{
          scopes: ["flat", "namespace"],
          optional_boolean_keys: ["strict", "defer_loading"],
          allowed_callers: ["direct", "programmatic"],
          output_schema: %{shape: "opaque_json_map", strict: false}
        },
        stateless_policy: %{
          vercel_store: false,
          upstream_stream: true,
          upstream_store: false,
          reference_only_continuation: "reject",
          ordinary_continuation: "reject",
          semantic_tool_result_continuation: "accept"
        },
        relay_surfaces: ["collected_json", "public_sse", "public_responses_websocket"],
        compression: %{program_output_candidate: false, program_output_rewrite: false},
        privacy: %{
          mode: "metadata_only",
          stored_program_code: false,
          stored_program_results: false,
          stored_schema_values: false,
          stored_identifiers: false,
          stored_prompts: false,
          stored_frames: false
        },
        exclusions: %{
          remote_mcp: false,
          unrelated_hosted_tools: false,
          full_openai_parity: false
        }
      },
      hosted_shell_history: %{
        accepted_items: ["shell_call", "shell_call_output"],
        request_policy: %{
          closed_key_objects: [
            "shell_call",
            "shell_call.action",
            "shell_call.caller",
            "shell_call.environment",
            "shell_call.environment.skills[]",
            "shell_call_output",
            "shell_call_output.caller",
            "shell_call_output.output[]",
            "shell_call_output.output[].outcome"
          ],
          unknown_or_response_only_keys: "rejected",
          upstream_open_properties: "not_admitted"
        },
        input_items: %{
          shell_call: %{
            required: ["type", "call_id", "action"],
            optional_nullable: ["id", "caller", "status", "environment"],
            action: %{
              required: ["commands"],
              optional_nullable: ["timeout_ms", "max_output_length"],
              commands: "string_array_empty_allowed"
            },
            caller: %{
              accepted: ["null", "direct", "program"],
              direct_exact_keys: ["type"],
              program_required: ["type", "caller_id"]
            },
            environment: %{
              accepted: ["null", "local", "container_reference"],
              local_optional: ["skills"],
              local_skill_required: ["name", "description", "path"],
              container_required: ["type", "container_id"]
            }
          },
          shell_call_output: %{
            required: ["type", "call_id", "output"],
            optional_nullable: ["id", "caller", "status", "max_output_length"],
            output_chunk_required: ["stdout", "stderr", "outcome"],
            outcomes: %{
              timeout: ["type"],
              exit: ["type", "exit_code"]
            }
          }
        },
        codepoint_limits: %{
          call_id: %{minimum: 1, maximum: 64},
          program_caller_id: %{minimum: 1, maximum: 64},
          stdout: %{maximum: 10_485_760},
          stderr: %{maximum: 10_485_760},
          local_skills: %{maximum_items: 200}
        },
        status_values: ["in_progress", "completed", "incomplete", nil],
        edge_semantics: %{
          empty_allowed: [
            "action.commands",
            "shell_call_output.output",
            "id",
            "container_id",
            "local_skill.name",
            "local_skill.description",
            "local_skill.path"
          ],
          signed_integer_fields: [
            "action.timeout_ms",
            "action.max_output_length",
            "shell_call_output.max_output_length",
            "shell_call_output.output[].outcome.exit_code"
          ]
        },
        continuation: %{
          stateless_full_history_replay: "accepted",
          previous_response_id_semantic_tool_output: "producing_websocket_connection_only",
          call_output_pairing: "not_enforced",
          item_order: "not_enforced"
        },
        relay: %{
          event_types: [
            "response.shell_call_command.added",
            "response.shell_call_command.delta",
            "response.shell_call_command.done",
            "response.shell_call_output_content.delta",
            "response.shell_call_output_content.done"
          ],
          normalization: %{
            sequence_number: "existing_public_responses_normalization_only",
            stream_id: "existing_public_responses_websocket_addition_only"
          }
        },
        privacy: %{
          mode: "metadata_only",
          command_persisted: false,
          output_persisted: false,
          command_logged: false,
          output_logged: false
        },
        exclusions: %{
          command_execution: false,
          shell_tool_declarations: false,
          local_shell_history: false,
          remote_mcp: false,
          command_index_accumulation: false,
          full_openai_hosted_tool_parity: false
        }
      },
      responses_truncation: %{
        accepted_values: ["auto", "disabled"],
        forwarded_upstream: false
      },
      compaction_recovery_boundary: %{
        backend_compaction_trigger: %{
          client_routes: ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"],
          upstream_endpoint: "/backend-api/codex/responses",
          accounting_endpoint: "/backend-api/codex/responses/compact",
          admission_endpoint: :original_client_route,
          route_class: "proxy_compact",
          transport: "http_compact_json",
          valid_trigger: "exactly_one_final_input_item",
          malformed_trigger: %{status: 400, param: "input", upstream_dispatch: false},
          retained: ["final_compaction_trigger"],
          strips: ["include", "prompt_cache_options"],
          result_classification: %{
            source: "request_input_compaction_trigger",
            marker: "terminal_compaction_trigger",
            additive_metadata: "ignored",
            returned_compaction_items: "not_inspected"
          },
          upstream_payload: %{
            mode: "responses_sse",
            terminal_trigger: "retained",
            store: false,
            stream: true
          },
          response_adaptation: %{
            upstream: "responses_sse",
            downstream: "backend_responses_sse",
            output_events: ["response.output_item.done", "response.completed", "[DONE]"]
          },
          accepted_result_shapes: [
            %{location: "output", type: "compaction"},
            %{location: "output", type: "compaction_summary"},
            %{location: "top_level", key: "compaction_summary"}
          ],
          output_item: %{
            "type" => "compaction",
            "encrypted_content" => "encrypted_content"
          },
          output_item_policy: %{
            required: ["type", "encrypted_content"],
            optional_string: ["id"],
            unknown_fields: "dropped",
            terminal_events_share_identical_item: true
          },
          websocket_bridge: %{
            client_routes: [
              "/backend-api/codex/responses",
              "/backend-api/codex/v1/responses"
            ],
            admission: %{
              outer_route_class: "proxy_websocket",
              nested_route_class: "proxy_compact",
              nested_timing: "after_coercion_before_compact_execution"
            },
            canonical_identity: %{
              upstream_endpoint: "/backend-api/codex/responses",
              accounting_endpoint: "/backend-api/codex/responses/compact",
              transport_contracts: %{
                incremental_websocket: %{
                  input_mode: "nonblank_top_level_previous_response_id",
                  request_transport: "websocket",
                  attempt_transport: "websocket",
                  connection: "current_live_matching_generation_reused_only",
                  delivery: "collect_compaction_before_validation_settlement_and_adapter",
                  retry_or_fallback: false
                },
                full_history_http: %{
                  input_mode: "no_top_level_previous_response_id",
                  request_transport: "http_compact_json",
                  attempt_transport: "http_compact_json"
                }
              }
            },
            result_transports: %{
              trigger: "responses_sse_independent_of_client_metadata"
            },
            turn_state: %{
              source: "client_metadata.x-codex-turn-state_or_upgrade_header",
              forwarded_header: "x-codex-turn-state",
              persistence: "hashed_alias_only"
            },
            native_frames: ["response.output_item.done", "response.completed"],
            collected_result: %{
              source: "collect_delivery_accumulator_not_diagnostic_retention",
              max_bytes: 8_388_608,
              diagnostic_retention_bytes: 65_536,
              overflow_reason: "compaction_result_too_large"
            },
            errors: %{
              malformed_trigger: "pre_dispatch_invalid_request",
              compact_saturation: "server_is_overloaded",
              invalid_result: "invalid_compaction_response",
              oversized_result: "invalid_compaction_response",
              provider_terminal: "canonical_provider_terminal"
            },
            socket_reuse: "ordinary_follow_up_same_downstream_socket",
            collector_retry: "one_client_full_history_successor_when_codex_retryable",
            diagnostic: %{
              request_metadata: "compaction_bridge",
              applied: true,
              result_transport: ["buffered", "sse"],
              raw_payload_or_frame: false
            }
          },
          hidden_replay: false,
          direct_compact_preservation: %{
            client_routes: [
              "/backend-api/codex/responses/compact",
              "/backend-api/codex/v1/responses/compact"
            ],
            upstream_endpoint: "/backend-api/codex/responses/compact",
            behavior: "legacy_compact_route_unchanged",
            upstream_payload: %{
              compaction_trigger: "omitted",
              store: "omitted",
              stream: "omitted"
            }
          }
        },
        harness_applicability: %{
          codex: %{
            version: "rust-v0.153.3",
            peeled_commit: "b1a547b1f73ce86205d9222ac19cff334b3b7a2e",
            sanitized_fixtures: [
              "test/fixtures/codex/rust-v0.153.3-b1a547b1f73ce86205d9222ac19cff334b3b7a2e/remote_compaction_v2_request.json",
              "test/fixtures/codex/rust-v0.153.3-b1a547b1f73ce86205d9222ac19cff334b3b7a2e/remote_compaction_v2_incremental_request.json"
            ],
            applicability: "native_v2",
            classifier_authority: true,
            verification: "commit_blocking"
          },
          omp: %{
            version: "18.0.4",
            applicability: "distinct_v2_and_configured_direct_fallback_adapter",
            classifier_authority: false
          },
          cursor: %{
            applicability: "http_sse_openai_base_url_override",
            support: "local_contract_tested",
            request: %{
              path: "/v1/chat/completions",
              shape: "responses_shaped_body"
            },
            response: %{formats: ["chat_completions_json", "chat_completions_sse"]},
            classifier_authority: false,
            websocket_support: false,
            compaction_support: false,
            verification: "authenticated_live_smoke_required",
            verified: false
          },
          opencode: %{
            applicability: "http_and_websocket_replay_only",
            classifier_authority: false
          },
          hermes: %{
            applicability: "no_independent_native_classifier_authority",
            classifier_authority: false
          },
          pi: %{
            applicability: "native_remote_compaction_unverified",
            classifier_authority: false,
            verification: "not_applicable"
          }
        },
        public_v1_compaction_trigger: %{
          client_route: "/v1/responses",
          surfaces: ["http_json", "http_sse", "responses_websocket"],
          upstream_endpoint: "/backend-api/codex/responses",
          accounting_endpoint: "/backend-api/codex/responses/compact",
          admission_endpoint: "/v1/responses",
          route_class: "proxy_compact",
          websocket_admission: %{
            outer_route_class: "proxy_websocket",
            nested_route_class: "proxy_compact",
            timing: "after_coercion_before_compact_execution",
            completion: "local_websocket_completion"
          },
          transport_contracts: %{
            incremental_websocket: %{
              surface: "responses_websocket",
              input_mode: "nonblank_top_level_previous_response_id",
              request_transport: "websocket",
              attempt_transport: "websocket",
              connection: "current_live_matching_generation_reused_only",
              delivery: "collect_compaction_before_validation_settlement_and_adapter",
              retry_or_fallback: false
            },
            full_history_http: %{
              surfaces: ["http_json", "http_sse", "responses_websocket"],
              input_mode: "no_top_level_previous_response_id",
              request_transport: "http_compact_json",
              attempt_transport: "http_compact_json"
            }
          },
          closed_item: %{"type" => "compaction_trigger"},
          valid_trigger: "exactly_one_final_after_visible_input",
          malformed_trigger: %{status: 400, param: "input", upstream_dispatch: false},
          retained: ["final_compaction_trigger"],
          strips: ["include", "prompt_cache_options"],
          upstream_payload: %{
            mode: "responses_sse",
            terminal_trigger: "retained",
            store: false,
            stream: true
          },
          response_adaptation: %{
            upstream: "responses_sse",
            downstream: %{
              http_json: ["response"],
              http_sse: [
                "response.created",
                "response.output_item.added",
                "response.output_item.done",
                "response.completed",
                "[DONE]"
              ],
              responses_websocket: [
                "response.created",
                "response.output_item.added",
                "response.output_item.done",
                "response.completed"
              ]
            }
          },
          public_compact_route_supported: false,
          hidden_replay: false,
          public_item_id: %{
            upstream_nonblank_string: "preserved",
            absent_null_or_blank: "cmp_ plus 40 hex of a domain-separated SHA-256 of encrypted_content",
            replay: "a derived id is dropped before upstream dispatch"
          }
        },
        anchor_lineage_and_smoke: %{
          explicit_anchor: "preserve_nonblank_opaque_top_level_anchor_semantically",
          no_anchor: "send_full_history",
          provenance: %{
            stages: ["downstream", "projection", "upstream"],
            durable_output: "bounded_safe_projection_only",
            client_proof: "post_projection_absence_is_not_client_proof"
          },
          routing: %{
            anchored_continuation: "assignment_hard_pin",
            unavailable_assignment: "fail_closed_without_fallback",
            recovery: "new_full_history_request_without_anchor"
          },
          authentic_smoke: %{
            client: "exact_released_codex_app_server",
            provider_modes: ["http_only_full_history_control", "websocket_anchored_compaction"],
            required_lifecycle: [
              "tool_execution",
              "automatic_same_turn_compaction",
              "anchored_compact_request",
              "compact_terminal",
              "same_turn_final_response",
              "correlated_accounting_and_cleanup"
            ],
            insufficient_evidence: ["client_exit_zero", "receipt_without_lifecycle"]
          }
        },
        native_fallback: %{
          provider_unsupported: %{
            request: %{
              admitted: true,
              endpoint: "/backend-api/codex/responses/compact",
              last_error_code: "upstream_status",
              response_status_code: 404,
              status: "failed"
            },
            attempt: %{
              matching_request_id: true,
              status: "failed",
              upstream_status_code: 404
            },
            local_route_404: false
          },
          omp_terminal: "configured_local_fallback_from_pinned_configuration"
        },
        context_overflow: %{
          recovery_owner: "client_or_upstream",
          public_v1_compaction_replay: %{
            route: "/v1/responses",
            surfaces: ["http_json", "http_sse", "responses_websocket"],
            required: %{"type" => "compaction", "encrypted_content" => "nonblank_string"},
            public_id: %{
              presence: "optional",
              accepted_types: ["string", "null"],
              preserved_exactly: true
            },
            verified_variants: [
              %{name: "public_id_absent", exact_keys: ["type", "encrypted_content"]},
              %{
                name: "public_id_string",
                exact_keys: ["type", "encrypted_content", "id"],
                id_type: "string"
              },
              %{
                name: "public_id_null",
                exact_keys: ["type", "encrypted_content", "id"],
                id_type: "null"
              },
              %{
                name: "native_turn_metadata",
                exact_keys: [
                  "type",
                  "encrypted_content",
                  "id",
                  "internal_chat_message_metadata_passthrough"
                ],
                id_type: "nonblank_string",
                metadata: %{
                  exact_keys: ["turn_id"],
                  turn_id_type: "nonblank_string",
                  public_documentation: false
                }
              }
            ],
            item_order: "preserved",
            continuation: "new_chain_without_previous_response_id",
            unknown_fields: "reject_before_dispatch",
            upstream_dispatch: true,
            privacy: "opaque_values_not_persisted_or_logged"
          },
          server_side_compaction: false,
          hidden_replay: false,
          stores_prompt_bodies: false,
          stores_websocket_frames: false,
          client_action: "restart_with_full_context"
        }
      },
      backend_regular_metadata_forwarding: %{
        routes: [
          "/backend-api/codex/responses",
          "/backend-api/codex/v1/responses",
          "/backend-api/codex/responses/compact",
          "/backend-api/codex/v1/responses/compact"
        ],
        forwarded_headers: [
          "x-codex-turn-state",
          "x-codex-turn-metadata",
          "x-codex-window-id",
          "x-codex-parent-thread-id",
          "x-openai-subagent",
          "x-openai-memgen-request",
          "x-codex-guardian",
          "x-codex-inference-call-id",
          "session-id",
          "thread-id",
          "x-client-request-id"
        ],
        bounded_header_values: %{
          "x-openai-memgen-request" => %{accepted: ["true"], otherwise: "dropped"},
          "x-codex-guardian" => %{accepted: ["reviewer", "classifier"], otherwise: "dropped"},
          "x-codex-inference-call-id" => %{accepted: "ascii_identifier_max_128_bytes", otherwise: "dropped"}
        },
        client_metadata_only_names: ["x-codex-installation-id"],
        file_bridge: %{
          routes: ["/backend-api/files", "/backend-api/files/:file_id/uploaded"],
          policy: "same_allowlist_and_value_bounds_as_native_responses",
          never_forwarded: ["x-codex-routing-hint", "x-codex-beta-features"]
        },
        provider_session_headers: %{
          names: ["session-id", "thread-id", "x-client-request-id"],
          value_contract: "ascii_identifier_max_128_bytes",
          purpose: "provider_sticky_routing_for_prompt_cache",
          local_only_headers: ["x-session-id", "x-session-affinity"],
          native_websocket_handshake: %{
            routes: ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"],
            source: "authenticated_downstream_native_websocket_upgrade_headers",
            value_contract: "ascii_identifier_max_128_bytes",
            duplicate_headers: "first_valid_value_per_name",
            upstream_connection_reuse_key: "included_differing_or_absent_values_open_a_new_connection",
            owner_forwarded_turns: "carried_in_owner_request_headers_built_on_the_proxy_node",
            public_v1_origins: "caller_values_never_forwarded_derived_session_id_only"
          },
          native_http_derived_session_id: %{
            routes: [
              "/backend-api/codex/responses",
              "/backend-api/codex/v1/responses",
              "/backend-api/codex/responses/compact",
              "/backend-api/codex/v1/responses/compact"
            ],
            transports: ["http_json", "http_sse"],
            applies_when: "no_client_session_id_within_the_provider_bound",
            precedence: "client_session_id_then_prompt_cache_key_then_local_continuity_alias",
            alias_namespace: "60a80f24-3dd3-5aeb-be77-26ea7c41d36f",
            alias_derivation: "uuid_v5_distinct_namespace_over_pool_id_api_key_id_and_raw_alias_never_forwarded_raw",
            client_session_id: "forwarded_unchanged_never_replaced",
            derivation: "same_as_public_v1_same_pool_api_key_and_prompt_cache_key_yield_the_same_value",
            local_session: "keyed_by_the_client_continuity_header_unchanged",
            native_websocket_handshake: "unchanged_only_the_upgrade_session_headers",
            privacy: "derived_value_not_persisted_or_logged"
          },
          public_v1: %{
            client_headers: "local_only_never_forwarded",
            synthesized_header: "session-id",
            derived_from: "prompt_cache_key",
            derivation: "uuid_v5_fixed_pooler_namespace_over_pool_id_api_key_id_and_raw_key",
            name_encoding: "netstring_pool_id_then_netstring_api_key_id_then_raw_key",
            namespace: "0aac30b0-0311-52bd-8fb7-258f9c6f0278",
            scope: "authenticated_pool_and_api_key",
            missing_scope: "no_header_fail_closed_no_unscoped_derivation",
            model: "excluded_from_derivation",
            key_contract: "non_empty_string_max_512_bytes",
            routes: ["/v1/responses", "/v1/chat/completions"],
            transports: ["http_json", "http_sse", "websocket"],
            websocket_surfaces: "derived_session_id_on_the_upstream_websocket_handshake",
            websocket_source: "raw_prompt_cache_key_of_the_final_upstream_body",
            websocket_upstream_connection_reuse_key: "included_changed_or_absent_prompt_cache_key_opens_a_new_connection",
            local_session: "none_bridge_eligibility_stays_fail_closed",
            client_key_contract: "shared_key_within_one_api_key_shares_one_provider_session_id_never_across_api_keys_or_pools",
            privacy: "derived_value_not_persisted_or_logged"
          }
        },
        relayed_response_headers: ["x-codex-turn-state"],
        not_forwarded_on: [
          "/v1/responses",
          "backend_websocket_response.create",
          "public_v1_websocket_response.create"
        ],
        privacy: "raw_values_not_persisted",
        turn_metadata_projection: %{
          direct_header_removes_top_level: ["code_mode_tool_names"],
          structured_output: "ascii_safe_json",
          object_without_target: "original_bytes",
          opaque_or_non_object: "original_bytes",
          duplicate_headers: "project_each_preserve_order",
          canonical_client_metadata: "full_value_preserved",
          websocket_upgrade_header_forwarded: false,
          generic_size_cap_added: false
        }
      },
      store_false_policy: %{
        server_side_hidden_tools: false,
        memory_tool_injection: false,
        client_store_false_to_true_override: false
      },
      json: %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic text request",
        "stream" => true
      }
    },
    response_body_cap: %{
      default_limit_bytes: 64 * 1024 * 1024,
      error_code: "upstream_response_too_large",
      public_status: 502,
      oversized_body_retained: false,
      metadata_keys: [
        "response_body_limit_exceeded",
        "response_body_limit_bytes",
        "response_body_seen_bytes",
        "response_body_content_length"
      ],
      streaming_uses_existing_buffer_guards: true
    },
    backend_v1_alias_surface: %{
      auth: "required_bearer_api_key",
      default_enabled: true,
      prompt_cache_routing_allowed_routes: [
        "/backend-api/codex/v1/responses",
        "/backend-api/codex/v1/chat/completions"
      ],
      prompt_cache_routing_excluded_routes: [
        "/backend-api/codex/v1/responses websocket",
        "/backend-api/codex/v1/responses/compact"
      ],
      routes: [
        "/backend-api/codex/v1/models",
        "/backend-api/codex/v1/responses",
        "/backend-api/codex/v1/responses/compact",
        "/backend-api/codex/v1/chat/completions"
      ],
      chat_input_fallback: %{
        messages_precedence: "non_empty_messages",
        fallback_when: ["messages_absent", "messages_empty"],
        fallback_source: "input"
      },
      json: %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic alias surface request"
      }
    },
    usage_alias_meter_identity: %{
      auth: "required_bearer_api_key_or_matching_chatgpt_account_token",
      routes: [
        "/api/codex/usage",
        "/wham/usage",
        "/backend-api/wham/usage"
      ],
      payload_equivalence: "normalized_json_exact",
      additional_rate_limits: %{
        stale: "omitted_by_dynamic_freshness",
        unknown: "preserved",
        ordering: ["quota_key", "canonical_meter_token", "window_kind", "window_minutes"],
        repeated_legacy_quota_key: true,
        cross_meter_window_pairing: false
      },
      wire_schema: %{
        legacy_fields_and_types: "unchanged",
        freshness_fields: false,
        raw_identity_fields: false
      },
      request_log: %{
        endpoint: "exact_requested_alias",
        operation: "usage",
        metadata_only: true
      }
    },
    websocket_turn: %{
      quota_recovery: %{
        transport: "same_downstream_websocket",
        retry_codes: ["usage_limit_reached", "usage_limit_exceeded"],
        retry_boundary: "before_output_with_absent_or_zero_usage",
        portable_history: "unanchored_input_including_encrypted_reasoning_compaction_checkpoints_and_recognized_agent_handoffs",
        retained_fences: ["previous_response_id", "file_affinity", "item_reference", "compaction_trigger", "connection_bound_compaction"],
        denial_evidence: "explicit_error_source_over_percentage_only_permission",
        accounting: "one_request_with_failed_then_successful_attempts_and_one_settlement"
      },
      headers: %{"x-codex-turn-state" => "fixture-upgrade-turn-state"},
      response_create_client_metadata: %{"x-codex-turn-state" => "fixture-frame-turn-state"},
      turn_state_precedence: "response.create.client_metadata_over_upgrade_header",
      privacy: "raw_value_not_persisted",
      native_turn_identity: %{
        source_precedence: [
          "client_metadata.turn_id",
          "client_metadata.x-codex-turn-metadata.turn_id",
          "turn_id",
          "request_id"
        ],
        validation: %{
          accepted: "1_to_256_byte_ascii_[A-Za-z0-9_.:-]+",
          present_invalid: "source_specific_invalid_request_without_fallback",
          missing: "no_native_turn_identity"
        },
        semantic_key: "opaque_claim_scoped_sha256_32_bytes",
        claim_key: "opaque_claim_scoped_full_base64url_sha256_claim",
        claim_scope: %{
          thread_named: "hmac_of_pool_api_key_and_thread",
          thread_absent: "codex_session_id"
        }
      },
      native_tool_continuation: %{
        logical_turn: %{
          identity: "semantic_turn_key_and_turn_claim_key",
          client_turns: 1
        },
        request_claim: %{
          kind: "deterministic_continuation_claim",
          separate_from_logical_turn_identity: true
        },
        accepted_semantic_continuation: %{
          requests: 2,
          attempts: 2,
          codex_turns: 2,
          settlements: 2,
          sequences: [1, 2]
        },
        exact_replay: %{
          status: 409,
          new_request_attempt_codex_turn_or_settlement: false,
          upstream_dispatch: false
        }
      },
      released_native_metadata: %{
        request_kinds: [:turn, :prewarm, :compaction, :memory],
        canonical_envelope: %{
          accepted_encodings: [:map, :json_string],
          ordinary_and_prewarm: %{
            optional: [:window_id, :context_window_id, :window_number],
            explicit_null: "rejected",
            compaction: "omitted_only"
          },
          compaction: %{
            authority: "strict_complete_enum_map",
            malformed: "pre_dispatch_rejected"
          },
          memory: %{
            semantic_turn_identity: false,
            ordinary_websocket_accounting_continuity_owner_or_compaction_lifecycle: false
          }
        },
        prewarm: %{
          admitted_without_compaction_authority: true
        },
        rejection_diagnostics: %{
          vocabulary: :fixed,
          metadata_only: true,
          raw_metadata_values: false
        }
      },
      active_reconnect: %{
        same_active_non_cancelled: %{
          disposition: "same_turn_replay",
          result: "suppressed_without_new_task_or_accounting_rows",
          terminal: "predecessor_terminal_only"
        },
        bounded_busy: %{
          cancelled_equal_identity: "owner_busy",
          noncancelled_different_identity: "owner_busy",
          missing_identity: "owner_busy",
          public_response_create: "owner_busy",
          non_native_active_descriptor: "owner_busy",
          response_processed: "owner_busy"
        },
        owner_replay_preflight: %{
          new_turn_refused_by_occupied_owner: "owner_error_payload_not_duplicate_turn",
          live_owner_refusal_code: "owner_busy",
          running_request_lost_race: "duplicate_turn_counted_as_owner_replay_preflight",
          resend_of_recorded_turn: "duplicate_turn_counted_as_owner_replay_preflight",
          newer_socket_turn_at_armed_previsible_replay: "retires_replay_settles_predecessor_once_then_dispatches",
          request_from_socket_that_inherited_visible_turn: "owner_cancels_inherited_turn_awaits_settlement_then_judges_request",
          inherited_visible_turn_at_owner_without_take_over: "refusal_kept"
        },
        runtime_replay_pre_classification: %{
          session_not_reconnectable: "owner_unavailable",
          session_binding_mismatch: "owner_unavailable",
          session_pool_mismatch: "owner_unavailable",
          pool_inactive: "pool_inactive_revocation",
          pool_missing: "pool_inactive_revocation",
          invalid_replay_context: "server_error",
          counted_as_duplicate_turn: false
        }
      },
      prewarm: %{
        generate_false: "local_created_completed",
        accounting_rows: "none",
        active_reconnect: "neutral",
        pending_handoff: "neutral",
        reconnect_events: "none",
        owner_cancellation: "none"
      },
      edited_replacement_handoff: %{
        eligibility: "cancelled_predecessor_with_different_native_identity",
        admission: "matching_fenced_ready_only",
        before_ready_accounting_rows: "none",
        soft_cancellation_bound_ms: 1_000,
        absolute_handoff_bound_ms: 5_000,
        absolute_failure: "owner_forward_timeout",
        duplicate_pending_identity: "suppressed_without_second_task_or_rows",
        third_identity: "owner_busy"
      },
      exactly_once: %{
        predecessor: "client_disconnected_once",
        replacement: "success_once_after_ready",
        later_turn: "success_once",
        accounting: "one_request_attempt_turn_and_settlement_per_turn",
        replacement_connection: "new_generation",
        later_connection: "reuse_replacement_connection",
        automatic_replay: false
      },
      mixed_release: %{
        new_new: "identity_aware_handoff",
        new_old: "identity_aware_handoff_fails_owner_unavailable_before_accounting",
        old_new: "legacy_submission_behavior_without_new_handoff_protection",
        old_old: "legacy_behavior_unchanged"
      },
      native_continuation_generation_guard: %{
        scope: "native_backend_websocket_exact_previous_response_not_found",
        marked_continuation_connection_use: "reused_only",
        guarded_connection_uses: ["fresh", "reconnected"],
        guard: %{
          upstream_payload_send: false,
          client_error_code: "previous_response_not_found",
          client_error_type: "invalid_request_error",
          client_status: 400,
          client_retry: "later_explicit_full_request_without_previous_response_id",
          automatic_replay: false
        },
        public_v1: "generic_terminal_masking_and_shape_unchanged",
        diagnostic: %{
          reason: "previous_response_generation_mismatch",
          reason_class: "previous_response_generation_mismatch",
          termination_source: "continuation_generation_guard",
          raw_payloads_or_response_values: false
        },
        serving_mode_guard: %{
          connection_use: "reused",
          condition: "lite_continuation_after_a_full_served_last_completed_response_on_the_connection",
          full_after_lite: "sent",
          unknown_mode: "reuse_rule_only",
          reason: "previous_response_serving_mode_mismatch"
        },
        provider_refusal: %{
          upstream_message_class: "invalid_previous_response_id",
          client_error_code: "previous_response_not_found",
          attempt_rejection_error_code: "absent"
        },
        full_resend: "one_linked_successor_with_or_without_owner_forwarding"
      },
      native_compaction_admission: %{
        semantic_sequence: ["anchor", "compact", "final"],
        first_compact: %{
          authority: "ordinary_durable_turn_claim",
          capability_required: false,
          replay: "duplicate_turn_without_new_side_effects"
        },
        mid_turn_transitions: %{
          compact: "owner_capability_plus_sealed_runtime_proof",
          final: "owner_capability_plus_sealed_runtime_proof",
          payload_shape_or_client_metadata_alone: "never_authoritative",
          final_resume_claim: "durable_codex_resume_claim_so_an_identical_resend_is_refused"
        },
        binding: [
          "phase",
          "semantic_turn",
          "prepared_frame_control",
          "owner_epoch_and_lease",
          "serving_mode",
          "physical_websocket_lifecycle_and_generation"
        ],
        legitimate_accounting: %{
          distinct_correlations: 3,
          requests: 3,
          attempts: 3,
          codex_turns: 3,
          reservations: 3,
          settlements: 3,
          semantic_client_turns: 1,
          websocket_lifecycles: 1,
          websocket_generations: 1,
          http_fallbacks: 0
        },
        rejected_frames: %{
          new_rows: 0,
          upstream_calls: 0,
          saved_reset_probe_or_redeem: false,
          hidden_replay_retry_or_fallback: false
        },
        public_v1: %{
          inherits_owner_capability_or_proof: false,
          replay_and_bridge_semantics: "unchanged",
          relayed_bytes_and_terminal_shape: "unchanged"
        }
      },
      json: %{"model" => "gpt-fixture-text", "input" => "synthetic websocket turn"}
    },
    duplicate_turn_fence: %{
      json: %{"model" => "gpt-fixture-text", "input" => "synthetic duplicate turn"},
      turn_metadata: %{"request_kind" => "turn", "turn_id" => "synthetic-turn-id"},
      claim_prefixes: %{
        turn: "codex-turn:",
        request: "codex-request:",
        derived_retry: "codex-request-retry:"
      },
      refused: [
        "identical_native_http_resend",
        "every_further_resend_of_one_turn",
        "resend_of_a_turn_that_delivered_output_after_a_served_zero_output_failure",
        "grown_body_retry_of_an_uncompacted_turn",
        "grown_body_retry_of_a_turn_in_a_compacted_thread",
        "changed_non_input_field_between_a_compacted_turns_attempts",
        "reordered_or_dropped_item_before_the_compaction_output_item",
        "https_fallback_of_a_drained_websocket_turn_in_a_compacted_session",
        "one_turn_id_reused_across_a_user_message_after_an_opener_that_recorded_no_progress",
        "identical_resend_of_a_served_steered_websocket_frame",
        "full_history_resend_on_another_socket_of_a_steer_served_anchored",
        "https_fallback_of_a_websocket_opener_as_sent_or_rebuilt_with_its_answer",
        "full_history_resend_of_a_next_turn_opener_anchored_on_the_previous_turn",
        "full_history_resend_of_a_turn_opener_with_fewer_user_messages_after_the_same_pivot",
        "full_history_resend_of_a_turn_opener_whose_compaction_pivot_is_gone",
        "identical_post_compaction_resume",
        "identical_prewarm_or_memory_sharing_the_turn_id"
      ],
      served: [
        "post_compaction_resume_retry_advanced_by_exact_delivered_output",
        "resend_after_a_zero_output_provider_failure",
        "retry_while_the_predecessor_is_unfinished",
        "prewarm_sharing_the_turn_id",
        "turn_and_its_own_compaction_in_either_order",
        "post_compaction_resume_with_nothing_after_the_compaction_output_item",
        "tool_continuation_of_a_post_compaction_resume",
        "two_genuinely_different_native_http_turns",
        "same_turn_id_under_a_different_codex_session",
        "tool_result_continuation_resent_with_a_grown_body",
        "compaction_resent_with_a_changed_body",
        "attempt_past_the_chain_depth_bound",
        "identical_native_http_compaction_resend_chained_once_per_request",
        "steered_user_message_under_the_turn_id_of_a_native_http_opener",
        "steered_websocket_frame_anchored_on_its_own_turns_response_on_the_same_socket",
        "steered_full_history_frame_on_a_new_socket_after_a_websocket_opener",
        "steered_native_http_request_after_a_websocket_opener",
        "steered_request_after_a_mid_turn_compaction_of_an_already_compacted_session"
      ]
    },
    reasoning_minimal: %{
      json: %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic reasoning request",
        "reasoning" => %{"effort" => "minimal"}
      }
    },
    reasoning_none: %{
      json: %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic reasoning request",
        "reasoning" => %{"effort" => "none"}
      }
    },
    reasoning_ultra: %{
      json: %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic reasoning request",
        "reasoning" => %{"effort" => "ultra"}
      }
    },
    api_key_reservation_policy_refusals: %{
      code: "api_key_policy_limit_exceeded",
      window: %{
        limits: ["max_requests_per_minute", "max_tokens_per_day", "max_tokens_per_week"],
        admits_request_once_moved: true,
        status: 429,
        type: "rate_limit_error",
        retry_after_seconds: %{minute: 60, daily: :until_next_utc_midnight, weekly: nil},
        http_x_should_retry: %{minute: nil, daily: "false", weekly: "false"},
        hint_surfaces: %{http: "retry-after header", websocket: "error event headers.retry-after"}
      },
      request_cap: %{
        limits: ["max_input_tokens_per_request", "max_output_tokens_per_request"],
        window_below_request_estimate: ["max_tokens_per_day", "max_tokens_per_week"],
        status: 400,
        type: "invalid_request_error",
        retry_hint: nil
      },
      recorded_status: :answered_status,
      owner_forwarding: :same_answer,
      retry_successor_refusal: %{recorded: true, holds_request_claim: false},
      pre_claim_refusal_holds_request_claim: false
    },
    api_key_terminal_policy_denials: %{
      model_not_allowed: %{status: 400, type: "invalid_request_error", param: "model"},
      request_cap: %{status: 400, type: "invalid_request_error", code: "api_key_policy_limit_exceeded"},
      image_generation_disabled: %{status: 403, type: "invalid_request_error", routes: :http_image_routes_only},
      recorded_status: :answered_status
    },
    exhausted_pool_usage_limit: %{
      terminal: %{status: 429, type: "usage_limit_reached", code: "quota_exhausted", fields: ["resets_at", "resets_in_seconds"], retry_after: :earliest_reset_seconds, x_should_retry_false_above_seconds: 60},
      retryable: %{status: 503, codes: ["quota_evidence_unavailable", "quota_exhausted"], when: [:reset_unknown, :circuit_excluded_candidate]},
      v1_message: "upstream quota is exhausted until its reset time",
      recorded_status: :answered_status,
      relayed_provider_usage_limit: %{when: :last_candidate_provider_429, reset: ["resets_at", "resets_in_seconds"], answer: :terminal, without_reset: %{v1_type: "rate_limit_error"}, recorded: %{status: 429, code: "upstream_rate_limited"}},
      circuit_retry_after: %{status: 503, header: "retry-after", seconds: :earliest_circuit_probe, clamp: {1, 60}, x_should_retry: :absent}
    },
    api_key_reasoning_availability: %{
      modes: [:unrestricted, :allow_up_to, :always_use],
      known_efforts: ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"],
      denial: %{
        status: 400,
        code: "reasoning_effort_not_allowed",
        message: "reasoning effort is not available for this API key",
        responses_param: "reasoning.effort",
        chat_param: "reasoning_effort",
        before_reservation: true,
        upstream_called: false
      },
      websocket: %{
        policy_timing: "response.create_after_upgrade",
        denial: "existing_error_frame",
        upgrade_rejected: false
      },
      metadata: %{
        unrestricted: "existing_levels_and_default",
        allow_up_to: "permitted_known_levels_and_default",
        always_use: "singleton_when_model_effective_else_empty",
        models_remain_visible: true,
        public_v1_models_changed: false
      },
      aliases: %{"minimal" => "low", "ultra" => "max"},
      json: %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic reasoning availability request",
        "reasoning" => %{"effort" => "medium"}
      }
    },
    reasoning_context: %{
      accepted_values: ["auto", "current_turn", "all_turns"],
      normalization: "trim_and_lowercase",
      rejected_values: ["unknown_strings", "empty_strings", "non_strings", "arrays", "maps"],
      routes: ["/v1/responses"],
      json: %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic reasoning context request",
        "reasoning" => %{"context" => " current_turn "}
      }
    },
    unsupported_upstream_fields: %{
      json: %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic unsupported field request",
        "max_output_tokens" => 128,
        "prompt_cache_retention" => "24h",
        "safety_identifier" => "safe_fixture",
        "temperature" => 0.2,
        "top_p" => 0.9
      }
    },
    api_key_websocket_revocation: %{
      disabling_statuses: [:paused, :revoked],
      disabling_changes: [
        :pause,
        :revoke,
        :key_delete,
        :expiry,
        :pool_disable,
        :pool_archive,
        :pool_delete,
        :pool_move
      ],
      new_authentication: :blocked,
      prompt_delivery: %{
        channel: :pool_scoped_post_commit_event,
        role: :prompt_only,
        authorization_authority: :durable_api_key_row,
        newer_epoch_event: :latches_revocation,
        reread_events: [
          :api_key_deleted,
          :api_key_updated,
          :pool_status_updated,
          :inactive_pool_updated,
          :pool_deleted
        ]
      },
      durable_fence: %{
        authority: :locked_api_key_row,
        captured_epoch: :must_match,
        missed_relay: :reject_later_frame,
        key_missing: :refused_with_captured_epoch,
        expiry: :compared_with_database_clock,
        pool_status: :read_with_key_row,
        response_processed: :authorized_before_upstream_forward,
        claim_and_reservation_refusal: :latches_revocation,
        pool_move: :advances_runtime_epoch
      },
      idle_expiry: %{
        event: :none,
        check: :scheduled_at_expires_at,
        authority: :durable_reread
      },
      close: %{
        code: 1008,
        reason: "api key is no longer active",
        synthetic_error_frame: false
      },
      work: %{
        pre_admitted: :drains_and_settles_once,
        queued_and_later: :dropped
      },
      legacy_epochless_event: %{
        fallback: :reread_durable_authorization,
        delayed_after_resume: :ignored_when_active
      },
      resume: :fresh_connection_required,
      rolling_release: :full_cluster_protection_after_all_app_replicas_updated,
      firewall: :unchanged
    },
    firewall: %{
      protected_route_families: [
        :backend_codex,
        :backend_files,
        :backend_transcribe,
        :codex_usage,
        :wham_usage,
        :backend_wham_usage,
        :public_v1,
        :mcp
      ],
      canonical_path: %{
        decode_passes: 1,
        decoded_segments_mutated: false,
        candidate_separators: ["/", "\\"],
        candidate_nul: %{classification: :truncate, runtime: :reject_invalid_path}
      },
      forwarded_client_ip: %{
        sources: [:peer, :x_forwarded_for, :x_real_ip],
        default_source: :x_forwarded_for,
        default_proxy_depth: 0,
        source_depths: %{peer: [0], x_forwarded_for: 0..16, x_real_ip: [0]},
        trusted_peer_required_for_x_forwarded_for: true,
        trusted_peer_required_for_x_real_ip: true,
        selected_source_fallback: false,
        xff_duplicate_fields: :combined_in_wire_order,
        x_real_ip_fields: :exactly_one,
        positional_depth: %{
          range: 1..16,
          selected_entry: :nth_from_right,
          peer_counts_as_proxy: true,
          peer_is_xff_entry: false
        },
        max_hops: 32,
        max_entry_bytes: 64,
        accepted_ports: %{ipv4: true, bracketed_ipv6: true, range: 1..65_535},
        nonruntime_client_ip: :peer,
        strict_ip_cidr: %{
          outer_whitespace: :ascii_space_or_tab,
          prefix: :canonical_unsigned_decimal,
          ipv4_mapped_ipv6: :normalized_to_ipv4,
          invalid_stored_rules: :fail_closed
        }
      },
      allowlist: %{empty: :disabled},
      cold_settings: %{status: 503, runtime_and_mcp: :fail_closed},
      warm_settings: :last_known_good_enforced,
      revoked_websocket: %{
        close_code: 1008,
        admitted_work: :finishes,
        new_work: :refused,
        reason: :websocket_revoked
      },
      denial_telemetry: %{
        metric: "codex_pooler_ingress_firewall_denied_count",
        labels: [:scope, :reason],
        accounting: :before_authenticated_request_accounting
      }
    },
    pruned_runtime_helper_firewall: %{
      routes: [
        %{method: :get, path: "/backend-api/codex/agent-identities/jwks"},
        %{method: :get, path: "/backend-api/wham/agent-identities/jwks"},
        %{method: :post, path: "/api/codex/rate-limit-reset-credits/consume"},
        %{method: :post, path: "/wham/rate-limit-reset-credits/consume"},
        %{method: :post, path: "/backend-api/wham/rate-limit-reset-credits/consume"},
        %{method: :post, path: "/backend-api/codex/thread/goal/get"},
        %{method: :post, path: "/backend-api/codex/thread/goal/set"},
        %{method: :post, path: "/backend-api/codex/thread/goal/clear"},
        %{method: :post, path: "/backend-api/codex/analytics-events/events"},
        %{method: :post, path: "/backend-api/codex/memories/trace_summarize"},
        %{method: :post, path: "/backend-api/codex/alpha/search"},
        %{method: :post, path: "/backend-api/codex/realtime/calls"},
        %{method: :post, path: "/backend-api/codex/safety/arc"}
      ],
      disabled: %{status: 404, content_type: "text/html; charset=utf-8", body: "Not Found"},
      admitted: %{status: 404, content_type: "text/html; charset=utf-8", body: "Not Found"},
      denied: %{status: 403, error_code: "access_denied"},
      settings_unavailable: %{status: 503, error_code: "settings_unavailable"},
      authentication: :not_attempted,
      body_read: false,
      upstream_dispatch: false,
      reservation: false,
      accounting: false,
      denial_observation: :exactly_one_bounded_event
    },
    compressed_request: %{encoding: "gzip", bytes: "synthetic compressed bytes"},
    bulkhead_overload: %{lane: "proxy_http", decision: "synthetic shed"},
    database_unavailable: %{
      status: 503,
      error_code: "service_unavailable",
      error_type: "server_error",
      stages: [:authentication, :pre_dispatch, :turn_claim, :replay_intent, :reservation],
      upstream_dispatch: false,
      reservation: false,
      denied_request_record: false
    },
    degraded_routing: %{
      json: %{"model" => "gpt-fixture-text", "input" => "synthetic fallback"},
      windowless_provider_availability: %{
        routing_state: "windowless_provider_available",
        required_metadata: ["version", "state", "observed_at", "credential_epoch"],
        requires_current_credential_epoch: true,
        requires_fresh_observation: true,
        requires_no_account_window_evidence: true,
        precedence: "below_reset_bearing_windows",
        fabricated_window_or_reset: false
      },
      fail_closed: %{
        status: 503,
        blocked_error_code: "quota_exhausted",
        unavailable_error_code: "quota_evidence_unavailable",
        states: [
          "provider_blocked",
          "provider_unknown",
          "stale_provider_availability",
          "credential_epoch_mismatch",
          "malformed_provider_availability",
          "applicable_model_or_additional_blocker"
        ]
      }
    },
    strict_schema_rejection: %{
      json: %{
        "model" => "gpt-fixture-text",
        "text" => %{
          "format" => %{
            "type" => "json_schema",
            "strict" => true,
            "schema" => %{"type" => "object", "properties" => %{"value" => %{"type" => "string"}}}
          }
        }
      }
    },
    public_strict_schema_object_roots: %{
      scope: "public_and_translated_openai_compatibility",
      strict_target_shapes: [
        "text.format.schema",
        "response_format.json_schema.schema",
        "tools[].parameters",
        "tools[].function.parameters",
        "tools[].tools[].parameters"
      ],
      required_root: %{
        shape: "map",
        type: "object",
        direct_type_pair: true,
        root_ref: false,
        root_any_of: false
      },
      rejected_root_families: [
        "omitted_type",
        "primitive_type",
        "array_type",
        "singleton_type_array",
        "nullable_object_type_union",
        "root_ref",
        "root_any_of",
        "object_with_root_any_of"
      ],
      accepted_nested_constructs: [
        "local_refs",
        "recursive_refs",
        "primitives",
        "arrays",
        "nullable_unions",
        "any_of",
        "one_of",
        "all_of"
      ],
      accepted_definition_dialects: ["$defs", "definitions"],
      errors: %{
        structured_output: %{
          status: 400,
          code: "invalid_json_schema",
          root_param: "text.format.schema"
        },
        function_parameters: %{
          status: 400,
          code: "invalid_function_parameters",
          root_params: [
            "tools.0.parameters",
            "tools.0.function.parameters",
            "tools.0.tools.0.parameters"
          ]
        }
      },
      rejection_boundary: %{
        upstream_dispatch: false,
        request_created: false,
        attempt_created: false,
        ledger_entry_created: false,
        request_log_fact_created: false
      },
      preservation: %{
        non_strict_structured_output: "unchanged",
        non_strict_function_parameters: "unchanged",
        direct_responses_nested_missing_type_repair: "unchanged",
        native_backend_strict_array_root: "unchanged",
        native_backend_strict_local_root_ref: "unchanged"
      },
      native_backend_exclusions: [
        "/backend-api/codex/responses",
        "/backend-api/codex/v1/responses",
        "/backend-api/codex/responses websocket",
        "/backend-api/codex/v1/responses websocket"
      ],
      privacy: "schema_shape_only"
    },
    unsupported_input_image_reference: %{
      accepted_url_schemes: ["https", "data:image"],
      unsupported_url_schemes: ["http", "sediment", "file"],
      v1_image_details: ["low", "high", "auto", "original"],
      v1_invalid_image_detail: %{status: 400, type: "invalid_request_error", code: "invalid_value", param: "input[2].output[1].detail"},
      v1_chat_invalid_image_detail: %{status: 400, type: "invalid_request_error", code: "invalid_value", param: "messages[0].content[1].image_url.detail"},
      v1_chat_tool_message_image_parts: ["image_url"],
      v1_role_tool_invalid_image_detail: %{status: 400, type: "invalid_request_error", code: "invalid_value", param: "input[1].content[1].image_url.detail"},
      v1_chat_tool_result_invalid_image_detail: %{status: 400, type: "invalid_request_error", code: "invalid_value", param: "messages[1].content[0].output[1].image_url.detail"},
      json: %{
        "model" => "gpt-fixture-vision",
        "input" => [
          %{
            "role" => "user",
            "content" => [%{"type" => "input_image", "file_id" => "file_fixture"}]
          }
        ]
      }
    },
    first_event_stream_retry: %{
      json: %{"model" => "gpt-fixture-text", "input" => "synthetic stream", "stream" => true},
      retry_window: "before_visible_output"
    },
    request_compression: %{
      pool_gate: %{
        setting: "request_compression_enabled",
        default_enabled: false,
        disabled_behavior: "original_request_passthrough"
      },
      direction: "request_side_only",
      failure_mode: "fail_open_original_request",
      route_classes: %{
        http: ["proxy_http", "proxy_stream"],
        compact: "proxy_compact",
        websocket: "proxy_websocket",
        public_unsupported_compact: "proxy_http"
      },
      eligible_route_families: [
        "backend_responses",
        "backend_v1_responses_alias",
        "backend_v1_chat_alias",
        "public_v1_responses",
        "public_v1_chat_translation",
        "backend_compact",
        "backend_v1_compact_alias",
        "backend_websocket_response_create",
        "backend_v1_websocket_response_create_alias",
        "public_v1_websocket_response_create"
      ],
      ineligible_surfaces: [
        "multipart",
        "files",
        "audio",
        "images",
        "admin",
        "mcp",
        "usage",
        "control_plane"
      ],
      public_unsupported_compact: %{
        method: :post,
        path: "/v1/responses/compact",
        status: 404,
        error_code: "unsupported_endpoint",
        compression_eligible: false,
        upstream_dispatch: false
      },
      privacy: %{
        raw_outputs_stored: false,
        raw_response_bodies_stored: false,
        ccr_retrieval: false,
        request_log_metadata: "payload_compression",
        metadata_only: true
      },
      protected_tool_outputs: %{
        default_function_names: [
          "Read",
          "Glob",
          "Grep",
          "Write",
          "Edit",
          "WebSearch",
          "WebFetch",
          "web_search",
          "web_fetch"
        ],
        lowercase_variants: true,
        external_retrieval: true,
        unknown_function_output_behavior: "protected_original_output_preserved",
        command_backed_reads: %{
          arguments: ["cmd", "command"],
          native_action: %{type: "exec", command: "argv"},
          direct_commands: ["cat", "nl", "head", "tail", "sed_print_only"],
          pipeline: "nl_to_sed_print_only",
          producer_aliases: %{
            function_call: ["call_id"],
            local_shell_call: ["call_id", "id"]
          },
          output_aliases: %{
            function_call_output: ["call_id"],
            local_shell_call_output: ["call_id", "id"]
          },
          output_compatibility: %{
            function_call_output: ["function_call", "local_shell_call"],
            local_shell_call_output: ["local_shell_call"]
          },
          owner_identity: "positional_producer_path",
          unresolved_function_output: "protected_legacy",
          unresolved_local_shell_output: "existing_behavior",
          duplicate_aliases: "protected_original_output_preserved",
          cross_kind_collisions: "protected_original_output_preserved",
          conflicting_output_aliases: "protected_original_output_preserved",
          recognized_owner_stage: "before_output_range_lookup_and_content_detection",
          malformed_or_unrecognized: "existing_behavior",
          output_behavior: "byte_exact",
          metadata: "aggregate_counts_only"
        },
        output_behavior: "original_output_preserved",
        metadata: "aggregate_counts_only"
      },
      supported_input_shapes: %{
        embedded_json: %{
          container_kinds: ["object", "array"],
          surrounding_bytes: "preserved",
          quoted_json_looking_text: "preserved",
          malformed_or_over_limit_behavior: "original_output_preserved",
          maximum_spans: 50
        },
        search_results: [
          "classic_path_line",
          "grouped_heading",
          "portable_nul_delimited"
        ],
        diffs: [
          "hunk_additions_only",
          "hunk_deletions_only",
          "hunk_replacement",
          "minimal_unified_hunk",
          "combined_unified_hunk",
          "long_preamble_diff"
        ],
        false_positive_guards: [
          "path_like_group_heading",
          "minimum_grouped_matches",
          "hunk_header_required"
        ],
        log_output: [
          "failure_summary_guard"
        ]
      }
    },
    backend_agent_v2_handoffs: %{
      transports: ["websocket_response_create"],
      preserved_message_types: ["NEW_TASK", "MESSAGE"],
      content_shape: ["input_text", "encrypted_content"],
      author_recipient_shape: "absolute_agent_paths",
      protocol_bindings: %{task_name: "recipient", sender: "author"},
      encrypted_content: "nonempty",
      fixture_source: "c9c6c0daa994109cec50fddcb57d076fdf9e738c",
      v1_ordinary_user_role_handoff: "preserved",
      v2_collaboration_namespace: "byte_exact_passthrough",
      plaintext_encrypted_function_args_empty: "preserved",
      plaintext_final_answer: "preserved",
      other_encrypted_agent_messages: "removed",
      assistant_encrypted_replay: "preserved",
      durable_metadata: "encrypted_content_omitted"
    },
    multi_agent_product_certification: %{
      source_pin: "c9c6c0daa994109cec50fddcb57d076fdf9e738c",
      primary_serving_mode: "full",
      preflight: %{
        catalog_authenticated: true,
        catalog_use_responses_lite: false,
        configured_mode: "full",
        effective_mode: "full",
        http_lite_header_present: false,
        websocket_lite_metadata_present: false
      },
      protocol_matrix: %{
        v1: %{
          model: "gpt-5.5",
          selection: "feature_fallback",
          multi_agent: true,
          multi_agent_v2: false
        },
        v2: %{
          model: "gpt-5.6-terra",
          selection: "feature_override",
          multi_agent_v2: true
        },
        direct_control: %{model: "gpt-5.6-terra", provider: "builtin_openai"},
        same_model_causal_pair: ["v2", "direct_control"]
      },
      live_text_stages: [
        "provider_to_pooler",
        "pooler_to_codex_writer",
        "codex_app_server",
        "desktop_preview"
      ],
      live_text_disposition: %{
        pooler_delivery: "present",
        first_failing_stage: "codex_app_server_boundary",
        native_writer_regression: "byte_exact_native_websocket_writer_pass_through",
        production_transport_change: "none"
      },
      done_claim_stages: [
        "resolved_child_instruction",
        "raw_child_completion",
        "parent_delivered_completion",
        "lazycodex_validator"
      ],
      done_claim_disposition: %{
        v2_exact_instruction: "instruction_observation_missing",
        reason: "opaque_encrypted_arguments_without_permitted_external_resolution_source",
        downstream_stages: "not_attributed_past_first_missing_observation"
      },
      implemented_runtime_outcomes: %{
        compact_projection: %{
          preserves: [
            "model",
            "input",
            "instructions",
            "tools",
            "parallel_tool_calls",
            "reasoning",
            "service_tier",
            "prompt_cache_key",
            "text"
          ],
          excludes: [
            "tool_choice",
            "previous_response_id",
            "conversation",
            "stream",
            "include",
            "store",
            "compaction_trigger"
          ],
          singleton_disposition: "provider_selected_compact_route_no_synthetic_success"
        },
        overload: %{
          public_status: 503,
          wire_code: "server_is_overloaded",
          internal_reasons: ["bulkhead_rejected", "bulkhead_queue_timeout"]
        },
        flat_schema_encrypted_property: "preserved_while_true_schema_keyword_removed",
        public_v1: %{
          unknown_typed_input: "reject_before_dispatch",
          nested_tool_search: "reject_before_dispatch",
          encrypted_function_args: "validated_and_round_tripped"
        },
        native_encrypted_function_args: "pass_through",
        routing_hint: "trusted_effective_model_and_service_tier_native_and_v1_translated",
        schema_bound_function_output_compression: "byte_exact_json_preserved",
        encrypted_continuity: "evidence_selected_without_node_local_state",
        responses_lite_full: %{
          native_input_and_tools: "same_validation_across_modes",
          compact_lite: "body_rewrite_and_marker",
          auto_source: "health_level_aggregate",
          image_retry_snapshot: "immutable",
          context_window_policy: "mode_independent",
          explicit_override_retention: "retained_until_auto_deletes",
          assigned_instance_admin: "models_only_pool_operate"
        }
      },
      deployment_certification: "exact_tested_commit_sha_required",
      reporting: "metadata_only",
      metrics_added: false,
      runtime_config_added: false,
      dashboards_changed: false,
      helm_changed: false
    },
    function_tool_schema_lowering: %{
      backend_namespace_passthrough: %{
        scope: "top_level_decoded_namespace_term",
        transports: ["http_sse", "websocket_response_create"],
        exact_term_preserved: true,
        nested_schema_lowering: false,
        encrypted_marker_cleanup: false
      },
      public_v1_nested_lowering: %{
        scope: "namespace_nested_function",
        transports: ["http_sse", "websocket_response_create"],
        recursive: true
      },
      lowered_tool_types: [
        "flat_function",
        "nested_function",
        "namespace_nested_function"
      ],
      strict_function_tools_lowered: false,
      strict_structured_outputs_lowered: false,
      unsupported_json_schema_keywords_dropped: ["$schema", "title", "default"],
      supported_schema_keywords_preserved: [
        "$ref",
        "description",
        "enum",
        "required",
        "items",
        "additionalProperties",
        "anyOf",
        "oneOf",
        "allOf",
        "$defs",
        "definitions"
      ],
      schema_repairs: [
        "boolean_schema_to_object",
        "const_to_single_value_enum",
        "infer_object_type",
        "infer_array_type",
        "default_object_properties",
        "default_array_items"
      ],
      routes: [
        "/backend-api/codex/responses",
        "/backend-api/codex/v1/responses",
        "/backend-api/codex/responses websocket",
        "/backend-api/codex/v1/responses websocket",
        "/v1/responses",
        "/v1/responses websocket"
      ],
      privacy: "schema_shape_only"
    },
    responses_allowed_tools: %{
      scope: "direct_public_responses_only",
      transports: ["http", "websocket_response_create"],
      root: %{
        exact_keys: ["type", "mode", "tools"],
        type: "allowed_tools",
        modes: ["auto", "required"],
        tools: "nonempty_list"
      },
      entries: %{
        direct_named: %{
          types: ["function", "custom"],
          exact_keys: ["type", "name"],
          name: "nonblank_string",
          declaration_scope: "direct_top_level_tools_only",
          resolution: "same_kind_and_exact_name",
          defer_loading: ["absent", false]
        },
        built_in: %{
          types: [
            "programmatic_tool_calling",
            "web_search_preview",
            "web_search",
            "image_generation"
          ],
          exact_keys: ["type"],
          declaration_scope: "top_level_tools_only",
          resolution: "at_least_one_same_type_declaration",
          multiple_same_type_declarations: "accepted"
        }
      },
      preservation: %{
        entry_order: "caller_order_unchanged",
        duplicate_entries: "preserved",
        full_mode_forwarding: "structurally_identical_tool_choice"
      },
      definition_normalization: %{
        existing_non_strict_function_schema_lowering: "unchanged",
        additional_tool_definition_rewrite: false,
        tool_choice_rewrite: false
      },
      errors: %{
        full_malformed_or_undeclared: %{
          status: 400,
          code: "invalid_request",
          message: "tool_choice shape is not translatable",
          param: "tool_choice"
        },
        lite_valid: %{
          status: 400,
          code: "unsupported_parameter",
          message: "Unsupported parameter: tool_choice",
          param: "tool_choice"
        },
        mcp_split: %{
          top_level_declaration: %{
            status: 400,
            code: "invalid_request",
            message: "remote MCP tools are not supported",
            param: "tools"
          },
          allowed_tools_member: %{
            status: 400,
            code: "invalid_request",
            message: "tool_choice shape is not translatable",
            param: "tool_choice"
          }
        }
      },
      lifecycle: %{
        full_malformed: %{
          phase: "pre_admission",
          request_rows: 0,
          attempt_rows: 0,
          ledger_rows: 0,
          upstream_dispatch: false
        },
        lite_valid: %{
          phase: "post_admission_mode_rejection",
          request_status: "rejected",
          request_rows: 1,
          attempt_rows: 0,
          ledger_rows: 0,
          upstream_dispatch: false
        }
      },
      exclusions: [
        "chat_completions",
        "native_backend_responses",
        "namespace_children",
        "input_additional_tools",
        "deferred_direct_function_or_custom",
        "unknown_or_cross_kind_names",
        "extra_root_or_entry_keys",
        "entry_aliases",
        "unsupported_or_mcp_entry_types",
        "realtime",
        "broad_openai_tool_parity"
      ],
      provider_availability: "selected_model_and_account_dependent",
      privacy: "schema_shape_only"
    },
    responses_executable_custom_tools: %{
      scope: "direct_public_responses_and_translated_chat",
      transports: ["http", "sse", "websocket_response_create"],
      required_keys: ["type", "name"],
      optional_keys: ["description", "defer_loading", "allowed_callers", "format"],
      allowed_callers: ["direct", "programmatic"],
      allowed_callers_null: true,
      formats: ["omitted", "text", "grammar_lark", "grammar_regex"],
      nested_definitions: %{
        container: "namespace",
        transports: ["http", "websocket_response_create"],
        public_scope: "direct_public_responses",
        full_mode: "preserved",
        typed_choice_scope: "namespace_nested_custom"
      },
      typed_choice: %{
        exact_keys: ["type", "name"],
        resolves_same_kind: true,
        full_mode: "preserved",
        lite_mode: "rejected_unsupported_parameter_before_dispatch",
        # The Lite rejection is serving-mode driven and applies to ANY map-shaped
        # tool_choice on any gateway lane that dispatches to the backend
        # Responses endpoint, not only to the typed custom choice on direct
        # public Responses. Chat named-function choices translate to the same
        # map form and are rejected identically on a Lite-served model.
        lite_rejection_scope: "any_map_shaped_tool_choice",
        lite_rejection_lanes: ["direct_public_responses", "chat_completions", "backend_codex"]
      },
      response_namespace_restoration: %{
        transports: ["http", "sse", "websocket_direct", "websocket_owner_forwarded"],
        when: "missing_or_null_provider_namespace_with_one_exact_namespaced_custom_declaration",
        preserves: "explicit_provider_namespace",
        unchanged: ["flat", "unknown", "non_unique"]
      },
      executable_name_collision_scope: [
        "flat_function",
        "namespace_nested_function",
        "namespace_nested_custom",
        "custom"
      ],
      custom_replay_contract: "separate_input_item_shape",
      chat_supported: true,
      chat: %{
        request_definition: "nested_type_and_custom",
        optional_definition_fields: ["description", "format"],
        typed_choice: "nested_type_and_custom_name",
        upstream_translation: "flat_responses_custom",
        completed_output: "nested_chat_custom_call",
        streamed_input: "free_form_fragments_not_json_parsed"
      },
      provider_availability: "selected_model_and_account_dependent",
      broad_openai_tool_parity: false,
      privacy: "schema_shape_only"
    },
    direct_responses_strict_schema_repair: %{
      scope: "direct_public_responses_strict_flat_function_parameters",
      transports: ["http", "websocket_response_create"],
      inserted_types: ["object", "array"],
      target_tool_shapes: ["top_level_flat_function", "namespace_child_flat_function"],
      requires_typed_object_root: true,
      requires_unambiguous_structural_evidence: true,
      exclusions: [
        "parameters_root",
        "explicit_type",
        "refs",
        "definition_tables",
        "combinators_and_descendants",
        "annotations_and_unknown_keywords",
        "ambiguous_or_incomplete_evidence",
        "strict_structured_outputs",
        "chat",
        "native_nested_function_shapes",
        "backend_routes"
      ],
      public_explicit_type_vocabulary: [
        "null",
        "boolean",
        "object",
        "array",
        "number",
        "integer",
        "string"
      ],
      malformed_duplicate_or_unsupported_explicit_type: "reject",
      strict_function_tools_lowered: false,
      strict_structured_outputs_lowered: false,
      privacy: "schema_shape_only"
    },
    v1_supported_surface: %{
      auth: "required_bearer_api_key",
      default_enabled: true,
      provider_event_headers: %{
        surfaces: [
          %{method: :post, path: "/v1/responses", transport: "http_sse"},
          %{method: :get, path: "/v1/responses", transport: "responses_websocket"}
        ],
        dropped_keys: ["headers", "response.headers"],
        scope: "every_relayed_event",
        native_websocket_with_snapshot: "projected_native_controls_only"
      },
      audio_transcription: %{
        path: "/v1/audio/transcriptions",
        caller_models: ["gpt-4o-transcribe", "gpt-transcribe"],
        caller_aliases: %{"gpt-transcribe" => "gpt-4o-transcribe"},
        alias_scope: "caller_input_only",
        canonical_model: "gpt-4o-transcribe",
        response_formats: ["json"],
        rejected_fields: ["language", "temperature"],
        decoded_list_fields: %{
          "keywords" => %{
            upstream_name: "keywords[]",
            item_shape: "non_empty_string",
            empty: "omitted",
            order: "preserved",
            duplicates: "preserved",
            malformed: "invalid_request_with_field_param",
            rejected_shapes: [
              "non_list",
              "null",
              "non_string_item",
              "empty_string_item",
              "whitespace_only_string_item"
            ]
          },
          "languages" => %{
            upstream_name: "languages[]",
            item_shape: "non_empty_string",
            empty: "omitted",
            order: "preserved",
            duplicates: "preserved",
            malformed: "invalid_request_with_field_param",
            rejected_shapes: [
              "non_list",
              "null",
              "non_string_item",
              "empty_string_item",
              "whitespace_only_string_item"
            ]
          }
        },
        response_omissions: ["languages"],
        auth: "required_bearer_api_key_before_multipart_parsing",
        persistence: "metadata_only_without_audio_or_decoded_list_values",
        exclusions: %{
          detected_language_output: false,
          caller_alias_in_model_discovery: false,
          caller_alias_in_catalog: false,
          model_discovery_claim: false,
          catalog_claim: false,
          full_openai_audio_parity: false
        }
      },
      prompt_cache_routing_allowed_routes: [
        "/v1/responses",
        "/v1/chat/completions"
      ],
      prompt_cache_routing_excluded_surfaces: [
        "compact",
        "files",
        "audio",
        "images"
      ],
      unsupported_compact: %{
        method: :post,
        path: "/v1/responses/compact",
        status: 404,
        error_code: "unsupported_endpoint",
        upstream_dispatch: false
      },
      routes: [
        "/v1/models",
        "/v1/responses",
        "/v1/responses/compact",
        "/v1/chat/completions",
        "/v1/usage",
        "/v1/files",
        "/v1/audio/transcriptions",
        "/v1/images/generations",
        "/v1/images/edits"
      ],
      websocket_route: %{method: :get, path: "/v1/responses"},
      websocket_contract: "narrow_responses_websocket_only",
      stream_interruption_contract: %{
        applies_to: "POST /v1/responses HTTP SSE after public Responses data",
        event_label_normalization: %{
          absent_blank_whitespace: "absent",
          nonblank_mismatch: "drop"
        },
        oversized_incomplete_sse: %{
          ordinary_max_buffered_bytes: 8_388_608,
          terminal_candidate_max_buffered_bytes: 67_108_864,
          source_bytes_relayed: false,
          terminal_event: "error",
          accounting_error_code: "upstream_stream_error"
        },
        terminal_event: "error",
        wire_error_code: "server_error",
        accounting_error_code: "upstream_stream_error",
        safe_message: "upstream request failed: stream interrupted before terminal response event",
        post_budget_owner_drain: %{
          applies_to: "committed websocket bridge turn aborted after rollout drain budget",
          accounting_error_code: "owner_drained",
          local_activity: ["direct_response_task", "remote_owner_proxy_response_task"],
          admission: "register_before_atomic_cutoff_gate",
          deadline: "shared_absolute_existing_budget",
          completion_boundary: "socket_terminal_delivery_safe",
          remote_owner: "matching_turn_cancelled_owner_and_lease_reusable",
          summary_counters: [
            "direct_turns_seen",
            "direct_turns_completed",
            "direct_turns_aborted",
            "direct_turns_failed",
            "proxy_turns_seen",
            "proxy_turns_completed",
            "proxy_turns_aborted",
            "proxy_turns_failed"
          ]
        },
        deferred_http_sse_drain: %{
          applies_to: "in-flight deferred HTTP SSE stream drained by rollout drain",
          accounting_error_code: "owner_drained",
          response_status_code: 499,
          turn_status: "interrupted",
          reservation: "released",
          registry: "node_local_deferred_stream_registry",
          admission: "register_before_relay_and_signal_after_cutoff",
          deadline: "shared_absolute_existing_budget",
          settlement: "stream_process_finalizes_once",
          upstream_health: "neutral",
          unsettled_stream: "aborted_then_left_to_absent_instance_recovery",
          summary_counters: [
            "http_streams_seen",
            "http_streams_completed",
            "http_streams_aborted",
            "http_streams_failed"
          ]
        },
        absent_instance_recovery: %{
          applies_to: "open attempt whose owning instance stopped publishing presence, including an attempt still waiting for the first upstream byte that no drain can reach",
          accounting_error_code: "absent_instance_recovered",
          response_status_code: 499,
          turn_status: "interrupted",
          reservation: "released",
          owner: "attempt_owner_node_name_and_boot_id",
          owner_identity: "node_name_plus_vm_incarnation",
          presence: "shared_postgres_instance_presence_row_per_incarnation",
          in_place_restart: "successor_incarnation_never_refreshes_predecessor_row",
          pre_incarnation_attempt: "left_to_stale_reservation_sweep",
          session_owner: "session_and_lease_owner_node_name_and_boot_id",
          session_owner_claim: "same_incarnation_only_successor_takes_owner_unavailable_takeover",
          owner_lease_liveness: "absent_incarnation_lease_is_not_live_work",
          unknown_owner_lease: "treated_as_live_and_left_to_stale_reservation_sweep",
          pre_incarnation_session: "node_name_only_match_preserved_and_never_recoverable",
          liveness_window_seconds: 120,
          live_instance: "never_finalized",
          unknown_instance: "left_to_stale_reservation_sweep",
          upstream_health: "neutral",
          runs_in: "runtime_state_cleanup_pass",
          final_backstop: "stale_reservation_sweep_at_six_hours"
        },
        precommit_drain: "fail_closed_without_resubmission",
        client_disconnect: "unchanged",
        non_drain_interruptions: "byte_identical",
        backend_raw_streams: "unchanged",
        public_owner_forwarded_websocket_interruption: %{
          applies_to: "GET /v1/responses owner-forwarded per-call turns after committed public output",
          terminal_event: "error",
          status: 502,
          wire_error_code: "server_error",
          accounting_error_code: "upstream_stream_error",
          safe_message: "upstream request failed: stream interrupted before terminal response event"
        },
        public_websocket_invalid_provider_frames: %{
          forms: ["invalid_json", "string", "array", "number", "null"],
          direct: "drop_without_state_advance",
          accepted_owner_forwarded: "drop_without_state_advance",
          wrong_owner_metadata: "drop",
          local_terminal: false
        },
        other_websocket_streams: "unchanged",
        raw_error_details: false
      },
      chat_input_fallback: %{
        messages_precedence: "non_empty_messages",
        fallback_when: ["messages_absent", "messages_empty"],
        fallback_source: "input",
        default_instructions: "blank_string"
      },
      additional_tools_input_item: %{
        shape: "request_input_item",
        required: ["type", "role", "tools"],
        optional: ["id"],
        role: "developer",
        executable: false,
        merges_into_tools: false,
        satisfies_tool_choice: false,
        unsupported_nested_tool_types: ["mcp", "tool_search"]
      },
      remote_mcp_tools: %{
        supported: false,
        locations: ["tools", "input.additional_tools.tools"],
        error_code: "invalid_request",
        dispatch: false
      },
      responses_truncation: %{
        accepted_values: ["auto", "disabled"],
        forwarded_upstream: false
      },
      responses_builtin_tools: %{
        web_search_preview: %{accepted_shape: "type_only"},
        web_search: %{
          accepted_required: ["type"],
          accepted_optional: ["external_web_access", "index_gated_web_access", "filters"],
          valid_combinations: [
            "type_only",
            "external_web_access=false",
            "external_web_access=true",
            "external_web_access=true,index_gated_web_access=true"
          ],
          filters: %{
            shape: "nonempty_object",
            allowed_keys: ["allowed_domains", "blocked_domains"],
            lists: %{
              allowed_domains: %{
                minimum_items: 1,
                maximum_items: 100,
                item_shape: "nonblank_string_without_http_scheme",
                forwarding: "unchanged"
              },
              blocked_domains: %{
                minimum_items: 1,
                maximum_items: 100,
                item_shape: "nonblank_string_without_http_scheme",
                forwarding: "unchanged"
              }
            },
            valid_combinations: [
              "allowed_domains",
              "blocked_domains",
              "allowed_domains,blocked_domains"
            ]
          },
          rejected_options: ["search_context_size", "user_location"],
          upstream_confidence: %{
            pooler_contract: "validation_and_unchanged_forwarding",
            availability_and_enforcement: "selected_model_and_account_dependent",
            blocked_domains: "hosted_codex_enforcement_not_locally_proven",
            broad_parity_claim: false
          }
        },
        image_generation: %{accepted_shape: "type_only_or_exact_known_image_options"}
      },
      instruction_lifting: %{
        roles: ["system", "developer"],
        destination: "instructions",
        merge_order: ["existing_instructions", "input_order_instruction_text"],
        residual_non_text_role: "user",
        blank_text: "omitted",
        malformed_content: "sanitized_invalid_request"
      },
      early_stream_errors: %{
        responses_first_events: ["response.failed", "error"],
        responses_suppresses_synthetic_success_prefix_before_output: true,
        chat_first_chunk: "data_error_object",
        chat_omits_assistant_role_before_output: true,
        chat_omits_done_before_output: true,
        late_failures_retry: false,
        non_stream_errors: "json_error"
      },
      public_error_redaction: %{
        pooler_policy_denials_unredacted: [
          "api_key_missing",
          "api_key_disabled",
          "api_key_policy_malformed",
          "model_not_allowed",
          "image_generation_disabled",
          "api_key_concurrency_limit_exceeded",
          "api_key_policy_limit_exceeded"
        ],
        pooler_policy_denial_marker: "pooler_policy",
        server_class_surfaces: ["responses_json", "responses_sse_terminal", "chat_streaming"],
        server_class_message: "upstream request failed",
        server_class_type: "server_error",
        server_class_code: ["safe_upstream_code", "upstream_error"],
        responses_terminal_code_locations: [
          "response.error.code",
          "top_level_error.code_when_emitted"
        ],
        responses_terminal_stream_paths: [
          "low_level_public_sse_normalization",
          "runtime_streaming_relay"
        ],
        relayed_failed_projection: %{
          event_fields: ["type", "response", "sequence_number_when_present", "error_when_present"],
          response_fields: [
            "id",
            "created_at",
            "status",
            "error",
            "incomplete_details",
            "model",
            "object",
            "output",
            "output_text",
            "instructions",
            "metadata",
            "parallel_tool_calls",
            "tool_choice",
            "tools",
            "usage",
            "temperature",
            "top_p"
          ],
          unknown_siblings: "excluded",
          error_locations: "sanitized_independently_without_copying",
          valid_error_code: "preserved_unchanged",
          invalid_error_code: "upstream_error",
          error_message: "upstream request failed",
          error_type: "server_error",
          # findings#254 row 254-82: the masked failure of a provider 429 the
          # upstream websocket sent as its wrapped frame, typed like the `/v1`
          # HTTP answer of the same throttle.
          wrapped_429_error_type: "rate_limit_error",
          id: "validated_resp_identifier_or_resp_failed",
          usage: "bounded_named_field_projection_or_nil",
          content_fields: %{
            output: [],
            output_text: "",
            instructions: nil,
            metadata: nil,
            tools: [],
            temperature: nil,
            top_p: nil
          }
        },
        preserves_invalid_request_error_details: true
      },
      chat_finish_reasons: %{
        content_filter_incomplete_reasons: ["content_filter", "content-filter"],
        content_filter_finish_reason: "content_filter",
        other_incomplete_finish_reason: "length"
      },
      structured_tool_results: %{
        accepted_outputs: ["nested_json_map", "nested_json_list", "long_string_values"],
        forwarded_unchanged: true,
        projection_mode: "shape_counts_and_hashed_previews_only",
        raw_echo_allowed: false
      },
      chat_style_tool_continuation: %{
        input_role: "tool",
        id_fields: ["tool_call_id", "call_id"],
        translated_type: "function_call_output",
        requires_previous_response_id: true,
        metadata_only: true
      },
      hermes_assistant_tool_call_replay: %{
        input_role: "assistant",
        source_field: "tool_calls",
        translated_type: "function_call",
        id_fields: ["call_id", "id"],
        reasoning_replay_sequence: ["reasoning", "assistant", "function_call", "tool"],
        empty_assistant_content_type: "output_text",
        tool_content_output_field: "output",
        ordinary_replay_status_values: ["completed", "incomplete", "in_progress"],
        requires_previous_response_id: true,
        metadata_only: true
      },
      open_responses_reasoning_replay: %{
        input_type: "reasoning",
        content_part_type: "reasoning_text",
        preserves_with_previous_response_id: true,
        stateless_behavior: "dropped_before_dispatch",
        continuation_malformed_content: "reject_before_dispatch",
        metadata_only: true
      },
      openclaw_assistant_thinking_replay: %{
        input_role: "assistant",
        dropped_content_part_type: "thinking",
        normalized_content_part_type: "output_text",
        source_text_part_type: "text",
        output_text_annotations: %{
          accepted_type: "url_citation",
          exact_keys: ["type", "start_index", "end_index", "url", "title"],
          preserves: ["order", "exact_values", "explicit_empty_list", "omission"],
          malformed: "reject_before_dispatch"
        },
        requires_previous_response_id: false,
        metadata_only: true
      },
      open_responses_websocket_stream_id: %{
        scope: "GET /v1/responses websocket response.create only",
        validator: %{
          type: "string",
          byte_length: 1..256,
          pattern: "^[A-Za-z0-9_.-]+$"
        },
        conditional_echo: "every attributable Open Responses server event for an accepted create",
        same_id_fifo: "guaranteed_by_existing_per_connection_serialization",
        cross_id_concurrency: "unspecified; different IDs remain per-connection serialized",
        previous_response_id: "independent_conversation_lineage",
        upstream: "stripped_before_coercion_request_options_continuity_and_upstream_dispatch",
        privacy: "transient_queue_and_active_socket_turn_only; excluded_from_persistence_accounting_logs_telemetry_metadata_and_owner_contracts",
        exclusions: [
          "POST /v1/responses",
          "native backend HTTP and WebSockets",
          "Chat",
          "compact",
          "batches",
          "response-output storage"
        ]
      },
      continuity_precedence: [
        "x-codex-window-id",
        "x-codex-session-id",
        "session-id",
        "x-session-id",
        "x-session-affinity",
        "session_id",
        "x-codex-conversation-id"
      ],
      local_session_scope: "authenticated_pool_and_api_key",
      local_continuity_headers_not_forwarded: ["session-id", "x-session-id", "x-session-affinity"],
      public_v1_upstream_session_id: %{
        header: "session-id",
        derived_from: "prompt_cache_key",
        derivation: "uuid_v5_fixed_pooler_namespace_over_pool_id_api_key_id_and_raw_key",
        scope: "authenticated_pool_and_api_key",
        key_contract: "non_empty_string_max_512_bytes",
        routes: [
          %{method: :post, path: "/v1/responses"},
          %{method: :post, path: "/v1/chat/completions"}
        ],
        client_session_id_header: "local_only_never_forwarded",
        local_session: "none_bridge_eligibility_stays_fail_closed",
        client_key_contract: "shared_key_within_one_api_key_shares_one_provider_session_id_never_across_api_keys_or_pools",
        privacy: "derived_value_not_persisted_or_logged"
      },
      pinned_continuation_reauth: %{
        routes: [
          %{method: :post, path: "/v1/responses"},
          %{method: :get, path: "/v1/responses", transport: "websocket"}
        ],
        status: 503,
        error_code: "pinned_continuation_reauth_required",
        recovery_kind: "restart_with_full_context",
        anchor_removal: %{
          body: ["previous_response_id"],
          headers: [
            "x-codex-previous-response-id",
            "x-codex-turn-state",
            "x-codex-window-id",
            "x-codex-session-id",
            "session-id",
            "x-session-id",
            "x-session-affinity",
            "session_id",
            "x-codex-conversation-id"
          ]
        }
      },
      pinned_continuation_unavailable: %{
        routes: [
          %{method: :post, path: "/v1/responses"},
          %{method: :get, path: "/v1/responses", transport: "websocket"}
        ],
        status: 503,
        error_code: "pinned_continuation_unavailable",
        recovery_kind: "restart_with_full_context",
        examples: ["quota_exhausted", "assignment_unavailable", "identity_unavailable"],
        hard_pin_fallback: false,
        soft_pin_fallback: true,
        anchor_removal: %{
          body: ["previous_response_id"],
          headers: [
            "x-codex-previous-response-id",
            "x-codex-turn-state",
            "x-codex-window-id",
            "x-codex-session-id",
            "session-id",
            "x-session-id",
            "x-session-affinity",
            "session_id",
            "x-codex-conversation-id"
          ]
        }
      },
      timeout_contract: %{
        route_specific_defaults_added: false,
        progress_receive_timeout_ms: 250,
        progress_interval_ms: 100,
        idle_receive_timeout_ms: 150,
        idle_silent_gap_min_ms: 250,
        idle_error_code: "stream_idle_timeout"
      },
      unsupported_realtime_routes: [
        %{method: :get, path: "/v1/realtime"},
        %{method: :post, path: "/v1/realtime"}
      ],
      error_shape: %{
        "error" => %{
          "message" => "synthetic fixture error",
          "type" => "invalid_request_error",
          "code" => "unsupported_parameter",
          "param" => "logprobs"
        }
      }
    },
    upstream_websocket_bridge: %{
      downstream_transport: "http_sse",
      upstream_transport: "websocket",
      eligibility: %{
        route: "public_v1_responses_stream",
        owner_forwarding: "required",
        websocket_writer: "absent",
        session: "unpinned_or_selected_assignment"
      },
      owner_retention: %{
        setting: "websocket_owner_idle_timeout_ms",
        default_ms: 1_800_000,
        min_ms: 60_000,
        max_ms: 3_600_000,
        starts_after: "final_downstream_detach_without_active_turn",
        capture: "node_local_at_new_or_recovered_owner_start",
        existing_owner_update: "retains_captured_value",
        previous_release_default_ms: 300_000
      },
      fallback: %{
        boundary: "first_downstream_visible_public_event",
        precommit_buffer_event_types: [
          "response.created",
          "response.in_progress",
          "response.queued",
          "codex.rate_limits"
        ],
        unknown_typed_event: :commit,
        legacy_typeless_success: :completed_preserve_raw,
        backend_done_event: :preserve,
        public_http_done_event: :response_completed,
        public_websocket_done_event: :response_completed,
        synthetic_missing_terminal_surfaces: ["public_post_http_sse"],
        target: "websocket_failure_without_resubmission",
        settlements: 1,
        upstream_committed: "no_http_fallback_or_automatic_replay",
        post_visible_upstream_death: "failed_request",
        cache_locality: "heuristic_never_guarantee"
      },
      terminal_delivery: %{
        barrier: "private_owner_terminal_delivery",
        terminal_classes: ["completed", "failed", "incomplete", "error"],
        settlement: "after_terminal_send_success",
        timeout_ms: 1_000,
        timeout_reason: "upstream_websocket_terminal_delivery_timeout",
        timeout_phase: "terminal_delivery",
        timeout_state: %{
          upstream_committed: true,
          terminal_seen: true,
          terminal_forwarded: false
        },
        invalidation_scope: "current_physical_connection_only",
        settlements: 1
      },
      metadata_handoff: %{
        operation: "atomic_one_shot_take",
        clears_after_take: true,
        second_take: %{upstream_websocket_connection: nil, transport_failure: nil},
        upstream_websocket_connection_fields: [
          "lifecycle_id",
          "generation",
          "reused",
          "reconnected"
        ],
        transport_failure_fields: [
          "exception",
          "reason_class",
          "reason",
          "phase",
          "pre_visible_output",
          "upstream_committed",
          "terminal_seen",
          "terminal_forwarded",
          "text_frame_count",
          "peer_close_code",
          "peer_close_reason_present",
          "peer_close_reason_bytes"
        ],
        upstream_committed: "monotonic_true",
        raw_frames_or_payloads: false
      },
      recovery: %{
        failed_turn_automatic_replay: false,
        next_explicit_turn: "same_lifecycle_generation_plus_one",
        next_explicit_turn_reconnected: true,
        later_healthy_turn: "reuse_reconnected_generation"
      },
      health: %{
        terminal_delivery_timeout: "pooler_local_health_neutral",
        assignment_health_changed: false,
        quota_eligibility_changed: false,
        circuit_counters_changed: false
      },
      multi_node_owner: %{
        authority: "persisted_owner_lease",
        proxy_behavior: "forward_to_current_owner",
        fenced_messages: [
          "stale_epoch",
          "stale_lease_token",
          "delayed_remote_completion",
          "drained_owner"
        ],
        lease_transfer: "single_replacement_owner",
        takeover: "new_owner_lifecycle",
        physical_connection_invalidation: "same_owner_lifecycle_next_generation"
      },
      accounting: %{
        request_transport: "http_sse",
        attempt_transport: "websocket",
        attempt_metadata: ["upstream_websocket_bridge", "upstream_transport"],
        payload_compression_subject: "websocket_envelope",
        upstream_websocket_connection: %{
          projection: "admin_attempt_detail_only",
          exact_fields: ["lifecycle_id", "generation", "reused", "reconnected"],
          lifecycle_id: "canonical_uuid_per_upstream_websocket_session_lifecycle",
          generation: "positive_successful_connection_ordinal_within_lifecycle",
          reused: "request_started_on_already_established_connection",
          reconnected: "request_retried_on_new_connection_after_pre_response_reuse_failure",
          omitted_for: [
            "malformed_metadata",
            "previous_release_owner",
            "http_fallback",
            "request_list",
            "mcp"
          ]
        }
      },
      crash_hygiene: %{
        submit_task: "catch_all_scrubbed_atom_reasons",
        payload_in_crash_logs: false,
        authorization_in_crash_logs: false,
        format_status: "bounded_lifecycle_and_boolean_projection",
        opaque_transient_inspection: true
      },
      rolling_deploy: %{
        native_attach_arity: 2,
        bridge_attach_arity: 3,
        old_owner_native_attach: "compatible_without_connection_metadata",
        old_owner_bridge_attach: "fail_closed_without_resubmission",
        owner_submission: %{
          protocol: "versioned_data_only",
          callback_construction: "owner_node_only",
          incompatible_remote_owner: "reject_before_owner_lookup_or_upstream_submission",
          native_result: "existing_owner_unavailable_error",
          previsible_bridge_result: "fail_closed_without_resubmission"
        },
        operator_action: "none"
      }
    },
    misalignment_policy_violation: %{
      code: "misalignment_policy_violation",
      eligibility: %{
        immediate_pre_stream_http_json: %{
          routes: ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"],
          statuses: [400, 403],
          exact_error_code: "misalignment_policy_violation",
          stream_true_rejected_before_sse_starts: true,
          optional_fields: ["error_type", "detailed_explanation", "steer.message"]
        },
        private_native_app_server_response_failed_sse: %{
          routes: ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"],
          statuses: [400, 403],
          exact_error_code: "misalignment_policy_violation",
          stream_true: true,
          terminal_event: "response.failed",
          optional_fields: ["error_type", "detailed_explanation", "steer.message"]
        }
      },
      lifecycle: %{
        retryable: false,
        health_neutral: true,
        demotion: false,
        circuit_failure: false,
        settlement: "exactly_once"
      },
      public_error: %{
        code: "misalignment_policy_violation",
        type: "invalid_request_error",
        message: "nonblank_provider_message_or_fixed_safe_fallback",
        provider_param: false,
        provider_body: false,
        provider_siblings: false
      },
      durable_metadata: %{
        exact_code: true,
        accounting_message: "fixed",
        bounded_facts_only: true,
        raw_provider_message: false,
        raw_provider_body: false
      },
      redaction: %{
        native_websocket: false,
        native_compact: false,
        public_v1_responses_chat_sse_websocket: false,
        generic_errors: false,
        logs: false,
        request_or_attempt_metadata: false,
        audit: false,
        telemetry: false,
        receipts: false,
        stored_errors: false,
        durable_event_history: false
      },
      generic_provider_errors: %{
        message: "upstream request failed",
        type: "server_error",
        unchanged: true
      }
    },
    image_generation_permission: %{
      pool_gate: %{
        setting: "allow_image_generation",
        default_enabled: true,
        disabled_behavior: "403_image_generation_disabled"
      },
      controller_actions: [
        %{
          action: :image_generations,
          controller: :backend_codex,
          image_generation_permission_required?: true
        },
        %{
          action: :image_edits,
          controller: :backend_codex,
          image_generation_permission_required?: true
        },
        %{
          action: :generations,
          controller: :v1_images,
          image_generation_permission_required?: true
        },
        %{
          action: :edits,
          controller: :v1_images,
          image_generation_permission_required?: true
        }
      ],
      authoritative_gateway: :runtime_ingress,
      enforcement: %{
        after: :runtime_authentication,
        before: [:request_parsing, :upstream_dispatch, :body_decompression]
      }
    },
    v1_unsupported_public_surface: %{
      routes: [
        %{method: :post, path: "/v1/images/variations"},
        %{method: :post, path: "/v1/content_provenance_checks"},
        %{method: :post, path: "/v1/embeddings"},
        %{method: :post, path: "/v1/batches"},
        %{method: :post, path: "/v1/moderations"},
        %{method: :post, path: "/v1/fine_tuning/jobs"},
        %{method: :get, path: "/v1/responses/resp_fixture"},
        %{method: :post, path: "/v1/responses/resp_fixture/cancel"},
        %{method: :delete, path: "/v1/responses/resp_fixture"}
      ],
      status: 404,
      error_code: "unsupported_endpoint"
    }
  }

  def features, do: @features

  def feature_slugs, do: Enum.map(@features, & &1.slug)

  def by_slug!(slug) do
    Enum.find(@features, &(&1.slug == slug)) || raise ArgumentError, "unknown feature #{slug}"
  end

  def pending_gaps do
    Enum.filter(@features, &(&1.status == :gap))
  end

  def required_categories, do: @required_categories

  def fixtures, do: @fixtures

  def fixture!(name), do: Map.fetch!(@fixtures, name)
end
