defmodule CodexPooler.Gateway.Payloads.PublicCompactionTriggerTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Payloads.CompactionTrigger

  test "canonical Responses projection forces store false and retains one terminal trigger" do
    payload = compact_projection_payload()

    projected = CompactionTrigger.project_responses_payload(payload)

    assert projected["store"] == false
    refute Map.has_key?(projected, "stream")
    assert List.last(projected["input"]) == %{"type" => "compaction_trigger"}

    assert Enum.count(projected["input"], &match?(%{"type" => "compaction_trigger"}, &1)) == 1

    assert MapSet.new(Map.keys(projected)) ==
             MapSet.new(~w(
               model
               instructions
               input
               tools
               parallel_tool_calls
               reasoning
               service_tier
               prompt_cache_key
               prompt_cache_options
               text
               store
             ))
  end

  test "native compact projection omits store, stream, and compaction triggers" do
    projected = CompactionTrigger.project_native_payload(compact_projection_payload())

    refute Map.has_key?(projected, "store")
    refute Map.has_key?(projected, "stream")
    refute Enum.any?(projected["input"], &match?(%{"type" => "compaction_trigger"}, &1))

    assert MapSet.new(Map.keys(projected)) ==
             MapSet.new(~w(
               model
               instructions
               input
               tools
               parallel_tool_calls
               reasoning
               service_tier
               prompt_cache_key
               prompt_cache_options
               text
             ))
  end

  test "legacy SSE keeps first valid compact output and native replay metadata byte-identical" do
    first_invalid = %{
      "type" => "compaction",
      "encrypted_content" => " \t\n",
      "id" => nil,
      "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn-invalid"}
    }

    first_valid = %{
      "type" => "compaction_summary",
      "encrypted_content" => "opaque-legacy-content",
      "id" => "",
      "internal_chat_message_metadata_passthrough" => %{"turn_id" => ""}
    }

    assert {:ok, %{raw_body: body}} =
             CompactionTrigger.adapt_gateway_result(
               gateway_result(%{
                 "id" => "resp_legacy_compaction",
                 "output" => [first_invalid, first_valid]
               }),
               :sse
             )

    [done, completed] = sse_events(body)

    expected_item = %{
      "type" => "compaction",
      "encrypted_content" => " \t\n",
      "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn-invalid"}
    }

    assert done == %{"type" => "response.output_item.done", "item" => expected_item}
    assert get_in(completed, ["response", "output"]) == [expected_item]
  end

  test "public modes preserve only replay-safe fields and every emitted item is replayable" do
    for {source_name, source} <- public_sources() do
      for mode <- [:response, :public_sse, :websocket] do
        assert {:ok, adapted} =
                 CompactionTrigger.adapt_gateway_result(
                   gateway_result(
                     Map.merge(source, %{
                       "id" => "resp_public_#{source_name}",
                       "usage" => %{
                         "input_tokens" => 9,
                         "output_tokens" => 1,
                         "total_tokens" => 10
                       }
                     })
                   ),
                   mode
                 )

        {response, items} = public_result(adapted, mode)

        assert response["id"] == "resp_public_#{source_name}"
        assert response["usage"]["total_tokens"] == 10
        assert Enum.uniq(items) == [expected_public_item()]

        for item <- items do
          assert {:ok, %{payload: %{"input" => [^item]}}} =
                   Responses.coerce(%{
                     "model" => "gpt-public-compaction-fixture",
                     "input" => [item]
                   })
        end
      end
    end
  end

  test "public modes preserve ID absence, null, or binary exactly" do
    for {id_name, source_id, expected_id} <- [
          {:absent, :absent, :absent},
          {:null, nil, nil},
          {:empty, "", ""},
          {:binary, " opaque item id ", " opaque item id "}
        ] do
      source_item =
        %{"type" => "compaction", "encrypted_content" => "opaque-#{id_name}"}
        |> maybe_put_source_id(source_id)

      assert {:ok, adapted} =
               CompactionTrigger.adapt_gateway_result(
                 gateway_result(%{"output" => [source_item]}),
                 :response
               )

      item = adapted.raw_body |> Jason.decode!() |> get_in(["output", Access.at(0)])

      if expected_id == :absent do
        refute Map.has_key?(item, "id")
      else
        assert Map.fetch!(item, "id") == expected_id
      end
    end
  end

  test "public selection rejects the first compact output candidate without fallback" do
    for invalid_content <- [nil, 17, "", " \t\r\n"] do
      source = %{
        "output" => [
          %{"type" => "compaction_summary", "encrypted_content" => invalid_content},
          %{"type" => "compaction", "encrypted_content" => "opaque-later-content"}
        ],
        "compaction_summary" => %{"encrypted_content" => "opaque-fallback-content"}
      }

      for mode <- [:response, :public_sse, :websocket] do
        assert {:error,
                %{
                  status: 502,
                  code: "invalid_compaction_response",
                  message:
                    "upstream compact response did not include encrypted compaction content"
                }} = CompactionTrigger.adapt_gateway_result(gateway_result(source), mode)
      end
    end
  end

  test "public selection uses top-level summary only without an output compact candidate" do
    assert {:ok, adapted} =
             CompactionTrigger.adapt_gateway_result(
               gateway_result(%{
                 "output" => [%{"type" => "message", "encrypted_content" => "ignored"}],
                 "compaction_summary" =>
                   expected_public_item()
                   |> Map.delete("type")
                   |> Map.put("native_unknown", "drop")
               }),
               :response
             )

    assert get_in(Jason.decode!(adapted.raw_body), ["output", Access.at(0)]) ==
             expected_public_item()
  end

  defp gateway_result(body) do
    {:ok,
     %{
       status: 200,
       headers: [{"content-type", "application/json"}],
       raw_body: Jason.encode!(body)
     }}
  end

  defp compact_projection_payload do
    %{
      "model" => "gpt-compact-projection",
      "instructions" => "synthetic instruction",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => []},
        %{"type" => "compaction_trigger"}
      ],
      "tools" => [],
      "parallel_tool_calls" => false,
      "reasoning" => %{"effort" => "low"},
      "service_tier" => "default",
      "promptCacheKey" => "synthetic-cache-key",
      "prompt_cache_options" => %{"mode" => "synthetic"},
      "text" => %{"format" => %{"type" => "text"}},
      "store" => true,
      "stream" => true,
      "unsupported" => "drop"
    }
  end

  defp public_sources do
    item =
      expected_public_item()
      |> Map.put("type", "compaction_summary")
      |> Map.put("internal_chat_message_metadata_passthrough", %{
        "turn_id" => "native-turn-must-drop",
        "native_nested" => "drop"
      })
      |> Map.put("summary", "plaintext-must-drop")
      |> Map.put("native_unknown", "drop")

    [
      {:output, %{"output" => [item]}},
      {:top_level, %{"compaction_summary" => Map.delete(item, "type")}}
    ]
  end

  defp expected_public_item do
    %{
      "type" => "compaction",
      "encrypted_content" => " \u0000opaque-encrypted-content\n",
      "id" => "cmp_public_item"
    }
  end

  defp public_result(%{raw_body: body}, :response) do
    response = Jason.decode!(body)
    {response, response["output"]}
  end

  defp public_result(%{raw_body: body}, :public_sse) do
    [done, completed] = sse_events(body)
    response = completed["response"]
    {response, [done["item"] | response["output"]]}
  end

  defp public_result(%{websocket_messages: [done, completed]}, :websocket) do
    response = completed["response"]
    {response, [done["item"] | response["output"]]}
  end

  defp maybe_put_source_id(item, :absent), do: item
  defp maybe_put_source_id(item, id), do: Map.put(item, "id", id)

  defp sse_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.reject(&(&1 == "data: [DONE]"))
    |> Enum.map(fn block ->
      block
      |> String.split("\n")
      |> Enum.find_value(fn
        "data: " <> data -> Jason.decode!(data)
        _line -> nil
      end)
    end)
  end
end
