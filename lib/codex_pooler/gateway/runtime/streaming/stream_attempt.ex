defmodule CodexPooler.Gateway.Runtime.Streaming.StreamAttempt do
  @moduledoc """
  Tracks and classifies the first SSE event for a streaming gateway attempt.
  """

  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.Gateway.Runtime.Streaming.EventSummary
  alias CodexPooler.Gateway.Runtime.Streaming.SSEParser
  alias CodexPooler.Gateway.Runtime.Streaming.TerminalOutcome
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  @max_leading_sse_blocks 32

  @type classification ::
          {:retry, StreamProtocol.terminal_failure()}
          | {:write, binary()}
          | {:write_terminal_failure, binary(), StreamProtocol.terminal_failure()}
          | :buffered
  @type first_event_state :: %{
          required(:classified?) => boolean(),
          required(:buffer) => binary(),
          required(:parser) => SSEParser.state()
        }

  @spec first_event_state() :: first_event_state()
  def first_event_state,
    do: %{classified?: false, buffer: "", parser: SSEParser.new_state()}

  @spec classify_first_event(binary(), first_event_state()) ::
          {classification(), first_event_state()}
  def classify_first_event(data, state),
    do: classify_first_event_with_provenance(data, state, nil, nil)

  @spec classify_first_event(binary(), first_event_state(), boolean()) ::
          {classification(), first_event_state()}
  def classify_first_event(
        data,
        %{classified?: _classified?, buffer: buffer, parser: _parser} = state,
        assignment_advertised?
      )
      when is_binary(data) and is_binary(buffer) and is_boolean(assignment_advertised?) do
    classify_first_event_with_provenance(data, state, assignment_advertised?, nil)
  end

  if Mix.env() == :test do
    @doc false
    @spec classify_first_event(binary(), first_event_state(), boolean(), keyword()) ::
            {classification(), first_event_state()}
    def classify_first_event(data, state, assignment_advertised?, opts)
        when is_boolean(assignment_advertised?) and is_list(opts) do
      direct_gates = Keyword.fetch!(opts, :direct_gates)
      classify_first_event_with_provenance(data, state, assignment_advertised?, direct_gates)
    end
  end

  defp classify_first_event_with_provenance(
         data,
         %{classified?: classified?, buffer: buffer, parser: _parser} = state,
         assignment_advertised?,
         direct_gates
       )
       when is_binary(data) and is_binary(buffer) do
    if classified? do
      classify_data_after_first_event(data)
    else
      classify_data_before_first_event(data, state, assignment_advertised?, direct_gates)
    end
  end

  defp classify_data_after_first_event(data) do
    classification =
      case StreamProtocol.terminal_outcome(data) do
        {:ok, %{kind: :failed, failure: failure}} -> {:write_terminal_failure, data, failure}
        _outcome -> {:write, data}
      end

    {classification, classified_state()}
  end

  defp classify_data_before_first_event(
         data,
         %{buffer: buffer, parser: parser},
         assignment_advertised?,
         direct_gates
       )
       when is_binary(data) and is_binary(buffer) do
    buffer = buffer <> data
    {blocks, parser, newline?} = SSEParser.complete_blocks(parser, buffer, data)
    parser = match_complete_blocks(parser, blocks)

    case first_retry_window_event(buffer, data, parser, newline?, direct_gates) do
      {:ok, event} ->
        classify_complete_first_event(buffer, event, assignment_advertised?)

      :non_visible_complete ->
        {{:write, buffer}, first_event_state()}

      :classification_limit ->
        {{:write, buffer}, classified_state()}

      :incomplete ->
        classify_incomplete_first_event(buffer, parser)
    end
  end

  defp match_complete_blocks(%{matched: {:ok, _event}} = parser, _blocks), do: parser

  defp match_complete_blocks(%{blocks_seen: blocks_seen} = parser, blocks) do
    available = max(@max_leading_sse_blocks - (blocks_seen - length(blocks)), 0)

    matched =
      blocks
      |> Enum.take(available)
      |> Enum.find_value(fn block ->
        block
        |> EventSummary.from_complete_block()
        |> TerminalOutcome.retry_window_event()
      end)

    if matched, do: %{parser | matched: matched}, else: parser
  end

  defp first_retry_window_event(_buffer, _data, %{matched: {:ok, event}}, _newline?, _gates),
    do: {:ok, event}

  defp first_retry_window_event(_buffer, _data, %{blocks_seen: blocks_seen}, _newline?, _gates)
       when blocks_seen > @max_leading_sse_blocks,
       do: :classification_limit

  defp first_retry_window_event(buffer, data, %{blocks_seen: 0} = parser, newline?, gates) do
    if direct_rescan?(parser, data, newline?, gates) do
      buffer
      |> EventSummary.from_direct_candidate()
      |> TerminalOutcome.direct_retry_window_event()
    else
      if parser.residue_empty?, do: :non_visible_complete, else: :incomplete
    end
  end

  defp first_retry_window_event(_buffer, _data, %{residue_empty?: true}, _newline?, _gates),
    do: :non_visible_complete

  defp first_retry_window_event(_buffer, _data, _parser, _newline?, _gates), do: :incomplete

  defp direct_rescan?(parser, data, newline?, nil),
    do: SSEParser.direct_rescan?(parser, data, newline?)

  if Mix.env() == :test do
    defp direct_rescan?(parser, data, newline?, gates),
      do: SSEParser.direct_rescan?(parser, data, newline?, gates)
  end

  @spec clear_first_event_state(term()) :: :ok
  def clear_first_event_state(_attempt), do: :ok

  defp classify_incomplete_first_event(buffer, parser) do
    if StreamProtocol.oversized_incomplete_sse_block?(buffer) do
      BufferTelemetry.record_oversized_incomplete(
        "first_event",
        byte_size(buffer),
        StreamProtocol.max_incomplete_sse_block_bytes()
      )

      {{:write, buffer}, classified_state()}
    else
      {:buffered, %{classified?: false, buffer: buffer, parser: parser}}
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
      first_event_state()
    else
      classified_state()
    end
  end

  defp classified_state,
    do: %{classified?: true, buffer: "", parser: SSEParser.new_state()}
end
