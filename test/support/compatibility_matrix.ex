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
        "backend image generation and edit routes are explicit authenticated JSON proxy routes under /backend-api/codex/images, keep image-specific prompt and source fields intact, and stay distinct from the public /v1 image translator surface"
    },
    %{
      slug: :responses_chat,
      status: :supported,
      current: :proxied_json_and_sse,
      categories: [:route, :auth, :error, :streaming, :ownership],
      routes: [%{method: :post, path: "/backend-api/codex/responses"}],
      future_routes: [],
      fixture: :responses_chat,
      contract:
        "Responses and chat completions proxy JSON/SSE through the shared gateway accounting path; chat completions use messages when present and fall back to top-level input only when messages is absent or empty, with omitted fallback instructions defaulting to a blank string; request-shaped additional_tools input items are preserved as non-executable input, never merged into executable tools, and never used to satisfy tool_choice; OpenAI Responses remote MCP tool definitions are rejected before dispatch in both top-level tools and nested additional_tools.tools locations; Responses namespace tool definitions are accepted only for non-empty namespace name/description values and nested function tools; Responses truncation accepts auto and disabled locally but is not forwarded upstream; terminal compaction_trigger backend payloads bridge through /backend-api/codex/responses/compact with compact accounting and backend Responses SSE compaction output, while malformed trigger placement is rejected before dispatch; backend regular HTTP Responses and compact routes forward approved metadata headers, including request-scoped x-codex-turn-state, x-codex-window-id, and x-codex-installation-id, and relay upstream x-codex-turn-state response headers downstream, while public /v1 and websocket request-header lanes do not; context-overflow recovery stays client/upstream-owned with no server-side hidden replay or stored prompt/frame reconstruction; Hermes assistant replay may include safe assistant status metadata; OpenClaw assistant replay drops thinking metadata and normalizes text before upstream dispatch; safe OpenAI Responses fields, prompt-cache locality, SDK-control rejection, and backend-only control stripping stay scope-specific"
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
        "Responses input_image.file_id and Codex sediment:// file URIs used as input_image.image_url values are rejected before reservation or upstream dispatch"
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
        "Request compression is Pool-gated by request_compression_enabled, request-side only, fail-open to the original upstream request when scanning, token counting, rewriting, or limits fail, and metadata-only through safe payload_compression request-log metadata; eligible routes are backend Responses, backend /v1 Responses/chat aliases, public /v1 Responses/chat translations, backend compact routes, and backend or narrow public websocket response.create dispatches; protected exact-output function tool outputs for Read, Glob, Grep, Write, Edit, and external retrieval are skipped before rewriting with aggregate-only skip counts; output-only function tool results fail closed as protected when their tool name is unavailable; search-result compression covers classic path-line matches, grouped heading matches, and portable NUL-delimited matches, and diff compression covers hunk-based additions-only, deletions-only, replacement, minimal unified diffs, combined unified diffs, and long-preamble diffs without treating ordinary prose as diff/search input; public /v1/responses/compact remains unsupported with no upstream compact dispatch or compression eligibility"
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
        "OpenAI-compatible /v1 routes are default-on for pools, require bearer API-key auth, return OpenAI-shaped errors without anonymous local or CIDR bypasses, include narrow GET /v1/responses Responses websocket compatibility only, exclude broad /v1/realtime routes, keep POST /v1/responses/compact routed only to deterministic unsupported_endpoint with no upstream compact dispatch, reject OpenAI Responses remote MCP tool definitions before upstream dispatch in both top-level tools and nested additional_tools.tools locations with OpenAI-shaped invalid_request errors, consume continuity headers using the documented local precedence without forwarding session-id, x-session-id, or x-session-affinity upstream, fail closed for pinned /v1/responses continuations whose upstream account needs revoked-refresh-token reauthentication with the shared restart_with_full_context recovery guidance, allow prompt-cache routing locality only on POST responses and chat completions, accept Codex-native Responses web_search hosted tool shapes with boolean access flags while keeping web_search_preview type-only, accept Responses truncation auto and disabled locally without forwarding it upstream, lift Responses system/developer input-message text into top-level instructions, emit early public streaming terminal errors without synthetic success prefixes, redact server-class/internal/upstream public /v1 errors while preserving invalid_request_error validation details, map Responses content_filter/content-filter incomplete reasons to chat finish_reason content_filter while other incomplete reasons remain length, forward structured tool-result/function_call_output payloads unchanged, translate chat-style role=tool continuation messages and Hermes assistant tool-call replays into Responses function_call/function_call_output input items before validation, accept safe Hermes assistant replay status values, translate OpenClaw assistant thinking replays before validation, and keep chat input fallback, Responses additional_tools support narrow and non-executable, and Responses namespace-tool support narrow"
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
        "model" => "gpt-fixture-image",
        "prompt" => "synthetic backend image proxy request"
      }
    },
    responses_chat: %{
      prompt_cache_routing: %{
        setting: "prompt_cache_affinity_enabled",
        default_enabled: true,
        mode: "stateless_locality_over_already_eligible_assignments",
        typed_input: "prompt_cache_key",
        locality_key_material: "trimmed_sha256_hash",
        privacy: "raw_key_not_persisted_hash_only_locality",
        provider_cache_evidence: "upstream_cached_input_tokens_only"
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
      json: %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic text request",
        "stream" => true
      }
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
        default_function_names: ["Read", "Glob", "Grep", "Write", "Edit"],
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
