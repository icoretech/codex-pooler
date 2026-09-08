defmodule CodexPooler.Gateway.Payloads.RequestOptions.ConversationAffinity do
  @moduledoc false

  # Window ids and turn state belong to the short transport lifecycle. Capture
  # conversation identity separately, even when one of those headers wins attach.
  # Codex session-id is shared by root and child threads; it is not a conversation.
  @headers ~w(thread-id x-codex-conversation-id)

  @spec from_headers([{String.t(), String.t()}]) :: binary() | nil
  def from_headers(headers) when is_list(headers) do
    headers =
      for {name, value} <- headers, is_binary(name) and is_binary(value), do: {name, value}

    case Enum.find(@headers, &header_present?(headers, &1)) do
      nil ->
        nil

      name ->
        unique_header_hash(headers, name)
    end
  end

  def from_headers(_headers), do: nil

  @spec from_options(map()) :: binary() | nil
  def from_options(opts) do
    case Map.fetch(opts, :durable_conversation_key_hash) do
      {:ok, digest} when is_binary(digest) and byte_size(digest) == 32 ->
        digest

      {:ok, _invalid_or_absent} ->
        nil

      :error ->
        hash("conversation_key", Map.get(opts, :conversation_key)) ||
          from_headers(Map.get(opts, :forwarded_headers, [])) ||
          from_headers([{Map.get(opts, :session_header_source), Map.get(opts, :session_header)}])
    end
  end

  defp header_present?(headers, name), do: Enum.any?(headers, fn {key, _} -> key == name end)

  defp unique_header_hash(headers, name) do
    case Enum.filter(headers, fn {key, _value} -> key == name end) do
      [{^name, value}] -> hash(name, value)
      _ambiguous -> nil
    end
  end

  defp hash(kind, value) when is_binary(value) and byte_size(value) <= 1024 do
    case String.trim(value) do
      "" -> nil
      value -> :crypto.hash(:sha256, :erlang.term_to_binary({kind, value}))
    end
  end

  defp hash(_kind, _value), do: nil
end
