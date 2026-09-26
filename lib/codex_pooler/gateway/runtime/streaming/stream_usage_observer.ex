defmodule CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserver do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage
  alias CodexPooler.Gateway.Runtime.Streaming.ModelDeclarationObserver
  alias CodexPooler.Gateway.Runtime.Streaming.UsageEnvelope

  @max_candidate_bytes 16_384
  @type candidate :: %{buffer: binary()}
  @type t :: %{
          candidate: candidate() | nil,
          envelope: UsageEnvelope.t(),
          phase: :prefix | :data | :event | :ignore,
          line_prefix: binary(),
          event_type: binary() | nil,
          marker_suffix: binary(),
          cr?: boolean(),
          terminal?: boolean(),
          usage: ResponseUsage.usage() | nil,
          previous_usage: ResponseUsage.usage() | nil,
          previous_terminal?: boolean(),
          served_model: String.t() | nil,
          model_observer: ModelDeclarationObserver.t(),
          model_recorded?: boolean(),
          previous_model_observer: ModelDeclarationObserver.t(),
          classification: String.t(),
          marker_seen: boolean(),
          valid_object_seen: boolean(),
          candidate_count: 0..255,
          counted?: boolean()
        }
  @type diagnostics :: %{
          version: 1,
          classification: String.t(),
          marker_seen: boolean(),
          valid_object_seen: boolean(),
          candidate_count: 0..255
        }

  @spec new() :: t()
  def new do
    %{
      candidate: nil,
      envelope: UsageEnvelope.new(),
      phase: :prefix,
      line_prefix: "",
      event_type: nil,
      marker_suffix: "",
      cr?: false,
      terminal?: false,
      usage: nil,
      previous_usage: nil,
      previous_terminal?: false,
      served_model: nil,
      model_observer: ModelDeclarationObserver.new(),
      model_recorded?: false,
      previous_model_observer: ModelDeclarationObserver.new(),
      classification: "missing",
      marker_seen: false,
      valid_object_seen: false,
      candidate_count: 0,
      counted?: false
    }
  end

  @spec reset(term()) :: t()
  def reset(_state), do: new()

  @spec observe(t() | term(), iodata() | term()) :: t()
  def observe(%{envelope: %UsageEnvelope{}} = state, data) when is_binary(data),
    do: state |> scan(data) |> update_usage()

  def observe(_state, data) when is_binary(data), do: observe(new(), data)
  def observe(%{envelope: %UsageEnvelope{}} = state, _data), do: state
  def observe(_state, _data), do: new()

  @spec usage(t() | term()) :: ResponseUsage.usage() | nil
  def usage(%{usage: %{status: "usage_known"} = usage} = state), do: put_served_model(usage, state)
  def usage(_state), do: nil

  @spec result(t() | term()) :: ResponseUsage.usage()
  def result(%{envelope: envelope, previous_terminal?: false} = state) do
    if incomplete_or_invalid?(envelope) or (terminal_event?(state) and envelope.usage == nil),
      do: put_served_model(%{status: "usage_unknown", source: "sse_usage_missing"}, state),
      else: usage(state) || put_served_model(%{status: "usage_unknown", source: "sse_usage_missing"}, state)
  end

  def result(state),
    do: usage(state) || put_served_model(%{status: "usage_unknown", source: "sse_usage_missing"}, state)

  @doc """
  The bounded model identifier the first response object of the stream
  declared, or `nil` when no event has declared one yet.
  """
  @spec served_model(t() | term()) :: String.t() | nil
  def served_model(%{served_model: model}) when is_binary(model), do: model
  def served_model(_state), do: nil

  defp put_served_model(usage, %{model_observer: observer} = state) do
    observer = if incomplete_or_invalid?(state.envelope) and not state.previous_terminal?, do: ModelDeclarationObserver.partial(state.previous_model_observer), else: observer
    ModelDeclarationObserver.put_usage(usage, observer)
  end

  defp put_served_model(usage, _state), do: usage

  @spec resolve(t() | term(), ResponseUsage.usage()) :: ResponseUsage.usage()
  def resolve(%{envelope: %UsageEnvelope{}} = state, _fallback), do: result(state)
  def resolve(_state, fallback), do: fallback

  @spec candidate_bytes(t() | term()) :: non_neg_integer()
  def candidate_bytes(%{candidate: %{buffer: buffer}}), do: byte_size(buffer)
  def candidate_bytes(_state), do: 0

  @spec max_candidate_bytes() :: pos_integer()
  def max_candidate_bytes, do: @max_candidate_bytes

  @spec diagnostics(t() | term()) :: diagnostics()
  def diagnostics(%{envelope: envelope} = state) do
    classification =
      cond do
        result(state).status == "usage_known" -> "known"
        state.previous_terminal? -> state.classification
        incomplete_envelope?(envelope) -> "parser_discontinuity"
        true -> state.classification
      end

    %{
      version: 1,
      classification: classification,
      marker_seen: state.marker_seen,
      valid_object_seen: state.valid_object_seen,
      candidate_count: state.candidate_count
    }
  end

  def diagnostics(_state), do: diagnostics(new())

  defp scan(state, ""), do: state
  defp scan(%{cr?: true} = state, <<?\n, rest::binary>>), do: scan(%{state | cr?: false}, rest)

  defp scan(state, <<byte, rest::binary>>) when byte in [?\r, ?\n],
    do: state |> end_line() |> Map.put(:cr?, byte == ?\r) |> scan(rest)

  defp scan(%{phase: :data} = state, data) do
    case :binary.match(data, ["\r", "\n"]) do
      :nomatch ->
        %{state | envelope: UsageEnvelope.feed(state.envelope, data), cr?: false}

      {offset, _length} ->
        <<part::binary-size(^offset), rest::binary>> = data
        scan(%{state | envelope: UsageEnvelope.feed(state.envelope, part), cr?: false}, rest)
    end
  end

  defp scan(%{phase: phase, line_prefix: prefix} = state, data)
       when phase == :ignore or (phase == :event and byte_size(prefix) == 80) do
    case :binary.match(data, ["\r", "\n"]) do
      :nomatch ->
        %{state | cr?: false}

      {offset, _length} ->
        <<_ignored::binary-size(^offset), rest::binary>> = data
        scan(%{state | cr?: false}, rest)
    end
  end

  defp scan(state, <<byte, rest::binary>>) do
    prefix =
      if byte_size(state.line_prefix) < 80,
        do: state.line_prefix <> <<byte>>,
        else: state.line_prefix

    state = %{state | line_prefix: prefix, cr?: false}
    scan(prefix_phase(state), rest)
  end

  defp prefix_phase(%{phase: :event} = state), do: state
  defp prefix_phase(%{line_prefix: "data:"} = state), do: %{state | phase: :data, line_prefix: ""}

  defp prefix_phase(%{line_prefix: "event:"} = state),
    do: %{state | phase: :event, line_prefix: ""}

  defp prefix_phase(state) do
    if String.starts_with?("data:", state.line_prefix) or
         String.starts_with?("event:", state.line_prefix),
       do: state,
       else: %{state | phase: :ignore, line_prefix: ""}
  end

  defp end_line(%{phase: :prefix, line_prefix: ""} = state), do: start_event(state)

  defp end_line(%{phase: :event} = state) do
    # SSE allows event: after data:. Re-evaluate the provisional observation
    # against the record's final discriminator, never against itself.
    state = if state.previous_terminal?, do: state, else: %{state | model_observer: state.previous_model_observer, served_model: state.previous_model_observer.first_model, model_recorded?: false}

    %{
      state
      | event_type: event_type(String.trim(state.line_prefix)),
        phase: :prefix,
        line_prefix: ""
    }
  end

  defp end_line(%{phase: :data} = state) do
    %{state | envelope: UsageEnvelope.feed(state.envelope, "\n"), phase: :prefix, line_prefix: ""}
    |> update_usage()
  end

  defp end_line(state), do: %{state | phase: :prefix, line_prefix: ""}

  defp start_event(state) do
    state = update_usage(state)

    state =
      if incomplete_envelope?(state.envelope),
        do: reject(state, "parser_discontinuity"),
        else: state

    state = finalize_record(state)
    state = if incomplete_or_invalid?(state.envelope) and not state.previous_terminal?, do: %{state | model_observer: ModelDeclarationObserver.partial(state.previous_model_observer), served_model: state.previous_model_observer.first_model}, else: state

    %{
      state
      | envelope: UsageEnvelope.new(),
        candidate: nil,
        phase: :prefix,
        line_prefix: "",
        event_type: nil,
        counted?: false,
        model_recorded?: false,
        previous_model_observer: state.model_observer,
        previous_usage: state.usage,
        previous_terminal?: state.terminal?
    }
  end

  defp update_usage(%{previous_terminal?: true} = state), do: state

  defp update_usage(state) do
    state = observe_model_record(state)
    envelope = state.envelope
    count? = envelope.marker_seen? and not state.counted?
    candidate = if envelope.projection, do: %{buffer: envelope.projection.buffer}, else: nil

    state = %{
      state
      | candidate: candidate,
        marker_seen: state.marker_seen or envelope.marker_seen?,
        counted?: state.counted? or count?,
        candidate_count: min(state.candidate_count + if(count?, do: 1, else: 0), 255)
    }

    apply_envelope(state, envelope)
  end

  defp observe_model_record(%{model_recorded?: false, envelope: %{done?: true, error: nil} = envelope} = state) do
    event = %{"model" => envelope.model, "id" => envelope.response_id || envelope.root_id, "type" => envelope.type}
    observer = if envelope.model_coverage_complete?, do: state.model_observer, else: ModelDeclarationObserver.partial(state.model_observer)
    observer = ModelDeclarationObserver.observe(observer, event, state.event_type || envelope.type)
    %{state | model_observer: observer, model_recorded?: true, served_model: observer.first_model}
  end

  defp observe_model_record(state), do: state

  defp apply_envelope(state, %{error: error}) when error != nil,
    do: reject(state, error_class(error))

  defp apply_envelope(state, %{usage_error: error}) when error != nil,
    do: reject(state, error_class(error))

  defp apply_envelope(state, %{usage: usage}) when usage != nil, do: accept(state)

  defp apply_envelope(state, %{usage: nil, projection: nil, marker_seen?: true}),
    do: %{state | usage: state.previous_usage, terminal?: state.previous_terminal?}

  defp apply_envelope(state, _envelope), do: state

  defp accept(state) do
    decoded = %{
      "usage" => state.envelope.usage,
      "service_tier" => state.envelope.tier,
      "model" => state.served_model || state.envelope.model
    }

    case ResponseUsage.from_stream_event(decoded) do
      %{status: "usage_known"} = usage -> accept_usage(state, usage)
      _unknown -> reject(state, "malformed")
    end
  end

  defp accept_usage(state, usage) do
    cond do
      usage.total_tokens != usage.input_tokens + usage.output_tokens ->
        reject(state, "malformed")

      state.previous_terminal? ->
        state

      true ->
        terminal? = terminal_event?(state)

        %{state | usage: usage, terminal?: terminal?, valid_object_seen: true}
    end
  end

  defp reject(%{previous_terminal?: true} = state, _classification), do: state

  defp reject(state, classification) do
    priority = ~w(missing null malformed parser_discontinuity candidate_limit)
    current = Enum.find_index(priority, &(&1 == state.classification))
    incoming = Enum.find_index(priority, &(&1 == classification))
    classification = if incoming > current, do: classification, else: state.classification
    terminal_invalid? = terminal_event?(state) and not state.previous_terminal?
    invalid? = (terminal_invalid? or state.envelope.error != nil) and not state.previous_terminal?

    %{
      state
      | candidate: nil,
        classification: classification,
        usage: if(invalid?, do: nil, else: state.previous_usage),
        terminal?: terminal_invalid? or state.previous_terminal?
    }
  end

  defp finalize_record(%{previous_terminal?: true} = state), do: state

  defp finalize_record(state) do
    cond do
      incomplete_or_invalid?(state.envelope) ->
        %{state | usage: nil, terminal?: terminal_event?(state)}

      terminal_event?(state) ->
        %{state | usage: if(state.envelope.usage != nil, do: state.usage), terminal?: true}

      true ->
        state
    end
  end

  defp incomplete_or_invalid?(envelope),
    do: (envelope.started? and not envelope.done?) or envelope.error != nil

  defp incomplete_envelope?(envelope),
    do: envelope.started? and not envelope.done? and envelope.error == nil

  defp terminal_event?(state),
    do:
      (state.event_type || state.envelope.type) in [
        "response.completed",
        "response.incomplete",
        "response.failed"
      ]

  defp error_class(:limit), do: "candidate_limit"
  defp error_class(:null), do: "null"
  defp error_class(_error), do: "malformed"

  defp event_type(type)
       when type in ~w(chunk response.created response.queued response.in_progress response.completed response.incomplete response.failed response.cancelled), do: type

  defp event_type(""), do: nil
  defp event_type(_type), do: "other"
end
