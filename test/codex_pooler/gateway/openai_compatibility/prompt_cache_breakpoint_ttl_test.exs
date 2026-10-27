defmodule CodexPooler.Gateway.OpenAICompatibility.PromptCacheBreakpointTTLTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.{Chat, Responses}

  for ttl <- [:absent, "30m", "12h"] do
    test "Responses preserves supported content breakpoint TTL #{ttl}" do
      breakpoint = breakpoint(unquote(ttl))
      parts = response_parts(breakpoint)
      output_parts = Enum.reject(parts, &(Map.get(&1, "type") == "input_file" and Map.has_key?(&1, "file_id")))

      assert {:ok, result} =
               Responses.coerce(%{
                 "model" => "sample-model",
                 "input" => [
                   %{"role" => "system", "content" => [hd(parts)]},
                   %{"role" => "developer", "content" => [hd(parts)]},
                   %{"role" => "user", "content" => parts},
                   %{"type" => "function_call_output", "call_id" => "call_function", "output" => output_parts},
                   %{"type" => "custom_tool_call_output", "call_id" => "call_custom", "output" => output_parts}
                 ]
               })

      assert [%{"role" => "developer", "content" => [instruction]}, %{"role" => "developer"}, _, _, _] = result.payload["input"]
      assert instruction["prompt_cache_breakpoint"] == breakpoint
      refute Map.has_key?(result.payload, "instructions")
      assert breakpoints(result.payload) == List.duplicate(breakpoint, 18)
    end

    test "Chat preserves supported content breakpoint TTL #{ttl} when translating Responses input" do
      breakpoint = breakpoint(unquote(ttl))

      parts = [
        %{"type" => "text", "text" => "synthetic", "prompt_cache_breakpoint" => breakpoint},
        %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/synthetic.png"}, "prompt_cache_breakpoint" => breakpoint},
        %{"type" => "file", "file" => %{"file_id" => "file_synthetic"}, "prompt_cache_breakpoint" => breakpoint}
      ]

      assert {:ok, result} =
               Chat.coerce(%{
                 "model" => "sample-model",
                 "messages" => [
                   %{"role" => "system", "content" => [hd(parts)]},
                   %{"role" => "developer", "content" => [hd(parts)]},
                   %{"role" => "user", "content" => parts},
                   %{"role" => "tool", "tool_call_id" => "call_synthetic", "content" => [hd(parts)]}
                 ]
               })

      assert [%{"role" => "developer"}, %{"role" => "developer"} | _] = result.payload["input"]
      refute Map.has_key?(result.payload, "instructions")
      assert breakpoints(result.payload) == List.duplicate(breakpoint, 6)
    end
  end

  test "invalid nested TTLs have the same stable error through Responses and Chat" do
    for ttl <- [nil, "1h", "24h", 12, true, %{}, []], adapter <- [Responses, Chat] do
      payload = adapter_payload(adapter, %{"mode" => "explicit", "ttl" => ttl})

      assert {:error, %{status: 400, code: "invalid_request", message: "prompt_cache_breakpoint ttl is not supported", param: "input.prompt_cache_breakpoint.ttl"}} = adapter.coerce(payload)
    end
  end

  test "unknown breakpoint fields keep their deterministic precedence over TTL validation" do
    for adapter <- [Responses, Chat] do
      payload = adapter_payload(adapter, %{"mode" => "explicit", "ttl" => "1h", "zeta" => true, "alpha" => true})

      assert {:error, %{status: 400, code: "invalid_request", message: "prompt_cache_breakpoint field is not supported", param: "input.prompt_cache_breakpoint.alpha"}} = adapter.coerce(payload)
    end
  end

  for request_ttl <- ["30m", "12h"], breakpoint_ttl <- [:absent, "30m", "12h"], adapter <- [Responses, Chat] do
    test "#{adapter} keeps request TTL #{request_ttl} and breakpoint TTL #{breakpoint_ttl}" do
      assert_request_and_breakpoint_ttl!(unquote(adapter), unquote(request_ttl), unquote(breakpoint_ttl))
    end
  end

  test "unsupported request-level TTLs remain rejected" do
    for ttl <- [nil, "1h", "24h", 12, true, %{}, []], adapter <- [Responses, Chat] do
      payload = adapter_payload(adapter, breakpoint(:absent)) |> Map.put("prompt_cache_options", %{"ttl" => ttl})

      assert {:error, %{status: 400, code: "invalid_request", param: "prompt_cache_options.ttl"}} = adapter.coerce(payload)
    end
  end

  defp breakpoint_parts(%{"input" => input}), do: for(%{"content" => content} <- input, part <- content, Map.has_key?(part, "prompt_cache_breakpoint"), do: part["prompt_cache_breakpoint"])
  defp breakpoint_parts(%{}), do: []

  defp assert_request_and_breakpoint_ttl!(adapter, request_ttl, breakpoint_ttl) do
    breakpoint = breakpoint(breakpoint_ttl)

    payload =
      adapter_payload(adapter, breakpoint)
      |> Map.put("prompt_cache_options", %{"mode" => "explicit", "ttl" => request_ttl})

    assert {:ok, result} = adapter.coerce(payload)
    assert result.payload["prompt_cache_options"] == %{"mode" => "explicit", "ttl" => request_ttl}
    assert breakpoint_parts(result.payload) == [breakpoint]
  end

  defp breakpoint(:absent), do: %{"mode" => "explicit"}
  defp breakpoint(ttl), do: %{"mode" => "explicit", "ttl" => ttl}

  defp response_parts(breakpoint) do
    [
      %{"type" => "input_text", "text" => "synthetic", "prompt_cache_breakpoint" => breakpoint},
      %{"type" => "input_image", "image_url" => "https://example.com/synthetic.png", "prompt_cache_breakpoint" => breakpoint},
      %{"type" => "input_image", "file_id" => "file_image", "prompt_cache_breakpoint" => breakpoint},
      %{"type" => "input_file", "file_url" => "https://example.com/synthetic.txt", "prompt_cache_breakpoint" => breakpoint},
      %{"type" => "input_file", "filename" => "synthetic.txt", "file_data" => "data:text/plain;base64,c3ludGhldGlj", "prompt_cache_breakpoint" => breakpoint},
      %{"type" => "input_file", "file_id" => "file_synthetic", "prompt_cache_breakpoint" => breakpoint}
    ]
  end

  defp adapter_payload(Responses, breakpoint), do: %{"model" => "sample-model", "input" => [%{"role" => "user", "content" => [hd(response_parts(breakpoint))]}]}
  defp adapter_payload(Chat, breakpoint), do: %{"model" => "sample-model", "messages" => [%{"role" => "user", "content" => [%{"type" => "text", "text" => "synthetic", "prompt_cache_breakpoint" => breakpoint}]}]}

  defp breakpoints(%{} = value) do
    here = if Map.has_key?(value, "prompt_cache_breakpoint"), do: [value["prompt_cache_breakpoint"]], else: []
    here ++ Enum.flat_map(value, fn {_key, child} -> breakpoints(child) end)
  end

  defp breakpoints(value) when is_list(value), do: Enum.flat_map(value, &breakpoints/1)
  defp breakpoints(_value), do: []
end
