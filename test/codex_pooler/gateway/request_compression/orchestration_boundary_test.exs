defmodule CodexPooler.Gateway.RequestCompression.OrchestrationBoundaryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.RequestCompression
  alias CodexPooler.Gateway.RequestCompression.TokenCounter.Ranks

  @endpoint "/backend-api/codex/responses"

  test "string-key route context uses verified model and rewrites lossless tool JSON" do
    {body, context, opts} = fixture()
    {compressed, result} = RequestCompression.maybe_compress(body, context, opts)
    assert byte_size(compressed) < byte_size(body)
    assert result.runtime.payload_compression["status"] == "compressed"
    assert decoded_output(compressed) == decoded_output(body)
  end

  test "non-string model candidates are skipped in favor of the verified visible model" do
    {body, context, opts} = fixture()
    context = Map.put(context, "model", %{"upstream_model_id" => 42, "exposed_model_id" => false})
    {compressed, result} = RequestCompression.maybe_compress(body, context, opts)
    assert byte_size(compressed) < byte_size(body)
    assert result.runtime.payload_compression["status"] == "compressed"
  end

  test "unbuilt request options preserve the input unchanged" do
    for opts <- [nil, %{}, :invalid] do
      assert {"{}", ^opts} = RequestCompression.maybe_compress("{}", %{}, opts)
    end
  end

  test "unexpected tokenizer cache corruption preserves payload with safe failure metadata" do
    {body, context, opts} = fixture()
    key = {Ranks, :ranks, :o200k_base}
    # Capture before touching the key and put back exactly that. Loading the table first and
    # writing it back would hand every later test a cache this VM never had.
    previous = :persistent_term.get(key, :not_found)
    on_exit(fn -> restore_ranks_cache(key, previous) end)
    :persistent_term.put(key, :invalid_cache)

    {result, log} = with_log(fn -> RequestCompression.maybe_compress(body, context, opts) end)
    assert {^body, result_opts} = result

    assert %{"status" => "error_passthrough", "reason" => "compression_error"} =
             result_opts.runtime.payload_compression

    assert log =~ "request compression failed open"
    refute log =~ body
    refute inspect(result_opts.runtime.payload_compression) =~ "synthetic-value"
  end

  defp restore_ranks_cache(key, :not_found), do: :persistent_term.erase(key)
  defp restore_ranks_cache(key, previous), do: :persistent_term.put(key, previous)

  defp fixture do
    output =
      CodexPooler.JSON.encode!(
        %{"rows" => Enum.map(1..30, &%{"id" => &1, "value" => "synthetic-value"})},
        pretty: true
      )

    body =
      CodexPooler.JSON.encode!(%{
        "input" => [
          %{
            "type" => "function_call",
            "call_id" => "sample",
            "name" => "sample_tool",
            "arguments" => "{}"
          },
          %{"type" => "function_call_output", "call_id" => "sample", "output" => output}
        ]
      })

    opts =
      RequestOptions.build(
        %{transport: "http_json", upstream_endpoint: @endpoint},
        @endpoint,
        CodexPooler.JSON.decode!(body)
      )
      |> RequestOptions.put_transport(route_class: "proxy_http", upstream_endpoint: @endpoint)

    context = %{
      "endpoint" => @endpoint,
      "route_class" => "proxy_http",
      "model" => %{"upstream_model_id" => "gpt-4o"},
      "route_state" => %{
        "visible_model" => %{"upstream_model_id" => "gpt-4o"},
        "routing_settings" => %{"request_compression_enabled" => true}
      }
    }

    {body, context, opts}
  end

  defp decoded_output(body) do
    body
    |> CodexPooler.JSON.decode!()
    |> Map.fetch!("input")
    |> List.last()
    |> Map.fetch!("output")
    |> CodexPooler.JSON.decode!()
  end
end
