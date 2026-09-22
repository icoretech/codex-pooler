defmodule CodexPooler.Gateway.OpenAICompatibility.FallbackItemIdReplayTest do
  # Adapter-level edges of the replay rule the `/v1/responses` controller test
  # proves end to end: the input adapter drops only an item's own public
  # fallback id (`<type>_<output_index>` or `<type>`), and only where the item
  # stays a valid replay without an id (findings#254).
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.Responses

  @compaction_content "synthetic-opaque-compaction-content"

  test "a fallback id without an output index is dropped" do
    message = %{"type" => "message", "role" => "assistant", "id" => "message", "content" => [%{"type" => "output_text", "text" => "synthetic"}]}

    assert {:ok, %{payload: %{"input" => [replayed]}}} = coerce([message])
    assert replayed == Map.delete(message, "id")
  end

  test "a compaction item whose fallback id is dropped also loses its turn passthrough, as an id-less item does" do
    passthrough = %{"turn_id" => "synthetic-turn"}

    fallback = %{"type" => "compaction", "encrypted_content" => @compaction_content, "id" => "compaction_0", "internal_chat_message_metadata_passthrough" => passthrough}
    provider = %{fallback | "id" => "cmp_" <> String.duplicate("2c", 25)}

    assert {:ok, %{payload: %{"input" => [replayed]}}} = coerce([fallback])
    assert replayed == %{"type" => "compaction", "encrypted_content" => @compaction_content}

    assert {:ok, %{payload: %{"input" => [^provider]}}} = coerce([provider])
  end

  test "a reasoning item keeps a fallback-shaped id when it has no encrypted content to replay without one" do
    reasoning = %{"type" => "reasoning", "id" => "reasoning_0", "summary" => []}
    blank_content = Map.put(reasoning, "encrypted_content", " ")

    continuation = [%{"type" => "function_call_output", "call_id" => "call_fallback_fixture", "output" => "synthetic tool output"}]

    for item <- [reasoning, blank_content] do
      assert {:ok, %{payload: %{"input" => [replayed | _rest]}}} = coerce([item | continuation], %{"previous_response_id" => "resp_fallback_item_previous"})
      assert replayed["id"] == "reasoning_0"
    end
  end

  test "a call item whose id is its own call_id is replayed without the id, a required program id is kept" do
    call_id = "call_" <> String.duplicate("Ef3", 8)

    shell_call = %{"type" => "shell_call", "id" => call_id, "call_id" => call_id, "action" => %{"commands" => []}}
    shell_output = %{"type" => "shell_call_output", "id" => call_id, "call_id" => call_id, "output" => []}

    assert {:ok, %{payload: %{"input" => [replayed_call, replayed_output]}}} = coerce([shell_call, shell_output])
    assert replayed_call == Map.delete(shell_call, "id")
    assert replayed_output == Map.delete(shell_output, "id")

    # A program item requires its id; the rule never makes it invalid.
    program = %{"type" => "program", "id" => call_id, "call_id" => call_id, "code" => "synthetic code", "fingerprint" => "synthetic-fingerprint"}

    assert {:ok, %{payload: %{"input" => [^program]}}} = coerce([program])
  end

  defp coerce(input, extra \\ %{}) do
    %{"model" => "synthetic-model", "input" => input}
    |> Map.merge(extra)
    |> Responses.coerce()
  end
end
