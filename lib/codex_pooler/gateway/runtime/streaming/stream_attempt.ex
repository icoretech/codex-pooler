defmodule CodexPooler.Gateway.Runtime.Streaming.StreamAttempt do
  @moduledoc """
  Tracks and classifies the first SSE event for a streaming gateway attempt.
  """

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @type classification ::
          {:retry, StreamProtocol.terminal_failure()}
          | {:write, binary()}
          | {:write_terminal_failure, binary(), StreamProtocol.terminal_failure()}
          | :buffered
  @type first_event_state :: %{
          required(:classified?) => boolean(),
          required(:buffer) => binary()
        }

  @spec first_event_state() :: first_event_state()
  def first_event_state, do: %{classified?: false, buffer: ""}

  @spec classify_first_event(binary(), first_event_state()) ::
          {classification(), first_event_state()}
  def classify_first_event(data, %{classified?: classified?, buffer: buffer} = state)
      when is_binary(data) and is_binary(buffer) do
    if classified? do
      classify_data_after_first_event(data)
    else
      classify_data_before_first_event(data, state)
    end
  end

  @spec clear_first_event_state(term()) :: :ok
  def clear_first_event_state(_attempt), do: :ok

  defp classify_data_after_first_event(data) do
    classification =
      case StreamProtocol.terminal_failure(data) do
        {:ok, failure} -> {:write_terminal_failure, data, failure}
        :error -> {:write, data}
      end

    {classification, %{classified?: true, buffer: ""}}
  end

  defp classify_data_before_first_event(data, %{buffer: buffer}) do
    buffer = buffer <> data

    case StreamProtocol.first_complete_event(buffer) do
      {:ok, event} -> classify_complete_first_event(buffer, event)
      :incomplete -> {:buffered, %{classified?: false, buffer: buffer}}
    end
  end

  defp classify_complete_first_event(buffer, event) do
    classification =
      case StreamProtocol.retryable_first_terminal_failure(event) do
        {:ok, failure} -> {:retry, failure}
        :error -> classify_non_retryable_first_event(buffer, event)
      end

    {classification, classify_complete_first_event_state(event)}
  end

  defp classify_non_retryable_first_event(buffer, event) do
    if StreamProtocol.internal_rate_limit_event?(event) do
      {:write, buffer}
    else
      case StreamProtocol.terminal_failure_event(event) do
        {:ok, failure} -> {:write_terminal_failure, buffer, failure}
        nil -> {:write, buffer}
      end
    end
  end

  defp classify_complete_first_event_state(event) do
    if StreamProtocol.internal_rate_limit_event?(event) do
      %{classified?: false, buffer: ""}
    else
      %{classified?: true, buffer: ""}
    end
  end
end
