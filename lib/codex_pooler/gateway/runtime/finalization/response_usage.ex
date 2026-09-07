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

  @spec from_json(binary()) :: usage()
  def from_json(body) when is_binary(body) do
    case CodexPooler.JSON.decode(body) do
      {:ok, decoded} -> from_decoded(decoded)
      {:error, _reason} -> %{status: "usage_unknown", source: "json_decode_failed"}
    end
  end

  @spec from_decoded(term()) :: usage()
  def from_decoded(decoded), do: usage_from_decoded(decoded)

  @doc "Extracts only the aggregate usage owned by a streamed response envelope."
  @spec from_stream_event(term()) :: usage()
  def from_stream_event(%{"usage" => usage} = envelope) when is_map(usage),
    do: normalize_stream_usage(usage, envelope)

  def from_stream_event(%{"usage" => _invalid}),
    do: %{status: "usage_unknown", source: "invalid_usage_tokens"}

  def from_stream_event(%{"response" => %{"usage" => usage} = response}) when is_map(usage),
    do: normalize_stream_usage(usage, response)

  def from_stream_event(_event), do: %{status: "usage_unknown", source: "usage_missing"}

  defp normalize_stream_usage(usage, envelope) do
    case normalize_usage(usage, envelope) do
      %{status: "usage_known"} = normalized ->
        cached = Map.get(normalized, :cached_input_tokens, 0) || 0
        written = Map.get(normalized, :cache_write_tokens, 0) || 0

        if cached + written <= normalized.input_tokens and
             normalized.reasoning_tokens <= normalized.output_tokens,
           do: Map.put(normalized, :service_tier, stream_service_tier(envelope["service_tier"])),
           else: %{status: "usage_unknown", source: "invalid_usage_tokens"}

      unknown ->
        unknown
    end
  end

  defp stream_service_tier(tier) when tier in ~w(auto default flex priority scale ultrafast),
    do: :binary.copy(tier)

  defp stream_service_tier(_tier), do: nil

  @spec from_sse(binary()) :: usage()
  def from_sse(body) when is_binary(body) do
    case CodexPooler.JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> from_stream_event(decoded)
      _framed_or_incomplete -> decode_stream_body(body, "sse_usage_missing", false)
    end
  end

  @spec from_websocket_body(binary()) :: usage()
  def from_websocket_body(body) when is_binary(body),
    do: decode_stream_body(body, "websocket_usage_missing", true)

  defp decode_stream_body(body, missing_source, websocket?) do
    usage =
      body
      |> stream_records(websocket?)
      |> Enum.reduce_while(nil, &stream_record_usage/2)

    case usage do
      nil -> %{status: "usage_unknown", source: missing_source}
      %{source: "usage_missing"} -> %{status: "usage_unknown", source: missing_source}
      usage -> usage
    end
  end

  defp stream_record_usage({json, event_type}, previous) do
    case CodexPooler.JSON.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        candidate = from_stream_event(decoded)

        cond do
          terminal_type?(event_type || stream_event_type(decoded)) -> {:halt, candidate}
          candidate.source != "usage_missing" -> {:cont, candidate}
          true -> {:cont, previous}
        end

      _malformed ->
        if terminal_type?(event_type),
          do: {:halt, %{status: "usage_unknown", source: "json_decode_failed"}},
          else: {:cont, previous}
    end
  end

  defp terminal_type?(type),
    do: type in ["response.completed", "response.incomplete", "response.failed"]

  defp stream_event_type(%{"type" => type}) when is_binary(type), do: type
  defp stream_event_type(%{"response" => %{"type" => type}}) when is_binary(type), do: type
  defp stream_event_type(_event), do: nil

  defp stream_records(body, websocket?) do
    body
    |> String.split(~r/\r\n\r\n|\n\n|\r\r/, trim: true)
    |> Enum.flat_map(&stream_block(&1, websocket?))
  end

  defp stream_block(block, websocket?) do
    lines = String.split(block, ~r/\r\n|\n|\r/)
    data = for "data:" <> line <- lines, do: String.replace_prefix(line, " ", "")
    type = Enum.reduce(lines, nil, &sse_event_type/2)

    cond do
      data != [] -> [{Enum.join(data, "\n"), type}]
      websocket? -> Enum.map(lines, &{&1, nil})
      true -> []
    end
  end

  defp sse_event_type("event:" <> type, _previous) do
    case String.trim(type) do
      "" -> nil
      value -> value
    end
  end

  defp sse_event_type(_line, previous), do: previous

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

  defp normalize_usage(usage, envelope) do
    with {:ok, input_tokens} <-
           required_int_value(usage["input_tokens"] || usage["prompt_tokens"]),
         {:ok, cached_input_tokens} <- cached_input_tokens_value(usage),
         {:ok, cache_write_tokens} <- cache_write_tokens_value(usage),
         {:ok, output_tokens} <-
           required_int_value(usage["output_tokens"] || usage["completion_tokens"]),
         {:ok, reasoning_tokens} <- reasoning_tokens_value(usage),
         {:ok, total_tokens} <-
           total_tokens_value(usage["total_tokens"], input_tokens, output_tokens),
         true <- total_tokens == input_tokens + output_tokens do
      %{
        status: "usage_known",
        source: "upstream_usage",
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        reasoning_tokens: reasoning_tokens,
        total_tokens: total_tokens,
        service_tier: service_tier(envelope)
      }
      |> maybe_put_cached_input_tokens(cached_input_tokens)
      |> maybe_put_cache_write_tokens(cache_write_tokens)
    else
      _invalid -> %{status: "usage_unknown", source: "invalid_usage_tokens"}
    end
  end

  defp service_tier(%{"service_tier" => tier}) when is_binary(tier), do: tier
  defp service_tier(%{"response" => %{"service_tier" => tier}}) when is_binary(tier), do: tier
  defp service_tier(_envelope), do: nil

  defp cached_input_tokens_value(usage) do
    case fetch_cached_input_tokens(usage) do
      :absent -> {:ok, nil}
      {:present, value} -> int_value(value)
    end
  end

  defp fetch_cached_input_tokens(usage) do
    with :error <- Map.fetch(usage, "cached_input_tokens"),
         :error <- fetch_nested(usage, "input_tokens_details", "cached_tokens"),
         :error <- fetch_nested(usage, "prompt_tokens_details", "cached_tokens") do
      :absent
    else
      {:ok, value} -> {:present, value}
    end
  end

  defp reasoning_tokens_value(usage) do
    case fetch_nested(usage, "output_tokens_details", "reasoning_tokens") do
      {:ok, value} -> preferred_reasoning_tokens_value(value, usage)
      :error -> optional_int_value(usage["reasoning_tokens"])
    end
  end

  defp preferred_reasoning_tokens_value(value, usage) do
    case int_value(value) do
      {:ok, reasoning_tokens} -> {:ok, reasoning_tokens}
      :error -> fallback_reasoning_tokens_value(usage)
    end
  end

  defp fallback_reasoning_tokens_value(usage) do
    case Map.fetch(usage, "reasoning_tokens") do
      {:ok, value} -> int_value(value)
      :error -> :error
    end
  end

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

  defp maybe_put_cached_input_tokens(usage, nil), do: usage

  defp maybe_put_cached_input_tokens(usage, value),
    do: Map.put(usage, :cached_input_tokens, value)

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
