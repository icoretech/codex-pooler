defmodule CodexPooler.Gateway.OpenAICompatibility.ChatStreamArgumentsContractTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.ChatCompletions

  test "final argument and item snapshots append only missing bytes and never duplicate complete initial arguments" do
    arguments = CodexPooler.JSON.encode!(%{"prompt" => "synthetic", "description" => "fixture"})
    item = item("a", arguments)

    for prefix_size <- [0, 12, byte_size(arguments)], source <- [:arguments, :item, :terminal] do
      prefix = binary_part(arguments, 0, prefix_size)
      initial = event("response.output_item.added", %{"output_index" => 0, "item" => Map.put(item, "arguments", prefix)})

      snapshot =
        case source do
          :arguments -> [event("response.function_call_arguments.done", %{"output_index" => 0, "item_id" => item["id"], "arguments" => arguments})]
          :item -> [event("response.output_item.done", %{"output_index" => 0, "item" => item})]
          :terminal -> []
        end

      {chunks, state, raw} = normalize([initial] ++ snapshot ++ snapshot ++ [completed([item])])
      assert argument_summary(chunks) == [{0, byte_size(arguments), digest(arguments)}]
      assert call_headers(chunks) == [{0, item["call_id"], item["name"]}]
      assert state.terminal_seen?
      assert count_done(raw) == 1
    end
  end

  test "completed item and terminal snapshots restore an unseen call with its identity" do
    item = item("a", "{}")

    for events <- [[event("response.output_item.done", %{"output_index" => 0, "item" => item}), completed([item])], [completed([item])]] do
      {chunks, _state, raw} = normalize(events)
      assert argument_summary(chunks) == [{0, 2, digest("{}")}]
      assert call_headers(chunks) == [{0, item["call_id"], item["name"]}]
      assert count_done(raw) == 1
    end
  end

  test "interleaved calls after reasoning retain independent prefix state across bytewise Unicode and CRLF framing" do
    first = item("a", CodexPooler.JSON.encode!(%{"prompt" => "synthetic 漢字 🧪\r\nfixture"}))
    second = item("b", CodexPooler.JSON.encode!(%{"path" => "fixture.txt"}))
    reasoning = %{"type" => "reasoning", "id" => "rs_fixture", "summary" => []}

    events = [
      event("response.output_item.added", %{"output_index" => 0, "item" => reasoning}),
      event("response.output_item.added", %{"output_index" => 1, "item" => Map.put(first, "arguments", "")}),
      event("response.output_item.added", %{"output_index" => 2, "item" => Map.put(second, "arguments", "")}),
      event("response.function_call_arguments.delta", %{"output_index" => 2, "item_id" => second["id"], "delta" => second["arguments"]}),
      event("response.function_call_arguments.delta", %{"output_index" => 1, "item_id" => first["id"], "delta" => "{"}),
      event("response.function_call_arguments.done", %{"output_index" => 1, "item_id" => first["id"], "arguments" => first["arguments"]}),
      completed([reasoning, first, second])
    ]

    {chunks, _state, _raw} = normalize(events, %{}, true)
    assert argument_summary(chunks) == [{0, byte_size(first["arguments"]), digest(first["arguments"])}, {1, byte_size(second["arguments"]), digest(second["arguments"])}]
  end

  test "flat and nested custom calls recover final input without parsing it or duplicating their metadata" do
    input = "synthetic patch\nline"
    custom = %{"type" => "custom_tool_call", "id" => "ct_fixture", "call_id" => "call_fixture", "name" => "fixture_patch", "input" => input}

    for declaration <- [%{"type" => "custom", "name" => "fixture_patch"}, %{"type" => "custom", "custom" => %{"name" => "fixture_patch"}}] do
      events = [event("response.output_item.added", %{"output_index" => 0, "item" => Map.put(custom, "input", "")}), event("response.custom_tool_call_input.done", %{"output_index" => 0, "item_id" => custom["id"], "input" => input}), event("response.output_item.done", %{"output_index" => 0, "item" => custom}), completed([custom])]
      {chunks, _state, _raw} = normalize(events, %{"tools" => [declaration]})
      assert argument_summary(chunks) == [{0, byte_size(input), digest(input)}]
      assert call_headers(chunks) == [{0, custom["call_id"], custom["name"]}]
      [first | _rest] = calls(chunks)
      assert first["type"] == if(Map.has_key?(declaration, "custom"), do: "custom", else: "function")
    end
  end

  test "shorter divergent and conflicting identity snapshots fail once without success or leaking content" do
    item = item("a", "{\"prompt\":\"synthetic\"}")

    cases = [
      event("response.function_call_arguments.done", %{"output_index" => 0, "item_id" => item["id"], "arguments" => "{"}),
      event("response.function_call_arguments.done", %{"output_index" => 0, "item_id" => item["id"], "arguments" => "[private-snapshot-sentinel]"}),
      event("response.function_call_arguments.done", %{"output_index" => 0, "item_id" => "fc_other", "arguments" => item["arguments"]}),
      event("response.output_item.done", %{"output_index" => 0, "item" => Map.put(item, "call_id", "call_other")})
    ]

    for snapshot <- cases do
      {chunks, state, raw} = normalize([event("response.output_item.added", %{"output_index" => 0, "item" => item}), snapshot, snapshot, completed([item])])
      assert [%{"error" => %{"code" => "server_error", "message" => "upstream tool call snapshot is inconsistent"}}] = Enum.filter(chunks, &Map.has_key?(&1, "error"))
      assert state.terminal_seen?
      assert count_done(raw) == 0
      assert Enum.all?(chunks, &(get_in(&1, ["choices", Access.at(0), "finish_reason"]) == nil))
      refute raw =~ "private-snapshot-sentinel"
    end
  end

  test "argument tracking retains digest and byte count instead of an accumulated raw copy" do
    arguments = String.duplicate("synthetic-argument-fragment", 40_000)
    item = item("a", "")
    {_chunks, state, _raw} = normalize([event("response.output_item.added", %{"output_index" => 0, "item" => item}), event("response.function_call_arguments.delta", %{"output_index" => 0, "item_id" => item["id"], "delta" => arguments})])
    assert :erlang.external_size(state) < 20_000
    refute inspect(state) =~ "synthetic-argument-fragment"
  end

  test "unidentified argument snapshots do not invent a tool index or attach to an unproven identity" do
    item = item("a", "")

    snapshots = [
      event("response.function_call_arguments.done", %{"item_id" => item["id"], "arguments" => "{}"}),
      event("response.function_call_arguments.done", %{"output_index" => 0, "arguments" => "{}"}),
      event("response.function_call_arguments.done", %{"output_index" => 9, "item_id" => item["id"], "arguments" => "{}"})
    ]

    {chunks, _state, _raw} = normalize([event("response.output_item.added", %{"output_index" => 0, "item" => item}) | snapshots])
    assert argument_summary(chunks) == [{0, 0, digest("")}]

    no_id = Map.delete(item, "id")
    {chunks, _state, _raw} = normalize([event("response.output_item.added", %{"output_index" => 0, "item" => no_id}), event("response.function_call_arguments.done", %{"output_index" => 0, "item_id" => "fc_other", "arguments" => "{}"})])
    assert argument_summary(chunks) == [{0, 0, digest("")}]
  end

  test "an item snapshot may add its provider item id when its existing call identity agrees" do
    item = item("a", "{}")
    initial = item |> Map.delete("id") |> Map.put("arguments", "{")
    {chunks, _state, raw} = normalize([event("response.output_item.added", %{"output_index" => 0, "item" => initial}), event("response.output_item.done", %{"output_index" => 0, "item" => item}), completed([item])])
    assert argument_summary(chunks) == [{0, 2, digest("{}")}]
    assert call_headers(chunks) == [{0, item["call_id"], item["name"]}]
    assert count_done(raw) == 1
  end

  defp normalize(events, payload \\ %{}, bytes? \\ false) do
    separator = if bytes?, do: "\r\n", else: "\n"
    wire = Enum.map_join(events, fn event -> "event: " <> event["type"] <> separator <> "data: " <> CodexPooler.JSON.encode!(event) <> separator <> separator end)
    inputs = if bytes?, do: for(<<byte <- wire>>, do: <<byte>>), else: [wire]

    {output, state} =
      Enum.reduce(inputs, {[], ChatCompletions.stream_state(Map.put(payload, "model", "sample-model"))}, fn input, {output, state} ->
        {chunk, state} = ChatCompletions.normalize_stream_data(input, state)
        {[output, chunk], state}
      end)

    raw = IO.iodata_to_binary(output)
    chunks = raw |> String.split("\n\n", trim: true) |> Enum.reject(&(&1 == "data: [DONE]")) |> Enum.map(fn "data: " <> json -> CodexPooler.JSON.decode!(json) end)
    {chunks, state, raw}
  end

  defp calls(chunks), do: Enum.flat_map(chunks, &(get_in(&1, ["choices", Access.at(0), "delta", "tool_calls"]) || []))
  defp call_headers(chunks), do: calls(chunks) |> Enum.filter(&Map.has_key?(&1, "id")) |> Enum.map(&{&1["index"], &1["id"], (&1["function"] || &1["custom"])["name"]})

  defp argument_summary(chunks) do
    calls(chunks)
    |> Enum.reduce(%{}, fn call, acc ->
      part = call["function"] || call["custom"]
      Map.update(acc, call["index"], part["arguments"] || part["input"] || "", &(&1 <> (part["arguments"] || part["input"] || "")))
    end)
    |> Enum.sort()
    |> Enum.map(fn {index, value} -> {index, byte_size(value), digest(value)} end)
  end

  defp digest(value), do: :crypto.hash(:sha256, value)
  defp count_done(raw), do: length(String.split(raw, "data: [DONE]")) - 1
  defp item(id, arguments), do: %{"type" => "function_call", "id" => "fc_" <> id, "call_id" => "call_" <> id, "name" => "fixture_" <> id, "arguments" => arguments, "status" => "completed"}
  defp event(type, fields), do: Map.put(fields, "type", type)
  defp completed(items), do: event("response.completed", %{"response" => %{"id" => "resp_fixture", "status" => "completed", "output" => items}})
end
