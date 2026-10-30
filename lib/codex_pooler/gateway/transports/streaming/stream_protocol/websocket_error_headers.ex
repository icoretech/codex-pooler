defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.WebsocketErrorHeaders do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.RetryAfter

  @type headers :: %{optional(String.t()) => String.t()}

  # The names a provider uses for its request id, in the order the released
  # Codex client reads them: `x-request-id` first, then `x-oai-request-id`
  # (the name the Codex backend actually uses), then `openai-request-id`.
  # This list is the one source of truth for the attempt metadata writer
  # (`Finalization.Metadata`) and for this frame allowlist, so a frame header
  # is admitted here exactly when the writer reads it; `x-openai-request-id`
  # used to be admitted and never read.
  @upstream_request_id_header_names ~w(x-request-id x-oai-request-id openai-request-id)
  @quota_header_prefixes ~w(x-ratelimit-limit- x-ratelimit-remaining- x-ratelimit-reset-)
  @quota_window_header_suffixes ~w(
    -primary-reset-at
    -primary-used-percent
    -primary-window-minutes
    -secondary-reset-at
    -secondary-used-percent
    -secondary-window-minutes
  )

  @spec upstream_request_id_header_names() :: [String.t()]
  def upstream_request_id_header_names, do: @upstream_request_id_header_names

  # The name allowlist as a predicate, for the accounting sanitizer: a header
  # admitted here is name-allowlisted at the frame read and value-bounded at
  # persistence, so the sanitizer may keep its value even when the name
  # carries a redaction fragment (`x-ratelimit-*-tokens`).
  @spec allowed_header_name?(term()) :: boolean()
  def allowed_header_name?(name) when is_binary(name),
    do: allowed_websocket_error_header?(String.downcase(name))

  def allowed_header_name?(_name), do: false

  @spec websocket_error_frame_headers(term()) :: headers()
  def websocket_error_frame_headers(data) when is_binary(data) do
    case CodexPooler.JSON.decode(data) do
      {:ok, %{} = decoded} ->
        websocket_error_frame_headers(decoded)

      _other ->
        %{}
    end
  end

  def websocket_error_frame_headers(%{"type" => type} = frame)
      when type in ["response.failed", "response.incomplete", "error"] do
    headers = sanitized_websocket_error_headers(Map.get(frame, "headers"))

    case retry_after(frame) do
      nil -> headers
      value -> Map.put(headers, "retry-after", value)
    end
  end

  def websocket_error_frame_headers(_data), do: %{}
  @spec retry_after(term()) :: String.t() | nil
  def retry_after(%{"type" => type} = frame) when type in ["response.failed", "response.incomplete", "error"] do
    nested_headers =
      case frame do
        %{"response" => %{"error" => %{} = error}} -> Map.get(error, "headers")
        %{"error" => %{} = error} -> Map.get(error, "headers")
        _other -> nil
      end

    retry_after_header(nested_headers) || retry_after_header(Map.get(frame, "headers"))
  end

  def retry_after(_frame), do: nil

  defp retry_after_header(headers) when is_map(headers) do
    Enum.find_value(headers, fn
      {name, value} when is_binary(name) -> if String.downcase(name) == "retry-after", do: RetryAfter.normalize(value)
      _other -> nil
    end)
  end

  defp retry_after_header(_headers), do: nil

  defp sanitized_websocket_error_headers(headers) when is_map(headers) do
    Enum.reduce(headers, %{}, fn header, acc ->
      put_allowed_websocket_error_header(acc, header)
    end)
  end

  defp sanitized_websocket_error_headers(_headers), do: %{}

  defp put_allowed_websocket_error_header(acc, {name, value}) do
    name = name |> to_string() |> String.downcase()

    case allowed_scalar_header_value(name, value) do
      {:ok, value} -> Map.put(acc, name, value)
      :error -> acc
    end
  end

  defp allowed_scalar_header_value("retry-after", value) do
    case RetryAfter.normalize(value) do
      nil -> :error
      normalized -> {:ok, normalized}
    end
  end

  defp allowed_scalar_header_value(name, value) do
    if allowed_websocket_error_header?(name), do: scalar_header_value(value), else: :error
  end

  defp allowed_websocket_error_header?(name) when name in @upstream_request_id_header_names,
    do: true

  defp allowed_websocket_error_header?("x-codex-rate-limit-reached-type"), do: true
  defp allowed_websocket_error_header?("retry-after"), do: true

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
