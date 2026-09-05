defmodule CodexPooler.Gateway.Runtime.Streaming.StreamUsageObserver do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Finalization.ResponseUsage

  @max_candidate_bytes 16_384
  @max_skipped_nesting 128
  @marker_suffix_bytes 64
  @usage_marker ~r/(?<!\\)"usage"\s*:/
  @service_tier_pattern ~r/(?<!\\)"service_tier"\s*:\s*"([^"\\]+)"/
  @type_pattern ~r/(?<!\\)"type"\s*:\s*"(response\.(?:completed|incomplete)|[^"]+)"/
  @event_pattern ~r/(?:^|\n)event:\s*(response\.[^\r\n]+)/
  @event_prefix "event:"

  @type sanitizer :: %{
          required(:depth) => non_neg_integer(),
          required(:escaped?) => boolean(),
          required(:in_string?) => boolean(),
          required(:key_position?) => boolean(),
          required(:phase) =>
            :normal | :after_attribution_key | :attribution_value | :skip | :invalid,
          required(:skip_stack) => [integer()],
          required(:string) => binary()
        }
  @type candidate :: %{
          required(:buffer) => binary(),
          required(:event_prefix) => binary(),
          required(:event_type) => String.t() | nil,
          required(:sanitizer) => sanitizer(),
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
          required(:usage_event_type) => String.t() | nil
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
      usage_event_type: nil
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

  defp observe_binary(%{candidate: %{} = candidate} = state, data) do
    scan = Map.get(candidate, :event_prefix, "") <> data

    case explicit_event_boundary(candidate.buffer, scan) do
      {:ok, event} ->
        observe_binary(%{state | candidate: nil, marker_suffix: ""}, event)

      :none ->
        {candidate_data, event_prefix} = split_event_prefix(scan)
        {candidate, buffer} = append_candidate(candidate, candidate_data)

        inspect_candidate(%{
          state
          | candidate: %{
              candidate
              | buffer: buffer,
                event_prefix: event_prefix
            }
        })
    end
  end

  defp observe_binary(state, data) do
    scan = state.marker_suffix <> data

    case Regex.run(@usage_marker, scan, return: :index) do
      [{offset, _length}] ->
        context = binary_part(scan, 0, offset)
        state = update_event_context(state, context)

        candidate = %{
          buffer: "",
          event_prefix: "",
          event_type: state.event_type,
          sanitizer: new_sanitizer(),
          service_tier: state.service_tier
        }

        candidate_data = binary_part(scan, offset, byte_size(scan) - offset)
        {candidate, buffer} = append_candidate(candidate, candidate_data)
        candidate = %{candidate | buffer: buffer}

        inspect_candidate(%{state | candidate: candidate, marker_suffix: ""})

      nil ->
        state = update_event_context(state, scan)
        %{state | marker_suffix: suffix(scan, @marker_suffix_bytes)}
    end
  end

  defp inspect_candidate(%{candidate: %{buffer: buffer} = candidate} = state) do
    with {object_offset, _length} <- :binary.match(buffer, "{"),
         {:ok, object_end} <- json_object_end(buffer, object_offset) do
      usage_object = binary_part(buffer, object_offset, object_end - object_offset)
      remainder = binary_part(buffer, object_end, byte_size(buffer) - object_end)

      state
      |> Map.put(:candidate, nil)
      |> maybe_accept_candidate(candidate, usage_object)
      |> observe_binary(remainder)
    else
      _incomplete -> bound_incomplete_candidate(state)
    end
  end

  defp bound_incomplete_candidate(
         %{candidate: %{buffer: buffer, sanitizer: %{phase: :invalid}} = candidate} = state
       ) do
    %{state | candidate: %{candidate | buffer: suffix(buffer, @marker_suffix_bytes)}}
  end

  defp bound_incomplete_candidate(%{candidate: %{buffer: buffer}} = state)
       when byte_size(buffer) > @max_candidate_bytes do
    %{state | candidate: nil, marker_suffix: suffix(buffer, @marker_suffix_bytes)}
  end

  defp bound_incomplete_candidate(state), do: state

  defp append_candidate(candidate, data) do
    {sanitizer, output} = sanitize_attribution(candidate.sanitizer, data)
    {%{candidate | sanitizer: sanitizer}, candidate.buffer <> output}
  end

  defp new_sanitizer do
    %{
      depth: 0,
      escaped?: false,
      in_string?: false,
      key_position?: false,
      phase: :normal,
      skip_stack: [],
      string: ""
    }
  end

  defp sanitize_attribution(sanitizer, data),
    do: sanitize_attribution(sanitizer, data, [])

  defp sanitize_attribution(sanitizer, "", output),
    do: {sanitizer, output |> Enum.reverse() |> IO.iodata_to_binary()}

  defp sanitize_attribution(%{phase: :invalid} = sanitizer, _data, output) do
    sanitize_attribution(sanitizer, "", output)
  end

  defp sanitize_attribution(
         %{phase: :after_attribution_key} = sanitizer,
         <<byte, rest::binary>>,
         output
       ) do
    cond do
      byte in [32, 9, 10, 13] ->
        sanitize_attribution(sanitizer, rest, [<<byte>> | output])

      byte == ?: ->
        sanitize_attribution(%{sanitizer | phase: :attribution_value}, rest, [":" | output])

      true ->
        sanitize_attribution(%{sanitizer | phase: :normal}, <<byte, rest::binary>>, output)
    end
  end

  defp sanitize_attribution(
         %{phase: :attribution_value} = sanitizer,
         <<byte, rest::binary>>,
         output
       ) do
    cond do
      byte in [32, 9, 10, 13] ->
        sanitize_attribution(sanitizer, rest, [<<byte>> | output])

      byte == ?{ ->
        sanitizer = %{sanitizer | phase: :skip, skip_stack: [?}], in_string?: false}
        sanitize_attribution(sanitizer, rest, ["null" | output])

      true ->
        sanitize_attribution(%{sanitizer | phase: :normal}, <<byte, rest::binary>>, output)
    end
  end

  defp sanitize_attribution(
         %{phase: :skip, in_string?: true, escaped?: true} = sanitizer,
         <<_byte, rest::binary>>,
         output
       ),
       do: sanitize_attribution(%{sanitizer | escaped?: false}, rest, output)

  defp sanitize_attribution(
         %{phase: :skip, in_string?: true} = sanitizer,
         <<byte, rest::binary>>,
         output
       ) do
    sanitizer =
      case byte do
        ?\\ -> %{sanitizer | escaped?: true}
        ?" -> %{sanitizer | in_string?: false}
        _other -> sanitizer
      end

    sanitize_attribution(sanitizer, rest, output)
  end

  defp sanitize_attribution(
         %{phase: :skip, skip_stack: stack} = sanitizer,
         <<byte, rest::binary>>,
         output
       ) do
    case {byte, stack} do
      {?", _stack} ->
        sanitize_attribution(%{sanitizer | in_string?: true}, rest, output)

      {?{, _stack} ->
        push_skipped_container(sanitizer, ?}, rest, output)

      {?[, _stack} ->
        push_skipped_container(sanitizer, ?], rest, output)

      {closing, [closing]} ->
        sanitize_attribution(%{sanitizer | phase: :normal, skip_stack: []}, rest, output)

      {closing, [closing | remaining]} ->
        sanitize_attribution(%{sanitizer | skip_stack: remaining}, rest, output)

      {closing, _stack} when closing in [?}, ?]] ->
        # Keep skipping malformed attribution so it cannot become valid aggregate usage.
        sanitize_attribution(sanitizer, rest, output)

      _other ->
        sanitize_attribution(sanitizer, rest, output)
    end
  end

  defp sanitize_attribution(
         %{in_string?: true, escaped?: true} = sanitizer,
         <<byte, rest::binary>>,
         output
       ) do
    string = append_key_byte(sanitizer.string, byte)

    sanitize_attribution(%{sanitizer | escaped?: false, string: string}, rest, [<<byte>> | output])
  end

  defp sanitize_attribution(%{in_string?: true} = sanitizer, <<byte, rest::binary>>, output) do
    case byte do
      ?\\ ->
        sanitize_attribution(%{sanitizer | escaped?: true}, rest, ["\\" | output])

      ?" ->
        phase =
          if sanitizer.key_position? and sanitizer.depth == 1 and
               sanitizer.string == "attribution",
             do: :after_attribution_key,
             else: :normal

        sanitizer = %{sanitizer | in_string?: false, phase: phase, string: ""}
        sanitize_attribution(sanitizer, rest, ["\"" | output])

      _other ->
        string = append_key_byte(sanitizer.string, byte)
        sanitize_attribution(%{sanitizer | string: string}, rest, [<<byte>> | output])
    end
  end

  defp sanitize_attribution(%{phase: :normal} = sanitizer, <<byte, rest::binary>>, output) do
    sanitizer =
      case byte do
        ?" -> %{sanitizer | in_string?: true, string: ""}
        ?{ -> %{sanitizer | depth: sanitizer.depth + 1, key_position?: sanitizer.depth == 0}
        ?} -> %{sanitizer | depth: max(sanitizer.depth - 1, 0), key_position?: false}
        ?, -> %{sanitizer | key_position?: sanitizer.depth == 1}
        byte when byte in [32, 9, 10, 13] -> sanitizer
        _other -> %{sanitizer | key_position?: false}
      end

    sanitize_attribution(sanitizer, rest, [<<byte>> | output])
  end

  defp append_key_byte(string, byte) when byte_size(string) < 32, do: string <> <<byte>>
  defp append_key_byte(string, _byte), do: string

  defp push_skipped_container(%{skip_stack: stack} = sanitizer, closing, rest, output) do
    if length(stack) < @max_skipped_nesting do
      sanitize_attribution(%{sanitizer | skip_stack: [closing | stack]}, rest, output)
    else
      sanitize_attribution(%{sanitizer | phase: :invalid, skip_stack: []}, rest, output)
    end
  end

  defp maybe_accept_candidate(state, candidate, usage_object)
       when byte_size(usage_object) <= @max_candidate_bytes,
       do: accept_candidate(state, candidate, usage_object)

  defp maybe_accept_candidate(state, _candidate, _usage_object), do: state

  defp accept_candidate(%{terminal?: true} = state, _candidate, _usage_object), do: state

  defp accept_candidate(state, candidate, usage_object) do
    with {:ok, decoded_usage} <- Jason.decode(usage_object),
         true <- is_map(decoded_usage),
         envelope <- usage_envelope(decoded_usage, candidate.service_tier),
         %{status: "usage_known"} = usage <- ResponseUsage.from_decoded(envelope),
         true <- consistent_total?(usage) do
      terminal? = terminal_event?(candidate.event_type)

      %{
        state
        | pending_service_tier?: is_nil(usage.service_tier),
          terminal?: terminal?,
          usage: usage,
          usage_event_type: candidate.event_type
      }
    else
      _invalid_or_unknown -> state
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
      last_capture(@service_tier_pattern, event_scan, ~s("service_tier")) || state.service_tier

    state
    |> Map.put(:event_type, event_type)
    |> Map.put(:service_tier, service_tier)
    |> maybe_apply_pending_service_tier(service_tier)
  end

  defp event_context(state, scan) do
    case last_event_match(scan) do
      [{event_offset, _event_length}, {type_offset, type_length}] ->
        event_type = binary_part(scan, type_offset, type_length)
        event_scan = binary_part(scan, event_offset, byte_size(scan) - event_offset)
        {event_type, event_scan, true}

      _missing ->
        event_type = last_capture(@type_pattern, scan, ~s("type")) || state.event_type
        {event_type, scan, false}
    end
  end

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
      |> :binary.matches("\nevent:")
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

  defp explicit_event_boundary(candidate_buffer, data) do
    case event_from_scan(data) do
      :none -> event_from_scan(suffix(candidate_buffer, @marker_suffix_bytes) <> data)
      boundary -> boundary
    end
  end

  defp event_from_scan(scan) do
    case Regex.run(@event_pattern, scan, return: :index) do
      [{offset, _event_length}, {_type_offset, _type_length}] ->
        {:ok, binary_part(scan, offset, byte_size(scan) - offset)}

      _missing ->
        :none
    end
  end

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

  defp normalize_state(%{
         candidate: candidate,
         event_type: event_type,
         marker_suffix: marker_suffix,
         pending_service_tier?: pending_service_tier?,
         service_tier: service_tier,
         terminal?: terminal?,
         usage: usage,
         usage_event_type: usage_event_type
       })
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
      usage_event_type: usage_event_type
    }
  end

  defp normalize_state(_state), do: new()

  defp suffix(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp suffix(binary, max_bytes) do
    binary_part(binary, byte_size(binary) - max_bytes, max_bytes)
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
