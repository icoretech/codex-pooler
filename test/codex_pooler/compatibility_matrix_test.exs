defmodule CodexPooler.CompatibilityMatrixTest do
  use ExUnit.Case, async: true

  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.Pools.RoutingSettings

  describe "catalog and Responses runtime contract" do
    test "makes backend model catalog ETag derivation machine-readable" do
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
    end

    test "pins exact backend Responses catalog header equality and exclusions" do
      feature = CompatibilityMatrix.by_slug!(:backend_responses_etag)
      fixture = CompatibilityMatrix.fixture!(:backend_responses_etag)

      assert feature.current == :predispatch_catalog_snapshot
      assert fixture.header == "x-models-etag"
      assert fixture.equals == "authenticated_backend_models_etag"
      assert fixture.http_sse == "response_header"
      assert fixture.websocket == "upgrade_header"
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

      assert Map.fetch!(fixture, :pool_gate) == %{
               setting: "request_compression_enabled",
               default_enabled: false,
               disabled_behavior: "original_request_passthrough"
             }

      assert Map.fetch!(fixture, :direction) == "request_side_only"
      assert Map.fetch!(fixture, :failure_mode) == "fail_open_original_request"

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
    test "connects the documented pool gate to the production routing schema" do
      feature = CompatibilityMatrix.by_slug!(:upstream_websocket_bridge)
      fixture = CompatibilityMatrix.fixture!(:upstream_websocket_bridge)

      assert feature.status == :supported
      assert feature.current == :pool_gated_owner_websocket_cache_bridge
      assert feature.routes == [%{method: :post, path: "/v1/responses"}]

      setting = :upstream_websocket_bridge_enabled
      assert setting in RoutingSettings.__schema__(:fields)
      assert Map.fetch!(%RoutingSettings{}, setting) == false
      assert fixture.pool_gate.setting == Atom.to_string(setting)
      assert fixture.pool_gate.default_enabled == false

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
