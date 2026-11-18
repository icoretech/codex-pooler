defmodule CodexPooler.Gateway.OpenAICompatibility.ResponsesImageGenerationCallTest do
  # A Full-served model that ran the hosted `image_generation` tool returns an `image_generation_call` output item
  # (`id`, `status`, `action`, `background`, `output_format`, `quality`, `size`, `revised_prompt` and the image as
  # base64 in `result`). `/v1` returns it, so a client that sends `response.output` back as the history of its next
  # stateless request meets it, and it used to be a `400 invalid_request` on `input` ("input item shape is not
  # translatable"). The provider reads the item in a stateless request in the Full and the Lite request shape (direct
  # probe, 2026-11-18) and validates its keys strictly; without an inline `result` it looks the item up as a stored
  # one and answers 404, so the adapter requires the result and forwards an admitted item untouched.
  use ExUnit.Case, async: true

  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.Gateway.OpenAICompatibility.Responses

  @refusal %{status: 400, code: "invalid_request", param: "input", message: "input item shape is not translatable"}
  @call %{
    "id" => "ig_synthetic_0001",
    "type" => "image_generation_call",
    "status" => "completed",
    "action" => "generate",
    "background" => "opaque",
    "output_format" => "png",
    "quality" => "low",
    "size" => "1024x1024",
    "revised_prompt" => "synthetic revised prompt",
    "result" => "aVZCT1J3MEtHZ29BQUFBTlNVaEVVZ0FBQUFF"
  }

  @accepted [
    {"the item as the provider emits it", :as_emitted},
    {"the narrower item Codex replays", :codex_shape},
    {"an item without an id", :no_id},
    {"a null id", :null_id},
    {"an item without a status", :no_status},
    {"a null status", :null_status},
    {"another status string", :generating},
    {"an item without a revised prompt", :no_revised_prompt},
    {"a null revised prompt", :null_revised_prompt},
    {"an empty revised prompt", :empty_revised_prompt},
    {"an edit action", :action_edit},
    {"a null action", :null_action},
    {"a value the provider owns and validates itself", :provider_owned_value},
    {"a free-text size", :free_size},
    {"null image options", :null_options},
    {"a result that is not an image", :text_result},
    {"encrypted content", :encrypted_content},
    {"null encrypted content", :null_encrypted_content},
    {"a passthrough map", :passthrough_map},
    {"a null passthrough", :passthrough_null}
  ]

  @refused [
    {"an unknown item key", :unknown_item_key},
    {"an item without a result", :no_result},
    {"an empty result", :empty_result},
    {"a blank result", :blank_result},
    {"a null result", :null_result},
    {"a non-string result", :integer_result},
    {"an item with an id only", :id_only},
    {"an item with neither id nor result", :bare},
    {"a blank id", :blank_id},
    {"a non-string id", :integer_id},
    {"a blank status", :blank_status},
    {"a non-string status", :integer_status},
    {"a non-string action", :map_action},
    {"a non-string quality", :integer_quality},
    {"a non-string size", :integer_size},
    {"a non-string revised prompt", :list_revised_prompt},
    {"blank encrypted content", :blank_encrypted_content},
    {"non-string encrypted content", :map_encrypted_content},
    {"a non-map passthrough", :passthrough_string}
  ]

  describe "admitted image_generation_call items" do
    for {label, variant} <- @accepted do
      test "forwards #{label} untouched, in the position the client sent it" do
        item = mutate(unquote(variant), @call)

        assert {:ok, %{payload: %{"input" => input}}} = coerce(history(item))
        assert Enum.map(input, &(&1["type"] || "message")) == ["message", "image_generation_call", "message", "message"]
        assert Enum.at(input, 1) == item
      end
    end
  end

  describe "refused image_generation_call items" do
    for {label, variant} <- @refused do
      test "refuses #{label} before dispatch" do
        assert {:error, @refusal} = coerce(history(mutate(unquote(variant), @call)))
      end
    end

    test "refuses a passthrough that carries the reserved executed_tool_calls key" do
      item = Map.put(@call, "internal_chat_message_metadata_passthrough", %{"executed_tool_calls" => []})

      assert {:error, %{status: 400, param: "input", message: "executed_tool_calls is reserved"}} = coerce(history(item))
    end
  end

  describe "the id the public stream invents for an item the upstream sent without one" do
    for id <- ["image_generation_call", "image_generation_call_0", "image_generation_call_12"] do
      test "#{id} is dropped so the upstream receives the item as it produced it" do
        item = Map.put(@call, "id", unquote(id))

        assert {:ok, %{payload: %{"input" => input}}} = coerce(history(item))
        assert Enum.at(input, 1) == Map.delete(item, "id")
      end
    end

    for id <- ["ig_synthetic_0001", "image_generation_call_first", "ig_call_0", "image_generation_calls_1", "web_search_call_1"] do
      test "#{id} is not a fallback id and reaches the upstream unchanged" do
        item = Map.put(@call, "id", unquote(id))

        assert {:ok, %{payload: %{"input" => input}}} = coerce(history(item))
        assert Enum.at(input, 1) == item
      end
    end

    test "a fallback id on an item without a result is still refused, since the provider needs one or the other" do
      assert {:error, @refusal} = coerce(history(%{"type" => "image_generation_call", "id" => "image_generation_call_0"}))
    end
  end

  describe "compatibility matrix" do
    test "states the contract this adapter implements" do
      contract = CompatibilityMatrix.fixture!(:responses_chat).image_generation_call_history

      assert contract.accepted_items == ["image_generation_call"]
      assert contract.item.required == ["type", "result"]
      assert contract.item.result == "nonblank_string"
      assert contract.provider_owned_values == ["action", "background", "output_format", "quality"]
      assert contract.serving_modes == ["full", "lite"]
      assert contract.public_fallback_id == "dropped"
      assert Map.delete(contract.refusal, :upstream_dispatch) == Map.take(@refusal, [:status, :code, :param])
      assert contract.refusal.upstream_dispatch == false
    end
  end

  defp coerce(input), do: Responses.coerce(%{"model" => "gpt-fixture-text", "input" => input})

  defp history(item), do: [user("synthetic task"), item, assistant("synthetic answer"), user("synthetic follow-up")]

  defp user(text), do: %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}

  defp assistant(text), do: %{"role" => "assistant", "content" => [%{"type" => "output_text", "text" => text}]}

  defp mutate(:as_emitted, item), do: item
  defp mutate(:codex_shape, item), do: Map.take(item, ["type", "id", "status", "revised_prompt", "result"])
  defp mutate(:no_id, item), do: Map.delete(item, "id")
  defp mutate(:null_id, item), do: Map.put(item, "id", nil)
  defp mutate(:no_status, item), do: Map.delete(item, "status")
  defp mutate(:null_status, item), do: Map.put(item, "status", nil)
  defp mutate(:generating, item), do: Map.put(item, "status", "generating")
  defp mutate(:no_revised_prompt, item), do: Map.delete(item, "revised_prompt")
  defp mutate(:null_revised_prompt, item), do: Map.put(item, "revised_prompt", nil)
  defp mutate(:empty_revised_prompt, item), do: Map.put(item, "revised_prompt", "")
  defp mutate(:action_edit, item), do: Map.put(item, "action", "edit")
  defp mutate(:null_action, item), do: Map.put(item, "action", nil)
  defp mutate(:provider_owned_value, item), do: Map.put(item, "output_format", "avif")
  defp mutate(:free_size, item), do: Map.put(item, "size", "2172x724")
  defp mutate(:null_options, item), do: Map.merge(item, %{"background" => nil, "output_format" => nil, "quality" => nil, "size" => nil})
  defp mutate(:text_result, item), do: Map.put(item, "result", "synthetic text that is not an image")
  defp mutate(:encrypted_content, item), do: Map.put(item, "encrypted_content", "gAAAAsynthetic")
  defp mutate(:null_encrypted_content, item), do: Map.put(item, "encrypted_content", nil)
  defp mutate(:passthrough_map, item), do: Map.put(item, "internal_chat_message_metadata_passthrough", %{"turn_id" => "turn-synthetic-1"})
  defp mutate(:passthrough_null, item), do: Map.put(item, "internal_chat_message_metadata_passthrough", nil)
  defp mutate(:unknown_item_key, item), do: Map.put(item, "zz_probe_unknown_key", true)
  defp mutate(:no_result, item), do: Map.delete(item, "result")
  defp mutate(:empty_result, item), do: Map.put(item, "result", "")
  defp mutate(:blank_result, item), do: Map.put(item, "result", "  ")
  defp mutate(:null_result, item), do: Map.put(item, "result", nil)
  defp mutate(:integer_result, item), do: Map.put(item, "result", 7)
  defp mutate(:id_only, item), do: Map.take(item, ["type", "id"])
  defp mutate(:bare, item), do: Map.take(item, ["type", "status"])
  defp mutate(:blank_id, item), do: Map.put(item, "id", "")
  defp mutate(:integer_id, item), do: Map.put(item, "id", 7)
  defp mutate(:blank_status, item), do: Map.put(item, "status", "")
  defp mutate(:integer_status, item), do: Map.put(item, "status", 1)
  defp mutate(:map_action, item), do: Map.put(item, "action", %{"type" => "generate"})
  defp mutate(:integer_quality, item), do: Map.put(item, "quality", 1)
  defp mutate(:integer_size, item), do: Map.put(item, "size", 1024)
  defp mutate(:list_revised_prompt, item), do: Map.put(item, "revised_prompt", ["synthetic"])
  defp mutate(:blank_encrypted_content, item), do: Map.put(item, "encrypted_content", " ")
  defp mutate(:map_encrypted_content, item), do: Map.put(item, "encrypted_content", %{"data" => "synthetic"})
  defp mutate(:passthrough_string, item), do: Map.put(item, "internal_chat_message_metadata_passthrough", "turn-synthetic-1")
end
