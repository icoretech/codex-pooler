defmodule CodexPooler.Gateway.Runtime.Streaming.NativeSSEBlock do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCanonicalization
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.EventSummary

  # This value belongs to one normalization call, never to relay/parser state.
  # Classification uses the normalized label and whole-block JSON fallback;
  # delivery uses the raw SSE label and only the data field, as before.
  @type t :: %__MODULE__{
          raw: binary(),
          separator: binary(),
          event_type: String.t() | nil,
          decoded: map(),
          direct_failure?: boolean(),
          preamble_guard?: boolean(),
          preamble_fragment?: boolean(),
          request_local_terminal?: boolean() | nil,
          delivery_event: %{event_type: String.t() | nil, data_type: String.t() | nil}
        }
  defstruct [:raw, :event_type, :decoded, :delivery_event, :request_local_terminal?, separator: "\n\n", direct_failure?: false, preamble_guard?: false, preamble_fragment?: false]

  @type delivery_part :: %{
          data: binary(),
          preamble?: boolean(),
          preamble_guard?: boolean(),
          commits?: boolean(),
          outcome: {:ok, StreamProtocol.terminal_outcome()} | nil
        }
  @type delivery :: %{parts: [delivery_part()]}

  @spec parse(binary()) :: t()
  @spec parse(binary(), binary()) :: t()
  def parse(raw, separator \\ "\n\n") do
    raw = if :binary.match(raw, "\r") == :nomatch, do: raw, else: raw |> :binary.replace("\r\n", "\n", [:global]) |> :binary.replace("\r", "\n", [:global])
    separator = if separator == "", do: "", else: "\n\n"
    label = StreamProtocol.sse_field(raw, "event")
    data = StreamProtocol.sse_field(raw, "data")
    decoded = StreamProtocol.decode_sse_data(data || raw)
    data_type = decoded_type(decoded)

    %__MODULE__{
      raw: raw,
      separator: separator,
      event_type: StreamProtocol.normalize_sse_event_label(label) || data_type,
      decoded: decoded,
      preamble_guard?: label in ["response.created", "response.in_progress", "response.metadata"],
      direct_failure?: is_nil(data) and EventSummary.typeless_detail_error?(decoded),
      delivery_event: %{event_type: label, data_type: if(is_binary(data), do: data_type)}
    }
  end

  @spec outcome(t()) :: {:ok, StreamProtocol.terminal_outcome()} | nil
  def outcome(%{decoded: decoded}) when map_size(decoded) == 0, do: nil

  def outcome(%{request_local_terminal?: confirmed?} = block) when is_boolean(confirmed?) do
    case StreamProtocol.terminal_outcome(block.event_type, block.decoded) do
      {:ok, %{failure: failure} = outcome} ->
        failure = if confirmed?, do: Map.put(failure, :request_local_terminal?, true), else: Map.delete(failure, :request_local_terminal?)
        {:ok, %{outcome | failure: failure}}

      outcome ->
        outcome
    end
  end

  def outcome(block), do: StreamProtocol.terminal_outcome(block.event_type, block.decoded)

  @spec normalize(t(), boolean()) :: {iodata(), t()}
  def normalize(block, private_details?) do
    {wire, changed} =
      ErrorCanonicalization.normalize_decoded_block(
        block.raw,
        block.separator,
        block.event_type,
        block.decoded,
        private_details?
      )

    output =
      if changed do
        %__MODULE__{
          raw: "",
          event_type: "response.failed",
          decoded: changed,
          request_local_terminal?: ErrorCodes.request_local_terminal?(block.event_type, block.decoded),
          delivery_event: %{event_type: "response.failed", data_type: decoded_type(changed)}
        }
      else
        block
      end

    {wire, output}
  end

  @spec delivery([{iodata(), t()}]) :: delivery()
  def delivery(outputs) do
    parts = Enum.map(outputs, &delivery_part(&1, false))
    # Preserve the existing direct-JSON fallback, but do not concatenate a
    # batch's preambles before their ordered byte-budget admission.
    direct_failure? =
      not Enum.any?(parts, & &1.commits?) and
        Enum.any?(outputs, fn {_wire, block} -> block.direct_failure? end) and
        direct_delivery_failure?(parts)

    %{parts: if(direct_failure?, do: Enum.map(outputs, &delivery_part(&1, true)), else: parts)}
  end

  defp direct_delivery_failure?(parts) do
    data = parts |> Enum.reject(& &1.preamble?) |> Enum.map(& &1.data) |> IO.iodata_to_binary()
    match?({:ok, _outcome}, StreamProtocol.terminal_outcome(data))
  end

  defp delivery_part({wire, block}, direct_failure?) do
    preamble? = block.preamble_fragment? or StreamProtocol.retry_window_preamble_event?(block.delivery_event)
    commits? = not preamble? and (StreamProtocol.downstream_visible_event?(block.delivery_event) or not is_nil(outcome(block)) or direct_failure?)
    %{data: IO.iodata_to_binary(wire), preamble?: preamble?, preamble_guard?: block.preamble_guard?, commits?: commits?, outcome: outcome(block)}
  end

  defp decoded_type(decoded) do
    case Map.get(decoded, "type") do
      type when is_binary(type) -> type
      _other -> nil
    end
  end
end
