defmodule CodexPooler.Gateway.OpenAICompatibility.ChatTextPartsTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.OpenAICompatibility.{Chat, Responses}
  alias CodexPooler.Gateway.OpenAICompatibility.Chat.TextParts

  @limit 10_485_760
  @chunk_bytes 262_144

  test "oversized user and assistant text split losslessly while exact-bound text stays unchanged" do
    for role <- ["user", "assistant"], bytes <- [@limit, @limit + 1] do
      text = String.duplicate("x", bytes)
      assert {:ok, result} = Chat.coerce(payload([%{"role" => role, "content" => text}]))
      [item] = result.payload["input"]
      parts = item["content"]
      assert_summary(parts, text, bytes > @limit)
      assert Enum.all?(parts, &(&1["type"] == if(role == "assistant", do: "output_text", else: "input_text")))
      assert result.request_options.request_metadata.request_bytes == byte_size(CodexPooler.JSON.encode!(result.payload))
    end
  end

  test "UTF8 boundaries whitespace media order and the final cache breakpoint survive splitting" do
    text = String.duplicate("x", @chunk_bytes - 1) <> "🧪\r\n " <> String.duplicate("漢 ", div(@limit, 4)) <> "\n\t"
    media = %{"type" => "input_image", "image_url" => "https://example.com/image.png"}
    messages = [%{"role" => "user", "content" => [media, %{"type" => "text", "text" => text, "prompt_cache_breakpoint" => %{"mode" => "explicit"}}, %{"type" => "text", "text" => "tail"}]}]
    assert {:ok, result} = Chat.coerce(payload(messages))
    [item] = result.payload["input"]
    [first | rest] = item["content"]
    assert first == media
    assert List.last(rest) == %{"type" => "input_text", "text" => "tail"}
    parts = Enum.drop(rest, -1)
    assert_summary(parts, text, true)
    assert Enum.count(parts, &Map.has_key?(&1, "prompt_cache_breakpoint")) == 1
    assert List.last(parts)["prompt_cache_breakpoint"] == %{"mode" => "explicit"}
  end

  test "oversized normalized instructions become one leading developer item after lifting without changing bytes" do
    first = String.duplicate("a", @limit) <> " ending "
    messages = [%{"role" => "system", "content" => first}, %{"role" => "developer", "content" => "  final directive  "}, %{"role" => "user", "content" => "synthetic"}]
    assert {:ok, result} = Chat.coerce(payload(messages), %{client_request_id: "synthetic-request"})
    assert byte_size(result.payload["instructions"]) == 0
    [instruction, user] = result.payload["input"]
    assert instruction["role"] == "developer"
    assert_summary(instruction["content"], String.trim(first) <> "\nfinal directive", true)
    assert user["role"] == "user"
    assert result.request_options.request_metadata.client_request_id == "synthetic-request"
    assert result.request_options.request_metadata.request_bytes == byte_size(CodexPooler.JSON.encode!(result.payload))
  end

  test "oversized tool output splits inside the same call result with function arguments unchanged" do
    text = String.duplicate("t", @limit + 1)

    messages = [
      %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "call_fixture", "type" => "function", "function" => %{"name" => "fixture", "arguments" => "{}"}}]},
      %{"role" => "tool", "tool_call_id" => "call_fixture", "content" => text}
    ]

    assert {:ok, result} = Chat.coerce(payload(messages))
    [call, output] = result.payload["input"]
    assert call["arguments"] == "{}"
    assert call["call_id"] == output["call_id"]
    assert output["type"] == "function_call_output"
    assert is_list(output["output"])
    assert_summary(output["output"], text, true)
  end

  test "Responses input fallback and direct Responses keep their existing oversized text shape" do
    text = String.duplicate("x", @limit + 1)
    input = [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}]

    for messages <- [%{}, %{"messages" => []}] do
      raw = Map.merge(%{"model" => "sample-model", "input" => input}, messages)
      assert {:ok, chat} = Chat.coerce(raw)
      assert {:ok, responses} = Responses.coerce(Map.delete(raw, "messages"))
      assert :crypto.hash(:sha256, CodexPooler.JSON.encode!(chat.payload["input"])) == :crypto.hash(:sha256, CodexPooler.JSON.encode!(responses.payload["input"]))
      assert length(hd(chat.payload["input"])["content"]) == 1
    end
  end

  test "normalized tool parts retain media order and custom call ids without touching other large strings" do
    text = String.duplicate("x", @limit + 1)
    media = %{"type" => "input_image", "image_url" => "https://example.com/image.png"}
    opaque = %{"type" => "function_call", "call_id" => "call_fixture", "name" => "fixture", "arguments" => text}

    for type <- ["function_call_output", "custom_tool_call_output"] do
      item = %{"type" => type, "call_id" => "call_fixture", "output" => [media, %{"type" => "input_text", "text" => text}, %{"type" => "input_text", "text" => "tail"}]}
      assert {:ok, result} = TextParts.normalize(%{"input" => [opaque, item]}, %{"messages" => [%{}]})
      [call, output] = result["input"]
      assert byte_size(call["arguments"]) == byte_size(text)
      assert :crypto.hash(:sha256, call["arguments"]) == :crypto.hash(:sha256, text)
      assert output["call_id"] == "call_fixture"
      assert hd(output["output"]) == media
      assert List.last(output["output"])["text"] == "tail"
      assert_summary(output["output"] |> tl() |> Enum.drop(-1), text, true)
    end
  end

  test "oversized annotated text rejects explicitly while small and empty annotation parts remain lossless" do
    text = String.duplicate("x", @limit + 1)

    for metadata <- [%{"annotations" => [%{"type" => "url_citation", "start_index" => 0, "end_index" => 1}]}, %{"logprobs" => [%{"token" => "x"}]}] do
      part = Map.merge(%{"type" => "output_text", "text" => text}, metadata)
      input = [%{"type" => "message", "role" => "assistant", "content" => [part]}]
      assert {:error, %{status: 400, param: "messages", message: "oversized annotated text cannot be split losslessly"}} = TextParts.normalize(%{"input" => input}, %{"messages" => [%{}]})
    end

    part = %{"type" => "output_text", "text" => text, "annotations" => [], "logprobs" => []}
    assert {:ok, result} = TextParts.normalize(%{"input" => [%{"type" => "message", "role" => "assistant", "content" => [part]}]}, %{"messages" => [%{}]})
    assert_summary(hd(result["input"])["content"], text, true)
    assert Enum.all?(hd(result["input"])["content"], &(&1["annotations"] == [] and &1["logprobs"] == []))

    small = %{"input" => [%{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "small", "annotations" => [%{"type" => "url_citation"}]}]}]}
    assert {:ok, ^small} = TextParts.normalize(small, %{"messages" => [%{}]})
    assert {:ok, ordinary} = Chat.coerce(payload([%{"role" => "user", "content" => "small"}]), %{request_bytes: 123})
    assert ordinary.request_options.request_metadata.request_bytes == 123
  end

  test "small arbitrary nested JSON tool output arrays remain exactly unchanged" do
    for type <- ["function_call_output", "custom_tool_call_output"] do
      payload = %{"input" => [%{"type" => type, "call_id" => "call_fixture", "output" => [["synthetic", [1, %{"value" => [true, nil]}]], %{"nested" => ["small"]}]}]}
      assert {:ok, ^payload} = TextParts.normalize(payload, %{"messages" => [%{}]})
    end
  end

  defp assert_summary(parts, expected, split?) do
    assert is_list(parts)
    texts = Enum.map(parts, & &1["text"])
    assert Enum.all?(texts, &String.valid?/1)
    assert :crypto.hash(:sha256, texts) == :crypto.hash(:sha256, expected)
    assert Enum.sum(Enum.map(texts, &byte_size/1)) == byte_size(expected)
    sizes = Enum.map(texts, &byte_size/1)
    if split?, do: assert(Enum.max(sizes) <= @chunk_bytes), else: assert(length(texts) == 1)
  end

  defp payload(messages), do: %{"model" => "sample-model", "messages" => messages}
end
