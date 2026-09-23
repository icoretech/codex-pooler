defmodule CodexPooler.Gateway.Transports.Streaming.StreamProtocol.TerminalOutcome do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.ModelUnavailability
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCanonicalization
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.EventSummary
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.SSEParser

  @terminal_event_types ["response.failed", "response.incomplete", "error"]
  @success_event_types ["response.completed", "response.done"]
  @internal_control_event_types ["codex.rate_limits", "codex.response.metadata"]
  # These events are forwarded downstream but carry no model output. They also
  # carry candidate-specific client state: response identity/model headers on
  # lifecycle events, and verification/moderation/safety/turn-state metadata on
  # `response.metadata`. Keep them attempt-local until output or a terminal
  # commits the candidate; otherwise a retry mixes state from two candidates.
  @retry_window_preamble_event_types [
    "response.created",
    "response.in_progress",
    "response.metadata"
  ]
  @downstream_visible_event_types @terminal_event_types ++
                                    @retry_window_preamble_event_types
  # Lifecycle frames announce a response and carry nothing a client shows: the
  # released Codex client maps `response.created` to a bare Created event and
  # ignores `response.in_progress` and `response.queued`
  # (`codex-api/src/sse/responses.rs`, rust-v0.156.0). The client retry
  # observation already treats a cut after only these frames as nothing shown
  # (`ClientRetry.visible_frame?/1`); pre-visible replay classification uses
  # the same rule (findings#232 row 232-161). `response.metadata` is not one of
  # them: it can switch the client's safety buffering UI on.
  @lifecycle_only_event_types ["response.created", "response.in_progress", "response.queued"]

  @type terminal_failure :: %{
          required(:code) => String.t(),
          required(:upstream_code) => String.t() | nil,
          required(:upstream_error_param) => String.t() | nil,
          required(:event_type) => String.t() | nil,
          required(:data_type) => String.t() | nil
        }
  @type terminal_outcome :: %{
          required(:kind) => atom(),
          required(:event_type) => String.t() | nil,
          required(:data_type) => String.t() | nil,
          optional(:failure) => terminal_failure(),
          optional(:incomplete_reason) => String.t() | nil
        }

  @spec first_complete_event(binary()) :: {:ok, map()} | :incomplete
  def first_complete_event(buffer) do
    case SSEParser.complete_sse_blocks(buffer, bounded?: false) do
      {[block | _rest], _remaining} ->
        {:ok, ErrorCanonicalization.event_summary_from_block(block)}

      {[], _remaining} ->
        ErrorCanonicalization.incomplete_sse_or_direct_stream_event_summary(buffer)
    end
  end

  @spec terminal_outcome(binary()) :: {:ok, terminal_outcome()} | :error
  def terminal_outcome(data) when is_binary(data) do
    {blocks, _buffer} = SSEParser.complete_sse_blocks(data, bounded?: false)

    blocks
    |> Enum.find_value(fn block ->
      {event_type, decoded} = SSEParser.stream_block_event(block)
      terminal_outcome(event_type, decoded)
    end)
    |> Kernel.||(direct_terminal_outcome(data))
  end

  @spec terminal_outcome_event(map()) :: {:ok, terminal_outcome()} | nil
  def terminal_outcome_event(%{event_type: "response.completed"} = event) do
    {:ok,
     %{
       kind: :completed,
       event_type: "response.completed",
       data_type: Map.get(event, :data_type)
     }}
  end

  def terminal_outcome_event(%{event_type: "response.incomplete"} = event) do
    if ErrorCanonicalization.incomplete_failure_event?(event) do
      failure = terminal_failure_from_event(event)

      {:ok,
       %{
         kind: :failed,
         event_type: "response.incomplete",
         data_type: Map.get(event, :data_type),
         incomplete_reason: Map.get(event, :incomplete_reason),
         failure: failure
       }}
    else
      {:ok,
       %{
         kind: :incomplete,
         event_type: "response.incomplete",
         data_type: Map.get(event, :data_type),
         incomplete_reason: Map.get(event, :incomplete_reason)
       }}
    end
  end

  def terminal_outcome_event(%{event_type: event_type} = event)
      when event_type in ["response.failed", "error"] do
    failure = terminal_failure_from_event(event)

    {:ok,
     %{
       kind: :failed,
       event_type: event_type,
       data_type: Map.get(event, :data_type),
       failure: failure
     }}
  end

  def terminal_outcome_event(_event), do: nil

  @spec terminal_failure(binary()) :: {:ok, terminal_failure()} | :error
  def terminal_failure(data) when is_binary(data) do
    case terminal_outcome(data) do
      {:ok, %{kind: :failed, failure: failure}} -> {:ok, failure}
      {:ok, _outcome} -> :error
      :error -> :error
    end
  end

  @spec terminal_outcome(String.t() | nil, map()) :: {:ok, terminal_outcome()} | nil
  def terminal_outcome(event_type, decoded) when is_map(decoded) do
    case structural_success_outcome(event_type, decoded) do
      {:ok, _outcome} = outcome ->
        outcome

      nil ->
        if not success_candidate?(event_type, decoded) and
             terminal_types_agree?(event_type, decoded) do
          (event_type || ErrorCanonicalization.decoded_string(decoded, "type"))
          |> ErrorCanonicalization.event_summary(decoded)
          |> terminal_outcome_event()
        end
    end
  end

  @spec terminal_failure_event(map()) :: {:ok, terminal_failure()} | nil
  def terminal_failure_event(event) do
    case terminal_outcome_event(event) do
      {:ok, %{kind: :failed, failure: failure}} -> {:ok, failure}
      _outcome -> nil
    end
  end

  @spec retryable_first_terminal_failure(map()) :: {:ok, terminal_failure()} | :error
  def retryable_first_terminal_failure(event) do
    with {:ok, %{code: code} = failure} <- terminal_failure_event(event),
         true <- ErrorCanonicalization.retryable_first_event_code?(code),
         false <- ErrorCanonicalization.previous_response_miss_code?(failure.upstream_code) do
      {:ok, failure}
    else
      _other -> :error
    end
  end

  @spec retryable_first_terminal_failure(map(), boolean()) ::
          {:ok, terminal_failure()} | :error
  def retryable_first_terminal_failure(event, assignment_advertised?)
      when is_boolean(assignment_advertised?) do
    with {:ok, %{code: code} = failure} <- terminal_failure_event(event),
         true <-
           ErrorCanonicalization.retryable_first_event_code?(code) or
             ModelUnavailability.terminal_failure?(failure, assignment_advertised?),
         false <- ErrorCanonicalization.previous_response_miss_code?(failure.upstream_code) do
      {:ok, failure}
    else
      _other -> :error
    end
  end

  @spec auth_refresh_first_terminal_failure(map()) :: {:ok, terminal_failure()} | :error
  def auth_refresh_first_terminal_failure(event) do
    with {:ok, %{code: code} = failure} <- terminal_failure_event(event),
         true <- ErrorCanonicalization.websocket_auth_refresh_event_code?(code) do
      {:ok, failure}
    else
      _other -> :error
    end
  end

  @spec internal_rate_limit_event?(term()) :: boolean()
  def internal_rate_limit_event?(%{} = event) do
    event_type = Map.get(event, :event_type) || Map.get(event, "event_type")

    data_type =
      Map.get(event, :data_type) || Map.get(event, "data_type") || Map.get(event, "type")

    event_type == "codex.rate_limits" or data_type == "codex.rate_limits"
  end

  def internal_rate_limit_event?(data) when is_binary(data) do
    case ErrorCanonicalization.incomplete_sse_or_direct_stream_event_summary(data) do
      {:ok, event} -> internal_rate_limit_event?(event)
      :incomplete -> false
    end
  end

  def internal_rate_limit_event?(_data), do: false

  @doc """
  True for an event that is forwarded downstream but carries no model output.

  The retry window stays open across these: nothing the client has received so
  far is output, so another candidate can still serve the turn.
  """
  @spec retry_window_preamble_event?(term()) :: boolean()
  def retry_window_preamble_event?(%{} = event) do
    {event_type, data_type} = event_stream_types(event)

    preamble_types_agree?(event_type, data_type)
  end

  def retry_window_preamble_event?(_event), do: false

  @doc """
  True for a frame that carries neither model output nor a terminal: an
  internal control event or a response lifecycle event (`response.created`,
  `response.in_progress`, `response.queued`). A binary is such a frame when
  every complete SSE block is, or when it decodes to one JSON event that is.
  """
  @spec lifecycle_only_event?(term()) :: boolean()
  def lifecycle_only_event?(%{} = event) do
    {event_type, data_type} = event_stream_types(event)

    internal_control_event?(event) or
      ((is_nil(event_type) or event_type in @lifecycle_only_event_types) and
         (is_nil(data_type) or data_type in @lifecycle_only_event_types) and
         not (is_nil(event_type) and is_nil(data_type)))
  end

  def lifecycle_only_event?(data) when is_binary(data) do
    case SSEParser.complete_sse_blocks(data, bounded?: false) do
      {[_block | _rest] = blocks, ""} ->
        Enum.all?(blocks, fn block ->
          decoded = block |> SSEParser.sse_field("data") |> SSEParser.decode_sse_data()

          lifecycle_only_event?(%{
            event_type: SSEParser.sse_field(block, "event"),
            data_type: ErrorCanonicalization.decoded_string(decoded, "type")
          })
        end)

      {[_block | _rest], _remaining} ->
        false

      {[], _remaining} ->
        case CodexPooler.JSON.decode(data) do
          {:ok, %{} = decoded} -> lifecycle_only_event?(decoded)
          _other -> false
        end
    end
  end

  def lifecycle_only_event?(_data), do: false

  @doc """
  True for a downstream-visible frame that shows the client something: a
  terminal or model output, never a lifecycle-only frame
  (`lifecycle_only_event?/1`). This is the visibility a pre-visible replay is
  classified by (findings#232 row 232-161).
  """
  @spec client_visible_output_event?(term()) :: boolean()
  def client_visible_output_event?(event),
    do: downstream_visible_event?(event) and not lifecycle_only_event?(event)

  @spec internal_control_event?(term()) :: boolean()
  def internal_control_event?(%{} = event) do
    {event_type, data_type} = event_stream_types(event)
    event_type in @internal_control_event_types or data_type in @internal_control_event_types
  end

  def internal_control_event?(data) when is_binary(data) do
    case SSEParser.complete_sse_blocks(data, bounded?: false) do
      {[_block | _rest] = blocks, ""} ->
        Enum.all?(blocks, &internal_control_sse_block?/1)

      {[_block | _rest], _remaining} ->
        false

      {[], _remaining} ->
        case CodexPooler.JSON.decode(data) do
          {:ok, %{} = decoded} -> internal_control_event?(decoded)
          _other -> false
        end
    end
  end

  def internal_control_event?(_data), do: false

  @spec downstream_visible_event?(term()) :: boolean()
  def downstream_visible_event?(%{} = event) do
    not internal_control_event?(event) and visible_downstream_event?(event)
  end

  def downstream_visible_event?(data) when is_binary(data) do
    case ErrorCanonicalization.incomplete_sse_or_direct_stream_event_summary(data) do
      {:ok, event} -> downstream_visible_event?(event)
      :incomplete -> false
    end
  end

  def downstream_visible_event?(_event), do: false

  @doc """
  Splits `data` into the bytes to relay and whether a preamble block was seen.

  A fast provider failure arrives as one chunk carrying the preamble and the
  terminal error together, so a replayed attempt has to be filtered block by
  block rather than chunk by chunk. Residue that is not yet a complete block is
  always kept: it belongs to an event this function cannot classify yet.
  """
  @spec split_preamble_blocks(term()) :: {binary(), boolean()}
  def split_preamble_blocks(data) when is_binary(data) do
    {_preamble, kept, seen?} = partition_preamble_blocks(data)
    {kept, seen?}
  end

  def split_preamble_blocks(data), do: {data, false}

  @doc false
  @spec partition_preamble_blocks(term()) :: {binary(), binary(), boolean()}
  def partition_preamble_blocks(data) when is_binary(data) do
    {blocks, residue} = SSEParser.complete_sse_blocks(data, bounded?: false)

    {preamble, kept, seen?} =
      Enum.reduce(blocks, {[], [], false}, fn block, {preamble, kept, seen?} ->
        if preamble_block?(block),
          do: {[block | preamble], kept, true},
          else: {preamble, [block | kept], seen?}
      end)

    # `complete_sse_blocks/2` strips each block's terminator, so it has to be
    # put back: joining the bodies alone would run two events together and
    # corrupt the framing for everything behind the dropped preamble.
    preamble = preamble |> Enum.reverse() |> Enum.map_join(&(&1 <> "\n\n"))
    kept = kept |> Enum.reverse() |> Enum.map_join(&(&1 <> "\n\n"))

    {preamble, kept <> residue, seen?}
  end

  def partition_preamble_blocks(data), do: {"", data, false}

  defp preamble_block?(block) do
    event_type = SSEParser.sse_field(block, "event")
    decoded = block |> SSEParser.sse_field("data") |> SSEParser.decode_sse_data()
    data_type = ErrorCanonicalization.decoded_string(decoded, "type")

    retry_window_preamble_event?(%{event_type: event_type, data_type: data_type})
  end

  defp preamble_types_agree?(event_type, data_type) do
    cond do
      is_binary(event_type) and event_type != "" and is_binary(data_type) and data_type != "" ->
        event_type == data_type and event_type in @retry_window_preamble_event_types

      event_type in @retry_window_preamble_event_types ->
        true

      data_type in @retry_window_preamble_event_types ->
        true

      true ->
        false
    end
  end

  @doc """
  True when every complete block in `data` is a zero-output preamble event.

  Used to drop a retried attempt's `response.created` / `response.in_progress`
  so one turn stays one stream downstream even when it is served twice.
  """
  @spec preamble_only_stream_data?(term()) :: boolean()
  def preamble_only_stream_data?(data) when is_binary(data) do
    {blocks, _buffer} = SSEParser.complete_sse_blocks(data, bounded?: false)

    blocks != [] and
      Enum.all?(blocks, fn block ->
        event_type = SSEParser.sse_field(block, "event")
        decoded = block |> SSEParser.sse_field("data") |> SSEParser.decode_sse_data()
        data_type = ErrorCanonicalization.decoded_string(decoded, "type")
        retry_window_preamble_event?(%{event_type: event_type, data_type: data_type})
      end)
  end

  def preamble_only_stream_data?(_data), do: false

  @spec stream_data_visible?(term()) :: boolean()
  def stream_data_visible?(data) when is_binary(data) do
    {blocks, _buffer} = SSEParser.complete_sse_blocks(data, bounded?: false)

    Enum.any?(blocks, fn block ->
      event_type = SSEParser.sse_field(block, "event")
      decoded = block |> SSEParser.sse_field("data") |> SSEParser.decode_sse_data()
      data_type = ErrorCanonicalization.decoded_string(decoded, "type")
      downstream_visible_event?(%{event_type: event_type, data_type: data_type})
    end)
  end

  def stream_data_visible?(_data), do: false

  @doc """
  True when an upstream SSE chunk carries a block the client would be shown:
  model output or a terminal, never only lifecycle or control blocks
  (`client_visible_output_event?/1`). This is what commits a native HTTP turn's
  visibility; a withheld `response.created` never reached the client and is not
  a reason to refuse its resend (findings#225 row 225-191).
  """
  @spec stream_data_client_visible?(term()) :: boolean()
  def stream_data_client_visible?(data) when is_binary(data) do
    {blocks, _buffer} = SSEParser.complete_sse_blocks(data, bounded?: false)

    Enum.any?(blocks, fn block ->
      event_type = SSEParser.sse_field(block, "event")
      decoded = block |> SSEParser.sse_field("data") |> SSEParser.decode_sse_data()
      data_type = ErrorCanonicalization.decoded_string(decoded, "type")
      client_visible_output_event?(%{event_type: event_type, data_type: data_type})
    end)
  end

  def stream_data_client_visible?(_data), do: false

  defp direct_terminal_outcome(data) do
    case CodexPooler.JSON.decode(data) do
      {:ok, %{} = decoded} ->
        terminal_outcome(nil, decoded) ||
          if(success_candidate?(nil, decoded),
            do: :error,
            else: direct_event_summary_outcome(decoded)
          )

      _other ->
        :error
    end
  end

  defp direct_event_summary_outcome(decoded) do
    decoded =
      if EventSummary.typeless_detail_error?(decoded),
        do: EventSummary.canonical_typeless_detail_error_event(),
        else: decoded

    ErrorCanonicalization.event_summary(
      ErrorCanonicalization.decoded_string(decoded, "type"),
      decoded
    )
    |> terminal_outcome_event()
    |> Kernel.||(:error)
  end

  defp structural_success_outcome(event_type, %{} = decoded) do
    data_type = Map.get(decoded, "type")

    cond do
      legacy_success?(event_type, decoded) ->
        {:ok, %{kind: :completed, event_type: nil, data_type: nil}}

      data_type in @success_event_types and success_types_agree?(event_type, data_type) and
          valid_success_response?(decoded) ->
        {:ok,
         %{
           kind: :completed,
           event_type: event_type || data_type,
           data_type: data_type
         }}

      true ->
        nil
    end
  end

  defp legacy_success?(nil, %{"id" => id} = decoded) when is_binary(id),
    do: not Map.has_key?(decoded, "type")

  defp legacy_success?(_event_type, _decoded), do: false

  defp success_types_agree?(nil, data_type), do: data_type in @success_event_types
  defp success_types_agree?(event_type, data_type), do: event_type == data_type

  defp success_candidate?(event_type, decoded) do
    event_type in @success_event_types or Map.get(decoded, "type") in @success_event_types
  end

  defp valid_success_response?(%{"response" => %{} = response}) do
    case Map.fetch(response, "status") do
      :error -> true
      {:ok, "completed"} -> true
      {:ok, _status} -> false
    end
  end

  defp valid_success_response?(_decoded), do: false

  defp terminal_types_agree?(event_type, decoded) do
    data_type = Map.get(decoded, "type")

    type_labels_agree?(event_type, data_type)
  end

  defp type_labels_agree?(event_type, data_type)
       when is_binary(event_type) and event_type != "" and is_binary(data_type) and
              data_type != "",
       do: event_type == data_type

  defp type_labels_agree?(_event_type, _data_type), do: true

  defp terminal_failure_from_event(event) do
    event_type = Map.get(event, :event_type)

    %{
      code: Map.get(event, :error_code) || event_type,
      upstream_code: Map.get(event, :upstream_error_code),
      upstream_error_param: Map.get(event, :upstream_error_param),
      event_type: event_type,
      data_type: Map.get(event, :data_type)
    }
  end

  defp visible_downstream_event?(event) do
    {event_type, data_type} = event_stream_types(event)

    visible_event_type?(event_type) or visible_event_type?(data_type)
  end

  defp internal_control_sse_block?(block) do
    with data when is_binary(data) <- SSEParser.sse_field(block, "data"),
         {:ok, %{} = decoded} <- CodexPooler.JSON.decode(data) do
      internal_control_event?(%{
        event_type: SSEParser.sse_field(block, "event"),
        data_type: Map.get(decoded, "type")
      })
    else
      _other -> false
    end
  end

  defp event_stream_types(event) do
    event_type = Map.get(event, :event_type) || Map.get(event, "event_type")

    data_type =
      Map.get(event, :data_type) || Map.get(event, "data_type") || Map.get(event, "type")

    {event_type, data_type}
  end

  defp visible_event_type?(type) when type in @downstream_visible_event_types, do: true

  defp visible_event_type?(type) when is_binary(type) do
    String.starts_with?(type, "codex.") or String.contains?(type, ".delta") or
      String.contains?(type, "output") or
      String.contains?(type, "message") or String.contains?(type, "tool")
  end

  defp visible_event_type?(_type), do: false
end
