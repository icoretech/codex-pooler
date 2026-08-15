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
      contract:
        "backend file routes use JSON SAS create and finalize, return upstream file_id plus upload_url, reject OpenAI /v1/files multipart semantics, and store metadata only"
    },
    %{
      slug: :backend_transcription,
      status: :supported,
      current: :fixed_backend_transcription_model,
      categories: [:route, :auth, :multipart, :ownership],
      routes: [%{method: :post, path: "/backend-api/transcribe"}],
      future_routes: [],
      fixture: :backend_transcription,
      contract:
        "backend transcription should force the backend transcription model and preserve safe multipart fields"
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
      contract:
        "backend image generation and edit routes are explicit authenticated JSON proxy routes under /backend-api/codex/images; on either exact native route, any policy-authorized effective image model genuinely absent from the Pool catalog may use eligible visible host capacity while preserving that effective identifier exactly, but catalog-present invisible targets remain invalid; image-specific prompt and source fields stay intact, and the native routes remain distinct from the public /v1 image translator surface"
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
        identity: "canonical_source_digest_after_provenance_and_presentation_hint_removal",
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
        selection: "oldest_partition_with_quota_routable_member",
        selection_fallback: "oldest_partition_when_none_routable",
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
      contract:
        "backend model aliases return the same policy-visible effective catalog body and deterministic weak ETag from the canonical pristine-source partition selected as the oldest partition, by minimum created_at plus assignment id, that still holds a quota-routable member, falling back to the oldest partition when none is routable, so the catalog body and ETag can change when the anchor partition flips; shell_type values default, local, shell_command, and unified_exec are equivalent for partitioning, disabled is separate, and unknown, missing, or malformed values do not silently collapse, while the selected anchor's raw shell_type remains served; quota routing reads one shared candidate-identity snapshot and classifies it independently per model; API-key policy decides admission and projection only after canonical selection and never chooses or rewrites the partition; backend Codex catalog-driven new turns use the selected partition, while translated OpenAI Responses capacity includes all valid canonical assignments after concrete request compatibility; valid canonical hard pins may continue on their pinned partition; selected-partition exhaustion and malformed-source hard pins fail before accounting or upstream work; cache coherence across processes or replicas is eventual after a successful Responses token is observed"
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
      contract:
        "backend Responses HTTP SSE response headers expose x-models-etag equal byte-for-byte to the exact authenticated backend models ETag from the request snapshot; websocket upgrade headers retain the same backward-compatible connection-opening value, while each accepted backend websocket turn emits an authoritative codex.response.metadata x-models-etag from that turn's current predispatch snapshot; the value is never relayed from upstream and is excluded from backend JSON, compact, public /v1, usage, unauthenticated, and unrelated routes"
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
      contract:
        "Auto, Lite, and Full belong to one Pool-model pair while clients keep one exposed model id and their existing Pool API key and configuration. Auto is the recommended literal-true catalog decision; a resolved mode is immutable for one HTTP request or websocket response.create turn across retry, failover, and owner forwarding. Backend catalog ETags, compact transformation, and bounded accounting metadata follow that snapshot. Public /v1/models, unsupported public compact, assignment eligibility, and Helm/environment configuration remain unchanged. Full is an advanced ordinary Responses override: a generic terminal HTTP failure returns one fixed server-owned error without provider fields, a non-rate-limit 4xx records the operator-visible full_upstream_rejection diagnostic without raw upstream text, a 429 records upstream_rate_limited, an ordinary 5xx remains upstream_status, and Pooler never silently downgrades. Auto, Lite, compact or unrelated routes, and established model-miss responses remain unchanged."
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
      contract:
        "the final noncompact backend Responses envelope always has a reasoning map and exactly one reasoning.encrypted_content include after selected summary-capability normalization across backend, backend-alias, and translated public Responses surfaces; compact routes remain excluded and preserve their existing narrow shape"
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
      contract:
        "upstream_error_param is a bounded allowlisted field-path value projected on failed-attempt detail only; invalid values and successful attempts are omitted, with never raw upstream error messages or values projected"
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
      contract:
        "non-429 HTTP 4xx rejection metadata is extracted from a bounded private streaming drain or the bounded materialized body, projected only on failed-attempt detail, and publishes bounded code, type, param, message-presence, and message-byte facts without raw provider bodies or messages"
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
      contract:
        "backend Responses HTTP and websocket routes canonicalize binary client or enforced service_tier fast to upstream priority, compare advertised fast and priority as equivalent without rewriting catalog metadata, preserve every other backend tier value or type, and relay provider bytes, frames, and service-tier vocabulary unchanged"
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
      programmatic_tool_calling_contract:
        "closed-world Responses programmatic-tool calling rejects remote MCP and unrelated hosted tools and makes no full OpenAI parity claim",
      contract:
        "Responses and chat completions proxy JSON/SSE through the shared gateway accounting path; chat completions use messages when present and fall back to top-level input only when messages is absent or empty, with omitted fallback instructions defaulting to a blank string; /v1/responses and translated /v1/chat/completions accept client service_tier fast as canonical upstream priority while retaining existing invalid-tier rejection, preserve literal provider service_tier output, and include a Chat stream tier only on chunks emitted after observation without buffering or rewriting earlier chunks; translated Chat custom definitions and named choices use the official nested wrapper, flatten into the supported Responses subset, and restore completed or streamed custom calls without parsing free-form input as JSON; /v1/responses and translated /v1/chat/completions accept prompt_cache_options and supported content-part prompt_cache_breakpoint controls as public input, while account-backed egress omits both explicit controls and preserves prompt_cache_key; Pool affinity remains exclusively keyed by prompt_cache_key; request-shaped additional_tools input items are preserved as non-executable input, never merged into executable tools, and never used to satisfy tool_choice; OpenAI Responses remote MCP tool definitions are rejected before upstream dispatch in both top-level tools and nested additional_tools.tools locations; Responses namespace tool definitions are accepted only for non-empty namespace name/description values and exact flat function or executable custom namespace children; Responses truncation accepts auto and disabled locally but is not forwarded upstream; terminal compaction_trigger backend payloads on either backend Responses alias retain the final trigger, dispatch buffered JSON to /backend-api/codex/responses with compact accounting on /backend-api/codex/responses/compact, strip transient stream/include/store/prompt_cache_options fields, and adapt the compact result to backend Responses SSE; the response adaptation preserves only schema-backed string replay identity and drops other compact-result fields; direct compact aliases preserve their canonical legacy /backend-api/codex/responses/compact upstream route; malformed trigger placement is rejected before dispatch; public /v1/responses HTTP and Responses websocket turns accept exactly one final compaction_trigger after visible input, dispatch it through the same buffered compact bridge with compact accounting and ordinary backend Responses upstream routing, and adapt the result as public Responses JSON, SSE, or websocket events; public /v1/responses/compact remains unsupported and public /v1 Responses accepts encrypted compaction output replay items from prior remote compaction turns; backend regular HTTP Responses and compact routes forward approved metadata headers, including request-scoped x-codex-turn-state, x-codex-window-id, and x-codex-installation-id, and relay upstream x-codex-turn-state response headers downstream, while public /v1 and websocket request-header lanes do not; context-overflow recovery stays client/upstream-owned with no server-side hidden replay, no server-side memory tool injection, no client store=false-to-true override policy, and no stored prompt/frame reconstruction; Hermes assistant replay may include safe assistant status metadata; OpenClaw assistant replay drops thinking metadata and normalizes text before upstream dispatch; public /v1/responses and /v1/chat/completions accept exactly five lowercase input_audio labels (wav=>audio/wav, mp3=>audio/mpeg, m4a=>audio/mp4, webm=>audio/webm, ogg=>audio/ogg), apply a 52,428,800 decoded-byte maximum and a 69,905,068 non-whitespace encoded-byte precheck, canonicalize backend input_audio to an audio_url data URL after accepted ASCII whitespace normalization, reject malformed/empty/unsupported/oversized input as sanitized invalid_request without dispatch or accounting, honor configured request-envelope rejection before adapter checks, and keep audio metadata-only outside dispatch; safe OpenAI Responses fields, prompt-cache locality, SDK-control rejection, and backend-only control stripping stay scope-specific"
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
      contract:
        "non-streaming upstream HTTP response bodies are collected through a bounded reader, fail closed as upstream_response_too_large when the content-length or streamed bytes exceed the limit, do not retain oversized body bytes in client responses, request logs, attempt metadata, docs, or admin evidence, and leave streaming routes on their existing stream-buffer guards"
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
      contract:
        "backend /backend-api/codex/v1 aliases are explicit authenticated backend routes for models, responses, websocket responses, compact, and chat completions, preserve generic backend API-key auth, proxy to the canonical backend gateway paths, allow prompt-cache routing locality only on POST responses and chat completions aliases, keep the chat alias fallback limited to top-level input only when messages is absent or empty, and the translated chat alias emits the nested server_error terminal after visible output when the upstream stream ends without a terminal"
    },
    %{
      slug: :websocket_continuity,
      status: :supported,
      current: :persisted_session_turns,
      categories: [:route, :auth, :streaming, :ownership, :degraded],
      routes: [%{method: :get, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :websocket_turn,
      contract:
        "backend websocket continuity persists sessions and turns with sticky routing affinity, uses response.create.client_metadata x-codex-turn-state as per-frame request-scoped turn state with the upgrade/header value only as fallback, and is excluded from prompt-cache routing locality; an unresolved previous-response alias retains the current authenticated runtime and emits no owner-outage error; successful native turns register hashed previous-response aliases independent of retained-body completeness; a native websocket continuation marked from its final upstream payload may use only its reused upstream connection, while a fresh or reconnected connection emits the exact previous_response_not_found client retry signal before upstream payload send so only a later explicit full request may use that replacement connection; a mid-stream upstream death after visible output authors exactly one native type:error frame with status 502, wire code upstream_request_failed, and the pinned message upstream request failed, carrying no terminal event, no sequence_number, and no socket close so the same socket serves later turns; every frame authored through the shared websocket error envelope carries error type invalid_request_error, defaulting independently to status 500 when its reason has no status and to wire code websocket_request_failed when its reason has no code and message; public /v1 terminal masking and shape remain unchanged"
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
      contract: "none reasoning is accepted and forwarded unchanged before upstream dispatch"
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
      contract:
        "client-facing ultra reasoning is accepted and rewritten to backend-compatible max before backend Codex regular and compact upstream dispatch"
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
      contract:
        "API keys derive unrestricted, allow_up_to, or always_use reasoning policy from their configured fields. Unrestricted preserves omission and current accepted explicit values. Allow_up_to accepts known values through its ceiling and the selected model's effective known levels, resolves omission from the permitted default or highest permitted known value, and rejects above-ceiling, unknown, custom, or empty-intersection requests before reservation or upstream work without clamping. Always_use preserves legacy exact enforcement regardless of metadata membership. Denials are status 400 reasoning_effort_not_allowed with message reasoning effort is not available for this API key and param reasoning.effort for Responses/backend/compact or reasoning_effort for Chat; model_not_allowed remains the prior status 403 decision. Upgraded response.create frames receive the same existing error frame after upgrade, not an upgrade rejection. Backend model metadata is filtered by policy while models remain visible, and public /v1/models remains unchanged. minimal and ultra are evaluated before their backend low and max rewrites."
    },
    %{
      slug: :reasoning_context,
      status: :supported,
      current: :openai_sdk_literal_normalization,
      categories: [:route, :auth, :error, :ownership],
      routes: [%{method: :post, path: "/v1/responses"}],
      future_routes: [],
      fixture: :reasoning_context,
      contract:
        "OpenAI Responses reasoning.context accepts SDK literals auto, current_turn, and all_turns after trimming and lowercasing, forwards accepted values through the Responses adapter, and rejects unknown or non-string context values before upstream dispatch"
    },
    %{
      slug: :unsupported_upstream_fields,
      status: :supported,
      current: :rejected_or_stripped_by_scope,
      categories: [:route, :auth, :ownership],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :unsupported_upstream_fields,
      contract:
        "OpenAI compatibility rejects known SDK request controls that cannot be translated locally and strips backend-only upstream-unsupported controls before dispatch"
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
      contract:
        "firewall checks are path-gated to runtime compatibility routes, use one explicit forwarded-client source with x_forwarded_for/depth 0 defaults, require a trusted immediate peer before any selected forwarding header, resolve duplicate XFF fields in wire order, fail cold settings with 503 while warm nodes keep last-known-good enforcement, revoke already-open websocket clients after local policy application without admitting new work, and expose one bounded denial counter with only scope and reason labels"
    },
    %{
      slug: :pruned_runtime_helper_firewall,
      status: :supported,
      current: :firewall_before_fixed_absence,
      categories: [:route, :error],
      routes: [],
      future_routes: [],
      fixture: :pruned_runtime_helper_firewall,
      contract:
        "pruned runtime helper routes enforce runtime settings availability and firewall policy before preserving their fixed unauthenticated HTML 404 response, without body parsing, upstream dispatch, reservation, or accounting side effects"
    },
    %{
      slug: :decompression,
      status: :supported,
      current: :bounded_compressed_json,
      categories: [:route, :error, :overload],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :compressed_request,
      contract:
        "request decompression accepts bounded gzip, deflate, and zstd JSON while compressed multipart stays unsupported"
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
      contract:
        "bulkheads isolate HTTP proxy, websocket, compact, media, file, and operator lanes"
    },
    %{
      slug: :degraded_routing,
      status: :supported,
      current: :bridge_ring_fallback,
      categories: [:route, :error, :ownership, :degraded],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :degraded_routing,
      contract:
        "degraded routing demotes failed bridge candidates and records sanitized routing metadata"
    },
    %{
      slug: :strict_schema_validation,
      status: :supported,
      current: :pre_reservation_rejection,
      categories: [:route, :auth, :error, :ownership],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :strict_schema_rejection,
      contract:
        "strict structured-output schemas are validated before reservation or upstream dispatch"
    },
    %{
      slug: :unsupported_input_image_reference,
      status: :supported,
      current: :pre_reservation_rejection,
      categories: [:route, :auth, :error, :ownership],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :unsupported_input_image_reference,
      contract:
        "Responses input_image.file_id, Codex sediment:// file URIs, and unsupported URL schemes such as http:// and file:// used as input_image.image_url values are rejected before reservation or upstream dispatch"
    },
    %{
      slug: :first_event_stream_retry,
      status: :supported,
      current: :pre_first_event_retry,
      categories: [:route, :auth, :error, :streaming, :ownership, :degraded],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :first_event_stream_retry,
      contract:
        "transient SSE failures may retry only before the client sees output, message, tool, or delta events"
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
      contract:
        "Request compression is Pool-gated by request_compression_enabled, request-side only, fail-open to the original upstream request when scanning, token counting, rewriting, or limits fail, and metadata-only through safe payload_compression request-log metadata; eligible routes are backend Responses, backend /v1 Responses/chat aliases, public /v1 Responses/chat translations, backend compact routes, and backend or narrow public websocket response.create dispatches; protected exact-output function tool outputs for Read, Glob, Grep, Write, Edit, WebSearch, WebFetch, web_search, web_fetch, and external retrieval are skipped before rewriting with aggregate-only skip counts; output-only function tool results fail closed as protected when their tool name is unavailable; search-result compression covers classic path-line matches, grouped heading matches, and portable NUL-delimited matches, diff compression covers hunk-based additions-only, deletions-only, replacement, minimal unified diffs, combined unified diffs, and long-preamble diffs, log-output compression preserves every failure block when a summary reports failure/error counts, and valid JSON object or array spans embedded in ordinary prose are minified losslessly while surrounding bytes, quoted JSON-looking text, malformed spans, and over-limit span sets remain unchanged; ordinary prose without eligible embedded JSON remains outside diff/search/log compression shapes; public /v1/responses/compact remains unsupported with no upstream compact dispatch or compression eligibility"
    },
    %{
      slug: :upstream_websocket_bridge,
      status: :supported,
      current: :owner_websocket_cache_bridge,
      categories: [:route, :auth, :error, :streaming, :ownership, :degraded],
      routes: [%{method: :post, path: "/v1/responses"}],
      future_routes: [],
      fixture: :upstream_websocket_bridge,
      contract:
        "the upstream websocket bridge applies only to public /v1/responses streaming turns with websocket owner forwarding enabled, no attached websocket writer, and a continuity session that is unpinned or pinned to the selected assignment; the downstream contract stays HTTP SSE while the turn dispatches over the session's owner websocket as a cache-locality heuristic, never a cache guarantee; the bridge commits on the first client-rendered content event, on any unknown event fail-closed, on any structurally valid terminal, or at its bounded pre-content buffer caps and commit deadline, buffering lifecycle envelopes, item and part adds, and internal codex.* events until then; a pre-content peer-initiated websocket death — a close without terminal, a TCP cut, or a peer Close frame — falls back to plain HTTP dispatch on the same candidate and attempt with a single settlement, while pre-content locally-declared receive or pong timeouts fail once without HTTP fallback; a private owner barrier delays settlement of a terminal-bearing result until its terminal frame is delivered, and a committed terminal-delivery timeout fails once without HTTP fallback or automatic replay; timeout diagnostics move through one atomic one-shot metadata handoff and remain health-neutral; invalidation preserves the owner lifecycle, so the next explicit turn reconnects at generation plus one and a later healthy turn reuses that generation; persisted leases provide two-node owner forwarding, fencing, transfer, and takeover; after visible output an upstream death finalizes the request as failed instead of synthesizing an empty success; websocket_owner_idle_timeout_ms controls post-detach owner retention with a 1_800_000 ms default and 60_000..3_600_000 ms bounds, is captured node-locally by each new or recovered owner, and does not change existing owners; the attempt-only upstream_websocket_connection namespace contains exactly lifecycle_id, generation, reused, and reconnected; the attempt records transport websocket plus upstream_websocket_bridge and upstream_transport metadata while the request keeps the downstream http_sse transport, and payload_compression metadata describes the websocket envelope actually sent; the submit task surfaces owner failures as scrubbed atom reasons without copying payload or authorization into crash logs; option-carrying bridge attaches fail closed to HTTP fallback against owner nodes still running the previous release while option-less native attaches keep the two-argument remote shape and previous-release owners retain legacy five-minute behavior without connection metadata"
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
      contract:
        "image generation and edits are Pool-gated by allow_image_generation (default on) after runtime authentication and before request parsing or upstream dispatch; disabled Pools receive a deterministic 403 image_generation_disabled error"
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
      contract:
        "direct public Responses HTTP and websocket response.create accept executable custom tools with an exact nonblank name, optional description and defer_loading, nullable direct/programmatic allowed_callers, and omitted, text, lark-grammar, or regex-grammar input format; the same exact custom definition is accepted as a child of a nonblank namespace with a nonempty tool list alongside exact flat function children; translated Chat Completions accepts the official nested custom definition with nonblank name and optional description or format plus the official nested named custom choice, flattens both into the Responses request, and projects completed JSON and streamed custom_tool_call input back into the Chat custom shape without parsing free-form input as JSON; an exact typed custom choice resolves only a declared custom tool of the same name and kind, including a namespace child, is preserved in Full mode, and is rejected before upstream dispatch in Lite mode with unsupported_parameter for tool_choice; that Lite rejection is serving-mode driven and covers any map-shaped tool_choice on any lane dispatching to backend Responses, including translated Chat choices, while string choices such as auto remain accepted in both modes; executable names are collision-free across flat functions, namespace children, and custom tools; malformed and unrelated tool families remain rejected, custom replay is a separate input-item contract, provider execution availability depends on the selected model and upstream account, and no broad OpenAI tool parity is claimed"
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
      contract:
        "backend Codex websocket response.create preserves canonical encrypted agent v2 NEW_TASK and MESSAGE handoffs only when the item contains exactly one input_text protocol envelope followed by one nonempty encrypted_content part, author and recipient are /morpheus or /root paths with lowercase-letter, digit, or underscore child segments, and the envelope task name and sender exactly match recipient and author; other encrypted agent_message variants remain filtered, assistant encrypted replay remains preserved, and durable request or attempt metadata never stores the encrypted payload"
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
      contract:
        "pinned Codex source certification uses distinct source-valid Full-mode lanes: gpt-5.5 resolves v1 through feature fallback, while gpt-5.6-terra resolves v2 through the explicit feature override and is also the direct-control model; preflight requires an authenticated Full catalog snapshot and absent HTTP and websocket Lite markers; live-text and DoneClaim verdicts remain staged, opaque v2 encrypted arguments are classified as instruction_observation_missing when no permitted resolved-instruction source exists, and the native Pooler websocket writer preserves a structural child output_text delta byte-for-byte without a production transport change"
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
      contract:
        "backend Responses HTTP and websocket response.create lower and remove encrypted markers only for ordinary top-level non-strict function tool schemas while preserving every decoded top-level namespace tool term exactly; public /v1 Responses HTTP and websocket recursively lower nested namespace function tools before local validation or upstream dispatch; lowering converts boolean schemas and const values into supported schema shapes, infers missing object or array structure, drops unsupported JSON Schema keywords, preserves supported refs/definitions/combinators recursively, and never weakens strict function tools or strict structured-output schemas"
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
      contract:
        "direct public Responses HTTP and websocket response.create may repair only a missing nested object or array type in top-level strict flat-function parameters or strict flat-function children of accepted namespaces when structural evidence is complete and unambiguous; the parameters root, explicit type values, refs, definition tables, combinators and their descendants, annotations, unknown keywords, ambiguous or incomplete evidence, strict structured outputs, Chat, the older nested function wrapper shape, and backend routes are not repaired; public Responses and Chat reject malformed, duplicate, or unsupported explicit type values globally before generic strict validation; strict function tools and strict structured-output schemas remain excluded from non-strict lowering"
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
        "Audio transcription accepts gpt-transcribe only as a caller alias for canonical gpt-4o-transcribe, accepts decoded keywords and languages as ordered non-empty string lists with duplicates preserved, omits empty lists, forwards exact repeated keywords[] and languages[] names, rejects malformed lists by field, removes detected languages from public output, stores no raw audio or decoded list values after auth-before-multipart, and makes no alias catalog, model-discovery, detected-language-output, or full OpenAI Audio parity claim; " <>
          "OpenAI-compatible /v1 routes are default-on for pools, require bearer API-key auth, return OpenAI-shaped errors without anonymous local or CIDR bypasses, include narrow GET /v1/responses Responses websocket compatibility only, exclude broad /v1/realtime routes, keep POST /v1/responses/compact routed only to deterministic unsupported_endpoint with no upstream compact dispatch, reject OpenAI Responses remote MCP tool definitions before upstream dispatch in both top-level tools and nested additional_tools.tools locations with OpenAI-shaped invalid_request errors, consume continuity headers using the documented local precedence without forwarding session-id, x-session-id, or x-session-affinity upstream, fail closed for pinned /v1/responses continuations whose upstream account needs revoked-refresh-token reauthentication with the shared restart_with_full_context recovery guidance, allow prompt-cache routing locality only on POST responses and chat completions, accept Codex-native Responses web_search hosted tool shapes with boolean access flags while keeping web_search_preview type-only, accept Responses truncation auto and disabled locally without forwarding it upstream, lift Responses system/developer input-message text into top-level instructions, treat absent, blank, and whitespace-only public SSE event labels identically before event/data type precedence while rejecting nonblank mismatches, emit early public streaming terminal errors without synthetic success prefixes, emit a sanitized type:error terminal with wire code server_error while accounting records upstream_stream_error when POST /v1/responses SSE has already exposed public Responses data and an ordinary upstream interruption occurs before a Responses terminal event, cap ordinary incomplete public Responses SSE blocks at 8 MiB so single large provider events such as reasoning items with encrypted content can finish decoding while allowing structurally recognizable terminal candidates up to 64 MiB so split large terminals can finish decoding, and emit that same bounded local terminal immediately when the applicable cap is crossed while dropping the source block and later frames, accounting records owner_drained while the emitted wire frame is byte-identical to the ordinary synthetic terminal only when a committed websocket-bridge turn is aborted by rollout drain after its drain budget, keep precommit drain admission on its existing fallback or refusal path, keep client disconnect and non-drain interruption mappings unchanged, limit synthetic SSE terminals to OpenAI-compatible HTTP SSE surfaces, drop malformed and JSON non-object provider frames on direct and accepted owner-forwarded GET /v1/responses without advancing public websocket state, emit the existing websocket type:error envelope with status 502 and wire code server_error when an owner-forwarded GET /v1/responses per-call turn is interrupted after committed public output while accounting records upstream_stream_error, never synthesize that interruption for pre-visible owner-forwarded turns, preserve native backend raw Responses streams and all other websocket behavior, and preserve bridge complete-block behavior, redact server-class/internal/upstream public /v1 errors while preserving invalid_request_error validation details, preserve safe machine-readable codes for redacted public OpenAI-compatible Responses terminal failures in nested response.error through low-level public SSE normalization and the runtime streaming relay, keep top-level error code-aligned when Pooler emits one, map Responses content_filter/content-filter incomplete reasons to chat finish_reason content_filter while other incomplete reasons remain length, forward structured tool-result/function_call_output payloads unchanged, translate chat-style role=tool continuation messages and Hermes assistant tool-call replays into Responses function_call/function_call_output input items before validation, accept safe Hermes assistant replay status values, drop known OMP function_call replay status fields before validation, translate OpenClaw assistant thinking replays before validation, accept narrow Codex custom tool replay with custom_tool_call.namespace preservation and matching custom_tool_call_output, accept executable custom definitions directly on Responses and through the official translated Chat wrapper, and keep chat input fallback, Responses additional_tools support narrow and non-executable, and Responses namespace-tool support narrow. For genuine upstream Responses terminal failures, the public `/v1` surface constructs a named-field `response.failed` projection, excludes unknown event, response, error, and usage siblings, validates the response id, projects bounded usage counters, and empties or nulls content-bearing response fields. It preserves a trimmed upstream error code only when it is at most 80 bytes and matches `^[A-Za-z0-9_.-]+$`, redacts every other code value to `upstream_error`, replaces upstream message text with `upstream request failed`, and upstream type text — including clean values — is replaced with `server_error`. Top-level and nested errors are sanitized independently without copying either location to the other, and clients must treat `error.code` as an open string."
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
      contract:
        "unsupported OpenAI public routes are explicitly routed only to return deterministic OpenAI-shaped 404 errors before gateway admission or upstream dispatch"
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
      digest_input: "policy_visible_effective_catalog_body",
      digest: "sha256_deterministic_canonical_json",
      format: "weak_cp_models_v1",
      aliases_share_exact_body_and_token: true,
      cache_coherence: "eventual_after_successful_responses_token"
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
        owner_forwarding: :preserve,
        next_websocket_turn: :reresolve
      },
      upstream_etag_relay: false,
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
        error_code: "full_upstream_rejection",
        applies_to: :explicit_full_ordinary_responses_http_non_rate_limit_4xx_rejection,
        rate_limit_error_code: "upstream_rate_limited",
        ordinary_5xx_error_code: "upstream_status",
        upstream_status_retained: true,
        client_error: %{
          "code" => "server_error",
          "message" => "upstream request failed",
          "type" => "server_error"
        },
        provider_fields_forwarded: false,
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
    rejection_metadata: %{
      fields: [
        "rejection_error_code",
        "rejection_error_type",
        "rejection_error_param",
        "rejection_message_present",
        "rejection_message_bytes"
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
            optional_nullable_nonblank_string_metadata: ["name", "namespace"],
            null_or_omitted: true,
            invalid_metadata: ["blank_string", "non_string"],
            legacy_result_branch: true,
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
          strips: ["stream", "include", "store", "prompt_cache_options"],
          response_adaptation: %{
            upstream: "buffered_responses_json",
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
            "encrypted_content" => "encrypted_content",
            "id" => "compaction_item_id",
            "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn_id"}
          },
          output_item_policy: %{
            required: ["type", "encrypted_content"],
            optional_string: ["id", "internal_chat_message_metadata_passthrough.turn_id"],
            unknown_fields: "dropped",
            terminal_events_share_identical_item: true
          },
          websocket_bridge: false,
          hidden_replay: false,
          direct_compact_preservation: %{
            client_routes: [
              "/backend-api/codex/responses/compact",
              "/backend-api/codex/v1/responses/compact"
            ],
            upstream_endpoint: "/backend-api/codex/responses/compact",
            behavior: "legacy_compact_route_unchanged"
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
          transport: "http_compact_json",
          closed_item: %{"type" => "compaction_trigger"},
          valid_trigger: "exactly_one_final_after_visible_input",
          malformed_trigger: %{status: 400, param: "input", upstream_dispatch: false},
          retained: ["final_compaction_trigger"],
          strips: ["stream", "include", "store", "prompt_cache_options"],
          response_adaptation: %{
            upstream: "buffered_responses_json",
            downstream: %{
              http_json: ["response"],
              http_sse: ["response.output_item.done", "response.completed", "[DONE]"],
              responses_websocket: ["response.output_item.done", "response.completed"]
            }
          },
          public_compact_route_supported: false,
          hidden_replay: false
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
          "x-codex-installation-id",
          "x-openai-subagent"
        ],
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
    websocket_turn: %{
      headers: %{"x-codex-turn-state" => "fixture-upgrade-turn-state"},
      response_create_client_metadata: %{"x-codex-turn-state" => "fixture-frame-turn-state"},
      turn_state_precedence: "response.create.client_metadata_over_upgrade_header",
      privacy: "raw_value_not_persisted",
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
        }
      },
      json: %{"model" => "gpt-fixture-text", "input" => "synthetic websocket turn"}
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
    degraded_routing: %{json: %{"model" => "gpt-fixture-text", "input" => "synthetic fallback"}},
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
    unsupported_input_image_reference: %{
      accepted_url_schemes: ["https", "data:image"],
      unsupported_url_schemes: ["http", "sediment", "file"],
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
        task15_regression: "byte_exact_native_websocket_writer_pass_through",
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
        routing_hint: "trusted_native_effective_model_and_service_tier_only",
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
      audio_transcription: %{
        path: "/v1/audio/transcriptions",
        caller_models: ["gpt-4o-transcribe", "gpt-transcribe"],
        caller_aliases: %{"gpt-transcribe" => "gpt-4o-transcribe"},
        alias_scope: "caller_input_only",
        canonical_model: "gpt-4o-transcribe",
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
        safe_message:
          "upstream request failed: stream interrupted before terminal response event",
        post_budget_owner_drain: %{
          applies_to: "committed websocket bridge turn aborted after rollout drain budget",
          accounting_error_code: "owner_drained"
        },
        precommit_drain: "existing_fallback_or_refusal",
        client_disconnect: "unchanged",
        non_drain_interruptions: "byte_identical",
        backend_raw_streams: "unchanged",
        public_owner_forwarded_websocket_interruption: %{
          applies_to:
            "GET /v1/responses owner-forwarded per-call turns after committed public output",
          terminal_event: "error",
          status: 502,
          wire_error_code: "server_error",
          accounting_error_code: "upstream_stream_error",
          safe_message:
            "upstream request failed: stream interrupted before terminal response event"
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
        privacy:
          "transient_queue_and_active_socket_turn_only; excluded_from_persistence_accounting_logs_telemetry_metadata_and_owner_contracts",
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
      local_continuity_headers_not_forwarded: ["session-id", "x-session-id", "x-session-affinity"],
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
        target: "same_candidate_same_attempt_http",
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
        authorization_in_crash_logs: false
      },
      rolling_deploy: %{
        native_attach_arity: 2,
        bridge_attach_arity: 3,
        old_owner_native_attach: "compatible_without_connection_metadata",
        old_owner_bridge_attach: "fail_closed_http_fallback"
      }
    },
    misalignment_policy_violation: %{
      code: "misalignment_policy_violation",
      eligibility: %{
        direct_http_statuses: [400, 403],
        terminal_transports: ["sse", "websocket"],
        route_scope: "eligible_direct_or_translated_responses_and_chat_routes_only",
        exact_error_envelope: true
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
