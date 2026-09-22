defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesWebsocket do
  @moduledoc false

  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesSequence

  @type state :: %{
          required(:max_seen) => integer() | nil,
          required(:terminal_latched?) => boolean(),
          required(:overflow_latched?) => boolean(),
          optional(:stream_id) => String.t(),
          optional(:custom_tool_namespaces) => map()
        }
  @type result ::
          {:push, binary(), state()}
          | {:drop, state()}
          | {:error, map(), state()}

  @spec new_state() :: state()
  @spec new_state(String.t() | nil) :: state()
  def new_state(stream_id \\ nil)

  def new_state(nil), do: PublicResponsesSequence.new_state()

  def new_state(stream_id) when is_binary(stream_id) do
    PublicResponsesSequence.new_state()
    |> Map.put(:stream_id, stream_id)
  end

  @spec normalize(binary(), state()) :: result()
  def normalize(data, state) when is_binary(data) do
    stream_id = Map.get(state, :stream_id)

    case CodexPooler.JSON.decode(data) do
      {:ok, %{} = source_decoded} ->
        {_data, decoded} = PublicResponses.normalize_json_message(data, source_decoded)
        decoded = PublicResponses.drop_provider_event_headers(decoded)
        event_type = string_value(decoded, "type")

        case public_event(event_type, decoded, state) do
          {:emit, type, normalized, state} ->
            normalized =
              type
              |> PublicResponses.normalize_terminal_errors(normalized)
              |> Responses.restore_custom_tool_call_namespaces(Map.get(state, :custom_tool_namespaces, %{}))
              |> maybe_put_stream_id(stream_id)

            {:push, CodexPooler.JSON.encode!(normalized), state}

          {:drop, state} ->
            {:drop, state}

          {:overflow, _failed, state} ->
            {:error, sequence_exhausted(), state}
        end

      _invalid ->
        {:drop, state}
    end
  end

  # Only the public Responses vocabulary reaches a public websocket client, as
  # on the public SSE relay: `response.*` (unknown ones included), the `error`
  # terminal and `keepalive`. Backend-internal types (`codex.*` controls, the
  # upstream websocket's `responsesapi.websocket_timing`) and typeless
  # non-terminal frames are dropped before they take a sequence number
  # (findings#254 row 254-14).
  defp public_event(event_type, decoded, state) do
    case PublicResponsesSequence.public_shape(event_type, decoded) do
      {:ok, type, public_decoded} ->
        if public_websocket_event?(type),
          do: PublicResponsesSequence.assign(type, public_decoded, state, :websocket),
          else: {:drop, state}

      :drop ->
        {:drop, state}
    end
  end

  defp public_websocket_event?("error"), do: true
  defp public_websocket_event?(type), do: PublicResponses.public_stream_event?(type)

  defp sequence_exhausted do
    %{
      status: 500,
      code: :websocket_sequence_exhausted,
      message: "websocket response sequence exhausted",
      param: nil
    }
  end

  defp maybe_put_stream_id(event, stream_id) when is_binary(stream_id) do
    Map.put(event, "stream_id", stream_id)
  end

  defp maybe_put_stream_id(event, _stream_id), do: event

  defp string_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
