defmodule CodexPoolerWeb.Runtime.CompatibilityContractTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle

  @expected_features ~w(
    files
    backend_transcription
    backend_image_proxy_surface
    backend_models_etag
    backend_responses_etag
    pool_model_serving_modes
    backend_responses_envelope
    upstream_error_param
    rejection_metadata
    backend_fast_service_tier
    responses_chat
    response_body_cap
    backend_v1_alias_surface
    websocket_continuity
    reasoning_minimal
    reasoning_none
    reasoning_ultra
    api_key_reasoning_availability
    reasoning_context
    unsupported_upstream_fields
    firewall
    pruned_runtime_helper_firewall
    decompression
    bulkheads
    degraded_routing
    strict_schema_validation
    unsupported_input_image_reference
    first_event_stream_retry
    request_compression
    upstream_websocket_bridge
    image_generation_permission
    responses_executable_custom_tools
    backend_agent_v2_handoffs
    multi_agent_product_certification
    function_tool_schema_lowering
    direct_responses_strict_schema_repair
    v1_supported_surface
    v1_unsupported_public_surface
  )a

  setup do
    old_config = Application.get_env(:codex_pooler, Files, [])

    Application.put_env(:codex_pooler, Files,
      max_file_size_bytes: 64,
      file_ttl_seconds: 60
    )

    on_exit(fn -> Application.put_env(:codex_pooler, Files, old_config) end)

    :ok
  end

  describe "compatibility matrix" do
    test "lists every in-scope Codex compatibility feature with sanitized fixtures" do
      assert CompatibilityMatrix.feature_slugs() == @expected_features

      for feature <- CompatibilityMatrix.features() do
        assert feature.status == :supported
        assert feature.current
        assert is_binary(feature.contract)
        assert feature.categories != []
        assert CompatibilityMatrix.fixture!(feature.fixture)
      end
    end

    test "covers baseline regression categories for later task promotion" do
      covered_categories =
        CompatibilityMatrix.features()
        |> Enum.flat_map(& &1.categories)
        |> Enum.uniq()
        |> Enum.sort()

      assert covered_categories == Enum.sort(CompatibilityMatrix.required_categories())
    end

    test "has no pending compatibility gaps" do
      assert CompatibilityMatrix.pending_gaps() == []
    end

    test "documents the pruned runtime helper firewall matrix" do
      feature = CompatibilityMatrix.by_slug!(:pruned_runtime_helper_firewall)
      fixture = CompatibilityMatrix.fixture!(:pruned_runtime_helper_firewall)

      assert feature.current == :firewall_before_fixed_absence
      assert feature.categories == [:route, :error]
      assert feature.routes == []

      assert %{method: :post, path: "/backend-api/codex/analytics-events/events"} in fixture.routes

      assert fixture.disabled == %{
               status: 404,
               content_type: "text/html; charset=utf-8",
               body: "Not Found"
             }

      assert fixture.admitted == fixture.disabled
      assert fixture.denied == %{status: 403, error_code: "access_denied"}

      assert fixture.settings_unavailable == %{
               status: 503,
               error_code: "settings_unavailable"
             }

      assert Map.take(fixture, [
               :authentication,
               :body_read,
               :upstream_dispatch,
               :reservation,
               :accounting,
               :denial_observation
             ]) == %{
               authentication: :not_attempted,
               body_read: false,
               upstream_dispatch: false,
               reservation: false,
               accounting: false,
               denial_observation: :exactly_one_bounded_event
             }
    end

    test "characterizes structured firewall and image permission seams" do
      firewall = CompatibilityMatrix.by_slug!(:firewall)
      firewall_fixture = CompatibilityMatrix.fixture!(:firewall)
      image_permission = CompatibilityMatrix.by_slug!(:image_generation_permission)
      image_fixture = CompatibilityMatrix.fixture!(:image_generation_permission)

      assert firewall.routes == [
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
               %{
                 family: :public_v1,
                 method: :get,
                 path: "/v1/responses",
                 transport: :websocket
               },
               %{family: :mcp, method: :post, path: "/mcp"}
             ]

      assert Map.take(firewall_fixture, [
               :protected_route_families,
               :canonical_path,
               :allowlist
             ]) == %{
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
               allowlist: %{empty: :disabled}
             }

      forwarded_client_ip = firewall_fixture.forwarded_client_ip

      assert Map.take(forwarded_client_ip, [
               :sources,
               :default_source,
               :default_proxy_depth,
               :source_depths,
               :trusted_peer_required_for_x_forwarded_for,
               :trusted_peer_required_for_x_real_ip,
               :selected_source_fallback,
               :xff_duplicate_fields,
               :x_real_ip_fields,
               :positional_depth,
               :max_hops,
               :max_entry_bytes,
               :accepted_ports,
               :nonruntime_client_ip,
               :strict_ip_cidr
             ]) == %{
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
             }

      assert firewall.current == :explicit_forwarded_client_policy

      assert Map.take(firewall_fixture, [
               :allowlist,
               :cold_settings,
               :warm_settings,
               :revoked_websocket,
               :denial_telemetry
             ]) == %{
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
             }

      assert image_permission.routes == [
               %{method: :post, path: "/backend-api/codex/images/generations"},
               %{method: :post, path: "/backend-api/codex/images/edits"},
               %{method: :post, path: "/v1/images/generations"},
               %{method: :post, path: "/v1/images/edits"}
             ]

      assert Map.take(image_fixture, [
               :controller_actions,
               :authoritative_gateway,
               :enforcement
             ]) == %{
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
             }
    end

    test "locks Pool-model serving modes as a machine-readable runtime contract" do
      feature = CompatibilityMatrix.by_slug!(:pool_model_serving_modes)
      fixture = CompatibilityMatrix.fixture!(:pool_model_serving_modes)

      assert feature.current == :pool_model_pair_request_or_turn_snapshot

      assert feature.routes == [
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
             ]

      assert fixture.persistence == %{
               scope: :pool_model_pair,
               shared_store: :postgres,
               persisted_modes: [:lite, :full],
               auto_representation: :row_absence,
               canonical_model_id: true,
               survives_catalog_churn: true,
               client_visible_model_ids: 1
             }

      assert fixture.auto_truth_table == %{
               any_routable_source_literal_true: :lite,
               all_routable_source_values_false_missing_or_malformed: :full,
               source_map_present_ignores_legacy_aggregate: true,
               absent_or_non_map_source_map_with_legacy_aggregate_literal_true: :lite,
               absent_or_non_map_source_map_with_other_aggregate_value: :full,
               zero_routable_sources: :no_runtime_model
             }

      assert fixture.snapshot_lifetime == %{
               http: :request,
               websocket: :response_create_turn,
               retry: :preserve,
               cross_assignment_failover: :preserve,
               owner_forwarding: :preserve,
               next_websocket_turn: :reresolve
             }

      assert fixture.catalog_etag == %{
               backend_field: "use_responses_lite",
               backend_value: :effective_boolean,
               digest_scope: :final_policy_visible_body,
               public_v1_models: :unchanged
             }

      assert fixture.accounting == %{
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
             }

      assert fixture.compact == %{
               backend_uses_snapshot: true,
               backend_transforms_payload: true,
               public_path: "/v1/responses/compact",
               public_status: 404,
               public_error_code: "unsupported_endpoint",
               public_upstream_dispatch: false
             }

      assert fixture.public_v1_exclusions == %{
               models_mode_fields: false,
               models_body_changed: false,
               compact_supported: false
             }

      assert fixture.assignment_eligibility == %{
               use_responses_lite_candidate_filter: false,
               membership_contract: :unchanged
             }

      assert fixture.configuration == %{
               client_api_key: :unchanged,
               client_model_id: :unchanged,
               client_configuration: :unchanged,
               global_env_switch: false,
               helm_value: false
             }

      assert fixture.full_rejection_diagnostic == %{
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
    end

    test "documents bounded non-streaming upstream response body behavior" do
      feature = CompatibilityMatrix.by_slug!(:response_body_cap)
      fixture = CompatibilityMatrix.fixture!(:response_body_cap)

      assert feature.current == :bounded_non_streaming_upstream_body
      assert :degraded in feature.categories
      assert feature.contract =~ "bounded reader"
      assert feature.contract =~ "upstream_response_too_large"
      assert feature.contract =~ "do not retain oversized body bytes"
      assert feature.contract =~ "streaming routes on their existing stream-buffer guards"

      assert fixture == %{
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
             }
    end

    @tag :external_issues_229_231
    test "documents catalog capacity, envelope, and safe error diagnostics as separate contracts" do
      models_etag = CompatibilityMatrix.by_slug!(:backend_models_etag)
      responses_etag = CompatibilityMatrix.by_slug!(:backend_responses_etag)
      envelope = CompatibilityMatrix.by_slug!(:backend_responses_envelope)
      error_param = CompatibilityMatrix.by_slug!(:upstream_error_param)

      assert models_etag.contract =~ "policy-visible effective catalog body"
      assert models_etag.contract =~ "eventual"

      assert models_etag.canonical_partition.new_turn_capacity == %{
               backend_codex_catalog_driven: "selected_partition_only",
               translated_openai_responses: "all_valid_canonical_assignments"
             }

      assert models_etag.canonical_partition.shell_type == %{
               equivalent_known_values: ["default", "local", "shell_command", "unified_exec"],
               digest_value: "shell_command",
               disabled: "separate_partition",
               non_collapsing_values: ["unknown", "missing", "malformed"]
             }

      assert models_etag.canonical_partition.quota_routing == %{
               snapshot: "one_shared_candidate_identity_snapshot",
               classification: "independent_per_model",
               input: "quota_evidence_only"
             }

      assert models_etag.canonical_partition.pinned_continuation == %{
               valid_canonical_hard_pin: "may_cross_partition",
               malformed_or_retired_source: "unavailable"
             }

      assert models_etag.contract =~
               "backend Codex catalog-driven new turns use the selected partition"

      assert models_etag.contract =~
               "translated OpenAI Responses capacity includes all valid canonical assignments"

      assert models_etag.contract =~
               "unknown, missing, or malformed values do not silently collapse"

      assert models_etag.contract =~ "classifies it independently per model"

      assert responses_etag.contract =~ "exact authenticated backend models ETag"
      assert responses_etag.contract =~ "backward-compatible connection-opening value"
      assert responses_etag.contract =~ "authoritative codex.response.metadata"
      assert responses_etag.contract =~ "current predispatch snapshot"
      assert responses_etag.contract =~ "never relayed from upstream"

      assert CompatibilityMatrix.fixture!(:backend_responses_etag) == %{
               header: "x-models-etag",
               equals: "authenticated_backend_models_etag",
               http_json: :excluded,
               http_sse: %{surface: :response_header, authority: :request_snapshot},
               websocket: %{
                 upgrade: %{
                   surface: :response_header,
                   authority: :backward_compatible_connection_open
                 },
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
             }

      assert envelope.contract =~ "exactly one reasoning.encrypted_content include"
      assert envelope.contract =~ "compact routes remain excluded"
      assert error_param.contract =~ "failed-attempt detail only"
      assert error_param.contract =~ "never raw upstream error messages or values"
    end

    test "documents reject versus strip behavior for unsupported OpenAI controls" do
      responses_chat = CompatibilityMatrix.by_slug!(:responses_chat)
      unsupported_upstream_fields = CompatibilityMatrix.by_slug!(:unsupported_upstream_fields)

      assert responses_chat.contract =~ "SDK-control rejection"
      assert unsupported_upstream_fields.current == :rejected_or_stripped_by_scope
      assert unsupported_upstream_fields.contract =~ "rejects known SDK request controls"

      assert unsupported_upstream_fields.contract =~
               "strips backend-only upstream-unsupported controls"
    end

    test "characterizes accepted public prompt cache controls" do
      fixture = CompatibilityMatrix.fixture!(:responses_chat)

      assert fixture.upstream_prompt_cache_controls.request_options_field ==
               "prompt_cache_options"

      assert fixture.upstream_prompt_cache_controls.content_breakpoint_field ==
               "prompt_cache_breakpoint"

      assert fixture.upstream_prompt_cache_controls.breakpoint_mode == "explicit"
      assert fixture.prompt_cache_routing.typed_input == "prompt_cache_key"
    end

    test "documents upstream prompt cache controls separately from Pool affinity" do
      feature = CompatibilityMatrix.by_slug!(:responses_chat)
      fixture = CompatibilityMatrix.fixture!(:responses_chat)

      assert feature.contract =~ "accept prompt_cache_options"
      assert feature.contract =~ "account-backed egress omits both explicit controls"
      assert feature.contract =~ "Pool affinity remains exclusively keyed by prompt_cache_key"

      assert fixture.upstream_prompt_cache_controls == %{
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
             }

      assert fixture.prompt_cache_routing.typed_input == "prompt_cache_key"
    end

    test "documents OpenAI reasoning context literal support" do
      feature = CompatibilityMatrix.by_slug!(:reasoning_context)
      fixture = CompatibilityMatrix.fixture!(:reasoning_context)

      assert feature.status == :supported
      assert feature.current == :openai_sdk_literal_normalization
      assert feature.routes == [%{method: :post, path: "/v1/responses"}]
      assert feature.contract =~ "reasoning.context"
      assert feature.contract =~ "auto"
      assert feature.contract =~ "current_turn"
      assert feature.contract =~ "all_turns"
      assert feature.contract =~ "trimming and lowercasing"
      assert feature.contract =~ "rejects unknown or non-string"

      assert fixture.accepted_values == ["auto", "current_turn", "all_turns"]
      assert fixture.normalization == "trim_and_lowercase"

      assert fixture.rejected_values == [
               "unknown_strings",
               "empty_strings",
               "non_strings",
               "arrays",
               "maps"
             ]

      assert fixture.routes == ["/v1/responses"]
    end

    test "documents input image scheme policy" do
      feature = CompatibilityMatrix.by_slug!(:unsupported_input_image_reference)
      fixture = CompatibilityMatrix.fixture!(:unsupported_input_image_reference)

      assert feature.contract =~ "input_image.file_id"
      assert feature.contract =~ "Codex sediment://"
      assert feature.contract =~ "unsupported URL schemes"

      assert fixture.accepted_url_schemes == ["https", "data:image"]
      assert fixture.unsupported_url_schemes == ["http", "sediment", "file"]
    end

    test "documents non-strict function tool schema lowering scope" do
      feature = CompatibilityMatrix.by_slug!(:function_tool_schema_lowering)
      fixture = CompatibilityMatrix.fixture!(:function_tool_schema_lowering)

      assert feature.status == :supported
      assert feature.current == :non_strict_function_tool_schema_lowering
      assert :streaming in feature.categories
      assert feature.contract =~ "non-strict function tool schemas"
      assert feature.contract =~ "before local validation"
      assert feature.contract =~ "nested namespace function tools"
      assert feature.contract =~ "never weakens strict function tools"
      assert feature.contract =~ "strict structured-output schemas"
      refute feature.contract =~ "hosted tools"

      assert fixture.lowered_tool_types == [
               "flat_function",
               "nested_function",
               "namespace_nested_function"
             ]

      assert fixture.strict_function_tools_lowered == false
      assert fixture.strict_structured_outputs_lowered == false
      assert "$schema" in fixture.unsupported_json_schema_keywords_dropped
      assert "$ref" in fixture.supported_schema_keywords_preserved
      assert "const_to_single_value_enum" in fixture.schema_repairs

      assert fixture.routes == [
               "/backend-api/codex/responses",
               "/backend-api/codex/v1/responses",
               "/backend-api/codex/responses websocket",
               "/backend-api/codex/v1/responses websocket",
               "/v1/responses",
               "/v1/responses websocket"
             ]
    end

    test "documents canonical encrypted agent v2 websocket handoffs" do
      feature = CompatibilityMatrix.by_slug!(:backend_agent_v2_handoffs)
      fixture = CompatibilityMatrix.fixture!(:backend_agent_v2_handoffs)

      assert feature.current == :canonical_encrypted_agent_handoff_preservation
      assert feature.contract =~ "NEW_TASK and MESSAGE"
      assert feature.contract =~ "/morpheus or /root paths"
      assert feature.contract =~ "task name and sender exactly match recipient and author"
      assert feature.contract =~ "durable request or attempt metadata never stores"

      assert feature.routes == [
               %{
                 method: :get,
                 path: "/backend-api/codex/responses",
                 transport: "websocket"
               },
               %{
                 method: :get,
                 path: "/backend-api/codex/v1/responses",
                 transport: "websocket"
               }
             ]

      assert fixture.preserved_message_types == ["NEW_TASK", "MESSAGE"]
      assert fixture.content_shape == ["input_text", "encrypted_content"]
      assert fixture.protocol_bindings == %{task_name: "recipient", sender: "author"}
      assert fixture.other_encrypted_agent_messages == "removed"
      assert fixture.durable_metadata == "encrypted_content_omitted"
    end

    test "pins Full-mode multi-agent certification and staged external disposition" do
      feature = CompatibilityMatrix.by_slug!(:multi_agent_product_certification)
      fixture = CompatibilityMatrix.fixture!(:multi_agent_product_certification)

      assert feature.current == :pinned_full_mode_v1_v2_stage_classification
      assert feature.contract =~ "gpt-5.5 resolves v1 through feature fallback"
      assert feature.contract =~ "gpt-5.6-terra resolves v2"
      assert feature.contract =~ "instruction_observation_missing"
      assert feature.contract =~ "without a production transport change"

      assert fixture.source_pin == "c9c6c0daa994109cec50fddcb57d076fdf9e738c"
      assert fixture.primary_serving_mode == "full"
      assert fixture.preflight.catalog_use_responses_lite == false
      assert fixture.preflight.http_lite_header_present == false
      assert fixture.preflight.websocket_lite_metadata_present == false

      assert fixture.protocol_matrix.v1 == %{
               model: "gpt-5.5",
               selection: "feature_fallback",
               multi_agent: true,
               multi_agent_v2: false
             }

      assert fixture.protocol_matrix.v2 == %{
               model: "gpt-5.6-terra",
               selection: "feature_override",
               multi_agent_v2: true
             }

      assert fixture.protocol_matrix.same_model_causal_pair == ["v2", "direct_control"]
      assert fixture.live_text_disposition.pooler_delivery == "present"
      assert fixture.live_text_disposition.first_failing_stage == "codex_app_server_boundary"
      assert fixture.live_text_disposition.production_transport_change == "none"

      assert fixture.done_claim_disposition == %{
               v2_exact_instruction: "instruction_observation_missing",
               reason: "opaque_encrypted_arguments_without_permitted_external_resolution_source",
               downstream_stages: "not_attributed_past_first_missing_observation"
             }

      assert fixture.implemented_runtime_outcomes.overload == %{
               public_status: 503,
               wire_code: "server_is_overloaded",
               internal_reasons: ["bulkhead_rejected", "bulkhead_queue_timeout"]
             }

      assert fixture.implemented_runtime_outcomes.compact_projection.preserves == [
               "model",
               "input",
               "instructions",
               "tools",
               "parallel_tool_calls",
               "reasoning",
               "service_tier",
               "prompt_cache_key",
               "text"
             ]

      assert fixture.implemented_runtime_outcomes.public_v1 == %{
               unknown_typed_input: "reject_before_dispatch",
               nested_tool_search: "reject_before_dispatch",
               encrypted_function_args: "validated_and_round_tripped"
             }

      assert fixture.implemented_runtime_outcomes.routing_hint ==
               "trusted_native_effective_model_and_service_tier_only"

      assert fixture.implemented_runtime_outcomes.schema_bound_function_output_compression ==
               "byte_exact_json_preserved"

      assert fixture.implemented_runtime_outcomes.responses_lite_full.auto_source ==
               "health_level_aggregate"

      assert fixture.deployment_certification == "exact_tested_commit_sha_required"
      assert fixture.reporting == "metadata_only"
      refute fixture.metrics_added
      refute fixture.runtime_config_added
      refute fixture.dashboards_changed
      refute fixture.helm_changed
    end

    test "documents executable custom tools separately from custom replay" do
      feature = CompatibilityMatrix.by_slug!(:responses_executable_custom_tools)
      fixture = CompatibilityMatrix.fixture!(:responses_executable_custom_tools)

      assert feature.current == :responses_and_chat_custom_tool_admission

      assert feature.routes == [
               %{method: :post, path: "/v1/responses"},
               %{method: :get, path: "/v1/responses", transport: "websocket"},
               %{method: :post, path: "/v1/chat/completions"}
             ]

      assert fixture.scope == "direct_public_responses_and_translated_chat"
      assert fixture.formats == ["omitted", "text", "grammar_lark", "grammar_regex"]
      assert fixture.allowed_callers_null == true

      assert fixture.nested_definitions == %{
               container: "namespace",
               transports: ["http", "websocket_response_create"],
               public_scope: "direct_public_responses",
               full_mode: "preserved",
               typed_choice_scope: "namespace_nested_custom"
             }

      assert fixture.typed_choice.resolves_same_kind == true
      assert fixture.typed_choice.full_mode == "preserved"
      assert fixture.typed_choice.lite_mode == "rejected_unsupported_parameter_before_dispatch"

      assert fixture.response_namespace_restoration == %{
               transports: ["http", "sse", "websocket_direct", "websocket_owner_forwarded"],
               when:
                 "missing_or_null_provider_namespace_with_one_exact_namespaced_custom_declaration",
               preserves: "explicit_provider_namespace",
               unchanged: ["flat", "unknown", "non_unique"]
             }

      assert fixture.executable_name_collision_scope == [
               "flat_function",
               "namespace_nested_function",
               "namespace_nested_custom",
               "custom"
             ]

      assert fixture.custom_replay_contract == "separate_input_item_shape"
      assert fixture.chat_supported == true
      assert fixture.chat.streamed_input == "free_form_fragments_not_json_parsed"
      assert fixture.provider_availability == "selected_model_and_account_dependent"
      assert fixture.broad_openai_tool_parity == false
    end

    test "locks the namespace custom contract and its provenance boundaries" do
      namespace_tool = CompatibilityMatrix.fixture!(:responses_chat).namespace_tool

      expected_namespace_tool = %{
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
      }

      assert namespace_tool == expected_namespace_tool

      stale_function_only_expected_namespace_tool =
        Map.put(expected_namespace_tool, :nested_tool_types, ["function"])

      refute namespace_tool == stale_function_only_expected_namespace_tool

      assert %{
               source: "OpenAI Python `openai`",
               version: "`2.52.0`",
               decision: "accept",
               observed_shape:
                 "Custom tool requires `type=custom` and nonblank `name`; optional description, boolean `defer_loading`, nullable direct/programmatic `allowed_callers`, and omitted/text/lark/regex format; typed choice has exact `type` and `name`"
             } = sdk_shape_row!("openai-python.responses.executable_custom_tool.v1")

      assert %{
               source: "OpenAI Node `openai`",
               version: "commit `6fa9152eb97b7a36e3c555fbdeaaa241423ae91e`",
               endpoint: "`POST /v1/chat/completions`",
               decision: "translate",
               observed_shape:
                 "Request tools use exact outer `type=custom` and nested `custom` with required nonblank `name` plus optional `description` and `format`; named choice nests the custom name; output calls use `type=custom` with nested `custom.name` and free-form `custom.input`"
             } = sdk_shape_row!("openai-node.chat.custom_tool.v1")

      assert %{
               source: "Vercel OpenAI provider `@ai-sdk/openai`",
               version: "`3.0.65+`",
               decision: "accept",
               observed_shape:
                 "Top-level `tools` entry has `type=namespace`, nonblank `name`, nonblank `description`, and nested function tools with flat `type`, `name`, `description`, `parameters`, optional `strict`, and optional `defer_loading`"
             } = sdk_shape_row!("vercel-ai-sdk-openai.responses.namespace_function_tool.v1")

      assert sdk_shape_row!("codex.responses.namespace_custom_tool.v1") == %{
               source: "Codex native Responses shape",
               version:
                 "Codex commits `f21dc4638803f40046c9e294b0349782928f6b36` and `d4fb78bfc59009a2bbc3245d125bf8ba92a8e33e`",
               endpoint:
                 "`POST /v1/responses` and `GET /v1/responses` websocket `response.create`",
               decision: "accept",
               observed_shape:
                 "Top-level `tools` entry has exact `type=namespace`, nonblank `name` and `description`, and a nonempty `tools` list whose children are exact flat `function` or exact executable `custom` definitions; typed custom choice has exact `type` and `name`",
               notes:
                 "Direct public Responses HTTP and websocket preserve valid namespace custom definitions and exact typed custom choices in Full mode. HTTP, SSE, direct websocket, and owner-forwarded websocket output restore a missing or null custom_tool_call namespace only when one exact namespaced custom declaration matches, while explicit, flat, unknown, and non-unique namespaces remain unchanged. Lite keeps the existing pre-dispatch `unsupported_parameter` rejection for map-shaped `tool_choice`; hosted/MCP/tool_search/nested namespace children, blank namespace names, malformed custom fields, and global executable-name collisions remain excluded. Chat uses a separate official nested wrapper and does not add namespace support. This Codex provenance is separate from the OpenAI Python direct-custom, OpenAI Node Chat-custom, and Vercel namespace-function rows."
             }
    end

    test "documents direct Responses strict repair separately from non-strict lowering" do
      feature = CompatibilityMatrix.by_slug!(:direct_responses_strict_schema_repair)
      fixture = CompatibilityMatrix.fixture!(:direct_responses_strict_schema_repair)

      assert feature.current == :nested_missing_type_repair
      assert feature.contract =~ "missing nested object or array type"
      assert feature.contract =~ "not repaired"
      assert feature.contract =~ "excluded from non-strict lowering"
      assert fixture.scope == "direct_public_responses_strict_flat_function_parameters"
      assert fixture.inserted_types == ["object", "array"]

      assert fixture.target_tool_shapes == [
               "top_level_flat_function",
               "namespace_child_flat_function"
             ]

      assert fixture.requires_typed_object_root == true
      assert fixture.requires_unambiguous_structural_evidence == true
      assert "parameters_root" in fixture.exclusions
      assert "combinators_and_descendants" in fixture.exclusions
      assert "chat" in fixture.exclusions
      assert "backend_routes" in fixture.exclusions
      assert fixture.malformed_duplicate_or_unsupported_explicit_type == "reject"
      assert fixture.strict_function_tools_lowered == false
      assert fixture.strict_structured_outputs_lowered == false
    end

    test "documents request compression supported input shapes" do
      feature = CompatibilityMatrix.by_slug!(:request_compression)
      fixture = CompatibilityMatrix.fixture!(:request_compression)

      assert feature.status == :supported
      assert feature.contract =~ "grouped heading matches"
      assert feature.contract =~ "portable NUL-delimited matches"
      assert feature.contract =~ "additions-only"
      assert feature.contract =~ "deletions-only"
      assert feature.contract =~ "minimal unified diffs"
      assert feature.contract =~ "combined unified diffs"
      assert feature.contract =~ "long-preamble diffs"
      assert feature.contract =~ "protected exact-output function tool outputs"
      assert feature.contract =~ "WebSearch, WebFetch, web_search, web_fetch"
      assert feature.contract =~ "external retrieval"
      assert feature.contract =~ "output-only function tool results fail closed"
      assert feature.contract =~ "valid JSON object or array spans embedded in ordinary prose"
      assert feature.contract =~ "quoted JSON-looking text"

      assert fixture.protected_tool_outputs == %{
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
             }

      assert feature.contract =~ "ordinary prose"

      assert fixture.supported_input_shapes == %{
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
               log_output: ["failure_summary_guard"]
             }
    end

    test "documents narrow chat input fallback and non-executable additional_tools" do
      responses_chat = CompatibilityMatrix.by_slug!(:responses_chat)
      responses_fixture = CompatibilityMatrix.fixture!(:responses_chat)
      v1_fixture = CompatibilityMatrix.fixture!(:v1_supported_surface)

      assert responses_chat.contract =~ "messages when present"
      assert responses_chat.contract =~ "top-level input only when messages is absent or empty"

      assert responses_chat.contract =~
               "omitted fallback instructions defaulting to a blank string"

      assert responses_chat.contract =~ "request-shaped additional_tools input items"
      assert responses_chat.contract =~ "non-executable input"
      assert responses_chat.contract =~ "never merged into executable tools"
      assert responses_chat.contract =~ "never used to satisfy tool_choice"
      assert responses_chat.contract =~ "truncation accepts auto and disabled locally"
      assert responses_chat.contract =~ "remote MCP tool definitions"
      assert responses_chat.contract =~ "additional_tools.tools"
      assert responses_chat.contract =~ "not forwarded upstream"
      refute responses_chat.contract =~ "web_search hosted tool shapes"
      refute responses_chat.contract =~ "web_search_preview remains type-only"

      assert responses_chat.contract =~
               "Hermes assistant replay may include safe assistant status metadata"

      assert responses_chat.contract =~
               "OpenClaw assistant replay drops thinking metadata and normalizes text"

      refute responses_chat.contract =~ "Responses-to-chat parity"
      refute responses_chat.contract =~ "top-level additional_tools"

      expected_chat_fallback = %{
        messages_precedence: "non_empty_messages",
        fallback_when: ["messages_absent", "messages_empty"],
        fallback_source: "input",
        default_instructions: "blank_string"
      }

      expected_additional_tools = %{
        shape: "request_input_item",
        required: ["type", "role", "tools"],
        optional: ["id"],
        role: "developer",
        executable: false,
        merges_into_tools: false,
        satisfies_tool_choice: false,
        unsupported_nested_tool_types: ["mcp", "tool_search"]
      }

      expected_remote_mcp_tools = %{
        supported: false,
        locations: ["tools", "input.additional_tools.tools"],
        error_code: "invalid_request",
        dispatch: false
      }

      expected_responses_builtin_tools = %{
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
      }

      assert responses_fixture.chat_input_fallback == expected_chat_fallback
      assert v1_fixture.chat_input_fallback == expected_chat_fallback
      assert responses_fixture.additional_tools_input_item == expected_additional_tools
      assert v1_fixture.additional_tools_input_item == expected_additional_tools
      assert responses_fixture.remote_mcp_tools == expected_remote_mcp_tools
      assert v1_fixture.remote_mcp_tools == expected_remote_mcp_tools

      assert responses_fixture.responses_truncation == %{
               accepted_values: ["auto", "disabled"],
               forwarded_upstream: false
             }

      assert v1_fixture.responses_truncation == responses_fixture.responses_truncation
      refute Map.has_key?(responses_fixture, :responses_builtin_tools)
      assert v1_fixture.responses_builtin_tools == expected_responses_builtin_tools
    end

    test "documents closed-world Responses programmatic-tool calling" do
      feature = CompatibilityMatrix.by_slug!(:responses_chat)
      fixture = CompatibilityMatrix.fixture!(:responses_chat)

      assert feature.programmatic_tool_calling_contract =~ "closed-world"
      assert feature.programmatic_tool_calling_contract =~ "remote MCP"
      assert feature.programmatic_tool_calling_contract =~ "unrelated hosted tools"
      assert feature.programmatic_tool_calling_contract =~ "no full OpenAI parity claim"

      programmatic = fixture.programmatic_tool_calling

      assert programmatic.input_items.program.required == [
               "type",
               "id",
               "call_id",
               "code",
               "fingerprint"
             ]

      assert programmatic.input_items.program.exact_keys == true

      assert programmatic.input_items.program_output.required == [
               "type",
               "id",
               "call_id",
               "result",
               "status"
             ]

      assert programmatic.input_items.program_output.exact_keys == true
      assert programmatic.input_items.program_output.statuses == ["completed", "incomplete"]

      for caller <- [
            programmatic.input_items.function_call.caller,
            programmatic.input_items.function_call_output.caller
          ] do
        assert caller.types == ["direct", "program"]
        assert caller.program_requires == ["caller_id"]
        assert caller.direct_forbids == ["caller_id"]
      end

      assert programmatic.hosted_tool.type == "programmatic_tool_calling"
      assert programmatic.hosted_tool.exact_keys == ["type"]
      assert programmatic.tool_choice.type == "programmatic_tool_calling"
      assert programmatic.tool_choice.exact_keys == ["type"]
      assert programmatic.function_options.scopes == ["flat", "namespace"]
      assert programmatic.function_options.optional_boolean_keys == ["strict", "defer_loading"]
      assert programmatic.function_options.allowed_callers == ["direct", "programmatic"]
      assert programmatic.function_options.output_schema.shape == "opaque_json_map"
      assert programmatic.function_options.output_schema.strict == false
      assert programmatic.stateless_policy.vercel_store == false
      assert programmatic.stateless_policy.upstream_stream == true
      assert programmatic.stateless_policy.upstream_store == false
      assert programmatic.stateless_policy.reference_only_continuation == "reject"
      assert programmatic.stateless_policy.ordinary_continuation == "reject"
      assert programmatic.stateless_policy.semantic_tool_result_continuation == "accept"

      assert programmatic.relay_surfaces == [
               "collected_json",
               "public_sse",
               "public_responses_websocket"
             ]

      assert programmatic.compression.program_output_candidate == false
      assert programmatic.compression.program_output_rewrite == false
      assert programmatic.privacy.mode == "metadata_only"
      assert programmatic.privacy.stored_program_code == false
      assert programmatic.privacy.stored_program_results == false
      assert programmatic.privacy.stored_schema_values == false
      assert programmatic.privacy.stored_identifiers == false
      assert programmatic.privacy.stored_prompts == false
      assert programmatic.privacy.stored_frames == false
      assert programmatic.exclusions.remote_mcp == false
      assert programmatic.exclusions.unrelated_hosted_tools == false
      assert programmatic.exclusions.full_openai_parity == false
    end

    @tag :input_audio_backport
    test "documents bounded five-format input audio compatibility" do
      feature = CompatibilityMatrix.by_slug!(:responses_chat)
      fixture = CompatibilityMatrix.fixture!(:responses_chat)

      assert feature.routes == [
               %{method: :post, path: "/backend-api/codex/responses"},
               %{method: :post, path: "/v1/responses"},
               %{method: :post, path: "/v1/chat/completions"}
             ]

      assert fixture.routes == ["/v1/responses", "/v1/chat/completions"]

      assert fixture.public_format_to_mime == %{
               "wav" => "audio/wav",
               "mp3" => "audio/mpeg",
               "m4a" => "audio/mp4",
               "webm" => "audio/webm",
               "ogg" => "audio/ogg"
             }

      assert fixture.decoded_max_bytes == 52_428_800
      assert fixture.encoded_non_whitespace_max_bytes == 69_905_068

      assert fixture.backend_audio_shape == %{
               type: "input_audio",
               field: "audio_url",
               value: "data:<canonical-mime>;base64,<canonical-data>"
             }

      assert fixture.accepted_ascii_whitespace == %{
               byte_values: [9, 10, 13, 32],
               ignored_during_decode: true,
               ignored_for_encoded_limit: true,
               canonical_reencoding: "no_ascii_whitespace"
             }

      assert fixture.failure_behavior == %{
               rejected_inputs: [
                 "malformed_base64",
                 "empty_data",
                 "unsupported_format",
                 "oversized_decoded_data"
               ],
               response: %{status: 400, code: "invalid_request", param: "input"},
               upstream_dispatch: false,
               accounting_rows: false
             }

      assert fixture.ingress_envelope_precedence == %{
               evaluation_order: ["configured_request_envelope", "audio_adapter"],
               may_reject_before_adapter: true,
               exact_decoded_limit_scope: "adapter_boundary"
             }

      assert fixture.privacy == %{
               mode: "metadata_only",
               raw_audio_persisted: false,
               raw_base64_logged: false,
               raw_data_url_exposed: false,
               safe_summary_fields: ["type", "canonical_mime", "decoded_bytes", "sha256"]
             }
    end

    test "documents compaction trigger bridge and context-overflow recovery boundary" do
      responses_chat = CompatibilityMatrix.by_slug!(:responses_chat)
      fixture = CompatibilityMatrix.fixture!(:responses_chat)

      assert responses_chat.contract =~ "terminal compaction_trigger backend payloads bridge"
      assert responses_chat.contract =~ "V2 endpoint at /backend-api/codex/responses"
      assert responses_chat.contract =~ "preserves only schema-backed string replay identity"
      assert responses_chat.contract =~ "drops other compact-result fields"
      assert responses_chat.contract =~ "malformed trigger placement is rejected before dispatch"

      assert responses_chat.contract =~
               "public /v1 Responses accepts encrypted compaction output replay items"

      assert responses_chat.contract =~ "backend regular HTTP Responses and compact routes"
      assert responses_chat.contract =~ "request-scoped x-codex-turn-state"
      assert responses_chat.contract =~ "relay upstream x-codex-turn-state response headers"
      assert responses_chat.contract =~ "x-codex-window-id"
      assert responses_chat.contract =~ "x-codex-installation-id"
      assert responses_chat.contract =~ "public /v1 and websocket request-header lanes do not"
      assert responses_chat.contract =~ "context-overflow recovery stays client/upstream-owned"
      assert responses_chat.contract =~ "no server-side hidden replay"
      assert responses_chat.contract =~ "stored prompt/frame reconstruction"

      assert fixture.store_false_policy == %{
               server_side_hidden_tools: false,
               memory_tool_injection: false,
               client_store_false_to_true_override: false
             }

      assert fixture.compaction_recovery_boundary == %{
               backend_compaction_trigger: %{
                 routes: ["/backend-api/codex/responses", "/backend-api/codex/v1/responses"],
                 behavior: "terminal_trigger_bridges_to_compact",
                 compact_endpoint: "/backend-api/codex/responses/compact",
                 upstream_endpoint: "/backend-api/codex/responses",
                 route_class: "proxy_compact",
                 transport: "http_compact_json",
                 valid_trigger: "exactly_one_final_input_item",
                 malformed_trigger: %{status: 400, param: "input", upstream_dispatch: false},
                 strips: ["stream", "include", "store"],
                 preserves: [
                   "model",
                   "instructions",
                   "input",
                   "tools",
                   "parallel_tool_calls",
                   "reasoning",
                   "service_tier",
                   "prompt_cache_key",
                   "text"
                 ],
                 output_events: ["response.output_item.done", "response.completed", "[DONE]"],
                 output_item: %{
                   "type" => "compaction",
                   "encrypted_content" => "encrypted_content",
                   "id" => "compaction_item_id",
                   "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn_id"}
                 },
                 accepted_result_shapes: [
                   %{location: "output", type: "compaction"},
                   %{location: "output", type: "compaction_summary"},
                   %{location: "top_level", key: "compaction_summary"}
                 ],
                 output_item_policy: %{
                   required: ["type", "encrypted_content"],
                   optional_string: [
                     "id",
                     "internal_chat_message_metadata_passthrough.turn_id"
                   ],
                   unknown_fields: "dropped",
                   terminal_events_share_identical_item: true
                 },
                 websocket_bridge: false,
                 hidden_replay: false
               },
               context_overflow: %{
                 recovery_owner: "client_or_upstream",
                 public_v1_compaction_replay: %{
                   route: "/v1/responses",
                   surfaces: ["http_json", "http_sse", "responses_websocket"],
                   required: %{
                     "type" => "compaction",
                     "encrypted_content" => "nonblank_string"
                   },
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
             }

      assert fixture.backend_regular_metadata_forwarding == %{
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
             }
    end

    test "documents backend websocket request-scoped turn-state carrier" do
      feature = CompatibilityMatrix.by_slug!(:websocket_continuity)
      fixture = CompatibilityMatrix.fixture!(:websocket_turn)

      assert feature.status == :supported
      assert feature.current == :persisted_session_turns
      assert feature.contract =~ "response.create.client_metadata"
      assert feature.contract =~ "per-frame request-scoped turn state"
      assert feature.contract =~ "upgrade/header value only as fallback"

      assert fixture.headers == %{"x-codex-turn-state" => "fixture-upgrade-turn-state"}

      assert fixture.response_create_client_metadata == %{
               "x-codex-turn-state" => "fixture-frame-turn-state"
             }

      assert fixture.turn_state_precedence ==
               "response.create.client_metadata_over_upgrade_header"

      assert fixture.privacy == "raw_value_not_persisted"

      assert feature.contract =~ "native websocket continuation"
      assert feature.contract =~ "reused upstream connection"
      assert feature.contract =~ "exact previous_response_not_found client retry signal"
      assert feature.contract =~ "public /v1 terminal masking and shape remain unchanged"

      assert feature.contract =~
               "a mid-stream upstream death after visible output authors exactly one native type:error frame with status 502, wire code upstream_request_failed, and the pinned message upstream request failed"

      assert feature.contract =~
               "carrying no terminal event, no sequence_number, and no socket close so the same socket serves later turns"

      assert feature.contract =~
               "every frame authored through the shared websocket error envelope carries error type invalid_request_error, defaulting independently to status 500 when its reason has no status and to wire code websocket_request_failed when its reason has no code and message"

      assert feature.contract =~
               "an unresolved previous-response alias retains the current authenticated runtime"

      assert feature.contract =~
               "successful native turns register hashed previous-response aliases independent of retained-body completeness"

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

    test "documents v1 supported surface as authenticated OpenAI compatibility" do
      feature = CompatibilityMatrix.by_slug!(:v1_supported_surface)
      fixture = CompatibilityMatrix.fixture!(:v1_supported_surface)

      assert feature.status == :supported
      assert feature.current == :authenticated_openai_compatibility
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :multipart in feature.categories
      assert :streaming in feature.categories
      assert :ownership in feature.categories

      assert Enum.any?(feature.routes, &(&1.method == :get and &1.path == "/v1/models"))
      assert Enum.any?(feature.routes, &(&1.method == :get and &1.path == "/v1/responses"))
      assert Enum.any?(feature.routes, &(&1.method == :post and &1.path == "/v1/responses"))
      assert feature.contract =~ "OpenAI-compatible /v1 routes"
      assert feature.contract =~ "narrow GET /v1/responses Responses websocket compatibility only"
      assert feature.contract =~ "exclude broad /v1/realtime routes"
      assert feature.contract =~ "POST /v1/responses/compact"
      assert feature.contract =~ "unsupported_endpoint"
      assert feature.contract =~ "no upstream compact dispatch"
      assert feature.contract =~ "documented local precedence"

      assert feature.contract =~
               "without forwarding session-id, x-session-id, or x-session-affinity"

      assert feature.contract =~ "pinned /v1/responses continuations"
      assert feature.contract =~ "restart_with_full_context recovery guidance"
      assert feature.contract =~ "accept Responses truncation auto and disabled locally"
      assert feature.contract =~ "accept Codex-native Responses web_search hosted tool shapes"
      assert feature.contract =~ "keeping web_search_preview type-only"

      assert feature.contract =~
               "emit a sanitized type:error terminal with wire code server_error while accounting records upstream_stream_error"

      assert feature.contract =~ "accounting records owner_drained"

      assert feature.contract =~
               "emitted wire frame is byte-identical to the ordinary synthetic terminal"

      assert feature.contract =~ "only when a committed websocket-bridge turn is aborted"

      assert feature.contract =~
               "keep precommit drain admission on its existing fallback or refusal path"

      assert feature.contract =~
               "keep client disconnect and non-drain interruption mappings unchanged"

      assert feature.contract =~
               "synthetic SSE terminals to OpenAI-compatible HTTP SSE surfaces"

      assert feature.contract =~
               "owner-forwarded GET /v1/responses per-call turn is interrupted after committed public output"

      assert feature.contract =~
               "preserve native backend raw Responses streams and all other websocket behavior"

      assert fixture.stream_interruption_contract == %{
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
             }

      assert get_in(CompatibilityMatrix.fixture!(:v1_supported_surface), [
               :responses_builtin_tools,
               :web_search,
               :valid_combinations
             ]) == [
               "type_only",
               "external_web_access=false",
               "external_web_access=true",
               "external_web_access=true,index_gated_web_access=true"
             ]

      assert feature.contract =~ "without forwarding it upstream"
      assert feature.contract =~ "lift Responses system/developer input-message text"
      assert feature.contract =~ "early public streaming terminal errors"

      assert feature.contract =~
               "preserves a trimmed upstream error code only when it is at most 80 bytes and matches `^[A-Za-z0-9_.-]+$`"

      assert feature.contract =~ "redacts every other code value to `upstream_error`"
      assert feature.contract =~ "including clean values — is replaced with `server_error`"
      assert feature.contract =~ "clients must treat `error.code` as an open string"

      assert feature.contract =~ "accept safe Hermes assistant replay status values"
      assert feature.contract =~ "drop known OMP function_call replay status fields"
      assert feature.contract =~ "translate OpenClaw assistant thinking replays before validation"
      assert feature.contract =~ "chat input fallback"
      assert feature.contract =~ "Responses additional_tools support narrow and non-executable"
      refute feature.contract =~ "metadata"

      assert fixture.auth == "required_bearer_api_key"
      assert fixture.default_enabled == true
      assert fixture.websocket_route == %{method: :get, path: "/v1/responses"}
      assert fixture.websocket_contract == "narrow_responses_websocket_only"

      assert fixture.unsupported_compact == %{
               method: :post,
               path: "/v1/responses/compact",
               status: 404,
               error_code: "unsupported_endpoint",
               upstream_dispatch: false
             }

      assert fixture.audio_transcription == %{
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
             }

      assert fixture.continuity_precedence == [
               "x-codex-window-id",
               "x-codex-session-id",
               "session-id",
               "x-session-id",
               "x-session-affinity",
               "session_id",
               "x-codex-conversation-id"
             ]

      assert fixture.local_continuity_headers_not_forwarded == [
               "session-id",
               "x-session-id",
               "x-session-affinity"
             ]

      assert fixture.pinned_continuation_reauth == %{
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
             }

      assert fixture.pinned_continuation_unavailable == %{
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
             }

      assert fixture.timeout_contract == %{
               route_specific_defaults_added: false,
               progress_receive_timeout_ms: 250,
               progress_interval_ms: 100,
               idle_receive_timeout_ms: 150,
               idle_silent_gap_min_ms: 250,
               idle_error_code: "stream_idle_timeout"
             }

      assert fixture.instruction_lifting == %{
               roles: ["system", "developer"],
               destination: "instructions",
               merge_order: ["existing_instructions", "input_order_instruction_text"],
               residual_non_text_role: "user",
               blank_text: "omitted",
               malformed_content: "sanitized_invalid_request"
             }

      assert fixture.early_stream_errors == %{
               responses_first_events: ["response.failed", "error"],
               responses_suppresses_synthetic_success_prefix_before_output: true,
               chat_first_chunk: "data_error_object",
               chat_omits_assistant_role_before_output: true,
               chat_omits_done_before_output: true,
               late_failures_retry: false,
               non_stream_errors: "json_error"
             }

      assert fixture.hermes_assistant_tool_call_replay.ordinary_replay_status_values == [
               "completed",
               "incomplete",
               "in_progress"
             ]

      assert fixture.openclaw_assistant_thinking_replay == %{
               input_role: "assistant",
               dropped_content_part_type: "thinking",
               normalized_content_part_type: "output_text",
               source_text_part_type: "text",
               requires_previous_response_id: false,
               metadata_only: true
             }

      assert fixture.unsupported_realtime_routes == [
               %{method: :get, path: "/v1/realtime"},
               %{method: :post, path: "/v1/realtime"}
             ]

      refute Map.has_key?(fixture, :metadata)

      assert fixture.routes |> Enum.sort() == [
               "/v1/audio/transcriptions",
               "/v1/chat/completions",
               "/v1/files",
               "/v1/images/edits",
               "/v1/images/generations",
               "/v1/models",
               "/v1/responses",
               "/v1/responses/compact",
               "/v1/usage"
             ]
    end

    test "keeps backend transcription fixture independent from v1 Audio compatibility" do
      assert CompatibilityMatrix.fixture!(:backend_transcription) == %{
               fields: %{"prompt" => "synthetic backend glossary"},
               filename: "fixture-backend-audio.wav",
               content_type: "audio/wav",
               bytes: "synthetic backend wav bytes"
             }
    end

    test "keeps broad public realtime routes outside the router surface" do
      route_set =
        CodexPoolerWeb.Router
        |> Phoenix.Router.routes()
        |> Enum.map(&{&1.verb, &1.path})
        |> MapSet.new()

      feature = CompatibilityMatrix.by_slug!(:v1_supported_surface)
      fixture = CompatibilityMatrix.fixture!(:v1_supported_surface)

      assert feature.contract =~ "exclude broad /v1/realtime routes"

      for route <- fixture.unsupported_realtime_routes do
        refute MapSet.member?(route_set, {route.method, route.path})
      end
    end

    test "keeps app-server, remote-control, and permission-profile routes outside supported surfaces" do
      route_set =
        CodexPoolerWeb.Router
        |> Phoenix.Router.routes()
        |> Enum.map(&{router_method(&1.verb), &1.path})
        |> MapSet.new()

      matrix_route_set =
        CompatibilityMatrix.features()
        |> Enum.flat_map(& &1.routes)
        |> Enum.map(&{&1.method, &1.path})
        |> MapSet.new()

      unsupported_routes = [
        %{method: :post, path: "/backend-api/codex/thread/start", family: :app_server},
        %{method: :post, path: "/backend-api/codex/thread/resume", family: :app_server},
        %{method: :post, path: "/backend-api/codex/thread/fork", family: :app_server},
        %{method: :post, path: "/backend-api/codex/turn/start", family: :app_server},
        %{method: :post, path: "/backend-api/codex/configRequirements/read", family: :app_server},
        %{method: :post, path: "/backend-api/codex/account/rateLimits/read", family: :app_server},
        %{
          method: :post,
          path: "/backend-api/codex/account/rateLimitResetCredit/consume",
          family: :app_server
        },
        %{
          method: :post,
          path: "/backend-api/codex/thread/realtime/appendSpeech",
          family: :app_server
        },
        %{
          method: :get,
          path: "/backend-api/codex/remote-control/pairing/status",
          family: :remote_control
        },
        %{
          method: :post,
          path: "/backend-api/codex/remote-control/pairing/status",
          family: :remote_control
        },
        %{
          method: :post,
          path: "/backend-api/codex/permission-profiles/validate",
          family: :permission_profile
        },
        %{method: :post, path: "/v1/remote-control/pairing/status", family: :remote_control},
        %{method: :post, path: "/v1/permission-profiles/validate", family: :permission_profile}
      ]

      assert unsupported_routes |> Enum.map(& &1.family) |> Enum.uniq() |> Enum.sort() ==
               [:app_server, :permission_profile, :remote_control]

      for route <- unsupported_routes do
        refute MapSet.member?(route_set, {route.method, route.path})
        refute MapSet.member?(matrix_route_set, {route.method, route.path})
      end
    end

    test "lists pruned helpers only in their fixed-absence firewall contract" do
      matrix_routes =
        CompatibilityMatrix.features()
        |> Enum.flat_map(& &1.routes)
        |> Enum.map(&{&1.method, &1.path})
        |> MapSet.new()

      router_routes =
        CodexPoolerWeb.Router
        |> Phoenix.Router.routes()
        |> Enum.map(&{router_method(&1.verb), &1.path})
        |> MapSet.new()

      refute :control_plane_surface in CompatibilityMatrix.feature_slugs()
      refute :backend_reset_credit_consume in CompatibilityMatrix.feature_slugs()
      refute :backend_alpha_search in CompatibilityMatrix.feature_slugs()

      pruned_routes =
        CompatibilityMatrix.fixture!(:pruned_runtime_helper_firewall)
        |> Map.fetch!(:routes)
        |> Enum.map(&{&1.method, &1.path})
        |> MapSet.new()

      for route <- pruned_routes do
        refute MapSet.member?(matrix_routes, route)
        refute MapSet.member?(router_routes, route)
      end

      refute MapSet.member?(matrix_routes, {:get, "/backend-api/codex/thread/goal/get"})
      refute MapSet.member?(router_routes, {:get, "/backend-api/codex/thread/goal/get"})
    end

    test "documents unsupported v1 public surface with exact OpenAI-shaped error contract" do
      feature = CompatibilityMatrix.by_slug!(:v1_unsupported_public_surface)
      fixture = CompatibilityMatrix.fixture!(:v1_unsupported_public_surface)

      expected_routes = [
        %{method: :post, path: "/v1/images/variations"},
        %{method: :post, path: "/v1/content_provenance_checks"},
        %{method: :post, path: "/v1/embeddings"},
        %{method: :post, path: "/v1/batches"},
        %{method: :post, path: "/v1/moderations"},
        %{method: :post, path: "/v1/fine_tuning/jobs"},
        %{method: :get, path: "/v1/responses/:response_id"},
        %{method: :post, path: "/v1/responses/:response_id/cancel"},
        %{method: :delete, path: "/v1/responses/:response_id"}
      ]

      assert feature.status == :supported
      assert feature.current == :openai_shaped_unsupported_route_contract
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :error in feature.categories
      assert feature.routes == expected_routes
      assert feature.contract =~ "deterministic OpenAI-shaped 404 errors"

      assert fixture.status == 404
      assert fixture.error_code == "unsupported_endpoint"

      assert fixture.routes == [
               %{method: :post, path: "/v1/images/variations"},
               %{method: :post, path: "/v1/content_provenance_checks"},
               %{method: :post, path: "/v1/embeddings"},
               %{method: :post, path: "/v1/batches"},
               %{method: :post, path: "/v1/moderations"},
               %{method: :post, path: "/v1/fine_tuning/jobs"},
               %{method: :get, path: "/v1/responses/resp_fixture"},
               %{method: :post, path: "/v1/responses/resp_fixture/cancel"},
               %{method: :delete, path: "/v1/responses/resp_fixture"}
             ]
    end

    test "documents backend v1 alias surface as explicit authenticated backend aliases" do
      feature = CompatibilityMatrix.by_slug!(:backend_v1_alias_surface)
      fixture = CompatibilityMatrix.fixture!(:backend_v1_alias_surface)

      assert feature.status == :supported
      assert feature.current == :explicit_authenticated_backend_alias_routes
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :streaming in feature.categories
      assert :ownership in feature.categories

      assert Enum.map(feature.routes, &{&1.method, &1.path}) == [
               {:get, "/backend-api/codex/v1/models"},
               {:get, "/backend-api/codex/v1/responses"},
               {:post, "/backend-api/codex/v1/responses"},
               {:post, "/backend-api/codex/v1/responses/compact"},
               {:post, "/backend-api/codex/v1/chat/completions"}
             ]

      assert feature.contract =~ "explicit authenticated backend routes"
      assert feature.contract =~ "chat alias fallback limited to top-level input"
      assert feature.contract =~ "messages is absent or empty"

      assert feature.contract =~
               "translated chat alias emits the nested server_error terminal after visible output"

      assert fixture.auth == "required_bearer_api_key"
      assert fixture.default_enabled == true

      assert fixture.routes == [
               "/backend-api/codex/v1/models",
               "/backend-api/codex/v1/responses",
               "/backend-api/codex/v1/responses/compact",
               "/backend-api/codex/v1/chat/completions"
             ]

      assert fixture.chat_input_fallback == %{
               messages_precedence: "non_empty_messages",
               fallback_when: ["messages_absent", "messages_empty"],
               fallback_source: "input"
             }
    end

    test "keeps prompt cache routing input limited to the exact POST route contract" do
      allowed_routes = [
        "/v1/responses",
        "/v1/chat/completions",
        "/backend-api/codex/responses",
        "/backend-api/codex/v1/responses",
        "/backend-api/codex/v1/chat/completions"
      ]

      excluded_routes = [
        {"GET", "/backend-api/codex/responses", %{transport: "websocket"}},
        {"POST", "/backend-api/codex/responses/compact", %{}},
        {"POST", "/backend-api/codex/v1/responses/compact", %{}},
        {"POST", "/v1/responses/compact", %{}},
        {"POST", "/backend-api/files", %{}},
        {"POST", "/backend-api/transcribe", %{}},
        {"POST", "/v1/audio/transcriptions", %{}},
        {"POST", "/v1/images/generations", %{}},
        {"POST", "/v1/images/edits", %{}},
        {"POST", "/backend-api/codex/images/generations", %{}},
        {"POST", "/backend-api/codex/images/edits", %{}}
      ]

      for endpoint <- allowed_routes do
        raw_prompt_cache_key = "fixture-cache-key"

        request_options =
          RequestOptions.build(%{request_method: "POST"}, endpoint, %{
            "model" => "gpt-fixture-text",
            "prompt_cache_key" => raw_prompt_cache_key
          })

        assert request_options.routing.prompt_cache_key =~ ~r/\A[0-9a-f]{64}\z/
        refute request_options.routing.prompt_cache_key == raw_prompt_cache_key
      end

      for {method, endpoint, opts} <- excluded_routes do
        request_options =
          opts
          |> Map.put(:request_method, method)
          |> RequestOptions.build(endpoint, %{
            "model" => "gpt-fixture-text",
            "prompt_cache_key" => "fixture-cache-key"
          })

        assert request_options.routing.prompt_cache_key == nil
      end
    end

    test "documents model-agnostic native image routing through eligible visible capacity" do
      feature = CompatibilityMatrix.by_slug!(:backend_image_proxy_surface)
      fixture = CompatibilityMatrix.fixture!(:backend_image_proxy_surface)

      assert feature.status == :supported
      assert feature.current == :explicit_authenticated_backend_image_proxy_routes
      assert :route in feature.categories
      assert :auth in feature.categories
      assert :error in feature.categories
      assert :ownership in feature.categories

      assert Enum.map(feature.routes, &{&1.method, &1.path}) == [
               {:post, "/backend-api/codex/images/generations"},
               {:post, "/backend-api/codex/images/edits"}
             ]

      assert feature.contract =~ "JSON proxy routes"
      assert feature.contract =~ "any policy-authorized effective image model"
      assert feature.contract =~ "genuinely absent from the Pool catalog"
      assert feature.contract =~ "eligible visible host capacity"
      assert feature.contract =~ "preserving that effective identifier exactly"
      assert feature.contract =~ "catalog-present invisible targets remain invalid"
      assert feature.contract =~ "public /v1 image translator surface"
      refute feature.contract =~ "placeholder"

      assert fixture.auth == "required_bearer_api_key"
      assert fixture.default_enabled == true
      assert fixture.route_class == "proxy_http"
      assert fixture.json["model"] == "gpt-image-2"

      assert fixture.routes == [
               "/backend-api/codex/images/generations",
               "/backend-api/codex/images/edits"
             ]
    end
  end

  defp sdk_shape_row!(id) do
    matrix_path =
      Path.expand("../../../fixtures/openai_compatibility/sdk_shapes/MATRIX.md", __DIR__)

    matrix_path
    |> File.stream!()
    |> Enum.find(&String.starts_with?(&1, "| `#{id}` |"))
    |> case do
      nil ->
        flunk("missing SDK-shape provenance row: #{id}")

      row ->
        [
          _id,
          source,
          version,
          endpoint,
          _scenario,
          observed_shape,
          decision,
          _owner,
          _code_target,
          _test_target,
          notes
        ] =
          row
          |> String.trim()
          |> String.split("|", trim: true)
          |> Enum.map(&String.trim/1)

        %{
          source: source,
          version: version,
          endpoint: endpoint,
          decision: String.trim(decision, "`"),
          observed_shape: observed_shape,
          notes: notes
        }
    end
  end

  describe "baseline route and gap contracts" do
    test "supported files contract requires API-key auth before JSON shape validation", %{
      conn: conn
    } do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/backend-api/files", %{"file_size" => 12})

      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"

      finalize_conn = post(build_conn(), "/backend-api/files/file_fixture/uploaded", %{})
      assert json_response(finalize_conn, 401)["error"]["code"] == "api_key_missing"
    end

    test "supported files contract bridges JSON create and finalize without local payload storage",
         %{
           conn: conn
         } do
      setup = active_api_key_fixture()

      upstream =
        start_upstream(
          FakeUpstream.file_protocol_success(
            file_id: "file_contract_bridge",
            file_name: "contract.txt",
            mime_type: "text/plain"
          )
        )

      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_contract_bridge",
        metadata: %{"base_url" => FakeUpstream.url(upstream)},
        access_token: "file-contract-bridge-token"
      })

      conn =
        conn
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/backend-api/files", %{
          "file_name" => "contract.txt",
          "file_size" => 13
        })

      assert %{
               "file_id" => file_id,
               "upload_url" => upload_url
             } = json_response(conn, 200)

      assert upload_url =~ "fake-upload.invalid"

      file = Repo.get_by!(FileRecord, file_id: file_id)
      assert file.metadata["source"] == "backend-api/files/upstream"
      assert file.purpose == "codex"
      refute is_nil(file.pool_upstream_assignment_id)

      finalize_conn =
        build_conn()
        |> auth(setup)
        |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

      assert %{"status" => "success", "download_url" => download_url} =
               json_response(finalize_conn, 200)

      assert download_url =~ "fake-download.invalid"

      request =
        Repo.one!(
          from request in Request,
            where: request.pool_id == ^setup.pool.id and request.endpoint == "/backend-api/files",
            order_by: [desc: request.admitted_at],
            limit: 1
        )

      assert request.status == "succeeded"
      refute inspect(request.request_metadata) =~ "contract.txt"
    end

    test "supported backend files contract rejects multipart create without local side effects",
         %{
           conn: _conn
         } do
      setup = active_api_key_fixture()
      file_count_before = Repo.aggregate(FileRecord, :count)
      request_count_before = Repo.aggregate(Request, :count)

      conn =
        Plug.Test.conn(
          "POST",
          "/backend-api/files",
          multipart_body("private-contract-name.txt", "contract body")
        )
        |> put_req_header("content-type", "multipart/form-data; boundary=#{multipart_boundary()}")
        |> auth(setup)
        |> @endpoint.call(@endpoint.init([]))

      response = json_response(conn, 400)
      assert response["error"]["code"] == "unsupported_multipart_file_create"
      refute Map.has_key?(response, "upload_url")
      refute inspect(response) =~ "private-contract-name.txt"
      assert Repo.aggregate(FileRecord, :count) == file_count_before
      assert Repo.aggregate(Request, :count) == request_count_before
    end

    test "supported responses contract records weekly probe upstream 400 as upstream error", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          {:json_error, 400,
           %{
             "error" => %{
               "code" => "invalid_request_error",
               "message" => "synthetic upstream validation failure"
             }
           }}
        )

      setup = gateway_setup(upstream, quota?: false)
      prime_weekly_probe_quota!(setup.identity)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("upstream validation secret text"),
          "stream" => true
        })

      assert response(conn, 400) == ""
      refute response(conn, 400) =~ "quota_evidence_unavailable"

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"

      assert [request] =
               Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)

      assert request.status == "failed"
      assert request.last_error_code == "upstream_status"
      assert request.response_status_code == 400

      assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) ==
               "weekly_only_probe"

      assert [attempt] =
               Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)

      assert attempt.status == "failed"
      assert attempt.network_error_code == "upstream_status"
      assert attempt.upstream_status_code == 400
      assert attempt.response_metadata["rejection_error_code"] == "invalid_request_error"
      assert attempt.response_metadata["rejection_message_present"] == true

      assert attempt.response_metadata["rejection_message_bytes"] ==
               byte_size("synthetic upstream validation failure")

      assert attempt.response_metadata["upstream_request_id"] == nil

      metadata_text = inspect({request.request_metadata, attempt.response_metadata})
      refute metadata_text =~ "upstream validation secret text"
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.upstream_token
      refute metadata_text =~ "synthetic upstream validation failure"
    end

    test "supported responses contract does not server-compact context-overflow failures", %{
      conn: conn
    } do
      upstream =
        start_upstream(
          {:json_error, 400,
           %{
             "error" => %{
               "code" => "context_length_exceeded",
               "message" => "synthetic context overflow failure"
             }
           }}
        )

      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic oversized context request"),
          "stream" => false
        })

      assert json_response(conn, 400)["error"]["code"] == "context_length_exceeded"

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"

      assert [request] =
               Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)

      assert request.status == "failed"
      assert request.last_error_code == "upstream_status"
      assert request.response_status_code == 400

      assert [attempt] =
               Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)

      assert attempt.status == "failed"
      assert attempt.network_error_code == "upstream_status"
      assert attempt.upstream_status_code == 400
      assert attempt.response_metadata["rejection_error_code"] == "context_length_exceeded"
      assert attempt.response_metadata["rejection_message_present"] == true

      assert attempt.response_metadata["rejection_message_bytes"] ==
               byte_size("synthetic context overflow failure")

      metadata_text = inspect({request.request_metadata, attempt.response_metadata})
      refute metadata_text =~ "synthetic oversized context request"
      refute metadata_text =~ "synthetic context overflow failure"
      refute metadata_text =~ "compacted"
      refute metadata_text =~ "server_side_compaction"
      refute metadata_text =~ setup.authorization
      refute metadata_text =~ setup.upstream_token
    end

    test "supported responses contract keeps safe OpenAI responses fields and strips auto controls",
         %{conn: conn} do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_tolerance_safe_fields",
            "object" => "response",
            "status" => "completed",
            "output" => [],
            "usage" => %{"input_tokens" => 4, "output_tokens" => 2, "total_tokens" => 6}
          })
        )

      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic safe field request"),
          "text" => %{"format" => %{"type" => "json_object"}},
          "store" => false,
          "include" => ["message.input_image.image_url"],
          "parallel_tool_calls" => true,
          "prompt_cache_key" => "synthetic-cache-key",
          "metadata" => %{"purpose" => "synthetic"},
          "previous_response_id" => "resp_previous_alias",
          "service_tier" => "auto"
        })

      assert %{"id" => "resp_tolerance_safe_fields"} = json_response(conn, 200)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["text"]["format"]["type"] == "json_object"
      assert captured.json["store"] == false

      assert captured.json["include"] == [
               "message.input_image.image_url",
               "reasoning.encrypted_content"
             ]

      assert captured.json["parallel_tool_calls"] == true
      assert captured.json["prompt_cache_key"] == "synthetic-cache-key"
      assert captured.json["metadata"] == %{"purpose" => "synthetic"}
      refute Map.has_key?(captured.json, "previous_response_id")
      refute Map.has_key?(captured.json, "service_tier")
    end

    test "supported backend transcription contract requires API-key auth before multipart dispatch",
         %{
           conn: conn
         } do
      upload = upload_fixture("fixture-audio.wav", "audio/wav", "synthetic wav bytes")

      conn =
        post(conn, "/backend-api/transcribe", %{
          "file" => upload,
          "prompt" => "synthetic glossary"
        })

      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
    end

    test "supported chat streaming contract keeps terminal SSE marker", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.sse_stream([%{"choices" => [%{"delta" => %{}}]}]))
      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic chat"),
          "stream" => true
        })

      assert response(conn, 200) =~ "data: [DONE]"
    end

    test "supported reasoning minimal contract rewrites minimal to low before dispatch",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_reasoning_minimal"}))
      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic reasoning request"),
          "reasoning" => %{"effort" => "minimal"}
        })

      assert %{"id" => "resp_reasoning_minimal"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["reasoning"] == %{"effort" => "low"}
    end

    test "supported reasoning none contract forwards none unchanged before dispatch",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_reasoning_none"}))
      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic reasoning request"),
          "reasoning" => %{"effort" => "none"}
        })

      assert %{"id" => "resp_reasoning_none"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["reasoning"] == %{"effort" => "none"}
    end

    test "supported reasoning ultra contract rewrites ultra to max before dispatch",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_reasoning_ultra"}))
      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic reasoning request"),
          "reasoning" => %{"effort" => "ultra"}
        })

      assert %{"id" => "resp_reasoning_ultra"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["reasoning"] == %{"effort" => "max"}
    end

    test "supported reasoning contract preserves non-minimal efforts", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_reasoning_medium"}))
      setup = gateway_setup(upstream)

      conn =
        conn
        |> auth(setup)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => native_text_input("synthetic reasoning request"),
          "reasoning" => %{"effort" => "medium"}
        })

      assert %{"id" => "resp_reasoning_medium"} = json_response(conn, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["reasoning"] == %{"effort" => "medium"}
    end
  end

  defp gateway_setup(upstream, opts \\ []) do
    key = active_api_key_fixture()
    pool = key.pool
    upstream_token = generated_secret("upstream")
    upstream = gateway_upstream(pool, upstream, upstream_token)

    if Keyword.get(opts, :quota?, true) do
      prime_routing_quota!(upstream.identity)
    end

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-contract-model",
        upstream_model_id: "provider-gpt-contract-model",
        pricing_ref: "provider-gpt-contract-model",
        metadata: %{
          "source_assignment_ids" => [upstream.assignment.id],
          "source_assignment_models" => %{
            upstream.assignment.id => %{
              "slug" => "gpt-contract-model",
              "capabilities" => %{
                "reasoning" => true,
                "responses" => true,
                "streaming" => true,
                "tools" => true
              }
            }
          }
        },
        supports_responses: true,
        supports_streaming: true
      })

    pricing_snapshot!(model)

    Map.merge(key, %{
      identity: upstream.identity,
      assignment: upstream.assignment,
      model: model,
      upstream_token: upstream_token
    })
  end

  defp gateway_upstream(pool, upstream, token) do
    metadata = %{"base_url" => FakeUpstream.url(upstream)}

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
               account_label: "Gateway upstream",
               onboarding_method: "import",
               metadata: metadata
             })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: Enum.join(["access", "token"], "_"),
               plaintext: token
             })

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: "Gateway assignment",
               metadata: metadata
             })

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment)

    %{identity: identity, assignment: assignment}
  end

  defp prime_routing_quota!(identity) do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("1"),
                 reset_at: reset_at,
                 source: "codex_response_headers",
                 source_precision: "observed",
                 freshness_state: "fresh"
               }
             ])
  end

  defp prime_weekly_probe_quota!(identity) do
    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_weekly]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("12"),
                 reset_at: reset_at,
                 source: "codex_usage_api",
                 source_precision: "inferred",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh"
               }
             ])
  end

  defp pricing_snapshot!(model) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PricingSnapshot{
      model_identifier: model.upstream_model_id,
      price_version: "compatibility-contract-test-v1",
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(10),
      cached_input_token_micros: Decimal.new(1),
      output_token_micros: Decimal.new(20),
      reasoning_token_micros: Decimal.new(30),
      request_base_micros: Decimal.new(0),
      effective_at: DateTime.add(now, -60, :second),
      captured_at: now,
      config: %{}
    }
    |> Repo.insert!()
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp upload_fixture(filename, content_type, contents) do
    path =
      Path.join(System.tmp_dir!(), "codex-pooler-compat-#{System.unique_integer([:positive])}")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp multipart_boundary, do: "codex-pooler-compat-boundary"

  defp native_text_input(text) do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      }
    ]
  end

  defp multipart_body(filename, contents) do
    [
      "--#{multipart_boundary()}\r\n",
      "Content-Disposition: form-data; name=\"purpose\"\r\n\r\n",
      "user_data\r\n",
      "--#{multipart_boundary()}\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n",
      "Content-Type: text/plain\r\n\r\n",
      contents,
      "\r\n--#{multipart_boundary()}--\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp router_method(verb) when is_atom(verb), do: verb

  defp router_method(verb) when is_binary(verb) do
    verb
    |> String.downcase()
    |> String.to_atom()
  end

  defp auth(conn, setup), do: put_req_header(conn, "authorization", setup.authorization)

  defp generated_secret(label),
    do: "fixture-secret-#{label}-#{System.unique_integer([:positive])}"
end
