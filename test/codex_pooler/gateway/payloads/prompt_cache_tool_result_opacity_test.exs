defmodule CodexPooler.Gateway.Payloads.PromptCacheToolResultOpacityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Payloads.{PayloadNormalizer, RequestOptions}

  @endpoint "/backend-api/codex/responses"
  @breakpoint %{"mode" => "explicit"}
  @tool %{"type" => "function", "name" => "synthetic_tool", "strict" => false, "parameters" => %{"type" => "object", "properties" => %{}}}
  @structured %{"payload" => %{"type" => "input_text", "text" => "synthetic business value", "prompt_cache_breakpoint" => @breakpoint}}

  for mode <- ["full", "lite"], transport <- [:http, :websocket] do
    @tag mode: mode, transport: transport
    test "structured tool output keeps its own prompt_cache_breakpoint property: #{mode} #{transport}", %{mode: mode, transport: transport} do
      {upstream, options} = serialize!(request(@structured), mode, transport)

      assert find_output(upstream) == @structured
      refute options.runtime.prompt_cache_controls_downgraded
    end

    @tag mode: mode, transport: transport
    test "direct content-part breakpoints are still removed and deeper tool data is kept: #{mode} #{transport}", %{mode: mode, transport: transport} do
      part = %{"type" => "input_text", "text" => "synthetic part", "prompt_cache_breakpoint" => @breakpoint}
      nested_in_list = [part, %{"value" => part}, [part]]

      payload =
        nested_in_list
        |> request()
        |> put_in(["input", Access.at(0), "content", Access.at(0), "prompt_cache_breakpoint"], @breakpoint)

      {upstream, options} = serialize!(payload, mode, transport)
      user = Enum.find(upstream["input"], &(&1["type"] == "message" and &1["role"] == "user"))

      refute Map.has_key?(hd(user["content"]), "prompt_cache_breakpoint")
      assert find_output(upstream) == [Map.delete(part, "prompt_cache_breakpoint"), %{"value" => part}, [part]]
      assert options.runtime.prompt_cache_controls_downgraded
    end
  end

  test "a schema literal keeps its prompt_cache_breakpoint property" do
    schema = %{"x-opaque-keyword" => [@structured["payload"]]}
    payload = Map.put(request("synthetic text output"), "tools", [Map.put(@tool, "output_schema", schema)])

    {upstream, options} = serialize!(payload, "full", :http)

    assert Enum.find(upstream["tools"], &(&1["name"] == "synthetic_tool"))["output_schema"] == schema
    refute options.runtime.prompt_cache_controls_downgraded
  end

  defp request(output) do
    %{
      "model" => "synthetic-model",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic request"}]},
        %{"type" => "function_call", "name" => "synthetic_tool", "call_id" => "call_synthetic", "arguments" => "{}"},
        %{"type" => "function_call_output", "call_id" => "call_synthetic", "output" => output}
      ],
      "tools" => [@tool]
    }
  end

  defp serialize!(payload, mode, transport) do
    assert {:ok, coerced} = Responses.coerce(payload)
    assert find_output(coerced.payload) == find_output(payload)

    options = RequestOptions.put_model_serving_mode(coerced.request_options, %{configured_mode: mode, effective_mode: mode, source: "override"})
    options = if transport == :websocket, do: RequestOptions.for_websocket(options, coerced.payload), else: options

    assert {:ok, encoded, options} = PayloadNormalizer.prepare_upstream_payload(coerced.payload, %Model{upstream_model_id: "provider-model"}, @endpoint, options)
    {CodexPooler.JSON.decode!(encoded), options}
  end

  defp find_output(payload), do: payload["input"] |> Enum.find(&(&1["type"] == "function_call_output")) |> Map.fetch!("output")
end
