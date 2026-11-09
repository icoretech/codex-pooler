defmodule CodexPooler.Gateway.OpenAICompatibility.ResponsesConfigurationUpdateAsyncTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses

  @model "gpt-fixture-text"
  @parameters %{"type" => "object", "properties" => %{}, "required" => [], "additionalProperties" => false}
  @function %{"type" => "function", "name" => "synthetic_lookup", "parameters" => @parameters, "strict" => true}
  @custom %{"type" => "custom", "name" => "synthetic_patch", "format" => %{"type" => "text"}}
  @function_call %{"type" => "function_call", "id" => "fc_configuration_async", "call_id" => "call_configuration_function", "name" => "synthetic_lookup", "arguments" => "{}"}
  @custom_call %{"type" => "custom_tool_call", "id" => "ctc_configuration_async", "call_id" => "call_configuration_custom", "name" => "synthetic_patch", "input" => "synthetic patch"}

  describe "configuration_update uses the measured reasoning shape" do
    for effort <- ~w(none minimal low medium high xhigh max synthetic-provider-effort) do
      test "accepts #{effort} locally and leaves the effort vocabulary to the provider" do
        input = [update(unquote(effort)), user("synthetic request")]
        assert_preserved(input)
      end
    end

    test "does not add an effort enum or nonblank policy for an empty string" do
      assert_preserved([update(""), user("synthetic request")])
    end

    test "does not trim or case-normalize a configuration effort string" do
      assert_preserved([update(" Synthetic-Provider-Effort "), user("synthetic request")])
    end

    test "retains updates between history messages in their original positions" do
      input = [user("synthetic opener"), update("high"), assistant("synthetic earlier answer"), update("low"), user("synthetic follow-up")]
      assert_preserved(input)
    end

    for role <- ~w(developer system) do
      test "does not manufacture consecutive updates by lifting the #{role} separator into existing instructions" do
        separator = %{"type" => "message", "role" => unquote(role), "content" => [%{"type" => "input_text", "text" => " synthetic first separator part "}, %{"type" => "input_text", "text" => "synthetic second separator part"}]}
        input = [update("high"), separator, update("low"), user("synthetic ordered follow-up")]
        expected = List.replace_at(input, 1, Map.put(separator, "role", "developer"))
        instructions = "Synthetic top-level instructions must stay separate"
        body = request(input, %{"instructions" => instructions})

        assert {:ok, validated} = Responses.validate(body)
        assert validated["input"] == expected
        assert validated["instructions"] == instructions
        assert {:ok, %{payload: payload}} = Responses.coerce(body)
        assert payload["input"] == expected
        assert payload["instructions"] == instructions
      end
    end

    test "retains the message-level update order captured from the real AI SDK" do
      assert_preserved([user("synthetic SDK opener"), assistant("synthetic SDK answer"), update("high"), user("synthetic SDK follow-up")])
    end

    test "does not enforce the provider's consecutive-update restriction" do
      assert_preserved([update("high"), update("low"), user("synthetic request")])
    end

    test "keeps the update and async calls through an anchored tool-result replay" do
      input = [user("synthetic opener"), update("high"), Map.put(@function_call, "async", true), function_output(), update("low"), Map.put(@custom_call, "async", false), custom_output()]
      body = request(input, %{"previous_response_id" => "resp_configuration_async_anchor"})

      assert {:ok, validated} = Responses.validate(body)
      assert validated["input"] == input
      assert validated["previous_response_id"] == body["previous_response_id"]
      assert {:ok, %{payload: payload}} = Responses.coerce(body)
      assert payload["input"] == input
      assert payload["previous_response_id"] == body["previous_response_id"]
    end

    test "names the original client index even after a preceding reasoning item would be dropped" do
      reasoning = %{"type" => "reasoning", "summary" => [], "encrypted_content" => "synthetic-replay-cipher"}
      assert_rejected(request([user("synthetic request"), reasoning, %{"type" => "configuration_update", "reasoning" => %{}}]), "missing_required_parameter", "input[2].reasoning.effort")
      assert_rejected(request([user("synthetic request"), reasoning, Map.put(@custom_call, "async", nil), custom_output()]), "invalid_type", "input[2].async")
    end

    for {label, item, code, suffix} <- [
          {"missing reasoning", %{"type" => "configuration_update"}, "missing_required_parameter", ".reasoning"},
          {"missing effort", %{"type" => "configuration_update", "reasoning" => %{}}, "missing_required_parameter", ".reasoning.effort"},
          {"unknown root key", %{"type" => "configuration_update", "reasoning" => %{"effort" => "high"}, "zz_unknown" => true}, "unknown_parameter", ".zz_unknown"},
          {"unknown reasoning key", %{"type" => "configuration_update", "reasoning" => %{"effort" => "high", "zz_unknown" => true}}, "unknown_parameter", ".reasoning.zz_unknown"},
          {"a content-only malformed update", %{"type" => "configuration_update", "content" => ""}, "missing_required_parameter", ".reasoning"},
          {"content beside valid reasoning", %{"type" => "configuration_update", "reasoning" => %{"effort" => "high"}, "content" => ""}, "unknown_parameter", ".content"}
        ] do
      test "rejects #{label} at the exact input coordinate without rewriting it" do
        assert_rejected(request([user("synthetic opener"), assistant("synthetic answer"), unquote(Macro.escape(item))]), unquote(code), "input[2]" <> unquote(suffix))
      end
    end

    for {label, value} <- [{"null", nil}, {"string", "high"}, {"list", []}, {"integer", 7}, {"boolean", true}] do
      test "rejects #{label} reasoning as invalid_type" do
        item = %{"type" => "configuration_update", "reasoning" => unquote(Macro.escape(value))}
        assert_rejected(request([user("synthetic request"), item]), "invalid_type", "input[1].reasoning")
      end
    end

    for {label, value} <- [{"null", nil}, {"object", %{}}, {"list", []}, {"integer", 7}, {"boolean", false}] do
      test "rejects #{label} effort as invalid_type" do
        item = %{"type" => "configuration_update", "reasoning" => %{"effort" => unquote(Macro.escape(value))}}
        assert_rejected(request([user("synthetic request"), item]), "invalid_type", "input[1].reasoning.effort")
      end
    end
  end

  describe "async declarations are optional booleans, including namespace members" do
    for value <- [true, false] do
      test "preserves async=#{value} on function and custom declarations and both namespace members" do
        tools = [Map.put(@function, "async", unquote(value)), Map.put(@custom, "async", unquote(value)), namespace(unquote(value))]
        body = request([user("synthetic request")], %{"tools" => tools})
        assert {:ok, validated} = Responses.validate(body)
        assert validated["tools"] == tools
        assert {:ok, %{payload: payload}} = Responses.coerce(body)
        assert payload["tools"] == tools
      end
    end

    test "does not invent async when the client omits it" do
      tools = [@function, @custom, namespace(false) |> Map.update!("tools", &Enum.map(&1, fn tool -> Map.delete(tool, "async") end))]
      assert {:ok, %{payload: payload}} = Responses.coerce(request([user("synthetic request")], %{"tools" => tools}))
      assert payload["tools"] == tools
    end

    for {label, value} <- [{"null", nil}, {"string", "yes"}, {"integer", 1}, {"object", %{}}, {"list", []}],
        kind <- [:function, :custom, :namespace_function, :namespace_custom] do
      test "rejects #{label} async on #{kind} at the declaration's indexed path" do
        assert_invalid_declaration(unquote(kind), unquote(Macro.escape(value)))
      end
    end

    for value <- [true, false, nil] do
      test "refuses async=#{inspect(value)} on the namespace wrapper as unknown_parameter" do
        wrapper = namespace(true) |> Map.put("async", unquote(value))
        assert_rejected(request([user("synthetic request")], %{"tools" => [@function, wrapper]}), "unknown_parameter", "tools[1].async")
      end
    end
  end

  describe "async tool declarations inside client-owned manifests" do
    for value <- [true, false], type <- [:additional_tools, :tool_search_output] do
      test "preserves async=#{value} in #{type} function, custom and namespace declarations" do
        tools = [Map.put(@function, "async", unquote(value)), Map.put(@custom, "async", unquote(value)), namespace(unquote(value))]
        item = manifest(unquote(type), tools)
        assert_preserved([user("synthetic request"), item, update("high"), user("synthetic follow-up")])
      end
    end

    for type <- [:additional_tools, :tool_search_output] do
      test "keeps #{type} async type and wrapper errors at original client coordinates" do
        reasoning = %{"type" => "reasoning", "summary" => [], "encrypted_content" => "synthetic-replay-cipher"}
        item = manifest(unquote(type), [@function, put_in(namespace(false), ["tools", Access.at(1), "async"], nil)])
        assert_rejected(request([user("synthetic request"), reasoning, item]), "invalid_type", "input[2].tools[1].tools[1].async")
        wrapper = manifest(unquote(type), [@function, Map.put(namespace(false), "async", true)])
        assert_rejected(request([user("synthetic request"), reasoning, wrapper]), "unknown_parameter", "input[2].tools[1].async")
      end
    end
  end

  describe "async replayed calls stay client-owned" do
    test "does not invent async on replayed function or custom calls that omit it" do
      assert_preserved([user("synthetic request"), update("high"), @function_call, function_output(), @custom_call, custom_output()])
    end

    for value <- [true, false], type <- [:function, :custom] do
      test "preserves async=#{value} on a replayed #{type} call beside its client result" do
        call = call(unquote(type)) |> Map.put("async", unquote(value)) |> Map.put("status", "completed")
        output = output(unquote(type))
        body = request([user("synthetic request"), update("high"), call, output])
        expected = [user("synthetic request"), update("high"), Map.delete(call, "status"), output]

        assert {:ok, validated} = Responses.validate(body)
        assert validated["input"] == expected
        assert {:ok, %{payload: payload}} = Responses.coerce(body)
        assert payload["input"] == expected
      end
    end

    for {label, value} <- [{"null", nil}, {"string", "yes"}, {"integer", 1}, {"object", %{}}, {"list", []}], type <- [:function, :custom] do
      test "rejects #{label} async on a replayed #{type} call at the exact input index" do
        item = call(unquote(type)) |> Map.put("async", unquote(Macro.escape(value)))
        assert_rejected(request([user("synthetic request"), update("high"), item, output(unquote(type))]), "invalid_type", "input[2].async")
      end
    end
  end

  describe "public output normalization and its following replay" do
    for value <- [true, false] do
      test "retains async=#{value} in JSON, SSE items and terminal output, including namespace restoration" do
        assert_public_output_replay(unquote(value))
      end
    end
  end

  @spec assert_preserved([map()]) :: :ok
  defp assert_preserved(input) do
    body = request(input)
    assert {:ok, validated} = Responses.validate(body)
    assert validated["input"] == input
    assert {:ok, %{payload: payload}} = Responses.coerce(body)
    assert payload["input"] == input
    :ok
  end

  @spec assert_rejected(map(), String.t(), String.t()) :: :ok
  defp assert_rejected(body, code, param) do
    assert {:error, %{status: 400, code: ^code, param: ^param}} = Responses.validate(body)
    assert {:error, %{status: 400, code: ^code, param: ^param}} = Responses.coerce(body)
    :ok
  end

  @spec assert_invalid_declaration(atom(), term()) :: :ok
  defp assert_invalid_declaration(kind, value) do
    {tool, param} =
      case kind do
        :function -> {Map.put(@function, "async", value), "tools[1].async"}
        :custom -> {Map.put(@custom, "async", value), "tools[1].async"}
        :namespace_function -> {put_in(namespace(false), ["tools", Access.at(0), "async"], value), "tools[1].tools[0].async"}
        :namespace_custom -> {put_in(namespace(false), ["tools", Access.at(1), "async"], value), "tools[1].tools[1].async"}
      end

    assert_rejected(request([user("synthetic request")], %{"tools" => [@function, tool]}), "invalid_type", param)
  end

  @spec assert_public_output_replay(boolean()) :: :ok
  defp assert_public_output_replay(value) do
    items = [Map.merge(@function_call, %{"name" => "synthetic_member_lookup", "async" => value}), Map.merge(@custom_call, %{"name" => "synthetic_member_patch", "async" => value})]
    body = request([user("synthetic request")], %{"tools" => [namespace(value)]})
    assert {:ok, %{request_options: options}} = Responses.coerce(body)
    response = %{"id" => "resp_configuration_async_output", "status" => "completed", "output" => items}
    expected = Enum.map(items, &Map.put(&1, "namespace", "synthetic"))

    assert {:ok, json} = Responses.response_from_sse(CodexPooler.JSON.encode!(response), options)
    assert json["output"] == expected

    events = [
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => List.first(items)},
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => List.first(items)},
      %{"type" => "response.output_item.added", "output_index" => 1, "item" => List.last(items)},
      %{"type" => "response.output_item.done", "output_index" => 1, "item" => List.last(items)},
      %{"type" => "response.completed", "response" => response}
    ]

    sse = Enum.map_join(events, fn event -> "event: #{event["type"]}\ndata: #{CodexPooler.JSON.encode!(event)}\n\n" end)
    assert {:ok, collected} = Responses.response_from_sse(sse, options)
    assert collected["output"] == expected

    {normalized, _state} = PublicResponses.normalize_data(sse, PublicResponses.new_state(options.openai_compatibility.tool_namespaces))
    normalized_events = for block <- String.split(normalized, "\n\n", trim: true), "data: " <> data <- String.split(block, "\n"), data != "[DONE]", do: CodexPooler.JSON.decode!(data)
    assert for(%{"type" => "response.output_item.done", "item" => item} <- normalized_events, do: item) == expected
    assert List.last(normalized_events)["response"]["output"] == expected
    assert_preserved([user("synthetic request"), update("high")] ++ collected["output"] ++ [function_output(), custom_output()])
  end

  @spec request([map()], map()) :: map()
  defp request(input, extra \\ %{}), do: Map.merge(%{"model" => @model, "input" => input, "store" => false}, extra)

  @spec namespace(boolean()) :: map()
  defp namespace(value), do: %{"type" => "namespace", "name" => "synthetic", "description" => "Synthetic fixture namespace", "tools" => [Map.merge(@function, %{"name" => "synthetic_member_lookup", "async" => value}), Map.merge(@custom, %{"name" => "synthetic_member_patch", "async" => value})]}

  @spec update(String.t()) :: map()
  defp update(effort), do: %{"type" => "configuration_update", "reasoning" => %{"effort" => effort}}

  @spec user(String.t()) :: map()
  defp user(text), do: %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}

  @spec assistant(String.t()) :: map()
  defp assistant(text), do: %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => text}]}

  @spec call(:function | :custom) :: map()
  defp call(:function), do: @function_call
  defp call(:custom), do: @custom_call

  @spec output(:function | :custom) :: map()
  defp output(:function), do: function_output()
  defp output(:custom), do: custom_output()

  @spec function_output() :: map()
  defp function_output, do: %{"type" => "function_call_output", "call_id" => @function_call["call_id"], "output" => "synthetic client function result"}

  @spec manifest(:additional_tools | :tool_search_output, [map()]) :: map()
  defp manifest(:additional_tools, tools), do: %{"type" => "additional_tools", "role" => "developer", "tools" => tools}
  defp manifest(:tool_search_output, tools), do: %{"type" => "tool_search_output", "tools" => tools}

  @spec custom_output() :: map()
  defp custom_output, do: %{"type" => "custom_tool_call_output", "call_id" => @custom_call["call_id"], "output" => "synthetic client custom result"}
end
