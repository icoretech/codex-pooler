defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.WebsocketErrorHeaders do
  @moduledoc false

  @type headers :: %{optional(String.t()) => String.t()}

  @metadata_header_names ~w(openai-request-id x-openai-request-id x-request-id)
  @quota_header_prefixes ~w(x-ratelimit-limit- x-ratelimit-remaining- x-ratelimit-reset-)
  @quota_window_header_suffixes ~w(
    -primary-reset-at
    -primary-used-percent
    -primary-window-minutes
    -secondary-reset-at
    -secondary-used-percent
    -secondary-window-minutes
  )

  @spec websocket_error_frame_headers(term()) :: headers()
  def websocket_error_frame_headers(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = decoded} ->
        websocket_error_frame_headers(decoded)

      _other ->
        %{}
    end
  end

  def websocket_error_frame_headers(%{"type" => type, "headers" => %{} = headers})
      when type in ["response.failed", "response.incomplete", "error"],
      do: sanitized_websocket_error_headers(headers)

  def websocket_error_frame_headers(_data), do: %{}

  defp sanitized_websocket_error_headers(headers) do
    Enum.reduce(headers, %{}, fn header, acc ->
      put_allowed_websocket_error_header(acc, header)
    end)
  end

  defp put_allowed_websocket_error_header(acc, {name, value}) do
    name = name |> to_string() |> String.downcase()

    case allowed_scalar_header_value(name, value) do
      {:ok, value} -> Map.put(acc, name, value)
      :error -> acc
    end
  end

  defp allowed_scalar_header_value(name, value) do
    if allowed_websocket_error_header?(name), do: scalar_header_value(value), else: :error
  end

  defp allowed_websocket_error_header?(name) when name in @metadata_header_names, do: true
  defp allowed_websocket_error_header?("x-codex-rate-limit-reached-type"), do: true

  defp allowed_websocket_error_header?(name) do
    Enum.any?(@quota_header_prefixes, &String.starts_with?(name, &1)) or
      (String.starts_with?(name, "x-") and
         Enum.any?(@quota_window_header_suffixes, &String.ends_with?(name, &1)))
  end

  defp scalar_header_value(value) when is_binary(value), do: {:ok, value}
  defp scalar_header_value(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp scalar_header_value(value) when is_float(value), do: {:ok, to_string(value)}
  defp scalar_header_value(value) when is_boolean(value), do: {:ok, to_string(value)}
  defp scalar_header_value(_value), do: :error
end
