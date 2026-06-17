defmodule CodexPooler.CompatibilityMatrixTest do
  use ExUnit.Case, async: true

  alias CodexPooler.CompatibilityMatrix

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
