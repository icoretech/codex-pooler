defmodule CodexPoolerWeb.WebsocketConnectionLogger do
  @moduledoc false

  require Logger

  @init_failed_message "websocket init failed before request reservation"
  @closed_message "websocket closed before request reservation"
  @failed_native_websocket_turn_message "websocket native turn failed"
  @bandit_oversize_fragmented_message_reason "Received oversize fragmented message"

  @metadata_keys [
    :request_id,
    :endpoint,
    :transport,
    :route_class,
    :error_code,
    :phase,
    :reason_class,
    :elapsed_ms,
    :codex_session_id,
    :visible_output,
    :owner_instance_id,
    :proxy_instance_id,
    :downstream_epoch
  ]

  @id_prefix_length 8

  @sensitive_value_patterns [
    "auth.json",
    "authorization",
    "bearer",
    "cookie",
    "header",
    "idempotency",
    "payload",
    "prompt",
    "raw_request_body",
    "upstream_body",
    "websocket_frame"
  ]

  @type event_metadata :: keyword() | map()

  @spec init_failed_message() :: String.t()
  def init_failed_message, do: @init_failed_message

  @spec closed_message() :: String.t()
  def closed_message, do: @closed_message

  @spec failed_native_websocket_turn_message() :: String.t()
  def failed_native_websocket_turn_message, do: @failed_native_websocket_turn_message

  @spec log_init_failed_before_request_reservation(event_metadata(), term()) :: :ok
  def log_init_failed_before_request_reservation(metadata, reason) do
    log_event(:warning, @init_failed_message, metadata, reason)
  end

  @spec log_closed_before_request_reservation(event_metadata(), term()) :: :ok
  def log_closed_before_request_reservation(metadata, reason) do
    log_event(:info, @closed_message, metadata, reason)
  end

  @spec log_failed_native_websocket_turn(event_metadata(), term()) :: :ok
  def log_failed_native_websocket_turn(metadata, reason) do
    log_event(
      failed_native_websocket_turn_level(
        metadata_value(normalize_metadata(metadata), :error_code)
      ),
      @failed_native_websocket_turn_message,
      metadata,
      reason
    )
  end

  @spec failed_native_websocket_turn_level(term()) :: :info | :warning
  def failed_native_websocket_turn_level(:client_disconnected), do: :info
  def failed_native_websocket_turn_level(:owner_drained), do: :info
  def failed_native_websocket_turn_level("client_disconnected"), do: :info
  def failed_native_websocket_turn_level("owner_drained"), do: :info
  def failed_native_websocket_turn_level(_error_code), do: :warning

  @spec reason_class(term()) :: String.t()
  def reason_class(:normal), do: "normal"
  def reason_class(:closed), do: "closed"
  def reason_class(:remote), do: "remote"
  def reason_class(:timeout), do: "timeout"
  def reason_class(:shutdown), do: "shutdown"
  def reason_class({:shutdown, _reason}), do: "shutdown"
  def reason_class({:error, reason}), do: reason_class(reason)
  def reason_class({:EXIT, _reason}), do: "exit"
  def reason_class({:deserializing, reason}), do: reason_class(reason)
  def reason_class({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  def reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)

  def reason_class(@bandit_oversize_fragmented_message_reason),
    do: "max_fragmented_message_size_exceeded"

  def reason_class(reason) when is_binary(reason), do: "binary_reason"
  def reason_class(reason) when is_integer(reason), do: "numeric_reason"
  def reason_class(%module{}) when is_atom(module), do: safe_log_value(inspect(module))
  def reason_class(_reason), do: "non_atom_reason"

  defp log_event(level, message, metadata, reason) do
    log_metadata =
      metadata
      |> normalize_metadata()
      |> Map.put(:reason_class, reason_class(reason))
      |> allowed_metadata()
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{safe_log_value(key, value)}" end)

    Logger.log(level, fn -> message <> metadata_suffix(log_metadata) end)

    :ok
  end

  defp metadata_suffix(""), do: ""
  defp metadata_suffix(metadata), do: " " <> metadata

  defp normalize_metadata(metadata) when is_list(metadata), do: Map.new(metadata)
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp allowed_metadata(metadata) do
    @metadata_keys
    |> Enum.reduce([], fn key, acc ->
      value = metadata_value(metadata, key)

      if is_nil(value) do
        acc
      else
        [{key, value} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp safe_log_value(:codex_session_id, value), do: safe_id_prefix(value)
  defp safe_log_value(_key, value), do: safe_log_value(value)

  defp safe_log_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> safe_binary_value()

  defp safe_log_value(value) when is_integer(value), do: Integer.to_string(value)

  defp safe_log_value(value) when is_binary(value) do
    safe_binary_value(value)
  end

  defp safe_log_value(_value), do: "unknown"

  defp safe_id_prefix(value) when is_binary(value) do
    case safe_binary_value(value) do
      "redacted" -> "redacted"
      "unknown" -> "unknown"
      sanitized -> String.slice(sanitized, 0, @id_prefix_length)
    end
  end

  defp safe_id_prefix(_value), do: "unknown"

  defp safe_binary_value(value) when is_binary(value) do
    if sensitive_value?(value) do
      "redacted"
    else
      value
      |> sanitize_binary_value()
      |> case do
        "" -> "unknown"
        sanitized -> sanitized
      end
    end
  end

  defp sanitize_binary_value(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
    |> String.slice(0, 120)
  end

  defp sensitive_value?(value) do
    normalized = String.downcase(value)

    Enum.any?(@sensitive_value_patterns, &String.contains?(normalized, &1))
  end
end
