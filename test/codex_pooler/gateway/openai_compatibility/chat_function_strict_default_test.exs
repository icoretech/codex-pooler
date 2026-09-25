defmodule CodexPooler.Gateway.OpenAICompatibility.ChatFunctionStrictDefaultTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.{Chat, Responses}

  test "omitted and null nested Chat strict preserve non-strict semantics without requiring optional properties" do
    for flag <- [%{}, %{"strict" => nil}] do
      tool = function_tool(flag)
      assert {:ok, result} = Chat.coerce(chat_payload(tool))
      assert [translated] = result.payload["tools"]
      assert Map.fetch(translated, "strict") == {:ok, false}
      assert translated["parameters"] == tool["function"]["parameters"]
      assert translated["parameters"]["required"] == ["path"]
    end
  end

  test "explicit strict true and false are preserved and malformed flags still reject" do
    for strict <- [true, false] do
      tool = function_tool(%{"strict" => strict})
      assert {:ok, result} = Chat.coerce(chat_payload(tool))
      assert [translated] = result.payload["tools"]
      assert Map.fetch(translated, "strict") == {:ok, strict}
      assert translated["parameters"] == tool["function"]["parameters"]
    end

    for strict <- ["false", 0, %{}, []] do
      assert {:error, %{status: 400, param: "tools"}} = Chat.coerce(chat_payload(function_tool(%{"strict" => strict})))
    end
  end

  test "direct Responses and Responses-shaped Chat fallback keep omission and null defaults" do
    for flag <- [%{}, %{"strict" => nil}] do
      tool = function_tool(flag)["function"] |> Map.put("type", "function")
      payload = %{"model" => "sample-model", "input" => "synthetic", "tools" => [tool]}
      assert {:ok, responses} = Responses.coerce(payload)
      assert [response_tool] = responses.payload["tools"]
      refute Map.has_key?(response_tool, "strict")

      for fallback <- [payload, Map.put(payload, "messages", [])] do
        assert {:ok, result} = Chat.coerce(fallback)
        assert result.payload["tools"] == responses.payload["tools"]
      end
    end
  end

  test "nested and flat custom tools do not acquire a strict flag" do
    custom = %{"name" => "apply_fixture", "format" => %{"type" => "text"}}

    for tool <- [%{"type" => "custom", "custom" => custom}, Map.put(custom, "type", "custom")] do
      assert {:ok, result} = Chat.coerce(chat_payload(tool))
      assert result.payload["tools"] == [Map.put(custom, "type", "custom")]
    end
  end

  defp chat_payload(tool), do: %{"model" => "sample-model", "messages" => [%{"role" => "user", "content" => "synthetic"}], "tools" => [tool]}

  defp function_tool(flag) do
    parameters = %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}, "limit" => %{"type" => "integer"}, "offset" => %{"type" => "integer"}},
      "required" => ["path"]
    }

    parameters = if flag["strict"] == true, do: Map.merge(parameters, %{"required" => ["path", "limit", "offset"], "additionalProperties" => false}), else: parameters
    %{"type" => "function", "function" => Map.merge(%{"name" => "read_fixture", "parameters" => parameters}, flag)}
  end
end
