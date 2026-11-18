defmodule CodexPooler.Gateway.OpenAICompatibility.Responses.Input.ImageGenerationCall do
  @moduledoc false

  # The `image_generation_call` item a Full-served model emits when it ran the hosted `image_generation` tool,
  # replayed by a client in the history of its next stateless request. `/v1` returns the item in its output, so an SDK
  # that sends `response.output` back meets it; Codex replays it too (`ResponseItem::ImageGenerationCall`, which keeps
  # only `id`, `status`, `revised_prompt`, `result` and the optional `encrypted_content` and passthrough).
  #
  # The provider reads it in a stateless request, in the Full and in the Lite request shape (direct probe on
  # `gpt-6-luna`, 2026-11-18: a canary carried in the replayed `revised_prompt` came back in the reply; the image bytes
  # in `result` are not tokenized). It validates the item strictly, so this adapter mirrors the key set and the value
  # types and forwards an admitted item untouched:
  #
  #   * item keys: `type`, `id`, `status`, `action`, `background`, `output_format`, `quality`, `size`,
  #     `revised_prompt`, `result`, `encrypted_content`, `internal_chat_message_metadata_passthrough`; any other key
  #     is refused `unknown_parameter` by the provider and here;
  #   * every field but `type` may be absent or null, except `result`: the provider takes an item without an inline
  #     `result` (or with an empty one, or with a blank `status`) as a reference to a stored item and answers `404`
  #     because `/v1` requests are not stored, and refuses an item with neither `id` nor `result` (`400`), so a
  #     nonblank string `result` is required and a present `id` or `status` must be a nonblank string;
  #   * `action`, `background`, `quality` and `output_format` are strings from vocabularies the provider owns and
  #     names in its own `invalid_value` refusal, which `/v1` relays with the param; they come from the provider's
  #     output, so the adapter checks only that they are strings and does not freeze today's values. `size` is free
  #     text to the provider, `revised_prompt` any string, `encrypted_content` provider ciphertext it decrypts itself;
  #   * the id prefix (`ig`) is the provider's check; the id the public stream invents for an item the upstream sent
  #     without one is dropped by `Normalization` before this runs.

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @passthrough_key "internal_chat_message_metadata_passthrough"
  @nonblank_keys ["id", "status", "encrypted_content"]
  @string_keys ["action", "background", "output_format", "quality", "size", "revised_prompt"]
  @item_keys ["type", "result", @passthrough_key] ++ @nonblank_keys ++ @string_keys

  @spec validate_item(term()) :: :ok | {:error, Error.reason()}
  def validate_item(%{"type" => "image_generation_call", "result" => result} = item) when is_binary(result) do
    if String.trim(result) != "" and Enum.all?(Map.keys(item), &(&1 in @item_keys)) and Enum.all?(@nonblank_keys, &optional_nonblank?(item, &1)) and
         Enum.all?(@string_keys, &optional_string?(item, &1)) and optional_passthrough?(item),
       do: :ok,
       else: refusal()
  end

  def validate_item(_item), do: refusal()

  defp optional_nonblank?(item, key) do
    case Map.get(item, key) do
      nil -> true
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end

  defp optional_string?(item, key), do: is_nil(Map.get(item, key)) or is_binary(Map.get(item, key))

  defp optional_passthrough?(item), do: is_nil(Map.get(item, @passthrough_key)) or is_map(Map.get(item, @passthrough_key))

  defp refusal, do: {:error, Error.invalid_request("input item shape is not translatable", "input")}
end
