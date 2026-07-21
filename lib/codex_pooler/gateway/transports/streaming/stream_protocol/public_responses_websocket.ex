defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesWebsocket do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
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
    with {:ok, %{} = decoded} <- Jason.decode(data) do
      event_type = string_value(decoded, "type")
      decoded = canonicalize_existing_public_error(data, decoded)

      case PublicResponsesSequence.normalize(event_type, decoded, state, :websocket) do
        {:emit, _type, normalized, state} -> {:push, Jason.encode!(normalized), state}
        {:drop, state} -> {:drop, state}
        {:overflow, _failed, state} -> {:error, sequence_exhausted(), state}
      end
    else
      _invalid -> {:push, data, state}
    end
  end

  defp canonicalize_existing_public_error(data, decoded) do
    case data |> StreamProtocol.canonicalize_codex_responses_json_message() |> Jason.decode() do
      {:ok, %{} = canonical} -> canonical
      _invalid -> decoded
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
