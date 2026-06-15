defmodule CodexPooler.Gateway.RequestCompression.FailOpenTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.RequestCompression
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools.RoutingSettings

  @endpoint "/backend-api/codex/responses"
  @supported_model "gpt-4o"

  describe "maybe_compress/3" do
    test "fails open on invalid JSON and records safe passthrough metadata and logs" do
      sentinel = "sentinel private payload text"
      invalid_json = ~s({"input":["#{sentinel}",)
      request_options = request_options()

      context = %Context{
        endpoint: @endpoint,
        payload: %{"model" => @supported_model, "input" => []},
        model: model(),
        request_options: request_options,
        route_state: %RouteState{
          visible_model: model(),
          candidates: [],
          routing_settings: compression_enabled_settings()
        },
        route_class: "proxy_stream"
      }

      {result, log} =
        with_log(fn ->
          assert {^invalid_json, compressed_options} =
                   RequestCompression.maybe_compress(invalid_json, context, request_options)

          compressed_options
        end)

      compressed_options = result

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "error_passthrough",
               "reason" => "invalid_json"
             } = compressed_options.runtime.payload_compression

      refute inspect(compressed_options.runtime.payload_compression) =~ invalid_json
      refute inspect(compressed_options.runtime.payload_compression) =~ sentinel
      assert log =~ "request compression failed open"
      refute log =~ invalid_json
      refute log =~ sentinel
    end
  end

  defp request_options do
    %{
      request_id: "request-compression-invalid-json",
      transport: "http",
      upstream_endpoint: @endpoint
    }
    |> RequestOptions.build(@endpoint, %{"model" => @supported_model, "input" => []})
    |> RequestOptions.put_routing(
      requested_model: @supported_model,
      effective_model: @supported_model
    )
  end

  defp model do
    %Model{
      exposed_model_id: @supported_model,
      upstream_model_id: @supported_model
    }
  end

  defp compression_enabled_settings do
    %RoutingSettings{}
    |> Map.put(:request_compression_enabled, true)
  end
end
