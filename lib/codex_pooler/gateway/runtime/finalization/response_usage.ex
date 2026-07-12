defmodule CodexPooler.Gateway.Runtime.Finalization.ResponseUsage do
  @moduledoc """
  Extracts accounting usage metadata from upstream JSON, SSE, and websocket response bodies.
  """

  @type usage :: %{
          required(:status) => String.t(),
          required(:source) => String.t(),
          optional(:input_tokens) => non_neg_integer(),
          optional(:cached_input_tokens) => non_neg_integer(),
          optional(:cache_write_tokens) => non_neg_integer() | nil,
          optional(:output_tokens) => non_neg_integer(),
          optional(:reasoning_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer(),
          optional(:service_tier) => String.t() | nil
        }

  @retained_usage_context_bytes 4_096
  @usage_field_pattern ~r/(?<!\\)"usage"\s*:/
  @service_tier_pattern ~r/(?<!\\)"service_tier"\s*:\s*"([^"\\]+)"/

  @spec from_json(binary()) :: usage()
  def from_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> usage_from_decoded(decoded)
      {:error, _reason} -> %{status: "usage_unknown", source: "json_decode_failed"}
    end
  end

  @spec from_sse(binary()) :: usage()
  def from_sse(body) when is_binary(body), do: from_sse_body(body, "sse_usage_missing")

  @spec from_websocket_body(binary()) :: usage()
  def from_websocket_body(body) when is_binary(body) do
    line_or_message_usage =
      best_usage(usage_from_sse_lines(body), from_delimited_json_messages(body))

    case best_usage(line_or_message_usage, usage_from_retained_usage_fragment(body)) do
      %{status: "usage_known"} = usage -> usage
      %{status: "usage_unknown"} = usage -> usage
      _missing -> %{status: "usage_unknown", source: "websocket_usage_missing"}
    end
  end

  defp from_sse_body(body, missing_source) do
    best_usage(usage_from_sse_lines(body), usage_from_retained_usage_fragment(body)) ||
      %{status: "usage_unknown", source: missing_source}
  end

  defp usage_from_sse_lines(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.replace_prefix(&1, "data: ", ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "[DONE]"))
    |> usage_from_json_lines()
  end

  defp usage_from_retained_usage_fragment(body) do
    body
    |> retained_usage_candidates()
    |> Enum.reduce(nil, fn candidate, acc ->
      case usage_from_retained_usage_candidate(candidate) do
        %{status: "usage_known"} = usage -> usage
        %{status: "usage_unknown"} = usage -> usage
        nil -> acc
      end
    end)
  end

  defp retained_usage_candidates(body) do
    @usage_field_pattern
    |> Regex.scan(body, return: :index)
    |> Enum.map(fn [{offset, _length} | _captures] ->
      record_offset = retained_record_start(body, offset)
      context_offset = max(offset - @retained_usage_context_bytes, record_offset)

      %{
        context_prefix: binary_part(body, context_offset, offset - context_offset),
        usage_fragment: binary_part(body, offset, byte_size(body) - offset)
      }
    end)
  end

  defp retained_record_start(body, offset) do
    body
    |> binary_part(0, offset)
    |> :binary.matches("\n")
    |> List.last()
    |> case do
      {newline_offset, _length} -> newline_offset + 1
      nil -> 0
    end
  end

  defp usage_from_retained_usage_candidate(%{
         context_prefix: context_prefix,
         usage_fragment: usage_fragment
       }) do
    with {:ok, input_tokens} <- retained_int(usage_fragment, ~r/"input_tokens"\s*:\s*(\d+)/),
         {:ok, output_tokens} <- retained_int(usage_fragment, ~r/"output_tokens"\s*:\s*(\d+)/),
         {:ok, total_tokens} <- retained_int(usage_fragment, ~r/"total_tokens"\s*:\s*(\d+)/),
         {:ok, cache_write_tokens} <- retained_optional_cache_write_tokens(usage_fragment) do
      %{
        "input_tokens" => input_tokens,
        "cached_input_tokens" => retained_cached_input_tokens(usage_fragment),
        "output_tokens" => output_tokens,
        "reasoning_tokens" =>
          retained_int_or_zero(usage_fragment, ~r/"reasoning_tokens"\s*:\s*(\d+)/),
        "total_tokens" => total_tokens
      }
      |> maybe_put_retained_cache_write_tokens(cache_write_tokens)
      |> normalize_usage(%{
        "service_tier" => retained_service_tier(context_prefix, usage_fragment)
      })
    else
      :invalid -> %{status: "usage_unknown", source: "invalid_usage_tokens"}
      :error -> nil
    end
  end

  defp retained_service_tier(context_prefix, usage_fragment) do
    retained_service_tier_after_usage(usage_fragment) ||
      retained_service_tier_before_usage(context_prefix)
  end

  defp retained_service_tier_after_usage(usage_fragment) do
    usage_fragment
    |> retained_suffix_after_usage_object()
    |> retained_line_suffix()
    |> retained_service_tier_matches()
    |> List.first()
  end

  defp retained_service_tier_before_usage(context_prefix) do
    context_prefix
    |> retained_service_tier_matches()
    |> List.last()
  end

  defp retained_suffix_after_usage_object(usage_fragment) do
    with {object_offset, _length} <- :binary.match(usage_fragment, "{"),
         {:ok, object_end} <- json_object_end(usage_fragment, object_offset) do
      binary_part(usage_fragment, object_end, byte_size(usage_fragment) - object_end)
    else
      _missing_or_incomplete -> ""
    end
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
      ?" ->
        scan_json_object(binary, offset + 1, depth, true, false)

      ?{ ->
        scan_json_object(binary, offset + 1, depth + 1, false, false)

      ?} when depth == 1 ->
        {:ok, offset + 1}

      ?} when depth > 1 ->
        scan_json_object(binary, offset + 1, depth - 1, false, false)

      ?} ->
        :error

      _other ->
        scan_json_object(binary, offset + 1, depth, false, false)
    end
  end

  defp retained_line_suffix(body) do
    case :binary.match(body, "\n") do
      {newline_offset, _length} -> binary_part(body, 0, newline_offset)
      :nomatch -> body
    end
  end

  defp retained_service_tier_matches(body) do
    @service_tier_pattern
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [tier] -> tier end)
  end

  defp retained_cached_input_tokens(body) do
    case retained_int(body, ~r/"cached_input_tokens"\s*:\s*(\d+)/) do
      {:ok, tokens} -> tokens
      :error -> retained_int_or_zero(body, ~r/"cached_tokens"\s*:\s*(\d+)/)
    end
  end

  defp retained_optional_cache_write_tokens(body) do
    case Regex.run(~r/"cache_write_tokens"\s*:\s*([^,}\s]+)/, body, capture: :all_but_first) do
      nil -> {:ok, nil}
      [scalar] -> normalize_retained_cache_write_scalar(scalar)
    end
  end

  defp normalize_retained_cache_write_scalar(scalar) do
    case int_value(scalar) do
      {:ok, value} -> {:ok, value}
      :error -> :invalid
    end
  end

  defp maybe_put_retained_cache_write_tokens(usage, nil), do: usage

  defp maybe_put_retained_cache_write_tokens(usage, value),
    do: Map.put(usage, "cache_write_tokens", value)

  defp retained_int_or_zero(body, pattern) do
    case retained_int(body, pattern) do
      {:ok, value} -> value
      :error -> 0
    end
  end

  defp retained_int(body, pattern) do
    case Regex.run(pattern, body, capture: :all_but_first) do
      [value] -> int_value(value)
      _other -> :error
    end
  end

  defp from_delimited_json_messages(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> usage_from_json_lines()
  end

  defp usage_from_json_lines(lines) do
    Enum.reduce(lines, nil, fn line, acc ->
      case Jason.decode(line) do
        {:ok, decoded} -> latest_usage_candidate(decoded, acc)
        {:error, _reason} -> acc
      end
    end)
  end

  defp usage_from_decoded(decoded, default \\ true)

  defp usage_from_decoded(%{"usage" => usage} = decoded, _default) when is_map(usage),
    do: normalize_usage(usage, decoded)

  defp usage_from_decoded(%{"response" => %{"usage" => usage} = response}, _default)
       when is_map(usage),
       do: normalize_usage(usage, response)

  defp usage_from_decoded(%{"output" => output}, default) when is_list(output) do
    latest_usage(output) || maybe_default_usage(default)
  end

  defp usage_from_decoded(_decoded, default), do: maybe_default_usage(default)

  defp latest_usage(items) do
    Enum.reduce(items, nil, fn item, acc ->
      case usage_from_decoded(item, false) do
        %{status: "usage_known"} = usage -> usage
        %{status: "usage_unknown"} = usage -> usage
        nil -> acc
      end
    end)
  end

  defp latest_usage_candidate(decoded, acc) do
    case usage_from_decoded(decoded, false) do
      %{status: "usage_known"} = usage -> usage
      %{status: "usage_unknown"} = usage -> usage
      nil -> acc
    end
  end

  defp best_usage(nil, nil), do: nil

  defp best_usage(%{status: "usage_known"} = usage, nil), do: usage
  defp best_usage(nil, %{status: "usage_known"} = usage), do: usage

  defp best_usage(
         %{status: "usage_known"} = line_usage,
         %{status: "usage_known"} = fragment_usage
       ) do
    if total_tokens(fragment_usage) > total_tokens(line_usage),
      do: inherit_missing_service_tier(fragment_usage, line_usage),
      else: line_usage
  end

  defp best_usage(%{status: "usage_unknown"}, %{status: "usage_known"} = usage), do: usage
  defp best_usage(%{status: "usage_known"}, %{status: "usage_unknown"} = usage), do: usage
  defp best_usage(%{status: "usage_unknown"} = usage, nil), do: usage
  defp best_usage(nil, %{status: "usage_unknown"} = usage), do: usage
  defp best_usage(%{status: "usage_unknown"} = usage, _fragment_usage), do: usage
  defp best_usage(_line_usage, %{status: "usage_unknown"} = usage), do: usage

  defp total_tokens(%{total_tokens: total_tokens}) when is_integer(total_tokens), do: total_tokens
  defp total_tokens(_usage), do: 0

  defp inherit_missing_service_tier(%{service_tier: tier} = usage, _fallback)
       when is_binary(tier),
       do: usage

  defp inherit_missing_service_tier(usage, %{service_tier: tier}) when is_binary(tier),
    do: Map.put(usage, :service_tier, tier)

  defp inherit_missing_service_tier(usage, _fallback), do: usage

  defp normalize_usage(usage, envelope) do
    with {:ok, input_tokens} <-
           required_int_value(usage["input_tokens"] || usage["prompt_tokens"]),
         {:ok, cached_input_tokens} <- optional_int_value(cached_input_tokens(usage)),
         {:ok, cache_write_tokens} <- cache_write_tokens_value(usage),
         {:ok, output_tokens} <-
           required_int_value(usage["output_tokens"] || usage["completion_tokens"]),
         {:ok, reasoning_tokens} <- optional_int_value(usage["reasoning_tokens"]),
         {:ok, total_tokens} <-
           total_tokens_value(usage["total_tokens"], input_tokens, output_tokens) do
      %{
        status: "usage_known",
        source: "upstream_usage",
        input_tokens: input_tokens,
        cached_input_tokens: cached_input_tokens,
        output_tokens: output_tokens,
        reasoning_tokens: reasoning_tokens,
        total_tokens: total_tokens,
        service_tier: service_tier(envelope)
      }
      |> maybe_put_cache_write_tokens(cache_write_tokens)
    else
      :error -> %{status: "usage_unknown", source: "invalid_usage_tokens"}
    end
  end

  defp service_tier(%{"service_tier" => tier}) when is_binary(tier), do: tier
  defp service_tier(%{"response" => %{"service_tier" => tier}}) when is_binary(tier), do: tier
  defp service_tier(_envelope), do: nil

  defp cached_input_tokens(%{"cached_input_tokens" => tokens}), do: tokens

  defp cached_input_tokens(%{"input_tokens_details" => %{"cached_tokens" => tokens}}),
    do: tokens

  defp cached_input_tokens(%{"prompt_tokens_details" => %{"cached_tokens" => tokens}}),
    do: tokens

  defp cached_input_tokens(_usage), do: nil

  defp cache_write_tokens_value(usage) do
    case fetch_cache_write_tokens(usage) do
      :absent -> {:ok, nil}
      {:present, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:present, _value} -> :error
    end
  end

  defp fetch_cache_write_tokens(usage) do
    with :error <- Map.fetch(usage, "cache_write_tokens"),
         :error <- fetch_nested(usage, "input_tokens_details", "cache_write_tokens"),
         :error <- fetch_nested(usage, "prompt_tokens_details", "cache_write_tokens") do
      :absent
    else
      {:ok, value} -> {:present, value}
    end
  end

  defp fetch_nested(map, parent_key, key) do
    case Map.fetch(map, parent_key) do
      {:ok, nested} when is_map(nested) -> Map.fetch(nested, key)
      _missing -> :error
    end
  end

  defp maybe_put_cache_write_tokens(usage, nil), do: usage
  defp maybe_put_cache_write_tokens(usage, value), do: Map.put(usage, :cache_write_tokens, value)

  defp maybe_default_usage(true), do: %{status: "usage_unknown", source: "usage_missing"}
  defp maybe_default_usage(false), do: nil

  defp total_tokens_value(nil, input_tokens, output_tokens),
    do: {:ok, input_tokens + output_tokens}

  defp total_tokens_value(value, _input_tokens, _output_tokens), do: required_int_value(value)

  defp required_int_value(nil), do: :error
  defp required_int_value(value), do: int_value(value)

  defp optional_int_value(nil), do: {:ok, 0}
  defp optional_int_value(value), do: int_value(value)

  defp int_value(nil), do: :error
  defp int_value(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp int_value(value) when is_float(value), do: :error

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _other -> :error
    end
  end

  defp int_value(_value), do: :error
end
