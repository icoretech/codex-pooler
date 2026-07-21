defmodule CodexPooler.Accounting.RequestLogs.DebugProjection.TransportFailure do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Attempt

  @transport_failure_phases ~w(
    connect
    decode
    receive
    receive_timeout
    request
    send_control
    send_payload
    unexpected_frame
    upstream_close
  )

  @spec build(Attempt.t()) :: map()
  def build(%Attempt{} = attempt) do
    metadata = Accounting.sanitize_metadata(attempt.response_metadata)

    metadata
    |> persisted_transport_failure()
    |> case do
      transport_failure when map_size(transport_failure) > 0 ->
        transport_failure

      _transport_failure ->
        stream_interruption_transport_failure(attempt, metadata)
    end
    |> safe_transport_failure()
  end

  defp persisted_transport_failure(metadata) do
    metadata
    |> Accounting.sanitize_metadata()
    |> case do
      %{"transport_failure" => transport_failure} when is_map(transport_failure) ->
        transport_failure

      %{transport_failure: transport_failure} when is_map(transport_failure) ->
        transport_failure

      _metadata ->
        %{}
    end
  end

  defp stream_interruption_transport_failure(
         %Attempt{} = attempt,
         %{"error_kind" => "stream_interrupted"} = metadata
       ) do
    cond do
      attempt.network_error_code == "client_disconnected" ->
        %{
          "reason_class" => "downstream_client_disconnect",
          "reason" => "client_disconnected",
          "phase" => "send_payload",
          "pre_visible_output" => pre_visible_output?(metadata),
          "terminal_seen" => false,
          "text_frame_count" => stream_text_frame_count(metadata)
        }

      attempt.network_error_code == "downstream_stream_error" ->
        %{
          "reason_class" => "downstream_stream_error",
          "reason" => "downstream_write_failed",
          "phase" => "send_payload",
          "pre_visible_output" => pre_visible_output?(metadata),
          "terminal_seen" => false,
          "text_frame_count" => stream_text_frame_count(metadata)
        }

      attempt.network_error_code == "stream_idle_timeout" ->
        %{
          "reason_class" => "upstream_stream_idle_timeout",
          "reason" => "idle_timeout",
          "phase" => "receive_timeout",
          "pre_visible_output" => pre_visible_output?(metadata),
          "terminal_seen" => false,
          "text_frame_count" => stream_text_frame_count(metadata)
        }

      present?(terminal_stream_error_code(metadata)) ->
        %{
          "reason_class" => "upstream_terminal_failure",
          "reason" => terminal_stream_error_code(metadata),
          "phase" => "receive",
          "pre_visible_output" => pre_visible_output?(metadata),
          "terminal_seen" => true,
          "text_frame_count" => stream_text_frame_count(metadata)
        }

      attempt.network_error_code == "upstream_stream_error" ->
        %{
          "reason_class" => "upstream_stream_interrupted",
          "reason" => "closed_before_terminal",
          "phase" => "upstream_close",
          "pre_visible_output" => pre_visible_output?(metadata),
          "terminal_seen" => false,
          "text_frame_count" => stream_text_frame_count(metadata)
        }

      true ->
        %{
          "reason_class" => "stream_interrupted",
          "reason" => "interrupted",
          "phase" => "receive",
          "pre_visible_output" => pre_visible_output?(metadata),
          "terminal_seen" => false,
          "text_frame_count" => stream_text_frame_count(metadata)
        }
    end
  end

  defp stream_interruption_transport_failure(_attempt, _metadata), do: %{}

  defp terminal_stream_error_code(metadata) do
    Map.get(metadata, "stream_error_code") || Map.get(metadata, "upstream_error_code")
  end

  defp pre_visible_output?(metadata), do: stream_text_frame_count(metadata) == 0

  defp stream_text_frame_count(metadata) do
    metadata
    |> Map.get("stream_text_frame_count")
    |> non_negative_integer()
    |> case do
      count when is_integer(count) -> count
      nil -> default_stream_text_frame_count(metadata)
    end
  end

  defp default_stream_text_frame_count(%{"error_kind" => "stream_interrupted"}), do: 1
  defp default_stream_text_frame_count(_metadata), do: 0

  defp safe_transport_failure(transport_failure) when is_map(transport_failure) do
    %{}
    |> put_transport_failure_text(
      :exception,
      transport_failure_value(transport_failure, "exception")
    )
    |> put_transport_failure_text(
      :reason_class,
      transport_failure_value(transport_failure, "reason_class")
    )
    |> put_transport_failure_text(:reason, transport_failure_value(transport_failure, "reason"))
    |> put_transport_failure_phase(transport_failure_value(transport_failure, "phase"))
    |> put_transport_failure_boolean(
      :pre_visible_output,
      transport_failure_value(transport_failure, "pre_visible_output")
    )
    |> put_transport_failure_boolean(
      :terminal_seen,
      transport_failure_value(transport_failure, "terminal_seen")
    )
    |> put_transport_failure_integer(
      :text_frame_count,
      transport_failure_value(transport_failure, "text_frame_count")
    )
    |> put_peer_close_code(transport_failure_value(transport_failure, "peer_close_code"))
    |> put_transport_failure_boolean(
      :peer_close_reason_present,
      transport_failure_value(transport_failure, "peer_close_reason_present")
    )
    |> put_peer_close_reason_bytes(
      transport_failure_value(transport_failure, "peer_close_reason_bytes")
    )
  end

  @spec transport_failure_value(map(), String.t()) :: term()
  defp transport_failure_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, transport_failure_atom_key(key))
    end
  end

  defp transport_failure_atom_key("exception"), do: :exception
  defp transport_failure_atom_key("reason_class"), do: :reason_class
  defp transport_failure_atom_key("reason"), do: :reason
  defp transport_failure_atom_key("phase"), do: :phase
  defp transport_failure_atom_key("pre_visible_output"), do: :pre_visible_output
  defp transport_failure_atom_key("terminal_seen"), do: :terminal_seen
  defp transport_failure_atom_key("text_frame_count"), do: :text_frame_count
  defp transport_failure_atom_key("peer_close_code"), do: :peer_close_code
  defp transport_failure_atom_key("peer_close_reason_present"), do: :peer_close_reason_present
  defp transport_failure_atom_key("peer_close_reason_bytes"), do: :peer_close_reason_bytes

  defp put_transport_failure_text(metadata, key, value) when is_binary(value) do
    value = String.trim(value)

    if safe_transport_failure_text?(value) do
      Map.put(metadata, key, value)
    else
      metadata
    end
  end

  defp put_transport_failure_text(metadata, _key, _value), do: metadata

  defp put_transport_failure_phase(metadata, phase) when is_binary(phase) do
    phase = String.trim(phase)

    if phase in @transport_failure_phases do
      Map.put(metadata, :phase, phase)
    else
      metadata
    end
  end

  defp put_transport_failure_phase(metadata, _phase), do: metadata

  defp put_transport_failure_boolean(metadata, key, value) when is_boolean(value),
    do: Map.put(metadata, key, value)

  defp put_transport_failure_boolean(metadata, _key, _value), do: metadata

  defp put_transport_failure_integer(metadata, key, value) when is_integer(value) and value >= 0,
    do: Map.put(metadata, key, value)

  defp put_transport_failure_integer(metadata, _key, _value), do: metadata

  defp put_peer_close_code(metadata, value) when is_integer(value) and value in 0..65_535,
    do: Map.put(metadata, :peer_close_code, value)

  defp put_peer_close_code(metadata, _value), do: metadata

  defp put_peer_close_reason_bytes(metadata, value)
       when is_integer(value) and value in 0..123,
       do: Map.put(metadata, :peer_close_reason_bytes, value)

  defp put_peer_close_reason_bytes(metadata, _value), do: metadata

  defp safe_transport_failure_text?(value) do
    value != "" and byte_size(value) <= 96 and
      Regex.match?(~r/^[A-Za-z0-9_.:-]+$/, value) and
      not Regex.match?(~r/(?i)\bBearer\b|https?:\/\/|sk-[A-Za-z0-9_-]{8,}/, value) and
      not Regex.match?(~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, value)
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
