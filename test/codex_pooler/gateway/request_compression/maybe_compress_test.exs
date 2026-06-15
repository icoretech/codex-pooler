defmodule CodexPooler.Gateway.RequestCompression.MaybeCompressTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.RequestCompression
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools.RoutingSettings

  @endpoint "/backend-api/codex/responses"
  @supported_model "gpt-4o"

  describe "maybe_compress/3" do
    test "rewrites eligible tool-output strings and records safe aggregate metadata" do
      omitted_sentinel = "direct compression omitted sentinel"
      original_output = compression_log_fixture(omitted_sentinel)

      body =
        Jason.encode!(%{
          "model" => @supported_model,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_direct_compression",
              "output" => original_output
            }
          ]
        })

      {context, request_options} = request_context(body)

      assert {compressed_body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert compressed_body != body

      compressed_output =
        compressed_body
        |> Jason.decode!()
        |> Map.fetch!("input")
        |> List.first()
        |> Map.fetch!("output")

      assert compressed_output != original_output
      assert compressed_output =~ "[compressed log output: omitted"
      refute compressed_output =~ omitted_sentinel

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "compressed",
               "route_class" => "proxy_http",
               "transport" => "http_json",
               "candidate_count" => 1,
               "compressed_count" => 1,
               "skipped_count" => 0
             } = metadata = compressed_options.runtime.payload_compression

      assert "log_output" in metadata["strategies"]
      assert metadata["original_bytes"] > metadata["compressed_bytes"]
      assert metadata["saved_bytes"] > 0
      assert metadata["original_tokens"] > metadata["compressed_tokens"]
      assert metadata["saved_tokens"] > 0
      refute inspect(metadata) =~ omitted_sentinel
      refute inspect(metadata) =~ "call_direct_compression"
    end

    test "skips unsupported tokenizer models without rewriting tool output" do
      omitted_sentinel = "unsupported tokenizer omitted sentinel"
      original_output = compression_log_fixture(omitted_sentinel)

      body =
        Jason.encode!(%{
          "model" => "gpt-fixture",
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_unsupported_tokenizer",
              "output" => original_output
            }
          ]
        })

      {context, request_options} = request_context(body, model: unsupported_model())

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "skipped",
               "reason" => "tokenizer_unavailable",
               "route_class" => "proxy_http",
               "transport" => "http_json",
               "candidate_count" => 0,
               "compressed_count" => 0,
               "skipped_count" => 0,
               "original_bytes" => original_bytes,
               "compressed_bytes" => compressed_bytes
             } = metadata = compressed_options.runtime.payload_compression

      assert original_bytes == byte_size(body)
      assert compressed_bytes == byte_size(body)
      refute Map.has_key?(metadata, "original_tokens")
      refute Map.has_key?(metadata, "compressed_tokens")
      refute inspect(metadata) =~ omitted_sentinel
      refute inspect(metadata) =~ "call_unsupported_tokenizer"
    end

    test "skips when no route model is available" do
      body =
        Jason.encode!(%{
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_missing_model",
              "output" => compression_log_fixture("missing model omitted sentinel")
            }
          ]
        })

      {context, request_options} = request_context(body, model: nil, visible_model: nil)

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "skipped",
               "reason" => "tokenizer_unavailable",
               "candidate_count" => 0,
               "compressed_count" => 0,
               "skipped_count" => 0
             } = compressed_options.runtime.payload_compression
    end

    test "does not fall back to payload model when route model is unsupported" do
      body =
        Jason.encode!(%{
          "model" => @supported_model,
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_payload_model_fallback",
              "output" => compression_log_fixture("payload fallback omitted sentinel")
            }
          ]
        })

      {context, request_options} = request_context(body, model: unsupported_model())

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert %{
               "status" => "skipped",
               "reason" => "tokenizer_unavailable",
               "candidate_count" => 0,
               "compressed_count" => 0
             } = compressed_options.runtime.payload_compression
    end
  end

  defp request_context(body, opts \\ []) do
    payload = Jason.decode!(body)
    route_model = Keyword.get(opts, :model, supported_model())
    visible_model = Keyword.get(opts, :visible_model, route_model)

    request_options =
      %{transport: "http_json", upstream_endpoint: @endpoint}
      |> RequestOptions.build(@endpoint, payload)
      |> RequestOptions.put_transport(route_class: "proxy_http", upstream_endpoint: @endpoint)

    context = %Context{
      endpoint: @endpoint,
      payload: payload,
      model: route_model,
      request_options: request_options,
      route_state: %RouteState{
        visible_model: visible_model,
        candidates: [],
        routing_settings: %RoutingSettings{request_compression_enabled: true}
      },
      route_class: "proxy_http"
    }

    {context, request_options}
  end

  defp supported_model do
    %Model{
      exposed_model_id: @supported_model,
      upstream_model_id: @supported_model
    }
  end

  defp unsupported_model do
    %Model{
      exposed_model_id: "gpt-fixture",
      upstream_model_id: "provider-gpt-fixture"
    }
  end

  defp compression_log_fixture(omitted_sentinel) do
    middle =
      1..96
      |> Enum.map(fn
        48 -> "ordinary build line 48 #{omitted_sentinel}"
        index -> "ordinary build line #{index}"
      end)

    [
      "command started",
      "context before first",
      "error: first failure",
      "context after first"
    ]
    |> Kernel.++(middle)
    |> Kernel.++([
      "context before final",
      "fatal: final failure",
      "context after final"
    ])
    |> Enum.join("\n")
  end
end
