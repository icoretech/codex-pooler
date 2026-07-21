defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponsesSequence do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @max_safe_integer 9_007_199_254_740_991

  @type state :: %{
          required(:max_seen) => integer() | nil,
          required(:terminal_latched?) => boolean(),
          required(:overflow_latched?) => boolean()
        }

  @type normalized ::
          {:emit, String.t(), map(), state()}
          | {:drop, state()}
          | {:overflow, map(), state()}

  @spec new_state() :: state()
  def new_state do
    %{max_seen: nil, terminal_latched?: false, overflow_latched?: false}
  end

  @spec normalize(String.t() | nil, map(), state(), :sse | :websocket) :: normalized()
  def normalize(event_type, decoded, state, overflow_mode)
      when is_map(decoded) and overflow_mode in [:sse, :websocket] do
    case public_shape(event_type, decoded) do
      {:ok, public_type, public_decoded} ->
        assign(public_type, public_decoded, state, overflow_mode)

      :drop ->
        {:drop, state}
    end
  end

  @spec public_shape(String.t() | nil, map()) ::
          {:ok, String.t() | nil, map()} | :drop
  def public_shape(event_type, decoded) when is_map(decoded) do
    if public_types_agree?(event_type, Map.get(decoded, "type")) do
      case normalize_public_success(event_type, decoded) do
        {:ok, public_type, public_decoded} ->
          {public_type, public_decoded} =
            StreamProtocol.normalize_terminal_event(public_type, public_decoded)

          {:ok, public_type, public_decoded}

        :drop ->
          :drop
      end
    else
      :drop
    end
  end

  @spec assign(String.t() | nil, map(), state(), :sse | :websocket) :: normalized()
  def assign(public_type, public_decoded, state, overflow_mode)
      when is_map(public_decoded) and overflow_mode in [:sse, :websocket] do
    if state.terminal_latched? do
      {:drop, state}
    else
      terminal? = valid_terminal?(public_type, public_decoded)
      sequence = next_sequence(public_decoded, state)

      if sequence == @max_safe_integer and not terminal? do
        overflow(state, overflow_mode)
      else
        state = %{
          state
          | max_seen: sequence,
            terminal_latched?: terminal?
        }

        {:emit, public_type, Map.put(public_decoded, "sequence_number", sequence), state}
      end
    end
  end

  @spec max_safe_integer() :: pos_integer()
  def max_safe_integer, do: @max_safe_integer

  defp normalize_public_success(event_type, decoded) do
    case StreamProtocol.terminal_outcome(event_type, decoded) do
      {:ok, %{kind: :completed, data_type: nil}} ->
        response = Map.put_new(decoded, "status", "completed")

        {:ok, "response.completed", %{"type" => "response.completed", "response" => response}}

      {:ok, %{kind: :completed, data_type: "response.done"}} ->
        response = decoded |> Map.fetch!("response") |> Map.put("status", "completed")

        {:ok, "response.completed",
         decoded
         |> Map.put("type", "response.completed")
         |> Map.put("response", response)}

      {:ok, %{kind: :completed, data_type: "response.completed"}} ->
        {:ok, "response.completed", decoded}

      _outcome when event_type in ["response.completed", "response.done"] ->
        :drop

      _outcome when is_map_key(decoded, "type") ->
        if Map.get(decoded, "type") in ["response.completed", "response.done"] do
          :drop
        else
          {:ok, event_type || string_value(decoded, "type"), decoded}
        end

      _outcome ->
        {:ok, event_type || string_value(decoded, "type"), decoded}
    end
  end

  defp valid_terminal?(type, decoded) do
    match?({:ok, _outcome}, StreamProtocol.terminal_outcome(type, decoded))
  end

  defp next_sequence(decoded, %{max_seen: max_seen}) do
    case Map.get(decoded, "sequence_number") do
      sequence
      when is_integer(sequence) and sequence >= 0 and sequence <= @max_safe_integer and
             (is_nil(max_seen) or sequence > max_seen) ->
        sequence

      _sequence ->
        (max_seen || -1) + 1
    end
  end

  defp overflow(state, :websocket) do
    {:overflow, %{}, %{state | terminal_latched?: true, overflow_latched?: true}}
  end

  defp overflow(state, :sse) do
    error = %{
      "code" => "response_sequence_exhausted",
      "message" => "response sequence exhausted"
    }

    failed = %{
      "type" => "response.failed",
      "sequence_number" => @max_safe_integer,
      "error" => error,
      "response" => %{"status" => "failed", "error" => error}
    }

    {:overflow, failed,
     %{
       state
       | max_seen: @max_safe_integer,
         terminal_latched?: true,
         overflow_latched?: true
     }}
  end

  defp string_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp public_types_agree?(event_type, data_type)
       when is_binary(event_type) and event_type != "" and is_binary(data_type) and
              data_type != "",
       do: event_type == data_type

  defp public_types_agree?(_event_type, _data_type), do: true
end
