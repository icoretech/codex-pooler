defmodule CodexPooler.Gateway.Runtime.Streaming.StreamAttempt do
  @moduledoc """
  Tracks and classifies the first SSE event for a streaming gateway attempt.
  """

  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @max_leading_sse_blocks 32

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
  def classify_first_event(data, state),
    do: classify_first_event_with_provenance(data, state, nil)

  @spec classify_first_event(binary(), first_event_state(), boolean()) ::
          {classification(), first_event_state()}
  def classify_first_event(
        data,
        %{classified?: _classified?, buffer: buffer} = state,
        assignment_advertised?
      )
      when is_binary(data) and is_binary(buffer) and is_boolean(assignment_advertised?) do
    classify_first_event_with_provenance(data, state, assignment_advertised?)
  end

  defp classify_first_event_with_provenance(
         data,
         %{classified?: classified?, buffer: buffer} = state,
         assignment_advertised?
       )
       when is_binary(data) and is_binary(buffer) do
    if classified? do
      classify_data_after_first_event(data)
    else
      classify_data_before_first_event(data, state, assignment_advertised?)
    end
  end

  defp classify_data_after_first_event(data) do
    classification =
      case StreamProtocol.terminal_outcome(data) do
        {:ok, %{kind: :failed, failure: failure}} -> {:write_terminal_failure, data, failure}
        _outcome -> {:write, data}
      end

    {classification, %{classified?: true, buffer: ""}}
  end

  defp classify_data_before_first_event(data, %{buffer: buffer}, assignment_advertised?)
       when is_binary(data) and is_binary(buffer) do
    buffer = buffer <> data

    case first_retry_window_event(buffer) do
      {:ok, event} ->
        classify_complete_first_event(buffer, event, assignment_advertised?)

      :non_visible_complete ->
        {{:write, buffer}, %{classified?: false, buffer: ""}}

      :classification_limit ->
        {{:write, buffer}, %{classified?: true, buffer: ""}}

      :incomplete ->
        classify_incomplete_first_event(buffer)
    end
  end

  defp first_retry_window_event(buffer) do
    {blocks, remaining} = StreamProtocol.complete_sse_blocks(buffer, bounded?: false)
    leading_blocks = Enum.take(blocks, @max_leading_sse_blocks)

    case Enum.find_value(leading_blocks, &retry_window_event/1) do
      {:ok, event} ->
        {:ok, event}

      nil when blocks == [] ->
        direct_retry_window_event(buffer)

      nil when length(blocks) > @max_leading_sse_blocks ->
        :classification_limit

      nil when remaining == "" ->
        :non_visible_complete

      nil ->
        :incomplete
    end
  end

  defp retry_window_event(block) do
    case StreamProtocol.first_complete_event(block <> "\n\n") do
      {:ok, event} ->
        if StreamProtocol.downstream_visible_event?(event) or
             not is_nil(StreamProtocol.terminal_outcome_event(event)),
           do: {:ok, event}

      :incomplete ->
        nil
    end
  end

  defp direct_retry_window_event(buffer) do
    case StreamProtocol.first_complete_event(buffer) do
      {:ok, event} ->
        if StreamProtocol.downstream_visible_event?(event),
          do: {:ok, event},
          else: :incomplete

      :incomplete ->
        :incomplete
    end
  end

  @spec clear_first_event_state(term()) :: :ok
  def clear_first_event_state(_attempt), do: :ok

  defp classify_incomplete_first_event(buffer) do
    if StreamProtocol.oversized_incomplete_sse_block?(buffer) do
      BufferTelemetry.record_oversized_incomplete(
        "first_event",
        byte_size(buffer),
        StreamProtocol.max_incomplete_sse_block_bytes()
      )

      {{:write, buffer}, %{classified?: true, buffer: ""}}
    else
      {:buffered, %{classified?: false, buffer: buffer}}
    end
  end

  defp classify_complete_first_event(buffer, event, assignment_advertised?) do
    classification =
      case retryable_first_terminal_failure(event, assignment_advertised?) do
        {:ok, failure} -> {:retry, failure}
        :error -> classify_non_retryable_first_event(buffer, event)
      end

    {classification, classify_complete_first_event_state(event)}
  end

  defp retryable_first_terminal_failure(event, nil),
    do: StreamProtocol.retryable_first_terminal_failure(event)

  defp retryable_first_terminal_failure(event, assignment_advertised?),
    do: StreamProtocol.retryable_first_terminal_failure(event, assignment_advertised?)

  defp classify_non_retryable_first_event(buffer, event) do
    if StreamProtocol.internal_rate_limit_event?(event) do
      {:write, buffer}
    else
      case StreamProtocol.terminal_outcome_event(event) do
        {:ok, %{kind: :failed, failure: failure}} -> {:write_terminal_failure, buffer, failure}
        _outcome -> {:write, buffer}
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
