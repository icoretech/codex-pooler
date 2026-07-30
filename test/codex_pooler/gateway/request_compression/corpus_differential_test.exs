defmodule CodexPooler.Gateway.RequestCompression.CorpusDifferentialTest do
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
  @model_id "gpt-4o"
  @max_body_bytes 1_048_576
  @max_candidate_count 50

  @reference %{
    combined_diff:
      {"7f360d6f696093d0d663cf6ab101729b6117766e7e2b670b389d2dccb0322858",
       "4a117b64c2fbc23b0707ec6e99c0a2abdfcbc14366c0931012b0de0ef4a935c5"},
    failure_log:
      {"3e01cc4dbc4299cfe5939d529e0b01beec3e2120e4d6f162f5cd56c7e520e5cc",
       "ce59dcd14011b2614f6c4dec20d24e59a8d0d419f58298974fb78adfcb6192f5"},
    grouped_search:
      {"552ee8caa4a53baa7defc1c4a4c8ebfc431b4eba48267276db97c5aa31a72825",
       "047e93f4181ff27e29de46af4c6005866831c7c1d05f07050381cb368fa612b9"},
    json_array:
      {"605780d686f0a89b8c8fca0779d650d863be08eab3f05c4be63d668f979de51e",
       "29fe807ba31c08b8e6b3942b66013046d4ea8c2ed153e0c59197a69628ff52f7"},
    json_document:
      {"f465332536042e4107919c5c2bfda0f08984ca7d60889de32267c92fe8abe6a5",
       "cc8a60b707cb45d4e87bb2f1549ce5fda2354f2329221b0ec65d04cf7ef80eff"},
    mixed_replacement_order:
      {"69422c6021cf1c2f278eacdb3fdff2a2e1f38b78705ef16734e8f5dbb393f41b",
       "3c2cb2de9802d505a9d8701d686c4ae74b9ea75122587db352698e9f25602fbe"},
    one_mib_boundary:
      {"ea465b954650b2651ebab7426b9bd2de66b55145e72d2e4d8afbb4fd7fa336eb",
       "205f74debd7dcfb752d0f1ed7778bb82bbf3219e7041f45ec04211e9607bf6cf"},
    over_candidate_boundary:
      {"200a101b06b6fa87966412579c629fdf5a51e904b7f45978cf95c3d012c0a31f",
       "bfdec4cb7d930d3da6149d454971b5b3ac5ee9fc45334d8ebd7ea5d1a30b1427"}
  }

  setup_all do
    assert {:ok, _count, _metadata} = TokenCounter.count(@model_id, "warm tokenizer ranks")
    :ok
  end

  test "current production entrypoint remains byte-identical to the pre-R7 corpus" do
    actual =
      Map.new(corpus(), fn {label, body} ->
        {context, request_options} = request_context(body)

        assert {output, compressed_options} =
                 RequestCompression.maybe_compress(body, context, request_options)

        metadata = compressed_options.runtime.payload_compression
        assert is_integer(metadata["elapsed_ms"])
        assert metadata["elapsed_ms"] >= 0

        {label, {digest(output), metadata |> Map.delete("elapsed_ms") |> digest()}}
      end)

    Enum.each(actual, fn {label, digests} ->
      assert digests == Map.fetch!(@reference, label),
             "corpus mismatch for #{label}: #{inspect(digests)}"
    end)
  end

  test "pre-R7 corpus covers every required class and exact guardrail boundaries" do
    cases = Map.new(corpus())

    assert Map.keys(cases) |> Enum.sort() == Map.keys(@reference) |> Enum.sort()
    assert byte_size(cases.one_mib_boundary) == @max_body_bytes

    assert cases.over_candidate_boundary
           |> Jason.decode!()
           |> Map.fetch!("input")
           |> Enum.count(&Map.has_key?(&1, "output")) == @max_candidate_count + 1
  end

  defp corpus do
    base = [
      {:grouped_search, request(grouped_search_output())},
      {:combined_diff, request(combined_diff_output())},
      {:failure_log, request(failure_log_output())},
      {:json_array, request(json_array_output())},
      {:json_document, request(json_document_output())},
      {:mixed_replacement_order,
       request([grouped_search_output(), failure_log_output(), combined_diff_output()])}
    ]

    base ++
      [
        {:one_mib_boundary, fixed_size_request(@max_body_bytes)},
        {:over_candidate_boundary, over_candidate_request()}
      ]
  end

  defp grouped_search_output do
    1..4
    |> Enum.flat_map(fn file ->
      ["lib/synthetic_#{file}.ex" | Enum.map(1..12, &"#{&1}: grouped match #{file}-#{&1}")]
    end)
    |> Enum.join("\n")
  end

  defp combined_diff_output do
    context = Enum.map_join(1..80, "\n", &"  unchanged synthetic context #{&1}")

    """
    Synthetic review preamble
    diff --cc lib/synthetic.ex
    index 1111111,2222222..3333333
    --- a/lib/synthetic.ex
    +++ b/lib/synthetic.ex
    @@@ -1,82 -1,82 +1,82 @@@
     -old synthetic value
    ++new synthetic value
    #{context}
    """
  end

  defp failure_log_output do
    details =
      Enum.flat_map(1..3, fn index ->
        [
          "error: Synthetic.Case#{index} failed",
          "assertion failed: expected synthetic value #{index}"
          | Enum.map(1..4, &"ordinary separator #{index}.#{&1}")
        ]
      end)

    ["synthetic suite started"]
    |> Kernel.++(details)
    |> Kernel.++(Enum.map(1..180, &"ordinary build line #{&1}"))
    |> Kernel.++(["Failed! - Failed: 3, Passed: 7, Skipped: 0, Total: 10"])
    |> Enum.join("\n")
  end

  defp json_array_output do
    1..60
    |> Enum.map(fn index ->
      %{
        "id" => index,
        "status" => "complete",
        "nested" => [%{"escaped" => "synthetic \\\"#{index}\\\"\nvalue"}],
        "values" => Enum.to_list(index..(index + 5))
      }
    end)
    |> Jason.encode!(pretty: true)
  end

  defp json_document_output do
    %{
      "status" => "complete",
      "records" =>
        Enum.map(1..60, fn index ->
          %{
            "id" => index,
            "label" => "synthetic document row #{index}",
            "metadata" => %{"priority" => rem(index, 3), "enabled" => true}
          }
        end)
    }
    |> Jason.encode!(pretty: true)
  end

  defp request(output) when is_binary(output), do: request([output])

  defp request(outputs) when is_list(outputs) do
    input =
      outputs
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {output, index} ->
        call_id = "call_synthetic_#{index}"

        [
          %{
            "type" => "function_call",
            "call_id" => call_id,
            "name" => "run_command",
            "arguments" => "{}"
          },
          %{"type" => "function_call_output", "call_id" => call_id, "output" => output}
        ]
      end)

    Jason.encode!(%{"model" => @model_id, "input" => input})
  end

  defp fixed_size_request(target_bytes) do
    output_item = %{
      "type" => "local_shell_call_output",
      "call_id" => "call_one_mib_boundary",
      "output" => ""
    }

    empty = Jason.encode!(%{"model" => @model_id, "input" => [output_item]})
    padding = String.duplicate("x", target_bytes - byte_size(empty))

    body =
      Jason.encode!(%{"model" => @model_id, "input" => [%{output_item | "output" => padding}]})

    assert byte_size(body) == target_bytes
    body
  end

  defp over_candidate_request do
    input =
      Enum.map(1..(@max_candidate_count + 1), fn index ->
        %{
          "type" => "local_shell_call_output",
          "call_id" => "call_candidate_#{index}",
          "output" => String.duplicate("plain synthetic output #{index} ", 32)
        }
      end)

    Jason.encode!(%{"model" => @model_id, "input" => input})
  end

  defp request_context(body) do
    payload = Jason.decode!(body)
    model = %Model{exposed_model_id: @model_id, upstream_model_id: @model_id}

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
      model: model,
      request_options: request_options,
      route_state: %RouteState{
        visible_model: model,
        candidates: [],
        routing_settings: %RoutingSettings{request_compression_enabled: true}
      },
      route_class: RouteClass.proxy_http()
    }

    {context, request_options}
  end

  defp digest(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp digest(value), do: value |> :erlang.term_to_binary() |> digest()
end
