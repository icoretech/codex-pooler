defmodule CodexPooler.Gateway.RequestCompression.PerformanceTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.RequestCompression
  alias CodexPooler.Gateway.RequestCompression.TokenCounter
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

  setup_all do
    assert {:ok, _count, _metadata} = TokenCounter.count(@supported_model, "warm tokenizer ranks")
    :ok
  end

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
      sentinel = "SANITIZED_LONG_RUN_SENTINEL"
      long_run = String.duplicate("a", 10_000) <> sentinel
      output = "[\n  " <> Jason.encode!(long_run) <> "\n]"

      body =
        encode_request([
          %{
            "type" => "local_shell_call_output",
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

    test "compresses oversized log-like shell and function outputs once bounded accounting is available" do
      shell_sentinel = "SANITIZED_SHELL_OVERSIZED_SENTINEL"
      function_sentinel = "SANITIZED_FUNCTION_OVERSIZED_SENTINEL"

      shell_output = oversized_log_fixture("shell", shell_sentinel)
      function_output = oversized_log_fixture("function", function_sentinel)

      assert byte_size(shell_output) > 8_192
      assert byte_size(function_output) > 8_192

      body =
        encode_request([
          %{
            "type" => "function_call",
            "call_id" => "call_oversized_function_output",
            "name" => "run_command",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_oversized_function_output",
            "output" => function_output
          },
          %{
            "type" => "local_shell_call_output",
            "call_id" => "call_oversized_shell_output",
            "output" => shell_output
          }
        ])

      {context, request_options} = request_context()
      started = System.monotonic_time(:millisecond)

      assert {compressed_body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      elapsed_ms = System.monotonic_time(:millisecond) - started
      compression = compressed_options.runtime.payload_compression

      assert elapsed_ms <= @local_budget_ms
      assert compressed_body != body

      compressed_outputs =
        compressed_body
        |> Jason.decode!()
        |> Map.fetch!("input")
        |> Enum.filter(&(&1["type"] in ["local_shell_call_output", "function_call_output"]))
        |> Enum.map(&Map.fetch!(&1, "output"))

      assert length(compressed_outputs) == 2
      assert Enum.all?(compressed_outputs, &(&1 =~ "[compressed log output: omitted"))
      refute Enum.any?(compressed_outputs, &String.contains?(&1, shell_sentinel))
      refute Enum.any?(compressed_outputs, &String.contains?(&1, function_sentinel))

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "compressed",
               "candidate_count" => 2,
               "compressed_count" => 2,
               "skipped_count" => 0,
               "original_bytes" => original_bytes,
               "compressed_bytes" => compressed_bytes,
               "original_tokens_lower_bound" => original_tokens_lower_bound,
               "compressed_tokens" => compressed_tokens
             } = compression

      assert original_bytes == byte_size(body)
      assert compressed_bytes == byte_size(compressed_body)
      assert compressed_bytes < original_bytes
      assert compressed_tokens < original_tokens_lower_bound
      assert compression["token_count_mode"] == "bounded_original"
      assert "log_output" in compression["strategies"]
      finite_elapsed_ms?(compression)
      refute Map.has_key?(compression, "original_tokens")
      refute Map.has_key?(compression, "saved_tokens")
      refute Map.has_key?(compression, "token_savings_ratio")
      refute Map.has_key?(compression, "token_savings_percent")
      refute Map.has_key?(compression, "tokenizer_input_skipped_count")
      refute inspect(compression) =~ shell_sentinel
      refute inspect(compression) =~ function_sentinel
      refute inspect(compression) =~ "call_oversized_function_output"
      refute inspect(compression) =~ "call_oversized_shell_output"
    end

    test "returns a large completed rewrite when a sibling candidate hits tokenizer input limit" do
      rewrite_item = %{
        "type" => "local_shell_call_output",
        "call_id" => "call_near_limit_completed_rewrite",
        "output" =>
          oversized_log_fixture("near-limit shell", "SANITIZED_NEAR_LIMIT_REWRITE_SENTINEL")
      }

      skipped_output =
        "[\n  " <>
          Jason.encode!(
            String.duplicate("a", TokenCounter.max_input_bytes() + 1) <>
              "SANITIZED_NEAR_LIMIT_SKIP_SENTINEL"
          ) <> "\n]"

      skip_item = %{
        "type" => "local_shell_call_output",
        "call_id" => "call_near_limit_tokenizer_skip",
        "output" => skipped_output
      }

      base_items = [rewrite_item, skip_item]
      body = encode_request(base_items ++ [near_limit_padding_item(@max_body_bytes, base_items)])

      assert byte_size(body) == @max_body_bytes

      {context, request_options} = request_context()
      started = System.monotonic_time(:millisecond)

      assert {compressed_body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      elapsed_ms = System.monotonic_time(:millisecond) - started
      compression = compressed_options.runtime.payload_compression

      assert elapsed_ms <= @local_budget_ms
      assert compressed_body != body

      decoded_outputs =
        compressed_body
        |> Jason.decode!()
        |> Map.fetch!("input")
        |> Map.new(&{&1["call_id"], &1["output"]})

      rewritten_output = Map.fetch!(decoded_outputs, "call_near_limit_completed_rewrite")
      assert rewritten_output =~ "[compressed log output: omitted"
      refute rewritten_output =~ "SANITIZED_NEAR_LIMIT_REWRITE_SENTINEL"

      assert Map.fetch!(decoded_outputs, "call_near_limit_tokenizer_skip") == skipped_output

      assert Map.fetch!(decoded_outputs, "call_near_limit_tokenizer_skip") =~
               "SANITIZED_NEAR_LIMIT_SKIP_SENTINEL"

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "compressed",
               "reason" => "rewritten",
               "route_class" => "proxy_http",
               "transport" => "http_json",
               "candidate_count" => 2,
               "compressed_count" => 1,
               "skipped_count" => 1,
               "tokenizer_input_skipped_count" => 1,
               "original_bytes" => @max_body_bytes,
               "compressed_bytes" => compressed_bytes,
               "original_tokens_lower_bound" => original_tokens_lower_bound,
               "compressed_tokens" => compressed_tokens
             } = compression

      assert compressed_bytes == byte_size(compressed_body)
      assert compressed_bytes < @max_body_bytes
      assert compression["token_count_mode"] == "bounded_original"
      assert compressed_tokens < original_tokens_lower_bound
      assert "log_output" in compression["strategies"]
      assert finite_elapsed_ms?(compression)
      refute Map.has_key?(compression, "original_tokens")
      refute Map.has_key?(compression, "saved_tokens")
      refute Map.has_key?(compression, "token_savings_ratio")
      refute Map.has_key?(compression, "token_savings_percent")
      refute inspect(compression) =~ "SANITIZED_NEAR_LIMIT_REWRITE_SENTINEL"
      refute inspect(compression) =~ "SANITIZED_NEAR_LIMIT_SKIP_SENTINEL"
      refute inspect(compression) =~ "call_near_limit_completed_rewrite"
      refute inspect(compression) =~ "call_near_limit_tokenizer_skip"
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
        "type" => "local_shell_call_output",
        "call_id" => "call_synthetic_#{index}",
        "output" => plain_output(index, 640)
      }
    end)
  end

  defp fixed_size_request(target_bytes, candidate_count) do
    empty_items =
      Enum.map(1..candidate_count, fn index ->
        %{
          "type" => "local_shell_call_output",
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
          "type" => "local_shell_call_output",
          "call_id" => "call_sanitized_#{index}",
          "output" =>
            plain_output(index, per_candidate_bytes + extra_byte(index, extra_candidates))
        }
      end)

    body = encode_request(items)
    assert byte_size(body) == target_bytes
    body
  end

  defp near_limit_padding_item(target_body_bytes, base_items) do
    empty_padding_item = %{"type" => "message", "role" => "user", "content" => ""}
    empty_body = encode_request(base_items ++ [empty_padding_item])
    remaining_bytes = target_body_bytes - byte_size(empty_body)
    padding = String.duplicate("p", remaining_bytes)
    padding_item = %{empty_padding_item | "content" => padding}
    body = encode_request(base_items ++ [padding_item])
    assert byte_size(body) == target_body_bytes
    padding_item
  end

  defp plain_output(index, bytes) do
    prefix = "synthetic output #{index}: "

    prefix <>
      String.duplicate("x", max(bytes - byte_size(prefix), 0))
  end

  defp oversized_log_fixture(kind, omitted_sentinel) do
    middle =
      1..420
      |> Enum.map(fn
        210 -> "ordinary #{kind} line 210 #{omitted_sentinel}"
        index -> "ordinary #{kind} line #{index} with repeated sanitized diagnostic context"
      end)

    [
      "command started",
      "context before first",
      "error: first #{kind} failure",
      "context after first"
    ]
    |> Kernel.++(middle)
    |> Kernel.++([
      "context before final",
      "fatal: final #{kind} failure",
      "context after final"
    ])
    |> Enum.join("\n")
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
