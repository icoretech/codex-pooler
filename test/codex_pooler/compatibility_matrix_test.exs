defmodule CodexPooler.CompatibilityMatrixTest do
  use ExUnit.Case, async: true

  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.Pools.RoutingSettings

  describe "catalog and Responses runtime contract" do
    test "distinguishes public terminal compaction triggers from the unsupported compact route" do
      fixture = CompatibilityMatrix.fixture!(:responses_chat)

      assert fixture.compaction_recovery_boundary.public_v1_compaction_trigger == %{
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
             }
    end

    test "keeps the issue-75 policy exception narrow and generic redaction intact" do
      fixture = CompatibilityMatrix.fixture!(:misalignment_policy_violation)

      assert fixture.eligibility == %{
               direct_http_statuses: [400, 403],
               terminal_transports: ["sse", "websocket"],
               route_scope: "eligible_direct_or_translated_responses_and_chat_routes_only",
               exact_error_envelope: true
             }

      assert fixture.lifecycle == %{
               retryable: false,
               health_neutral: true,
               demotion: false,
               circuit_failure: false,
               settlement: "exactly_once"
             }

      assert fixture.public_error == %{
               code: "misalignment_policy_violation",
               type: "invalid_request_error",
               message: "nonblank_provider_message_or_fixed_safe_fallback",
               provider_param: false,
               provider_body: false,
               provider_siblings: false
             }

      assert fixture.durable_metadata == %{
               exact_code: true,
               accounting_message: "fixed",
               bounded_facts_only: true,
               raw_provider_message: false,
               raw_provider_body: false
             }

      assert fixture.generic_provider_errors == %{
               message: "upstream request failed",
               type: "server_error",
               unchanged: true
             }
    end

    test "pins fast as a priority alias without collapsing relay and translation fidelity" do
      backend = CompatibilityMatrix.by_slug!(:backend_fast_service_tier)
      translated = CompatibilityMatrix.by_slug!(:responses_chat)

      assert backend.current == :canonical_priority_routing_alias
      assert backend.contract =~ "fast to upstream priority"

      assert backend.contract =~
               "relay provider bytes, frames, and service-tier vocabulary unchanged"

      assert translated.contract =~
               "accept client service_tier fast as canonical upstream priority"

      assert translated.contract =~ "preserve literal provider service_tier output"
    end

    test "keeps ultrafast Responses-only behind advertised candidate metadata" do
      fixture = CompatibilityMatrix.fixture!(:responses_chat)

      assert fixture.service_tier_boundary == %{
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
             }
    end

    @tag :external_issues_229_231
    test "makes backend model catalog ETag derivation and surface capacity machine-readable" do
      feature = CompatibilityMatrix.by_slug!(:backend_models_etag)
      fixture = CompatibilityMatrix.fixture!(:backend_models_etag)

      assert feature.current == :policy_visible_body_digest

      assert feature.routes == [
               %{method: :get, path: "/backend-api/codex/models"},
               %{method: :get, path: "/backend-api/codex/v1/models"}
             ]

      assert fixture == %{
               header: "etag",
               digest_input: "policy_visible_effective_catalog_body",
               digest: "sha256_deterministic_canonical_json",
               format: "weak_cp_models_v1",
               aliases_share_exact_body_and_token: true,
               cache_coherence: "eventual_after_successful_responses_token"
             }

      assert feature.canonical_partition.new_turn_capacity == %{
               backend_codex_catalog_driven: "selected_partition_only",
               translated_openai_responses: "all_valid_canonical_assignments"
             }

      assert feature.canonical_partition.shell_type == %{
               equivalent_known_values: ["default", "local", "shell_command", "unified_exec"],
               digest_value: "shell_command",
               disabled: "separate_partition",
               non_collapsing_values: ["unknown", "missing", "malformed"]
             }

      assert feature.canonical_partition.quota_routing == %{
               snapshot: "one_shared_candidate_identity_snapshot",
               classification: "independent_per_model",
               input: "quota_evidence_only"
             }

      assert feature.canonical_partition.pinned_continuation == %{
               valid_canonical_hard_pin: "may_cross_partition",
               malformed_or_retired_source: "unavailable"
             }

      assert feature.contract =~
               "same policy-visible effective catalog body and deterministic weak ETag"

      assert feature.contract =~
               "backend Codex catalog-driven new turns use the selected partition"

      assert feature.contract =~
               "translated OpenAI Responses capacity includes all valid canonical assignments"

      assert feature.contract =~ "unknown, missing, or malformed values do not silently collapse"
      assert feature.contract =~ "classifies it independently per model"
    end

    test "pins exact backend Responses catalog header equality and exclusions" do
      feature = CompatibilityMatrix.by_slug!(:backend_responses_etag)
      fixture = CompatibilityMatrix.fixture!(:backend_responses_etag)

      assert feature.current == :predispatch_catalog_snapshot
      assert fixture.header == "x-models-etag"
      assert fixture.equals == "authenticated_backend_models_etag"
      assert fixture.http_json == :excluded
      assert fixture.http_sse == %{surface: :response_header, authority: :request_snapshot}

      assert fixture.websocket == %{
               upgrade: %{
                 surface: :response_header,
                 authority: :backward_compatible_connection_open
               },
               turn: %{
                 surface: :codex_response_metadata_event,
                 authority: :current_turn_snapshot,
                 event_type: "codex.response.metadata"
               }
             }

      assert fixture.snapshot_lifetime == %{
               http: :request,
               websocket: :response_create_turn,
               retry: :preserve,
               owner_forwarding: :preserve,
               next_websocket_turn: :reresolve
             }

      assert fixture.upstream_etag_relay == false

      assert fixture.included_routes == [
               "/backend-api/codex/responses",
               "/backend-api/codex/v1/responses"
             ]

      assert fixture.excluded_surfaces == [
               "backend_json",
               "backend_compact",
               "public_v1",
               "usage",
               "unauthenticated",
               "unrelated_routes"
             ]
    end

    test "pins the final noncompact envelope and compact exclusion" do
      feature = CompatibilityMatrix.by_slug!(:backend_responses_envelope)
      fixture = CompatibilityMatrix.fixture!(:backend_responses_envelope)

      assert feature.current == :final_noncompact_backend_envelope

      assert feature.routes == [
               %{method: :post, path: "/backend-api/codex/responses"},
               %{method: :post, path: "/backend-api/codex/v1/responses"},
               %{
                 method: :get,
                 path: "/backend-api/codex/responses",
                 transport: "websocket"
               },
               %{
                 method: :get,
                 path: "/backend-api/codex/v1/responses",
                 transport: "websocket"
               },
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
             ]

      assert fixture.noncompact.reasoning == "map"
      assert fixture.noncompact.encrypted_include == "reasoning.encrypted_content"
      assert fixture.noncompact.encrypted_include_count == 1
      assert fixture.noncompact.idempotent_after_json_round_trip == true
      assert fixture.compact.applies_noncompact_envelope == false
      assert fixture.compact.preserves_existing_shape == true
    end

    test "pins safe detail-only upstream error parameter projection" do
      feature = CompatibilityMatrix.by_slug!(:upstream_error_param)
      fixture = CompatibilityMatrix.fixture!(:upstream_error_param)

      assert feature.current == :sanitized_failed_attempt_detail
      assert fixture.field == "upstream_error_param"
      assert fixture.source == "decoded_upstream_error_envelope"
      assert fixture.projection == "failed_attempt_detail_only"
      assert fixture.max_bytes == 160
      assert fixture.allowed_shape == "field_name_or_index_path"
      assert fixture.invalid_or_successful_attempt == "omitted"
      assert fixture.raw_error_message_or_value == "never_projected"
    end

    test "pins bounded rejection metadata extraction and publication" do
      feature = CompatibilityMatrix.by_slug!(:rejection_metadata)
      fixture = CompatibilityMatrix.fixture!(:rejection_metadata)

      assert feature.current == :bounded_non_429_4xx_rejection_metadata
      assert feature.routes == CompatibilityMatrix.by_slug!(:upstream_error_param).routes
      assert fixture.source == "private_stream_drain_then_materialized_body"
      assert fixture.projection == "failed_attempt_detail_only"
      assert fixture.max_body_bytes == 65_536
      assert fixture.message_bytes_max == 1_024
      assert fixture.fields == ~w(
               rejection_error_code
               rejection_error_type
               rejection_error_param
               rejection_message_present
               rejection_message_bytes
             )
      assert fixture.invalid_shapes == "omitted"
      assert fixture.raw_error_message_or_body == "never_projected"
    end
  end

  describe "Responses tool compatibility contract" do
    test "separates executable custom tools from replay and translates Chat" do
      feature = CompatibilityMatrix.by_slug!(:responses_executable_custom_tools)
      fixture = CompatibilityMatrix.fixture!(:responses_executable_custom_tools)

      assert feature.current == :responses_and_chat_custom_tool_admission
      assert feature.contract =~ "custom replay is a separate input-item contract"
      assert feature.contract =~ "without parsing free-form input as JSON"
      assert feature.contract =~ "selected model and upstream account"
      assert fixture.required_keys == ["type", "name"]
      assert fixture.allowed_callers == ["direct", "programmatic"]
      assert fixture.allowed_callers_null == true

      assert fixture.typed_choice == %{
               exact_keys: ["type", "name"],
               resolves_same_kind: true,
               full_mode: "preserved",
               lite_mode: "rejected_unsupported_parameter_before_dispatch",
               lite_rejection_scope: "any_map_shaped_tool_choice",
               lite_rejection_lanes: [
                 "direct_public_responses",
                 "chat_completions",
                 "backend_codex"
               ]
             }

      assert fixture.custom_replay_contract == "separate_input_item_shape"
      assert fixture.chat_supported == true

      assert fixture.chat == %{
               request_definition: "nested_type_and_custom",
               optional_definition_fields: ["description", "format"],
               typed_choice: "nested_type_and_custom_name",
               upstream_translation: "flat_responses_custom",
               completed_output: "nested_chat_custom_call",
               streamed_input: "free_form_fragments_not_json_parsed"
             }

      assert fixture.broad_openai_tool_parity == false
    end

    test "keeps strict missing-type repair outside non-strict lowering" do
      lowering = CompatibilityMatrix.fixture!(:function_tool_schema_lowering)
      repair = CompatibilityMatrix.fixture!(:direct_responses_strict_schema_repair)

      assert lowering.strict_function_tools_lowered == false
      assert lowering.strict_structured_outputs_lowered == false
      assert repair.strict_function_tools_lowered == false
      assert repair.strict_structured_outputs_lowered == false
      assert repair.inserted_types == ["object", "array"]

      assert repair.target_tool_shapes == [
               "top_level_flat_function",
               "namespace_child_flat_function"
             ]

      assert repair.public_explicit_type_vocabulary ==
               ~w(null boolean object array number integer string)

      assert repair.exclusions == [
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
             ]
    end
  end

  describe "request compression compatibility contract" do
    test "documents Pool-gated request-side fail-open metadata-only behavior" do
      feature = CompatibilityMatrix.by_slug!(:request_compression)
      fixture = CompatibilityMatrix.fixture!(:request_compression)

      assert feature.status == :supported
      assert feature.current == :pool_gated_request_side_payload_rewrite
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :error in feature.categories
      assert :streaming in feature.categories
      assert :ownership in feature.categories
      assert :degraded in feature.categories

      assert feature.contract =~ "Pool-gated"
      assert feature.contract =~ "request_compression_enabled"
      assert feature.contract =~ "request-side only"
      assert feature.contract =~ "fail-open"
      assert feature.contract =~ "metadata-only"
      assert feature.contract =~ "payload_compression"
      assert feature.contract =~ "valid JSON object or array spans embedded in ordinary prose"

      assert Map.fetch!(fixture, :pool_gate) == %{
               setting: "request_compression_enabled",
               default_enabled: false,
               disabled_behavior: "original_request_passthrough"
             }

      assert Map.fetch!(fixture, :direction) == "request_side_only"
      assert Map.fetch!(fixture, :failure_mode) == "fail_open_original_request"

      assert get_in(fixture, [:supported_input_shapes, :embedded_json]) == %{
               container_kinds: ["object", "array"],
               surrounding_bytes: "preserved",
               quoted_json_looking_text: "preserved",
               malformed_or_over_limit_behavior: "original_output_preserved",
               maximum_spans: 50
             }

      assert Map.fetch!(fixture, :privacy) == %{
               raw_outputs_stored: false,
               raw_response_bodies_stored: false,
               ccr_retrieval: false,
               request_log_metadata: "payload_compression",
               metadata_only: true
             }
    end

    test "keeps eligible routes and public compact unsupported behavior explicit" do
      feature = CompatibilityMatrix.by_slug!(:request_compression)
      fixture = CompatibilityMatrix.fixture!(:request_compression)

      assert feature.routes == [
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
             ]

      assert Map.fetch!(fixture, :eligible_route_families) == [
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
             ]

      assert Map.fetch!(fixture, :ineligible_surfaces) == [
               "multipart",
               "files",
               "audio",
               "images",
               "admin",
               "mcp",
               "usage",
               "control_plane"
             ]

      assert Map.fetch!(fixture, :public_unsupported_compact) == %{
               method: :post,
               path: "/v1/responses/compact",
               status: 404,
               error_code: "unsupported_endpoint",
               compression_eligible: false,
               upstream_dispatch: false
             }
    end
  end

  describe "upstream websocket bridge compatibility contract" do
    test "pins terminal delivery, committed no-fallback, and atomic metadata handoff" do
      feature = CompatibilityMatrix.by_slug!(:upstream_websocket_bridge)
      fixture = CompatibilityMatrix.fixture!(:upstream_websocket_bridge)

      assert feature.contract =~ "private owner barrier"
      assert feature.contract =~ "without HTTP fallback or automatic replay"
      assert feature.contract =~ "atomic one-shot metadata handoff"
      assert feature.contract =~ "health-neutral"

      assert fixture.fallback.upstream_committed == "no_http_fallback_or_automatic_replay"

      assert fixture.terminal_delivery == %{
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
             }

      assert fixture.metadata_handoff == %{
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
             }
    end

    test "pins health-neutral reconnect and two-node owner recovery" do
      feature = CompatibilityMatrix.by_slug!(:upstream_websocket_bridge)
      fixture = CompatibilityMatrix.fixture!(:upstream_websocket_bridge)

      assert feature.contract =~ "next explicit turn reconnects at generation plus one"
      assert feature.contract =~ "two-node owner forwarding, fencing, transfer, and takeover"

      assert fixture.recovery == %{
               failed_turn_automatic_replay: false,
               next_explicit_turn: "same_lifecycle_generation_plus_one",
               next_explicit_turn_reconnected: true,
               later_healthy_turn: "reuse_reconnected_generation"
             }

      assert fixture.health == %{
               terminal_delivery_timeout: "pooler_local_health_neutral",
               assignment_health_changed: false,
               quota_eligibility_changed: false,
               circuit_counters_changed: false
             }

      assert fixture.multi_node_owner == %{
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
             }
    end

    test "keeps owner-retention and rolling-deploy contracts explicit" do
      feature = CompatibilityMatrix.by_slug!(:upstream_websocket_bridge)
      fixture = CompatibilityMatrix.fixture!(:upstream_websocket_bridge)

      assert feature.status == :supported
      assert feature.current == :owner_websocket_cache_bridge
      assert feature.routes == [%{method: :post, path: "/v1/responses"}]

      assert fixture.owner_retention == %{
               setting: "websocket_owner_idle_timeout_ms",
               default_ms: 1_800_000,
               min_ms: 60_000,
               max_ms: 3_600_000,
               starts_after: "final_downstream_detach_without_active_turn",
               capture: "node_local_at_new_or_recovered_owner_start",
               existing_owner_update: "retains_captured_value",
               previous_release_default_ms: 300_000
             }

      assert fixture.fallback.cache_locality == "heuristic_never_guarantee"

      assert fixture.accounting.upstream_websocket_connection == %{
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

      assert fixture.rolling_deploy == %{
               native_attach_arity: 2,
               bridge_attach_arity: 3,
               old_owner_native_attach: "compatible_without_connection_metadata",
               old_owner_bridge_attach: "fail_closed_http_fallback"
             }
    end
  end

  describe "native websocket continuation compatibility contract" do
    test "pins the generation guard's native retry signal and public exclusion" do
      feature = CompatibilityMatrix.by_slug!(:websocket_continuity)
      fixture = CompatibilityMatrix.fixture!(:websocket_turn)

      assert feature.contract =~ "native websocket continuation"
      assert feature.contract =~ "reused upstream connection"
      assert feature.contract =~ "exact previous_response_not_found client retry signal"
      assert feature.contract =~ "later explicit full request"
      assert feature.contract =~ "public /v1 terminal masking and shape remain unchanged"

      assert fixture.native_continuation_generation_guard == %{
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
             }
    end
  end

  describe "image generation compatibility contract" do
    test "connects the documented Pool gate to the production routing schema" do
      feature = CompatibilityMatrix.by_slug!(:image_generation_permission)
      fixture = CompatibilityMatrix.fixture!(:image_generation_permission)

      assert feature.status == :supported
      assert feature.current == :pool_gated_image_generation_permission

      assert feature.routes == [
               %{method: :post, path: "/backend-api/codex/images/generations"},
               %{method: :post, path: "/backend-api/codex/images/edits"},
               %{method: :post, path: "/v1/images/generations"},
               %{method: :post, path: "/v1/images/edits"}
             ]

      setting = :allow_image_generation
      assert setting in RoutingSettings.__schema__(:fields)
      assert Map.fetch!(%RoutingSettings{}, setting) == true
      assert fixture.pool_gate.setting == Atom.to_string(setting)
      assert fixture.pool_gate.default_enabled == true
      assert fixture.pool_gate.disabled_behavior == "403_image_generation_disabled"

      assert fixture.enforcement == %{
               after: :runtime_authentication,
               before: [:request_parsing, :upstream_dispatch, :body_decompression]
             }
    end
  end

  describe "pruned runtime compatibility contract" do
    test "does not carry removed control-plane or reset-credit feature rows" do
      refute :control_plane_surface in CompatibilityMatrix.feature_slugs()
      refute :backend_reset_credit_consume in CompatibilityMatrix.feature_slugs()
      refute :backend_alpha_search in CompatibilityMatrix.feature_slugs()
    end

    test "does not carry fixtures or supported routes for removed runtime surfaces" do
      refute Map.has_key?(CompatibilityMatrix.fixtures(), :control_plane_surface)
      refute Map.has_key?(CompatibilityMatrix.fixtures(), :backend_reset_credit_consume)
      refute Map.has_key?(CompatibilityMatrix.fixtures(), :backend_alpha_search)

      matrix_routes =
        CompatibilityMatrix.features()
        |> Enum.flat_map(& &1.routes)
        |> Enum.map(&{&1.method, &1.path})
        |> MapSet.new()

      for route <- pruned_runtime_routes() do
        refute MapSet.member?(matrix_routes, route),
               "expected #{inspect(route)} to stay outside the supported compatibility matrix"
      end
    end
  end

  defp pruned_runtime_routes do
    [
      {:post, "/api/codex/rate-limit-reset-credits/consume"},
      {:post, "/wham/rate-limit-reset-credits/consume"},
      {:post, "/backend-api/wham/rate-limit-reset-credits/consume"},
      {:get, "/backend-api/codex/thread/goal/get"},
      {:post, "/backend-api/codex/thread/goal/get"},
      {:post, "/backend-api/codex/thread/goal/set"},
      {:post, "/backend-api/codex/thread/goal/clear"},
      {:post, "/backend-api/codex/analytics-events/events"},
      {:post, "/backend-api/codex/memories/trace_summarize"},
      {:post, "/backend-api/codex/alpha/search"},
      {:post, "/backend-api/codex/realtime/calls"},
      {:post, "/backend-api/codex/safety/arc"},
      {:get, "/backend-api/codex/agent-identities/jwks"},
      {:get, "/backend-api/wham/agent-identities/jwks"}
    ]
  end
end
