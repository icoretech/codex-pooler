defmodule CodexPooler.Gateway.RequestCompression.PerformanceTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.RequestCompression
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.RouteClass

  @endpoint "/backend-api/codex/responses"

  # Keep these test constants in sync with the operational guardrails in
  # CodexPooler.Gateway.RequestCompression.
  @max_body_bytes 1_048_576
  @max_candidate_count 50
  @local_budget_ms 500
  @supported_model "gpt-4o"

  describe "request compression guardrails" do
    test "skips over-limit bodies before JSON scanning" do
      body = "{" <> String.duplicate("x", @max_body_bytes)
      over_body_bytes = @max_body_bytes + 1
      {context, request_options} = request_context()

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "skipped",
               "reason" => "over_body_limit",
               "route_class" => "proxy_http",
               "transport" => "http_json",
               "candidate_count" => 0,
               "compressed_count" => 0,
               "skipped_count" => 0,
               "original_bytes" => ^over_body_bytes,
               "compressed_bytes" => ^over_body_bytes
             } = compressed_options.runtime.payload_compression

      assert finite_elapsed_ms?(compressed_options.runtime.payload_compression)
    end

    test "skips deterministically when candidate count exceeds the compression limit" do
      over_candidate_count = @max_candidate_count + 1
      body = encode_request(candidate_items(over_candidate_count))
      {context, request_options} = request_context()

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "skipped",
               "reason" => "over_candidate_limit",
               "candidate_count" => ^over_candidate_count,
               "compressed_count" => 0,
               "skipped_count" => ^over_candidate_count,
               "original_bytes" => original_bytes,
               "compressed_bytes" => compressed_bytes
             } = compressed_options.runtime.payload_compression

      assert original_bytes == byte_size(body)
      assert compressed_bytes == byte_size(body)
      assert finite_elapsed_ms?(compressed_options.runtime.payload_compression)
    end

    test "skips long-run compressible candidates within the local dispatch budget" do
      sentinel = "PRIVATE_LONG_RUN_SENTINEL"
      long_run = String.duplicate("a", 10_000) <> sentinel
      output = "[\n  " <> Jason.encode!(long_run) <> "\n]"

      body =
        encode_request([
          %{
            "type" => "function_call_output",
            "call_id" => "call_long_run_guard",
            "output" => output
          }
        ])

      {context, request_options} = request_context()
      started = System.monotonic_time(:millisecond)

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      elapsed_ms = System.monotonic_time(:millisecond) - started
      compression = compressed_options.runtime.payload_compression

      assert elapsed_ms <= @local_budget_ms

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "skipped",
               "reason" => "tokenizer_input_limit",
               "candidate_count" => 1,
               "compressed_count" => 0,
               "skipped_count" => 1,
               "tokenizer_input_skipped_count" => 1,
               "original_bytes" => original_bytes,
               "compressed_bytes" => compressed_bytes
             } = compression

      assert original_bytes == byte_size(body)
      assert compressed_bytes == byte_size(body)
      assert finite_elapsed_ms?(compression)
      refute Map.has_key?(compression, "original_tokens")
      refute inspect(compression) =~ sentinel
    end

    test "handles a sanitized one MiB fixture within the local dispatch budget" do
      body = fixed_size_request(@max_body_bytes, @max_candidate_count)
      {context, request_options} = request_context()

      started = System.monotonic_time(:millisecond)

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      elapsed_ms = System.monotonic_time(:millisecond) - started

      compression = compressed_options.runtime.payload_compression

      assert elapsed_ms <= @local_budget_ms

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "no_change",
               "reason" => "no_rewrites",
               "candidate_count" => @max_candidate_count,
               "compressed_count" => 0,
               "skipped_count" => @max_candidate_count,
               "original_bytes" => @max_body_bytes,
               "compressed_bytes" => @max_body_bytes
             } = compression

      assert finite_elapsed_ms?(compression)
    end
  end

  defp request_context do
    payload = %{"model" => @supported_model, "input" => []}

    request_options =
      %{transport: "http_json", upstream_endpoint: @endpoint}
      |> RequestOptions.build(@endpoint, payload)
      |> RequestOptions.put_transport(
        route_class: RouteClass.proxy_http(),
        upstream_endpoint: @endpoint
      )

    context = %Context{
      endpoint: @endpoint,
      payload: payload,
      model: model(),
      request_options: request_options,
      route_state: %RouteState{
        visible_model: model(),
        candidates: [],
        routing_settings: %RoutingSettings{request_compression_enabled: true}
      },
      route_class: RouteClass.proxy_http()
    }

    {context, request_options}
  end

  defp model do
    %Model{
      exposed_model_id: @supported_model,
      upstream_model_id: @supported_model
    }
  end

  defp candidate_items(count) do
    Enum.map(1..count, fn index ->
      %{
        "type" => "function_call_output",
        "call_id" => "call_synthetic_#{index}",
        "output" => plain_output(index, 640)
      }
    end)
  end

  defp fixed_size_request(target_bytes, candidate_count) do
    empty_items =
      Enum.map(1..candidate_count, fn index ->
        %{
          "type" => "function_call_output",
          "call_id" => "call_sanitized_#{index}",
          "output" => ""
        }
      end)

    empty_body = encode_request(empty_items)
    remaining_bytes = target_bytes - byte_size(empty_body)
    per_candidate_bytes = div(remaining_bytes, candidate_count)
    extra_candidates = rem(remaining_bytes, candidate_count)

    items =
      Enum.map(1..candidate_count, fn index ->
        %{
          "type" => "function_call_output",
          "call_id" => "call_sanitized_#{index}",
          "output" =>
            plain_output(index, per_candidate_bytes + extra_byte(index, extra_candidates))
        }
      end)

    body = encode_request(items)
    assert byte_size(body) == target_bytes
    body
  end

  defp plain_output(index, bytes) do
    prefix = "synthetic output #{index}: "

    prefix <>
      String.duplicate("x", max(bytes - byte_size(prefix), 0))
  end

  defp extra_byte(index, extra_candidates) when index <= extra_candidates, do: 1
  defp extra_byte(_index, _extra_candidates), do: 0

  defp encode_request(input) do
    Jason.encode!(%{"model" => @supported_model, "input" => input})
  end

  defp finite_elapsed_ms?(metadata) do
    is_integer(metadata["elapsed_ms"]) and metadata["elapsed_ms"] >= 0
  end
end
