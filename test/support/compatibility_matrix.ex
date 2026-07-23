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
      contract:
        "backend model aliases return the same policy-visible effective catalog body and deterministic weak ETag; cache coherence across processes or replicas is eventual after a successful Responses token is observed"
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
        "backend Responses HTTP SSE response headers and websocket upgrade headers expose x-models-etag equal byte-for-byte to the exact authenticated backend models ETag from the predispatch catalog snapshot; the value is never relayed from upstream and is excluded from backend JSON, compact, public /v1, usage, unauthenticated, and unrelated routes"
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
      contract:
        "Responses and chat completions proxy JSON/SSE through the shared gateway accounting path; chat completions use messages when present and fall back to top-level input only when messages is absent or empty, with omitted fallback instructions defaulting to a blank string; /v1/responses and translated /v1/chat/completions validate and preserve prompt_cache_options plus explicit supported content-part prompt_cache_breakpoint controls, while Pool affinity remains exclusively keyed by prompt_cache_key; request-shaped additional_tools input items are preserved as non-executable input, never merged into executable tools, and never used to satisfy tool_choice; OpenAI Responses remote MCP tool definitions are rejected before dispatch in both top-level tools and nested additional_tools.tools locations; Responses namespace tool definitions are accepted only for non-empty namespace name/description values and nested function tools; Responses truncation accepts auto and disabled locally but is not forwarded upstream; terminal compaction_trigger backend payloads bridge through /backend-api/codex/responses/compact with compact accounting and backend Responses SSE compaction output, while malformed trigger placement is rejected before dispatch; public /v1 Responses accepts encrypted compaction output replay items from prior remote compaction turns; backend regular HTTP Responses and compact routes forward approved metadata headers, including request-scoped x-codex-turn-state, x-codex-window-id, and x-codex-installation-id, and relay upstream x-codex-turn-state response headers downstream, while public /v1 and websocket request-header lanes do not; context-overflow recovery stays client/upstream-owned with no server-side hidden replay, no server-side memory tool injection, no client store=false-to-true override policy, and no stored prompt/frame reconstruction; Hermes assistant replay may include safe assistant status metadata; OpenClaw assistant replay drops thinking metadata and normalizes text before upstream dispatch; public /v1/responses and /v1/chat/completions accept exactly five lowercase input_audio labels (wav=>audio/wav, mp3=>audio/mpeg, m4a=>audio/mp4, webm=>audio/webm, ogg=>audio/ogg), apply a 52,428,800 decoded-byte maximum and a 69,905,068 non-whitespace encoded-byte precheck, canonicalize backend input_audio to an audio_url data URL after accepted ASCII whitespace normalization, reject malformed/empty/unsupported/oversized input as sanitized invalid_request without dispatch or accounting, honor configured request-envelope rejection before adapter checks, and keep audio metadata-only outside dispatch; safe OpenAI Responses fields, prompt-cache locality, SDK-control rejection, and backend-only control stripping stay scope-specific"
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
        "backend /backend-api/codex/v1 aliases are explicit authenticated backend routes for models, responses, websocket responses, compact, and chat completions, preserve generic backend API-key auth, proxy to the canonical backend gateway paths, allow prompt-cache routing locality only on POST responses and chat completions aliases, and keep the chat alias fallback limited to top-level input only when messages is absent or empty"
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
        "backend websocket continuity persists sessions and turns with sticky routing affinity, uses response.create.client_metadata x-codex-turn-state as per-frame request-scoped turn state with the upgrade/header value only as fallback, and is excluded from prompt-cache routing locality"
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
      current: :runtime_route_family_allowlist,
      categories: [:route, :auth, :error, :ownership],
      routes: [
        %{method: :get, path: "/backend-api/codex/models"},
        %{method: :post, path: "/backend-api/codex/responses"},
        %{method: :post, path: "/backend-api/files"},
        %{method: :post, path: "/backend-api/files/:file_id/uploaded"},
        %{method: :post, path: "/backend-api/transcribe"}
      ],
      future_routes: [],
      fixture: :firewall,
      contract: "firewall checks are path-gated to runtime compatibility routes"
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
        "Request compression is Pool-gated by request_compression_enabled, request-side only, fail-open to the original upstream request when scanning, token counting, rewriting, or limits fail, and metadata-only through safe payload_compression request-log metadata; eligible routes are backend Responses, backend /v1 Responses/chat aliases, public /v1 Responses/chat translations, backend compact routes, and backend or narrow public websocket response.create dispatches; protected exact-output function tool outputs for Read, Glob, Grep, Write, Edit, WebSearch, WebFetch, web_search, web_fetch, and external retrieval are skipped before rewriting with aggregate-only skip counts; output-only function tool results fail closed as protected when their tool name is unavailable; search-result compression covers classic path-line matches, grouped heading matches, and portable NUL-delimited matches, diff compression covers hunk-based additions-only, deletions-only, replacement, minimal unified diffs, combined unified diffs, and long-preamble diffs, and log-output compression preserves every failure block when a summary reports failure/error counts; ordinary prose remains outside diff/search/log compression shapes; public /v1/responses/compact remains unsupported with no upstream compact dispatch or compression eligibility"
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
        "non-strict function tool schemas are lowered for backend Responses HTTP, backend Responses websocket response.create, and public /v1 Responses compatibility before local validation or upstream dispatch; lowering is limited to function tools including nested namespace function tools, converts boolean schemas and const values into supported schema shapes, infers missing object or array structure, drops unsupported JSON Schema keywords, preserves supported refs/definitions/combinators recursively, and never weakens strict function tools or strict structured-output schemas"
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
        "OpenAI-compatible /v1 routes are default-on for pools, require bearer API-key auth, return OpenAI-shaped errors without anonymous local or CIDR bypasses, include narrow GET /v1/responses Responses websocket compatibility only, exclude broad /v1/realtime routes, keep POST /v1/responses/compact routed only to deterministic unsupported_endpoint with no upstream compact dispatch, reject OpenAI Responses remote MCP tool definitions before upstream dispatch in both top-level tools and nested additional_tools.tools locations with OpenAI-shaped invalid_request errors, consume continuity headers using the documented local precedence without forwarding session-id, x-session-id, or x-session-affinity upstream, fail closed for pinned /v1/responses continuations whose upstream account needs revoked-refresh-token reauthentication with the shared restart_with_full_context recovery guidance, allow prompt-cache routing locality only on POST responses and chat completions, accept Codex-native Responses web_search hosted tool shapes with boolean access flags while keeping web_search_preview type-only, accept Responses truncation auto and disabled locally without forwarding it upstream, lift Responses system/developer input-message text into top-level instructions, emit early public streaming terminal errors without synthetic success prefixes, emit sanitized response.failed upstream_stream_error when POST /v1/responses SSE has already exposed public Responses data and an ordinary upstream interruption occurs before a Responses terminal event, emit response.failed owner_drained with websocket owner is draining only when a committed websocket-bridge turn is aborted by rollout drain after its drain budget, keep precommit drain admission on its existing fallback or refusal path, keep client disconnect and non-drain interruption mappings unchanged, keep synthetic terminals limited to public HTTP SSE, and preserve backend raw/websocket stream behavior, redact server-class/internal/upstream public /v1 errors while preserving invalid_request_error validation details, preserve safe machine-readable codes for redacted public OpenAI-compatible Responses terminal failures in nested response.error through low-level public SSE normalization and the runtime streaming relay, keep top-level error code-aligned when Pooler emits one, map Responses content_filter/content-filter incomplete reasons to chat finish_reason content_filter while other incomplete reasons remain length, forward structured tool-result/function_call_output payloads unchanged, translate chat-style role=tool continuation messages and Hermes assistant tool-call replays into Responses function_call/function_call_output input items before validation, accept safe Hermes assistant replay status values, drop known OMP function_call replay status fields before validation, translate OpenClaw assistant thinking replays before validation, accept narrow Codex custom tool replay with custom_tool_call.namespace preservation and matching custom_tool_call_output while executable custom tool definitions remain unsupported, and keep chat input fallback, Responses additional_tools support narrow and non-executable, and Responses namespace-tool support narrow"
    },
    %{
      slug: :v1_unsupported_public_surface,
      status: :supported,
      current: :openai_shaped_unsupported_route_contract,
      categories: [:route, :auth, :error],
      routes: [
        %{method: :post, path: "/v1/images/variations"},
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
      http_sse: "response_header",
      websocket: "upgrade_header",
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
        preserved_surfaces: ["/v1/responses", "/v1/chat/completions"]
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
        unsupported_nested_tool_types: ["mcp"]
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
        nested_tool_types: ["function"],
        nested_optional: ["strict", "defer_loading"],
        satisfies_tool_choice: true
      },
      responses_truncation: %{
        accepted_values: ["auto", "disabled"],
        forwarded_upstream: false
      },
      compaction_recovery_boundary: %{
        backend_compaction_trigger: %{
          routes: ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"],
          behavior: "terminal_trigger_bridges_to_compact",
          compact_endpoint: "/backend-api/codex/responses/compact",
          route_class: "proxy_compact",
          transport: "http_compact_json",
          valid_trigger: "exactly_one_final_input_item",
          malformed_trigger: %{status: 400, param: "input", upstream_dispatch: false},
          strips: ["compaction_trigger", "stream", "include", "store"],
          preserves: [
            "model",
            "instructions",
            "input",
            "reasoning",
            "service_tier",
            "prompt_cache_key",
            "previous_response_id",
            "conversation"
          ],
          output_events: ["response.output_item.done", "response.completed", "[DONE]"],
          output_item: %{"type" => "compaction", "encrypted_content" => "encrypted_content"},
          websocket_bridge: false,
          hidden_replay: false
        },
        context_overflow: %{
          recovery_owner: "client_or_upstream",
          public_v1_compaction_replay_item: %{
            route: "/v1/responses",
            item: %{"type" => "compaction", "encrypted_content" => "encrypted_content"},
            upstream_dispatch: true
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
        privacy: "raw_values_not_persisted"
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
      json: %{"path" => "/backend-api/codex/responses", "decision" => "synthetic allow"}
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
    function_tool_schema_lowering: %{
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
    v1_supported_surface: %{
      auth: "required_bearer_api_key",
      default_enabled: true,
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
        terminal_event: "response.failed",
        error_code: "upstream_stream_error",
        safe_message:
          "upstream request failed: stream interrupted before terminal response event",
        post_budget_owner_drain: %{
          applies_to: "committed websocket bridge turn aborted after rollout drain budget",
          error_code: "owner_drained",
          safe_message: "websocket owner is draining"
        },
        precommit_drain: "existing_fallback_or_refusal",
        client_disconnect: "unchanged",
        non_drain_interruptions: "byte_identical",
        backend_raw_streams: "unchanged",
        websocket_streams: "unchanged",
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
        unsupported_nested_tool_types: ["mcp"]
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
          accepted_required: ["type", "external_web_access"],
          accepted_optional: ["index_gated_web_access"],
          valid_combinations: [
            "external_web_access=false",
            "external_web_access=true",
            "external_web_access=true,index_gated_web_access=true"
          ],
          rejected_options: ["filters", "search_context_size", "user_location"]
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
      openclaw_assistant_thinking_replay: %{
        input_role: "assistant",
        dropped_content_part_type: "thinking",
        normalized_content_part_type: "output_text",
        source_text_part_type: "text",
        requires_previous_response_id: false,
        metadata_only: true
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
    image_generation_permission: %{
      pool_gate: %{
        setting: "allow_image_generation",
        default_enabled: true,
        disabled_behavior: "403_image_generation_disabled"
      },
      enforcement: "after_runtime_authentication_before_request_parsing_or_upstream_dispatch"
    },
    v1_unsupported_public_surface: %{
      routes: [
        %{method: :post, path: "/v1/images/variations"},
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
