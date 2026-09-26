defmodule CodexPooler.Gateway.OpenAICompatibility.Chat.CallIds do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Error

  @call_types ~w(function_call custom_tool_call function_call_output custom_tool_call_output)
  @maximum_bytes 64
  @digest_domain "codex-pooler:chat-call-id:v1\0"

  @spec normalize(map(), map()) :: {:ok, map()} | {:error, Error.reason()}
  def normalize(%{"input" => items} = payload, %{"messages" => [_message | _rest]}) when is_list(items) do
    items
    |> Enum.reduce_while({[], %{}}, &normalize_item/2)
    |> case do
      {:error, _reason} = error -> error
      {normalized, _original_ids} -> {:ok, Map.put(payload, "input", Enum.reverse(normalized))}
    end
  end

  def normalize(payload, _chat_payload), do: {:ok, payload}

  defp normalize_item(%{"type" => type, "call_id" => original} = item, {items, original_ids})
       when type in @call_types and is_binary(original) do
    normalized = normalize_id(original)

    case Map.fetch(original_ids, normalized) do
      {:ok, other} when other != original ->
        {:halt, {:error, Error.invalid_request("tool call IDs collide after normalization", "messages")}}

      _same_or_new ->
        {:cont, {[Map.put(item, "call_id", normalized) | items], Map.put(original_ids, normalized, original)}}
    end
  end

  defp normalize_item(item, {items, original_ids}), do: {:cont, {[item | items], original_ids}}

  # Stable across history order, requests and nodes; retain the complete digest
  # instead of truncating a shared client prefix or depending on replay state.
  defp normalize_id(id) when byte_size(id) > @maximum_bytes do
    digest = :crypto.hash(:sha256, [@digest_domain, id])
    "call_" <> Base.url_encode64(digest, padding: false)
  end

  defp normalize_id(id), do: id
end
