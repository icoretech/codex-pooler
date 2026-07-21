defmodule CodexPooler.Gateway.Transports.TransportFailureReason do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.TransportFailureReason, as: SharedTransportFailureReason

  @max_reason_length 96
  @allowed_phases ~w(
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

  @type transport_failure_metadata :: %{String.t() => String.t() | non_neg_integer() | boolean()}
  @type upstream_transport_error :: %{
          required(:status) => pos_integer(),
          required(:code) => String.t(),
          required(:message) => String.t(),
          required(:param) => nil,
          optional(:transport_failure) => transport_failure_metadata()
        }

  @spec safe_reason(term()) :: String.t() | nil
  defdelegate safe_reason(reason), to: SharedTransportFailureReason

  @spec safe_exception(term()) :: String.t() | nil
  defdelegate safe_exception(reason), to: SharedTransportFailureReason

  @spec transport_failure_metadata(term(), map()) :: transport_failure_metadata()
  def transport_failure_metadata(reason, attrs) when is_map(attrs) do
    %{
      "exception" => safe_exception(reason),
      "reason_class" => safe_reason_class(reason),
      "reason" => safe_metadata_reason(reason),
      "phase" => safe_phase(Map.get(attrs, :phase) || Map.get(attrs, "phase")),
      "pre_visible_output" => safe_boolean(Map.get(attrs, :pre_visible_output)),
      "terminal_seen" => safe_boolean(Map.get(attrs, :terminal_seen)),
      "text_frame_count" => safe_non_negative_integer(Map.get(attrs, :text_frame_count)),
      "peer_close_code" =>
        safe_peer_close_code(metadata_attr(attrs, "peer_close_code", :peer_close_code)),
      "peer_close_reason_present" =>
        safe_boolean(
          metadata_attr(attrs, "peer_close_reason_present", :peer_close_reason_present)
        ),
      "peer_close_reason_bytes" =>
        safe_peer_close_reason_bytes(
          metadata_attr(attrs, "peer_close_reason_bytes", :peer_close_reason_bytes)
        )
    }
    |> compact_metadata()
  end

  @spec peer_close_metadata(term(), term()) :: transport_failure_metadata()
  def peer_close_metadata(code, reason) do
    %{
      "peer_close_code" => safe_peer_close_code(code),
      "peer_close_reason_present" => is_binary(reason) and reason != "",
      "peer_close_reason_bytes" => peer_close_reason_bytes(reason)
    }
    |> compact_metadata()
  end

  @spec upstream_stream_interrupted_metadata(term(), map()) :: transport_failure_metadata()
  def upstream_stream_interrupted_metadata(reason, attrs) when is_map(attrs) do
    %{
      "exception" => safe_transport_exception(reason),
      "reason_class" => "upstream_stream_interrupted",
      "reason" => "closed_before_terminal",
      "phase" => safe_phase(Map.get(attrs, :phase) || Map.get(attrs, "phase")),
      "pre_visible_output" => safe_boolean(Map.get(attrs, :pre_visible_output)),
      "terminal_seen" => safe_boolean(Map.get(attrs, :terminal_seen)),
      "text_frame_count" => safe_non_negative_integer(Map.get(attrs, :text_frame_count))
    }
    |> compact_metadata()
  end

  @spec maybe_put_upstream_stream_interrupted_metadata(map(), term(), term()) :: map()
  def maybe_put_upstream_stream_interrupted_metadata(
        metadata,
        {:upstream_stream_interrupted, original_reason},
        body
      ) do
    transport_failure =
      upstream_stream_interrupted_metadata(original_reason, %{
        phase: :upstream_close,
        pre_visible_output: false,
        terminal_seen: false,
        text_frame_count: sse_text_frame_count(body)
      })

    Map.put(metadata, "transport_failure", transport_failure)
  end

  def maybe_put_upstream_stream_interrupted_metadata(metadata, _reason, _body), do: metadata

  @spec upstream_transport_error(term(), map()) :: upstream_transport_error()
  def upstream_transport_error(reason, attrs) when is_map(attrs) do
    %{
      status: 502,
      code: "upstream_network_error",
      message: "upstream request failed",
      param: nil
    }
    |> maybe_put_transport_failure(transport_failure_metadata(reason, attrs))
  end

  defp safe_tuple_reason(value) when is_atom(value), do: safe_reason(value)
  defp safe_tuple_reason(value) when is_tuple(value), do: safe_reason(value)
  defp safe_tuple_reason(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_tuple_reason(_value), do: nil

  defp safe_reason_class(%Finch.TransportError{source: %Mint.TransportError{} = source}),
    do: safe_reason_class(source)

  defp safe_reason_class(%Finch.HTTPError{source: %Mint.HTTPError{} = source}),
    do: safe_reason_class(source)

  defp safe_reason_class(%module{}) when is_atom(module), do: inspect(module)
  defp safe_reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason_class(reason) when is_binary(reason), do: "binary"

  defp safe_reason_class(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.find_value(&safe_tuple_reason/1)
  end

  defp safe_reason_class(_reason), do: nil

  defp safe_metadata_reason(%Finch.TransportError{source: %Mint.TransportError{} = source}),
    do: safe_metadata_reason(source)

  defp safe_metadata_reason(%Finch.HTTPError{source: %Mint.HTTPError{} = source}),
    do: safe_metadata_reason(source)

  defp safe_metadata_reason(%{__struct__: _module, reason: reason}),
    do: safe_metadata_reason(reason)

  defp safe_metadata_reason(reason) when is_atom(reason), do: safe_reason(reason)
  defp safe_metadata_reason(reason) when is_tuple(reason), do: safe_reason(reason)
  defp safe_metadata_reason(_reason), do: nil

  defp safe_transport_exception(%Finch.TransportError{}), do: "Finch.TransportError"
  defp safe_transport_exception(%Mint.TransportError{}), do: "Mint.TransportError"
  defp safe_transport_exception(_reason), do: nil

  defp sse_text_frame_count(body) when is_binary(body) do
    {blocks, _buffer} = StreamProtocol.complete_sse_blocks(body, bounded?: false)

    Enum.count(blocks, &sse_text_frame?/1)
  end

  defp sse_text_frame_count(_body), do: 0

  defp sse_text_frame?(block) do
    case StreamProtocol.sse_field(block, "data") do
      nil -> false
      "[DONE]" -> false
      data -> String.trim(data) != ""
    end
  end

  defp safe_phase(phase) when is_atom(phase), do: phase |> Atom.to_string() |> safe_phase()

  defp safe_phase(phase) when is_binary(phase) do
    phase
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> truncate_reason()
    |> blank_to_nil()
    |> allow_phase()
  end

  defp safe_phase(_phase), do: nil

  defp allow_phase(phase) when phase in @allowed_phases, do: phase
  defp allow_phase(_phase), do: nil

  defp safe_boolean(value) when is_boolean(value), do: value
  defp safe_boolean(_value), do: nil

  defp safe_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp safe_non_negative_integer(_value), do: nil

  defp safe_peer_close_code(value) when is_integer(value) and value in 0..65_535, do: value
  defp safe_peer_close_code(_value), do: nil

  defp safe_peer_close_reason_bytes(value) when is_integer(value) and value in 0..123, do: value
  defp safe_peer_close_reason_bytes(_value), do: nil

  defp peer_close_reason_bytes(reason) when is_binary(reason), do: min(byte_size(reason), 123)
  defp peer_close_reason_bytes(_reason), do: 0

  defp metadata_attr(attrs, string_key, atom_key) do
    case Map.fetch(attrs, string_key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, atom_key)
    end
  end

  defp truncate_reason(reason) when byte_size(reason) > @max_reason_length,
    do: binary_part(reason, 0, @max_reason_length)

  defp truncate_reason(reason), do: reason

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_put_transport_failure(error, metadata) when map_size(metadata) > 0,
    do: Map.put(error, :transport_failure, metadata)

  defp maybe_put_transport_failure(error, _metadata), do: error
end
