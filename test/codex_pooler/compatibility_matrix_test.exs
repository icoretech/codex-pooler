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
               strips: ["stream", "include", "prompt_cache_options"],
               upstream_payload: %{
                 mode: "buffered_responses_json",
                 terminal_trigger: "retained",
                 store: false,
                 stream: "omitted"
               },
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

    test "pins the V2/native compaction split and provider-unsupported evidence" do
      fixture = CompatibilityMatrix.fixture!(:responses_chat)
      boundary = fixture.compaction_recovery_boundary

      assert boundary.backend_compaction_trigger.upstream_payload == %{
               mode: "semantic_v2_sse_or_buffered_responses_json",
               terminal_trigger: "retained",
               store: false,
               stream: "semantic_v2_true_otherwise_omitted"
             }

      assert boundary.backend_compaction_trigger.direct_compact_preservation.upstream_payload ==
               %{
                 compaction_trigger: "omitted",
                 store: "omitted",
                 stream: "omitted"
               }

      assert boundary.native_fallback.provider_unsupported == %{
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
             }

      assert boundary.native_fallback.omp_terminal ==
               "configured_local_fallback_from_pinned_configuration"
    end

    @tag :compatibility_contract
    test "pins semantic V2 classification and honest harness applicability" do
      boundary =
        CompatibilityMatrix.fixture!(:responses_chat).compaction_recovery_boundary

      assert boundary.backend_compaction_trigger.result_classification == %{
               source: "request_client_metadata.x-codex-turn-metadata",
               marker: "compaction.implementation=responses_compaction_v2",
               additive_metadata: "ignored",
               returned_compaction_items: "not_inspected"
             }

      assert boundary.harness_applicability == %{
               codex: %{
                 version: "rust-v0.149.1",
                 applicability: "native_v2",
                 classifier_authority: true,
                 verification: "commit_blocking"
               },
               omp: %{
                 version: "18.0.4",
                 applicability: "distinct_v2_and_configured_direct_fallback_adapter",
                 classifier_authority: false
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
             }
    end

    test "pins the native websocket compaction bridge as a closed machine contract" do
      bridge =
        CompatibilityMatrix.fixture!(:responses_chat).compaction_recovery_boundary
        |> get_in([:backend_compaction_trigger, :websocket_bridge])

      assert bridge == native_websocket_compaction_bridge_contract()
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

    @tag :hosted_shell_history
    test "makes hosted shell history replay boundaries machine-readable" do
      feature = CompatibilityMatrix.by_slug!(:responses_chat)
      fixture = CompatibilityMatrix.fixture!(:responses_chat)
      v1_feature = CompatibilityMatrix.by_slug!(:v1_supported_surface)

      assert feature.hosted_shell_history_contract =~ "closed-key hosted-shell history replay"
      assert feature.hosted_shell_history_contract =~ "without executing commands"
      assert feature.hosted_shell_history_contract =~ "shell tool declarations"
      assert feature.hosted_shell_history_contract =~ "local shell"
      assert feature.hosted_shell_history_contract =~ "remote MCP"

      assert fixture.hosted_shell_history == %{
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
                 previous_response_id_semantic_tool_output: "accepted",
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
             }

      assert v1_feature.contract =~ "hosted-shell history replay"
      assert v1_feature.contract =~ "does not execute commands"
      assert v1_feature.contract =~ "shell tool declarations"
      assert v1_feature.contract =~ "local shell"
      assert v1_feature.contract =~ "remote MCP"
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
               digest_input: "policy_visible_native_catalog_body",
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

      assert feature.canonical_partition.selection_rank == [
               "quota_routable_member_count_desc",
               "partition_member_count_desc",
               "anchor_created_at_asc",
               "anchor_assignment_id_asc"
             ]

      assert feature.canonical_partition.selection == "largest_quota_routable_partition"

      assert feature.canonical_partition.selection_fallback ==
               "largest_partition_when_none_routable"

      assert feature.canonical_partition.pinned_continuation == %{
               valid_canonical_hard_pin: "may_cross_partition",
               malformed_or_retired_source: "unavailable"
             }

      assert feature.contract =~
               "same policy-visible native catalog body and deterministic weak ETag"

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

    test "pins bounded terminal failure diagnostics as attempt detail only" do
      feature = CompatibilityMatrix.by_slug!(:terminal_failure_diagnostics)
      fixture = CompatibilityMatrix.fixture!(:terminal_failure_diagnostics)

      assert feature.current == :bounded_terminal_failure_attempt_detail
      assert feature.routes == CompatibilityMatrix.by_slug!(:upstream_error_param).routes
      assert fixture.fields == ~w(upstream_error_code stream_terminal_type upstream_error_param)
      assert fixture.projection == "failed_and_retryable_failed_attempt_detail_only"
      assert fixture.readable_identifier == "strict_ascii_80_bytes_or_less_cleartext"
      assert fixture.malformed_identifier == "sha256_12"
      assert fixture.invalid_or_successful_or_historical_attempt == "omitted"
      assert fixture.raw_provider_message_body_or_frame == "never_projected"
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
    @tag :responses_allowed_tools
    test "keeps allowed-tools independent from executable custom and chat choices" do
      feature = CompatibilityMatrix.by_slug!(:responses_allowed_tools)
      fixture = CompatibilityMatrix.fixture!(:responses_allowed_tools)

      assert feature.status == :supported
      assert feature.current == :declaration_backed_full_mode_choice
      assert feature.categories == [:route, :auth, :error, :streaming, :ownership]
      assert feature.future_routes == []
      assert feature.fixture == :responses_allowed_tools
      assert feature.routes == responses_allowed_tools_routes()
      assert feature.contract == responses_allowed_tools_summary()
      assert fixture == responses_allowed_tools_contract()
    end

    test "closes paired and named standalone function output shapes" do
      function_output =
        CompatibilityMatrix.fixture!(:responses_chat).programmatic_tool_calling.input_items.function_call_output

      assert function_output == function_call_output_contract()
    end

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

    test "pins every public strict object-root rejection and preservation category" do
      feature = CompatibilityMatrix.by_slug!(:public_strict_schema_object_roots)
      fixture = CompatibilityMatrix.fixture!(:public_strict_schema_object_roots)

      assert length(feature.routes) == 4

      assert fixture.strict_target_shapes == [
               "text.format.schema",
               "response_format.json_schema.schema",
               "tools[].parameters",
               "tools[].function.parameters",
               "tools[].tools[].parameters"
             ]

      assert fixture.rejected_root_families == [
               "omitted_type",
               "primitive_type",
               "array_type",
               "singleton_type_array",
               "nullable_object_type_union",
               "root_ref",
               "root_any_of",
               "object_with_root_any_of"
             ]

      assert fixture.accepted_nested_constructs == [
               "local_refs",
               "recursive_refs",
               "primitives",
               "arrays",
               "nullable_unions",
               "any_of",
               "one_of",
               "all_of"
             ]

      assert fixture.accepted_definition_dialects == ["$defs", "definitions"]

      assert fixture.errors.function_parameters == %{
               status: 400,
               code: "invalid_function_parameters",
               root_params: [
                 "tools.0.parameters",
                 "tools.0.function.parameters",
                 "tools.0.tools.0.parameters"
               ]
             }

      assert fixture.preservation == %{
               non_strict_structured_output: "unchanged",
               non_strict_function_parameters: "unchanged",
               direct_responses_nested_missing_type_repair: "unchanged",
               native_backend_strict_array_root: "unchanged",
               native_backend_strict_local_root_ref: "unchanged"
             }

      assert fixture.native_backend_exclusions == [
               "/backend-api/codex/responses",
               "/backend-api/codex/v1/responses",
               "/backend-api/codex/responses websocket",
               "/backend-api/codex/v1/responses websocket"
             ]

      assert fixture.privacy == "schema_shape_only"
      refute Map.has_key?(fixture, :json)
      refute Map.has_key?(fixture, :request_body)
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

      assert feature.owner_protocol == %{
               submission: "versioned_data_only",
               callback_construction: "owner_node_only",
               incompatible_remote_owner: "reject_before_owner_lookup_or_upstream_submission",
               native_result: "existing_owner_unavailable_error",
               previsible_bridge_result: "existing_http_fallback"
             }

      assert feature.observability == %{
               format_status: "bounded_lifecycle_and_boolean_projection",
               opaque_transient_inspection: true,
               payload_disclosure: false,
               authorization_disclosure: false
             }

      assert feature.contract =~ "websocket owner submission is versioned and data-only"
      assert feature.contract =~ "callbacks are built only on the owner node"
      assert feature.contract =~ "fails before owner lookup or upstream submission"
      assert feature.contract =~ "format_status/1 and opaque transient inspection"

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
               old_owner_bridge_attach: "fail_closed_http_fallback",
               owner_submission: %{
                 protocol: "versioned_data_only",
                 callback_construction: "owner_node_only",
                 incompatible_remote_owner: "reject_before_owner_lookup_or_upstream_submission",
                 native_result: "existing_owner_unavailable_error",
                 previsible_bridge_result: "existing_http_fallback"
               },
               operator_action: "none"
             }

      assert fixture.crash_hygiene == %{
               submit_task: "catch_all_scrubbed_atom_reasons",
               payload_in_crash_logs: false,
               authorization_in_crash_logs: false,
               format_status: "bounded_lifecycle_and_boolean_projection",
               opaque_transient_inspection: true
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

  defp native_websocket_compaction_bridge_contract do
    %{
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
        request_transport: "http_compact_json",
        attempt_transport: "http_compact_json"
      },
      result_transports: %{
        buffered: "responses_json",
        v2: "responses_sse_semantic_nested_implementation_with_additive_metadata"
      },
      turn_state: %{
        source: "client_metadata.x-codex-turn-state_or_upgrade_header",
        forwarded_header: "x-codex-turn-state",
        persistence: "hashed_alias_only"
      },
      native_frames: ["response.output_item.done", "response.completed"],
      errors: %{
        malformed_trigger: "pre_dispatch_invalid_request",
        compact_saturation: "server_is_overloaded",
        invalid_result: "invalid_compaction_response",
        provider_terminal: "invalid_compaction_response"
      },
      socket_reuse: "ordinary_follow_up_same_downstream_socket",
      collector_retry: false,
      diagnostic: %{
        request_metadata: "compaction_bridge",
        applied: true,
        result_transport: ["buffered", "sse"],
        raw_payload_or_frame: false
      }
    }
  end

  defp function_call_output_contract do
    %{
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
  end

  defp responses_allowed_tools_routes do
    [
      %{method: :post, path: "/v1/responses"},
      %{method: :get, path: "/v1/responses", transport: "websocket"}
    ]
  end

  defp responses_allowed_tools_summary do
    "direct public Responses HTTP and websocket response.create accept an exact type=allowed_tools choice only in Full mode, with mode auto or required and a nonempty ordered tools list; named function and custom entries must resolve to undeferred direct top-level same-kind declarations, while type-only programmatic_tool_calling, web_search_preview, web_search, and image_generation entries require a declared top-level tool of the same type; order and duplicates are forwarded unchanged after only the existing tool-definition schema lowering; malformed or undeclared Full choices fail before admission or accounting, valid Lite choices create one rejected Request without Attempts or Ledger rows, top-level MCP declarations retain the tools error while MCP allow-list members use the tool_choice error, and Chat, native backend Responses, namespaces, additional_tools, deferred tools, aliases, unsupported entries, Realtime, and broad OpenAI tool parity remain excluded"
  end

  defp responses_allowed_tools_contract do
    %{
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
    }
  end
end
