defmodule CodexPoolerWeb.WebsocketConnectionLogger do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy

  @init_failed_message "websocket init failed before request reservation"
  @closed_message "websocket closed before request reservation"
  @failed_native_websocket_turn_message "websocket native turn failed"
  @reconnect_disposition_message "websocket reconnect disposition"
  @handoff_outcome_message "websocket handoff outcome"
  @bandit_oversize_fragmented_message_reason "Received oversize fragmented message"

  @metadata_keys [
    :request_id,
    :endpoint,
    :transport,
    :route_class,
    :error_code,
    :phase,
    :reason_class,
    :reason_code,
    :elapsed_ms,
    :codex_session_id,
    :visible_output,
    :owner_instance_id,
    :proxy_instance_id,
    :downstream_epoch
  ]
  @reconnect_event_keys [:reconnect_disposition, :handoff_outcome]
  @reconnect_metadata_keys @metadata_keys ++ @reconnect_event_keys

  @type event_metadata :: keyword() | map()

  @spec init_failed_message() :: String.t()
  def init_failed_message, do: @init_failed_message

  @spec closed_message() :: String.t()
  def closed_message, do: @closed_message

  @spec failed_native_websocket_turn_message() :: String.t()
  def failed_native_websocket_turn_message, do: @failed_native_websocket_turn_message

  @spec reconnect_disposition_message() :: String.t()
  def reconnect_disposition_message, do: @reconnect_disposition_message

  @spec handoff_outcome_message() :: String.t()
  def handoff_outcome_message, do: @handoff_outcome_message

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
    metadata =
      metadata
      |> normalize_metadata()
      |> put_native_reason_code(reason)

    log_event(
      failed_native_websocket_turn_level(metadata_value(metadata, :error_code)),
      @failed_native_websocket_turn_message,
      failure_log_metadata(metadata),
      reason
    )
  end

  @spec log_reconnect_disposition(event_metadata(), term()) :: :ok
  def log_reconnect_disposition(metadata, disposition) do
    log_fixed_reconnect_event(
      @reconnect_disposition_message,
      metadata,
      :reconnect_disposition,
      DiagnosticTaxonomy.reconnect_disposition(disposition)
    )
  end

  @spec log_handoff_outcome(event_metadata(), term()) :: :ok
  def log_handoff_outcome(metadata, outcome) do
    log_fixed_reconnect_event(
      @handoff_outcome_message,
      metadata,
      :handoff_outcome,
      DiagnosticTaxonomy.handoff_outcome(outcome)
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

  def reason_class(reason) when is_map(reason),
    do: DiagnosticTaxonomy.reason_code(reason) || "non_atom_reason"

  def reason_class(_reason), do: "non_atom_reason"

  defp log_fixed_reconnect_event(_message, _metadata, _key, nil), do: :ok

  defp log_fixed_reconnect_event(message, metadata, key, value) do
    metadata =
      metadata
      |> normalize_metadata()
      |> drop_reconnect_event_values()
      |> Map.put(key, value)

    log_event(:info, message, metadata, nil, @reconnect_metadata_keys)
  end

  defp log_event(level, message, metadata, reason),
    do: log_event(level, message, metadata, reason, @metadata_keys)

  defp log_event(level, message, metadata, reason, metadata_keys) do
    log_metadata =
      metadata
      |> normalize_metadata()
      |> maybe_put_reason_class(reason)
      |> allowed_metadata(metadata_keys)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{safe_log_value(key, value)}" end)

    Logger.log(level, fn -> message <> metadata_suffix(log_metadata) end)

    :ok
  end

  defp metadata_suffix(""), do: ""
  defp metadata_suffix(metadata), do: " " <> metadata

  defp normalize_metadata(metadata) when is_list(metadata), do: Map.new(metadata)
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp drop_reconnect_event_values(metadata) do
    Enum.reduce(@reconnect_event_keys, metadata, fn key, metadata ->
      metadata
      |> Map.delete(key)
      |> Map.delete(Atom.to_string(key))
    end)
  end

  defp maybe_put_reason_class(metadata, nil), do: metadata

  defp maybe_put_reason_class(metadata, reason),
    do: Map.put(metadata, :reason_class, reason_class(reason))

  defp allowed_metadata(metadata, metadata_keys) do
    metadata_keys
    |> Enum.reduce([], fn key, acc ->
      value = allowed_metadata_value(key, metadata_value(metadata, key))

      if is_nil(value) do
        acc
      else
        [{key, value} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp allowed_metadata_value(:reconnect_disposition, value),
    do: DiagnosticTaxonomy.reconnect_disposition(value)

  defp allowed_metadata_value(:handoff_outcome, value),
    do: DiagnosticTaxonomy.handoff_outcome(value)

  defp allowed_metadata_value(_key, value), do: value

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp failure_log_metadata(metadata) do
    metadata
    |> replace_failure_correlator(:request_id)
    |> replace_failure_code(:error_code)
  end

  defp replace_failure_correlator(metadata, key) do
    value = metadata_value(metadata, key)
    metadata = Map.delete(metadata, Atom.to_string(key))
    Map.put(metadata, key, DiagnosticTaxonomy.safe_correlator(value))
  end

  defp replace_failure_code(metadata, key) do
    value = metadata_value(metadata, key)
    metadata = Map.delete(metadata, Atom.to_string(key))

    case DiagnosticTaxonomy.identifier(value) do
      nil -> Map.delete(metadata, key)
      identifier -> Map.put(metadata, key, identifier)
    end
  end

  defp put_native_reason_code(metadata, reason) do
    metadata =
      metadata
      |> Map.delete(:reason_code)
      |> Map.delete("reason_code")

    case DiagnosticTaxonomy.reason_code(reason) do
      nil -> metadata
      reason_code -> Map.put(metadata, :reason_code, reason_code)
    end
  end

  defp safe_log_value(key, value) when key in [:error_code, :reason_code, :reason_class],
    do: DiagnosticTaxonomy.identifier(value) || "unknown"

  defp safe_log_value(_key, value), do: safe_log_value(value)

  defp safe_log_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> DiagnosticTaxonomy.safe_correlator()

  defp safe_log_value(value) when is_integer(value), do: Integer.to_string(value)

  defp safe_log_value(value) when is_binary(value) do
    DiagnosticTaxonomy.safe_correlator(value)
  end

  defp safe_log_value(_value), do: "unknown"
end
