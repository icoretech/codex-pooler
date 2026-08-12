defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesWebsocket do
  @moduledoc false

  alias CodexPooler.Gateway.Facade.PublicProjection
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesSequence

  @type state :: PublicResponsesSequence.state()
  @type result ::
          {:push, binary(), state()}
          | {:drop, state()}
          | {:error, map(), state()}

  @spec new_state() :: state()
  defdelegate new_state(), to: PublicResponsesSequence

  @spec normalize(binary(), state()) :: result()
  def normalize(data, state) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{} = source_decoded} ->
        {_data, decoded} = PublicResponses.normalize_json_message(data, source_decoded)
        event_type = string_value(decoded, "type")

        case PublicResponsesSequence.normalize(event_type, decoded, state, :websocket) do
          {:emit, type, normalized, state} ->
            normalized =
              normalized
              |> then(&PublicResponses.normalize_terminal_errors(type, &1))
              |> PublicProjection.responses_event()

            {:push, Jason.encode!(normalized), state}

          {:drop, state} ->
            {:drop, state}

          {:overflow, _failed, state} ->
            {:error, sequence_exhausted(), state}
        end

      _invalid ->
        {:drop, state}
    end
  end

  defp sequence_exhausted do
    %{
      status: 500,
      code: :websocket_sequence_exhausted,
      message: "websocket response sequence exhausted",
      param: nil
    }
  end

  defp string_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end
end
