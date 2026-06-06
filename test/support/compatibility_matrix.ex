defmodule CodexPooler.CompatibilityMatrix do
  @moduledoc """
  Machine-readable Codex compatibility contract matrix for regression tests.

  Rows intentionally describe the current compatibility contract so regression
  tests can keep supported behavior pinned.
  """

  alias CodexPooler.ControlPlaneRoutes

  @control_plane_feature_routes Enum.map(ControlPlaneRoutes.all(), fn route ->
                                  %{method: route.method, path: route.local_path}
                                end)
  @control_plane_fixture_routes ControlPlaneRoutes.all()
                                |> Enum.map(& &1.local_path)
                                |> Enum.uniq()

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
        "Responses and chat completions proxy JSON/SSE through the shared gateway accounting path; chat completions use messages when present and fall back to top-level input only when messages is absent or empty, with omitted fallback instructions defaulting to a blank string; request-shaped additional_tools input items are preserved as non-executable input, never merged into executable tools, and never used to satisfy tool_choice; Responses truncation accepts auto and disabled locally but is not forwarded upstream; compaction_trigger payloads pass through unchanged on backend Responses, while context-overflow recovery stays client/upstream-owned with no server-side compaction, hidden replay, or stored prompt/frame reconstruction; safe OpenAI Responses fields, prompt-cache locality, SDK-control rejection, and backend-only control stripping stay scope-specific"
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
        "backend websocket continuity persists sessions and turns with sticky routing affinity and is excluded from prompt-cache routing locality"
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
      slug: :control_plane_surface,
      status: :supported,
      current: :explicit_authenticated_proxy_routes,
      categories: [:route, :auth, :error, :degraded],
      routes: @control_plane_feature_routes,
      future_routes: [],
      fixture: :control_plane_surface,
      contract:
        "control-plane endpoints are explicit authenticated proxy routes under the runtime API, use the proxy_control route class, forward to exact upstream control-plane paths, preserve raw SDP realtime bytes, allowlist response headers, and keep logs metadata-only"
    },
    %{
      slug: :backend_alpha_search,
      status: :supported,
      current: :explicit_authenticated_control_plane_route,
      categories: [:route, :auth, :error, :degraded],
      routes: [%{method: :post, path: "/backend-api/codex/alpha/search"}],
      future_routes: [],
      fixture: :backend_alpha_search,
      contract:
        "backend alpha search is an explicit authenticated Codex backend compatibility control-plane route, uses the proxy_control route class, forwards only to upstream /alpha/search, and keeps request logs metadata-only"
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
        "OpenAI-compatible /v1 routes are default-on for pools, require bearer API-key auth, return OpenAI-shaped errors without anonymous local or CIDR bypasses, include narrow GET /v1/responses Responses websocket compatibility only, exclude broad /v1/realtime routes, consume continuity headers using the documented local precedence without forwarding session-id or x-session-affinity upstream, fail closed for pinned /v1/responses continuations whose upstream account needs revoked-refresh-token reauthentication with the shared restart_with_full_context recovery guidance, allow prompt-cache routing locality only on POST responses and chat completions, accept Responses truncation auto and disabled locally without forwarding it upstream, and keep chat input fallback plus Responses additional_tools support narrow and non-executable"
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
        satisfies_tool_choice: false
      },
      responses_truncation: %{
        accepted_values: ["auto", "disabled"],
        forwarded_upstream: false
      },
      compaction_recovery_boundary: %{
        backend_compaction_trigger: %{
          route: "/backend-api/codex/responses",
          behavior: "forwarded_unchanged",
          local_retry: false
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
      headers: %{"x-codex-turn-state" => "fixture-turn-state"},
      json: %{"model" => "gpt-fixture-text", "input" => "synthetic websocket turn"}
    },
    reasoning_minimal: %{
      json: %{
        "model" => "gpt-fixture-text",
        "input" => "synthetic reasoning request",
        "reasoning" => %{"effort" => "minimal"}
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
    control_plane_surface: %{
      auth: "required_bearer_api_key",
      route_class: "proxy_control",
      analytics_forwarding_enabled_default: true,
      analytics_forwarding_disabled: %{status: 204, upstream_call: false},
      response_header_allowlist: [
        "cache-control",
        "content-type",
        "etag",
        "last-modified",
        "location",
        "openai-processing-ms",
        "request-id",
        "x-request-id"
      ],
      privacy: "metadata_only",
      routes: @control_plane_fixture_routes
    },
    backend_alpha_search: %{
      auth: "required_bearer_api_key",
      route_class: "proxy_control",
      privacy: "metadata_only",
      routes: ["/backend-api/codex/alpha/search"],
      upstream_path: "/alpha/search"
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
        satisfies_tool_choice: false
      },
      responses_truncation: %{
        accepted_values: ["auto", "disabled"],
        forwarded_upstream: false
      },
      continuity_precedence: [
        "x-codex-session-id",
        "session-id",
        "x-session-affinity",
        "session_id",
        "x-codex-conversation-id"
      ],
      local_continuity_headers_not_forwarded: ["session-id", "x-session-affinity"],
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
            "x-codex-session-id",
            "session-id",
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
