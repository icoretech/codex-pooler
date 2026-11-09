defmodule CodexPooler.Gateway.OpenAICompatibility.ResponsesToolNamespaceTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.Responses

  @function %{"type" => "function", "name" => "synthetic_lookup", "strict" => true, "parameters" => %{"type" => "object", "properties" => %{}, "required" => [], "additionalProperties" => false}}
  @custom %{"type" => "custom", "name" => "synthetic_patch", "format" => %{"type" => "text"}}
  @function_call %{"type" => "function_call", "id" => "fc_synthetic_namespace", "call_id" => "call_synthetic_function", "name" => @function["name"], "arguments" => "{}", "status" => "completed"}
  @custom_call %{"type" => "custom_tool_call", "id" => "ctc_synthetic_namespace", "call_id" => "call_synthetic_custom", "name" => @custom["name"], "input" => "synthetic patch", "status" => "completed"}
  @namespace %{"type" => "namespace", "name" => "catalog", "description" => "Synthetic namespace", "tools" => [@function, @custom]}

  for shape <- [:json, :sse] do
    test "#{shape} restores absent or null function/custom namespaces but preserves explicit and undeclared calls" do
      assert_namespace_restoration!(unquote(shape))
    end
  end

  for {label, layout} <- [
        {"top-level first", :top_first},
        {"top-level last", :top_last},
        {"two namespaces", :two_namespaces},
        {"two namespaces reversed", :reversed_namespaces},
        {"three namespaces", :three_namespaces}
      ] do
    test "does not guess a missing function namespace with #{label}" do
      assert_ambiguous_namespace!(unquote(layout))
    end
  end

  defp assert_namespace_restoration!(shape) do
    items =
      for call <- [@function_call, @custom_call], namespace <- [:absent, nil, "provider_catalog", ""] do
        if namespace == :absent, do: call, else: Map.put(call, "namespace", namespace)
      end

    undeclared = Map.put(@function_call, "name", "undeclared_lookup")
    items = items ++ [undeclared]
    expected = Enum.map(items, fn item -> if item["name"] != "undeclared_lookup" and is_nil(item["namespace"]), do: Map.put(item, "namespace", "catalog"), else: item end)

    assert {:ok, %{request_options: options}} = Responses.coerce(request([@namespace]))
    assert {:ok, response} = Responses.response_from_sse(encoded_response(shape, items), options)
    assert response["output"] == expected
  end

  defp assert_ambiguous_namespace!(layout) do
    first = %{@namespace | "tools" => [@function]}
    second = %{first | "name" => "inventory"}
    third = %{first | "name" => "archive"}

    tools =
      case layout do
        :top_first -> [@function, first]
        :top_last -> [first, @function]
        :two_namespaces -> [first, second]
        :reversed_namespaces -> [second, first]
        :three_namespaces -> [first, second, third]
      end

    assert {:ok, %{request_options: options}} = Responses.coerce(request(tools))
    assert {:ok, response} = Responses.response_from_sse(encoded_response(:json, [@function_call]), options)
    assert response["output"] == [@function_call]
  end

  defp request(tools), do: %{"model" => "gpt-fixture-text", "input" => "synthetic namespace request", "tools" => tools}

  defp encoded_response(shape, items) do
    response = %{"id" => "resp_synthetic_namespace", "object" => "response", "status" => "completed", "output" => items}

    case shape do
      :json -> CodexPooler.JSON.encode!(response)
      :sse -> "event: response.completed\ndata: #{CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => response})}\n\n"
    end
  end
end
