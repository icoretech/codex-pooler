defmodule CodexPooler.Gateway.Facade.HeaderPolicy do
  @moduledoc """
  Exact allowlists for client-visible facade response headers.

  Upstream request identifiers, provider metadata, account metadata, and rate
  limit headers never cross this boundary. A request ID already installed by
  the local HTTP stack remains on the connection and is not sourced here.
  """

  @codex_headers ~w(x-codex-turn-state x-models-etag)
  @local_recovery_header "x-codex-recovery-kind"
  @connection_values ~w(keep-alive close)

  @type protocol :: :ollama | :anthropic | :openai | :codex | :runtime_metadata

  @spec result_headers(protocol(), list()) :: [{String.t(), String.t()}]
  def result_headers(protocol, headers) when is_list(headers) do
    headers
    |> Enum.reduce([], fn header, accepted ->
      case normalize(protocol, header) do
        nil -> accepted
        normalized -> [normalized | accepted]
      end
    end)
    |> Enum.reverse()
    |> deduplicate()
  end

  def result_headers(_protocol, _headers), do: []

  defp normalize(protocol, {name, value}) when is_binary(value) do
    name = name |> to_string() |> String.downcase()

    case name do
      "content-type" -> normalize_content_type(protocol, value)
      "cache-control" -> exact_value(name, value, ["no-cache"])
      "connection" -> exact_value(name, value, @connection_values)
      @local_recovery_header -> safe_recovery_value(value)
      "etag" when protocol == :codex -> safe_models_etag(value)
      name when protocol == :codex and name in @codex_headers -> safe_opaque(name, value)
      _name -> nil
    end
  end

  defp normalize(_protocol, _header), do: nil

  defp normalize_content_type(protocol, value) do
    case value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() do
      "text/event-stream" ->
        {"content-type", "text/event-stream"}

      "application/x-ndjson" when protocol == :ollama ->
        {"content-type", "application/x-ndjson"}

      _content_type ->
        nil
    end
  end

  defp exact_value(name, value, allowed) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in allowed, do: {name, normalized}, else: nil
  end

  defp safe_opaque(name, value) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= 4096 and String.printable?(value) and
         not String.contains?(value, ["\r", "\n"]) do
      {name, value}
    end
  end

  defp safe_recovery_value(value) do
    exact_value(@local_recovery_header, value, ["restart_with_full_context"])
  end

  defp safe_models_etag(value) do
    value = String.trim(value)

    if Regex.match?(~r/^W\/"cp-models-v1-[0-9a-f]{64}"$/, value),
      do: {"etag", value},
      else: nil
  end

  defp deduplicate(headers) do
    Enum.reduce(headers, [], fn {name, _value} = header, accepted ->
      if List.keymember?(accepted, name, 0), do: accepted, else: accepted ++ [header]
    end)
  end
end
