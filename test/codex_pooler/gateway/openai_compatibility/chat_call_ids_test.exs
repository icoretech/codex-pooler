defmodule CodexPooler.Gateway.OpenAICompatibility.ChatCallIdsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.{Chat, Responses}
  alias CodexPooler.Gateway.OpenAICompatibility.Chat.CallIds

  test "64-byte IDs pass unchanged and 65-byte IDs retain matched call/result associations" do
    for bytes <- [64, 65] do
      original = String.duplicate("a", bytes)
      assert {:ok, result} = Chat.coerce(payload(pair(original)), %{request_bytes: 999})
      [call, output] = result.payload["input"]
      assert call["call_id"] == output["call_id"]
      assert byte_size(call["call_id"]) <= 64

      if bytes == 64 do
        assert call["call_id"] == original
        assert result.request_options.request_metadata.request_bytes == 999
      else
        refute call["call_id"] == original
        assert call["call_id"] == "call_TEnxpZenpXzfLCyKa_5OXCdc0-KfBeD4Q2PqSM3UANw"
        assert result.request_options.request_metadata.request_bytes == byte_size(CodexPooler.JSON.encode!(result.payload))
      end

      assert result.chat_payload == payload(pair(original))
    end
  end

  test "shared prefixes remain distinct and repeated IDs map identically independent of request order" do
    prefix = String.duplicate("a", 64)
    first = prefix <> "x"
    second = prefix <> "y"
    assert {:ok, forward} = Chat.coerce(payload(pair(first) ++ pair(second) ++ pair(first)))
    assert {:ok, reverse} = Chat.coerce(payload(pair(second) ++ pair(first)))
    ids = Enum.map(forward.payload["input"], & &1["call_id"])
    assert [a, a, b, b, a, a] = ids
    refute a == b
    assert Enum.map(reverse.payload["input"], & &1["call_id"]) == [b, b, a, a]
    assert Enum.all?(ids, &Regex.match?(~r/\Acall_[A-Za-z0-9_-]{43}\z/, &1))
  end

  test "UTF8 limits count bytes rather than codepoints" do
    for {original, changed?} <- [{String.duplicate("é", 32), false}, {String.duplicate("é", 33), true}] do
      assert {:ok, result} = Chat.coerce(payload(pair(original)))
      [call, output] = result.payload["input"]
      assert call["call_id"] != original == changed?
      assert byte_size(call["call_id"]) <= 64
      assert output["call_id"] == call["call_id"]
    end
  end

  test "short IDs colliding with a compacted ID reject explicitly in either order" do
    long = String.duplicate("c", 65)
    assert {:ok, normalized} = Chat.coerce(payload(pair(long)))
    compact = hd(normalized.payload["input"])["call_id"]
    assert byte_size(compact) <= 64

    for messages <- [pair(long) ++ pair(compact), pair(compact) ++ pair(long)] do
      assert {:error, %{status: 400, code: "invalid_request", param: "messages", message: "tool call IDs collide after normalization"}} = Chat.coerce(payload(messages))
    end
  end

  test "output-only and output-before-call histories normalize to the same ID" do
    original = String.duplicate("o", 65)
    [call_message, output_message] = pair(original)
    assert {:ok, ordinary} = Chat.coerce(payload([call_message, output_message]))
    expected = hd(ordinary.payload["input"])["call_id"]

    for messages <- [[output_message], [output_message, call_message]] do
      assert {:ok, result} = Chat.coerce(payload(messages))
      assert Enum.all?(result.payload["input"], &(&1["call_id"] == expected))
      assert hd(result.payload["input"])["type"] == "function_call_output"
    end
  end

  test "arguments tool definitions output content and media survive with only call IDs changed" do
    original = String.duplicate("p", 65)
    media = %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/image.png"}}
    tool = %{"type" => "function", "function" => %{"name" => "fixture", "parameters" => %{"type" => "object", "properties" => %{}}}}
    messages = [%{"role" => "user", "content" => [media, %{"type" => "text", "text" => "synthetic"}]} | pair(original)]
    request = Map.put(payload(messages), "tools", [tool])
    control = Map.put(payload([hd(messages) | pair("short")]), "tools", [tool])
    assert {:ok, actual} = Chat.coerce(request)
    assert {:ok, expected} = Chat.coerce(control)
    strip_ids = fn result -> Map.update!(result.payload, "input", &Enum.map(&1, fn item -> Map.delete(item, "call_id") end)) end
    assert strip_ids.(actual) == strip_ids.(expected)
    assert actual.chat_payload == request
  end

  test "canonical function and custom IDs normalize without rewriting nested arbitrary JSON or other item kinds" do
    original = String.duplicate("n", 65)
    opaque = %{"call_id" => original, "type" => "function_call", "nested" => [%{"call_id" => original}]}
    types = ~w(function_call function_call_output custom_tool_call custom_tool_call_output)
    items = Enum.map(types, &%{"type" => &1, "call_id" => original, "arguments" => original, "output" => opaque})
    untouched = %{"type" => "shell_call", "call_id" => original}
    request = %{"input" => items ++ [untouched], "metadata" => opaque}
    assert {:ok, result} = CallIds.normalize(request, %{"messages" => [%{}]})
    assert List.last(result["input"]) == untouched
    assert result["metadata"] == opaque
    normalized = Enum.take(result["input"], 4)
    assert normalized |> Enum.map(& &1["call_id"]) |> Enum.uniq() |> length() == 1
    assert Enum.all?(normalized, &(byte_size(&1["call_id"]) <= 64))
    assert Enum.map(normalized, &Map.delete(&1, "call_id")) == Enum.map(items, &Map.delete(&1, "call_id"))
  end

  test "direct Responses and Chat input fallback preserve long IDs" do
    original = String.duplicate("r", 65)
    input = [%{"type" => "function_call", "call_id" => original, "name" => "fixture", "arguments" => "{}"}, %{"type" => "function_call_output", "call_id" => original, "output" => "synthetic"}]
    request = %{"model" => "sample-model", "input" => input}
    assert {:ok, direct} = Responses.coerce(request)
    assert Enum.all?(direct.payload["input"], &(&1["call_id"] == original))

    for raw <- [request, Map.put(request, "messages", [])] do
      assert {:ok, fallback} = Chat.coerce(raw)
      assert fallback.payload["input"] == direct.payload["input"]
    end
  end

  test "Chat previous_response_id remains unsupported" do
    request = Map.put(payload(pair(String.duplicate("a", 65))), "previous_response_id", "resp_synthetic_fixture")
    assert {:error, %{status: 400, code: "unsupported_parameter", param: "previous_response_id"}} = Chat.coerce(request)
  end

  defp pair(id) do
    [%{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => id, "type" => "function", "function" => %{"name" => "fixture", "arguments" => "{\"value\":\"synthetic\"}"}}]}, %{"role" => "tool", "tool_call_id" => id, "content" => "synthetic-result"}]
  end

  defp payload(messages), do: %{"model" => "sample-model", "messages" => messages}
end
