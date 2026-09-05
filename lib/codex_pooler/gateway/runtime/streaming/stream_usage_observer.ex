defmodule CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserver do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage

  @max_candidate_bytes 16_384
  @marker_suffix_bytes 64
  @usage_marker ~r/(?<!\\)"usage"\s*:/
  @service_tier_pattern ~r/(?<!\\)"service_tier"\s*:\s*"([^"\\]+)"/
  @type_pattern ~r/(?<!\\)"type"\s*:\s*"(response\.(?:completed|incomplete)|[^"]+)"/
  @event_pattern ~r/(?:^|[\r\n])event:[ \t]*(response\.[^\r\n]+)/
  @record_boundary ~r/\r\n\r\n|\n\n|\r\r/
  @candidate_boundary ~r/\r\n\r\n|\n\n|\r\r|(?:^|[\r\n])event:[ \t]*response\.[^\r\n]+/
  @event_prefix "event:"

  @type candidate :: %{
          required(:buffer) => binary(),
          required(:event_prefix) => binary(),
          required(:event_type) => String.t() | nil,
          required(:service_tier) => String.t() | nil
        }
  @type t :: %{
          required(:candidate) => candidate() | nil,
          required(:event_type) => String.t() | nil,
          required(:marker_suffix) => binary(),
          required(:pending_service_tier?) => boolean(),
          required(:service_tier) => String.t() | nil,
          required(:terminal?) => boolean(),
          required(:usage) => ResponseUsage.usage() | nil,
          required(:usage_event_type) => String.t() | nil,
          required(:classification) => String.t(),
          required(:marker_seen) => boolean(),
          required(:valid_object_seen) => boolean(),
          required(:candidate_count) => 0..255
        }

  @spec new() :: t()
  def new do
    %{
      candidate: nil,
      event_type: nil,
      marker_suffix: "",
      pending_service_tier?: false,
      service_tier: nil,
      terminal?: false,
      usage: nil,
      usage_event_type: nil,
      classification: "missing",
      marker_seen: false,
      valid_object_seen: false,
      candidate_count: 0
    }
  end

  @spec reset(t() | term()) :: t()
  def reset(_state), do: new()

  @spec observe(t() | term(), iodata() | term()) :: t()
  def observe(%{} = state, data) when is_binary(data) do
    state
    |> normalize_state()
    |> observe_binary(data)
  end

  def observe(state, _data), do: normalize_state(state)

  @spec usage(t() | term()) :: ResponseUsage.usage() | nil
  def usage(%{usage: %{status: "usage_known"} = usage}), do: usage
  def usage(_state), do: nil

  @spec resolve(t() | term(), ResponseUsage.usage()) :: ResponseUsage.usage()
  def resolve(state, fallback), do: usage(state) || fallback

  @spec candidate_bytes(t() | term()) :: non_neg_integer()
  def candidate_bytes(%{candidate: %{buffer: buffer}}) when is_binary(buffer),
    do: byte_size(buffer)

  def candidate_bytes(_state), do: 0

  @spec max_candidate_bytes() :: pos_integer()
  def max_candidate_bytes, do: @max_candidate_bytes

  @type diagnostics :: %{
          version: 1,
          classification: String.t(),
          marker_seen: boolean(),
          valid_object_seen: boolean(),
          candidate_count: 0..255
        }

  @spec diagnostics(t() | term()) :: diagnostics()
  def diagnostics(state) do
    state = normalize_state(state)

    classification =
      cond do
        usage(state) != nil -> "known"
        state.candidate != nil -> reject_candidate(state, "parser_discontinuity").classification
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

  defp observe_binary(%{candidate: %{} = candidate} = state, data) do
    scan = Map.get(candidate, :event_prefix, "") <> data

    case candidate_before_event(scan) do
      {completion, event} when is_binary(event) ->
        state =
          inspect_candidate(%{
            state
            | candidate: %{candidate | buffer: candidate.buffer <> completion, event_prefix: ""}
          })

        state =
          if state.candidate, do: reject_candidate(state, "parser_discontinuity"), else: state

        observe_binary(state, event)

      _no_event ->
        {candidate_data, event_prefix} = split_event_prefix(scan)

        inspect_candidate(%{
          state
          | candidate: %{
              candidate
              | buffer: candidate.buffer <> candidate_data,
                event_prefix: event_prefix
            }
        })
    end
  end

  defp observe_binary(state, data) do
    scan = state.marker_suffix <> data

    case Regex.run(@record_boundary, scan, return: :index) do
      [{offset, length}] ->
        state = observe_scan(%{state | marker_suffix: ""}, binary_part(scan, 0, offset))

        state =
          if state.candidate, do: reject_candidate(state, "parser_discontinuity"), else: state

        remainder = binary_part(scan, offset + length, byte_size(scan) - offset - length)

        state
        |> reset_event_context(nil)
        |> Map.put(:marker_suffix, "")
        |> observe_binary(remainder)

      nil ->
        observe_scan(state, scan)
    end
  end

  defp observe_scan(state, scan) do
    case Regex.run(@usage_marker, scan, return: :index) do
      [{offset, _length}] ->
        context = binary_part(scan, 0, offset)
        state = update_event_context(state, context)

        candidate = %{
          buffer: binary_part(scan, offset, byte_size(scan) - offset),
          event_prefix: "",
          event_type: state.event_type,
          service_tier: state.service_tier
        }

        inspect_candidate(%{
          state
          | candidate: candidate,
            marker_suffix: "",
            marker_seen: true,
            candidate_count: min(state.candidate_count + 1, 255)
        })

      nil ->
        state = update_event_context(state, scan)
        %{state | marker_suffix: suffix(scan, @marker_suffix_bytes)}
    end
  end

  defp inspect_candidate(%{candidate: %{buffer: buffer} = candidate} = state) do
    if String.starts_with?(buffer, "{") do
      inspect_object(state, candidate, 0)
    else
      inspect_value(state, candidate)
    end
  end

  defp inspect_value(state, %{buffer: buffer} = candidate) do
    [{0, marker_length}] = Regex.run(@usage_marker, buffer, return: :index)
    value = binary_part(buffer, marker_length, byte_size(buffer) - marker_length)
    trimmed = String.trim_leading(value)

    case trimmed do
      "" ->
        bound_incomplete_candidate(state)

      "{" <> _rest ->
        candidate = %{candidate | buffer: trimmed}
        inspect_object(%{state | candidate: candidate}, candidate, 0)

      _other ->
        reject_value(state, candidate, trimmed)
    end
  end

  defp inspect_object(state, candidate, object_offset) do
    {buffer, boundary} = candidate_before_event(candidate.buffer)

    case json_object_end(buffer, object_offset) do
      {:ok, object_end} ->
        usage_object = binary_part(buffer, object_offset, object_end - object_offset)

        remainder =
          binary_part(candidate.buffer, object_end, byte_size(candidate.buffer) - object_end) <>
            candidate.event_prefix

        state
        |> Map.put(:candidate, nil)
        |> maybe_accept_candidate(candidate, usage_object)
        |> observe_binary(remainder)

      :error when is_binary(boundary) ->
        state
        |> reject_candidate("parser_discontinuity")
        |> observe_binary(boundary <> candidate.event_prefix)

      :error ->
        bound_incomplete_candidate(state)
    end
  end

  defp reject_value(state, candidate, value) do
    cond do
      byte_size(value) < 4 and String.starts_with?("null", value) ->
        bound_incomplete_candidate(state)

      String.starts_with?(value, "null") ->
        state
        |> reject_candidate("null")
        |> observe_binary(binary_part(value, 4, byte_size(value) - 4) <> candidate.event_prefix)

      true ->
        state
        |> reject_candidate("malformed")
        |> observe_binary(value <> candidate.event_prefix)
    end
  end

  defp candidate_before_event(buffer) do
    case Regex.run(@candidate_boundary, buffer, return: :index) do
      [{offset, _length} | _captures] ->
        {binary_part(buffer, 0, offset), binary_part(buffer, offset, byte_size(buffer) - offset)}

      nil ->
        {buffer, nil}
    end
  end

  defp reject_candidate(state, classification) do
    priority = ~w(missing null malformed parser_discontinuity candidate_limit)
    current = Enum.find_index(priority, &(&1 == state.classification))
    incoming = Enum.find_index(priority, &(&1 == classification))
    classification = if incoming > current, do: classification, else: state.classification
    %{state | candidate: nil, marker_suffix: "", classification: classification}
  end

  defp bound_incomplete_candidate(%{candidate: %{buffer: buffer}} = state)
       when byte_size(buffer) > @max_candidate_bytes do
    %{
      reject_candidate(state, "candidate_limit")
      | marker_suffix: suffix(buffer, @marker_suffix_bytes)
    }
  end

  defp bound_incomplete_candidate(%{candidate: %{buffer: buffer} = candidate} = state),
    do: %{state | candidate: %{candidate | buffer: :binary.copy(buffer)}}

  defp maybe_accept_candidate(state, candidate, usage_object)
       when byte_size(usage_object) <= @max_candidate_bytes,
       do: accept_candidate(state, candidate, usage_object)

  defp maybe_accept_candidate(state, _candidate, _usage_object),
    do: reject_candidate(state, "candidate_limit")

  defp accept_candidate(state, candidate, usage_object) do
    with {:ok, decoded_usage} <- Jason.decode(usage_object),
         true <- is_map(decoded_usage),
         envelope <- usage_envelope(decoded_usage, candidate.service_tier),
         %{status: "usage_known"} = usage <- ResponseUsage.from_decoded(envelope),
         true <- consistent_total?(usage) do
      terminal? = terminal_event?(candidate.event_type)

      if state.terminal? do
        %{state | valid_object_seen: true}
      else
        %{
          state
          | pending_service_tier?: is_nil(usage.service_tier),
            terminal?: terminal?,
            usage: usage,
            usage_event_type: candidate.event_type,
            valid_object_seen: true
        }
      end
    else
      _invalid_or_unknown -> reject_candidate(state, "malformed")
    end
  end

  defp usage_envelope(usage, service_tier) do
    %{"usage" => usage}
    |> maybe_put_service_tier(service_tier)
  end

  defp consistent_total?(usage),
    do: usage.total_tokens == usage.input_tokens + usage.output_tokens

  defp update_event_context(state, scan) do
    {event_type, event_scan, new_event?} = event_context(state, scan)
    state = if new_event?, do: reset_event_context(state, event_type), else: state

    service_tier =
      normalize_service_tier(last_capture(@service_tier_pattern, event_scan, ~s("service_tier"))) ||
        state.service_tier

    state
    |> Map.put(:event_type, event_type)
    |> Map.put(:service_tier, service_tier)
    |> maybe_apply_pending_service_tier(service_tier)
  end

  defp event_context(state, scan) do
    case last_event_match(scan) do
      [{event_offset, _event_length}, {type_offset, type_length}] ->
        event_type = normalize_event_type(binary_part(scan, type_offset, type_length))
        event_scan = binary_part(scan, event_offset, byte_size(scan) - event_offset)
        {event_type, event_scan, true}

      _missing ->
        event_type =
          normalize_event_type(last_capture(@type_pattern, scan, ~s("type"))) || state.event_type

        {event_type, scan, false}
    end
  end

  defp normalize_event_type(nil), do: nil
  defp normalize_event_type("response.completed"), do: "response.completed"
  defp normalize_event_type("response.incomplete"), do: "response.incomplete"
  defp normalize_event_type(_type), do: "other"

  defp normalize_service_tier(tier) when tier in ~w(auto default flex priority scale ultrafast),
    do: :binary.copy(tier)

  defp normalize_service_tier(_tier), do: nil

  defp reset_event_context(state, event_type) do
    %{
      state
      | event_type: event_type,
        pending_service_tier?: false,
        service_tier: nil,
        usage_event_type: nil
    }
  end

  defp maybe_apply_pending_service_tier(
         %{pending_service_tier?: true, usage: %{} = usage, usage_event_type: event_type} = state,
         service_tier
       )
       when is_binary(service_tier) and event_type == state.event_type do
    %{state | pending_service_tier?: false, usage: Map.put(usage, :service_tier, service_tier)}
  end

  defp maybe_apply_pending_service_tier(state, _service_tier), do: state

  defp last_capture(pattern, scan, marker) do
    scan
    |> :binary.matches(marker)
    |> Enum.reduce(nil, fn {offset, _length}, latest ->
      candidate = binary_part(scan, offset, byte_size(scan) - offset)

      case Regex.run(pattern, candidate, capture: :all_but_first) do
        [value] -> value
        _missing -> latest
      end
    end)
  end

  defp last_event_match(scan) do
    offset =
      scan
      |> :binary.matches(["\nevent:", "\revent:"])
      |> Enum.reduce(if(String.starts_with?(scan, @event_prefix), do: 0), fn
        {match_offset, _length}, _latest -> match_offset + 1
      end)

    if is_integer(offset) do
      candidate = binary_part(scan, offset, byte_size(scan) - offset)

      case Regex.run(@event_pattern, candidate, return: :index) do
        [{0, event_length}, {type_offset, type_length}] ->
          [{offset, event_length}, {offset + type_offset, type_length}]

        _missing ->
          nil
      end
    end
  end

  defp maybe_put_service_tier(envelope, tier) when is_binary(tier),
    do: Map.put(envelope, "service_tier", tier)

  defp maybe_put_service_tier(envelope, _tier), do: envelope

  defp terminal_event?(type), do: type in ["response.completed", "response.incomplete"]

  defp split_event_prefix(scan) do
    prefix_length =
      min(byte_size(scan), byte_size(@event_prefix) - 1)
      |> then(&event_prefix_length(scan, &1))

    split_at = byte_size(scan) - prefix_length
    {binary_part(scan, 0, split_at), binary_part(scan, split_at, prefix_length)}
  end

  defp event_prefix_length(_scan, 0), do: 0

  defp event_prefix_length(scan, length) do
    suffix = binary_part(scan, byte_size(scan) - length, length)

    if String.starts_with?(@event_prefix, suffix),
      do: length,
      else: event_prefix_length(scan, length - 1)
  end

  defp normalize_state(
         %{
           candidate: candidate,
           event_type: event_type,
           marker_suffix: marker_suffix,
           pending_service_tier?: pending_service_tier?,
           service_tier: service_tier,
           terminal?: terminal?,
           usage: usage,
           usage_event_type: usage_event_type
         } = state
       )
       when (is_nil(candidate) or is_map(candidate)) and is_binary(marker_suffix) and
              is_boolean(pending_service_tier?) and is_boolean(terminal?) do
    %{
      candidate: candidate,
      event_type: event_type,
      marker_suffix: marker_suffix,
      pending_service_tier?: pending_service_tier?,
      service_tier: service_tier,
      terminal?: terminal?,
      usage: usage,
      usage_event_type: usage_event_type,
      classification: Map.get(state, :classification, "missing"),
      marker_seen: Map.get(state, :marker_seen, false),
      valid_object_seen: Map.get(state, :valid_object_seen, false),
      candidate_count: Map.get(state, :candidate_count, 0)
    }
  end

  defp normalize_state(_state), do: new()

  defp suffix(binary, max_bytes) when byte_size(binary) <= max_bytes, do: :binary.copy(binary)

  defp suffix(binary, max_bytes) do
    binary |> binary_part(byte_size(binary) - max_bytes, max_bytes) |> :binary.copy()
  end

  defp json_object_end(binary, object_offset),
    do: scan_json_object(binary, object_offset, 0, false, false)

  defp scan_json_object(binary, offset, _depth, _in_string?, _escaped?)
       when offset >= byte_size(binary),
       do: :error

  defp scan_json_object(binary, offset, depth, true, true),
    do: scan_json_object(binary, offset + 1, depth, true, false)

  defp scan_json_object(binary, offset, depth, true, false) do
    case :binary.at(binary, offset) do
      ?\\ -> scan_json_object(binary, offset + 1, depth, true, true)
      ?" -> scan_json_object(binary, offset + 1, depth, false, false)
      _other -> scan_json_object(binary, offset + 1, depth, true, false)
    end
  end

  defp scan_json_object(binary, offset, depth, false, false) do
    case :binary.at(binary, offset) do
      ?" -> scan_json_object(binary, offset + 1, depth, true, false)
      ?{ -> scan_json_object(binary, offset + 1, depth + 1, false, false)
      ?} when depth == 1 -> {:ok, offset + 1}
      ?} when depth > 1 -> scan_json_object(binary, offset + 1, depth - 1, false, false)
      ?} -> :error
      _other -> scan_json_object(binary, offset + 1, depth, false, false)
    end
  end
end
