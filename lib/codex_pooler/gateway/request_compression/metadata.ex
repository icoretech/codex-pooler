defmodule CodexPooler.Gateway.RequestCompression.Metadata do
  @moduledoc """
  Shared safe metadata contract for request-side payload compression.
  """

  @redacted "[REDACTED]"
  @statuses ~w(disabled ineligible compressed no_change skipped error_passthrough)
  @reasons ~w(
    pool_disabled
    route_ineligible
    transport_ineligible
    payload_kind_ineligible
    invalid_json
    no_candidates
    no_rewrites
    below_min_bytes
    scanner_error
    strategy_unavailable
    tokenizer_unavailable
    token_count_failed
    tokenizer_input_limit
    protected_tool_outputs
    no_token_shrink
    over_body_limit
    over_candidate_limit
    compression_error
    native_load_failed
    rewritten
  )
  @strategy_names ~w(
    diff
    json_array_lossless
    json_document_lossless
    log_output
    search_results
  )
  @bool_keys MapSet.new(~w(attempted enabled))
  @integer_keys MapSet.new(~w(
    candidate_count
    compressed_bytes
    compressed_count
    compressed_tokens
    elapsed_ms
    original_bytes
    original_tokens
    saved_bytes
    saved_tokens
    skipped_count
    tokenizer_input_skipped_count
    protected_tool_output_skipped_count
  ))
  @number_keys MapSet.new(~w(
    byte_savings_percent
    byte_savings_ratio
    compression_ratio
    token_savings_percent
    token_savings_ratio
  ))
  @identifier_keys MapSet.new(~w(route_class tokenizer transport))
  @safe_keys MapSet.new(~w(
    attempted
    byte_savings_percent
    byte_savings_ratio
    candidate_count
    compressed_bytes
    compressed_count
    compressed_tokens
    compression_ratio
    elapsed_ms
    enabled
    original_bytes
    original_tokens
    reason
    route_class
    saved_bytes
    saved_tokens
    skipped_count
    status
    strategies
    token_savings_percent
    token_savings_ratio
    tokenizer_input_skipped_count
    protected_tool_output_skipped_count
    tokenizer
    transport
  ))
  @safe_value ~r/\A[a-zA-Z0-9_.:-]+\z/

  @type metadata :: %{optional(String.t()) => term()}

  @spec request_envelope(term()) :: map()
  def request_envelope(metadata) do
    case runtime_metadata(metadata) do
      metadata when is_map(metadata) -> %{"payload_compression" => metadata}
      nil -> %{}
    end
  end

  @spec runtime_metadata(term()) :: metadata() | nil
  def runtime_metadata(metadata) when is_map(metadata) do
    if metadata_bool(metadata, :attempted) == true do
      %{}
      |> put_optional_bool("enabled", metadata_bool(metadata, :enabled))
      |> Map.put("attempted", true)
      |> put_optional_value("status", status_name(metadata_value(metadata, :status)))
      |> put_optional_value("reason", reason_name(metadata_value(metadata, :reason)))
      |> put_optional_value(
        "route_class",
        safe_identifier(metadata_value(metadata, :route_class))
      )
      |> put_optional_value("transport", safe_identifier(metadata_value(metadata, :transport)))
      |> put_optional_value("tokenizer", safe_identifier(metadata_value(metadata, :tokenizer)))
      |> put_optional_integer("candidate_count", metadata_value(metadata, :candidate_count))
      |> put_optional_integer("compressed_count", metadata_value(metadata, :compressed_count))
      |> put_optional_integer("skipped_count", metadata_value(metadata, :skipped_count))
      |> put_optional_integer(
        "tokenizer_input_skipped_count",
        metadata_value(metadata, :tokenizer_input_skipped_count)
      )
      |> put_optional_integer(
        "protected_tool_output_skipped_count",
        metadata_value(metadata, :protected_tool_output_skipped_count)
      )
      |> put_byte_savings(metadata)
      |> put_token_savings(metadata)
      |> put_optional_strategies(metadata_value(metadata, :strategies))
      |> put_optional_integer("elapsed_ms", metadata_value(metadata, :elapsed_ms))
    end
  end

  def runtime_metadata(_metadata), do: nil

  @spec sanitize_map(map()) :: map()
  def sanitize_map(metadata) when is_map(metadata) do
    Map.new(metadata, fn {child_key, child_value} ->
      normalized = normalize_key(child_key)

      sanitized_value =
        if MapSet.member?(@safe_keys, normalized) do
          sanitize_value(normalized, child_value)
        else
          @redacted
        end

      {child_key, sanitized_value}
    end)
  end

  @spec put_writer_fields(map(), atom() | String.t(), atom() | String.t(), non_neg_integer()) ::
          map()
  def put_writer_fields(metadata, status, reason, elapsed_ms)
      when is_map(metadata) and is_integer(elapsed_ms) and elapsed_ms >= 0 do
    metadata
    |> Map.put(:attempted, true)
    |> Map.put(:status, status_name(status))
    |> Map.put(:reason, reason_name(reason))
    |> Map.put(:elapsed_ms, elapsed_ms)
  end

  @spec strategy_name(term()) :: String.t() | nil
  def strategy_name(value) do
    value
    |> safe_identifier()
    |> allow_value(@strategy_names)
  end

  @spec safe_identifier(term()) :: String.t() | nil
  def safe_identifier(value) do
    case safe_value_result(value) do
      {:ok, value} -> value
      :empty -> nil
      :unsafe -> nil
    end
  end

  defp status_name(value) do
    value
    |> safe_identifier()
    |> allow_value(@statuses)
  end

  defp reason_name(nil), do: nil

  defp reason_name(value) do
    value
    |> safe_identifier()
    |> allow_value(@reasons)
  end

  defp allow_value(nil, _allowed), do: nil
  defp allow_value(value, allowed), do: if(value in allowed, do: value)

  defp put_byte_savings(metadata, source) do
    original = non_negative_integer(metadata_value(source, :original_bytes))
    compressed = non_negative_integer(metadata_value(source, :compressed_bytes))
    saved = saved_count(source, :saved_bytes, original, compressed)

    metadata
    |> put_optional_value("original_bytes", original)
    |> put_optional_value("compressed_bytes", compressed)
    |> put_optional_value("saved_bytes", saved)
    |> put_savings_ratio("byte_savings", original, saved)
    |> put_compression_ratio(original, compressed)
  end

  defp put_token_savings(metadata, source) do
    original = non_negative_integer(metadata_value(source, :original_tokens))
    compressed = non_negative_integer(metadata_value(source, :compressed_tokens))
    saved = saved_count(source, :saved_tokens, original, compressed)

    metadata
    |> put_optional_value("original_tokens", original)
    |> put_optional_value("compressed_tokens", compressed)
    |> put_optional_value("saved_tokens", saved)
    |> put_savings_ratio("token_savings", original, saved)
  end

  defp put_savings_ratio(metadata, _prefix, nil, _saved), do: metadata
  defp put_savings_ratio(metadata, _prefix, 0, _saved), do: metadata
  defp put_savings_ratio(metadata, _prefix, _original, nil), do: metadata

  defp put_savings_ratio(metadata, prefix, original, saved) do
    ratio = Float.round(saved / original, 4)

    metadata
    |> Map.put("#{prefix}_ratio", ratio)
    |> Map.put("#{prefix}_percent", Float.round(ratio * 100, 2))
  end

  defp put_compression_ratio(metadata, nil, _compressed), do: metadata
  defp put_compression_ratio(metadata, 0, _compressed), do: metadata
  defp put_compression_ratio(metadata, _original, nil), do: metadata

  defp put_compression_ratio(metadata, original, compressed) do
    Map.put(metadata, "compression_ratio", Float.round(compressed / original, 4))
  end

  defp saved_count(_source, _key, original, compressed)
       when is_integer(original) and is_integer(compressed) do
    max(original - compressed, 0)
  end

  defp saved_count(source, key, _original, _compressed) do
    non_negative_integer(metadata_value(source, key))
  end

  defp put_optional_bool(metadata, key, value) when is_boolean(value),
    do: Map.put(metadata, key, value)

  defp put_optional_bool(metadata, _key, _value), do: metadata

  defp put_optional_integer(metadata, key, value),
    do: put_optional_value(metadata, key, non_negative_integer(value))

  defp put_optional_strategies(metadata, strategies) when is_list(strategies) do
    strategies =
      strategies
      |> Enum.map(&strategy_name/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(12)

    case strategies do
      [] -> metadata
      strategies -> Map.put(metadata, "strategies", strategies)
    end
  end

  defp put_optional_strategies(metadata, _strategies), do: metadata

  defp put_optional_value(metadata, _key, nil), do: metadata
  defp put_optional_value(metadata, key, value), do: Map.put(metadata, key, value)

  defp sanitize_value("status", value), do: allowed_or_redacted(value, @statuses)
  defp sanitize_value("reason", value), do: allowed_or_redacted(value, @reasons)

  defp sanitize_value("strategies", value) when is_list(value) do
    value
    |> Enum.map(&allowed_or_redacted(&1, @strategy_names))
    |> Enum.reject(&(is_nil(&1) or &1 == @redacted))
    |> Enum.take(12)
  end

  defp sanitize_value("strategies", nil), do: nil
  defp sanitize_value("strategies", _value), do: @redacted

  defp sanitize_value(key, value) do
    cond do
      MapSet.member?(@bool_keys, key) -> sanitize_bool(value)
      MapSet.member?(@integer_keys, key) -> sanitize_integer(value)
      MapSet.member?(@number_keys, key) -> sanitize_number(value)
      MapSet.member?(@identifier_keys, key) -> sanitize_identifier(value)
      true -> @redacted
    end
  end

  defp sanitize_bool(value) when is_boolean(value), do: value
  defp sanitize_bool(nil), do: nil
  defp sanitize_bool(_value), do: @redacted

  defp sanitize_integer(value) when is_integer(value) and value >= 0, do: value
  defp sanitize_integer(nil), do: nil
  defp sanitize_integer(_value), do: @redacted

  defp sanitize_number(value) when is_integer(value) and value >= 0, do: value
  defp sanitize_number(value) when is_float(value) and value >= 0, do: value
  defp sanitize_number(nil), do: nil
  defp sanitize_number(_value), do: @redacted

  defp sanitize_identifier(value) do
    case safe_value_result(value) do
      {:ok, value} -> value
      :empty -> nil
      :unsafe -> @redacted
    end
  end

  defp allowed_or_redacted(value, allowed_values) do
    case safe_value_result(value) do
      :empty -> nil
      :unsafe -> @redacted
      {:ok, value} -> if value in allowed_values, do: value, else: @redacted
    end
  end

  defp safe_value_result(nil), do: :empty

  defp safe_value_result(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> safe_value_result()
  end

  defp safe_value_result(value) when is_binary(value) do
    value = value |> String.trim() |> String.slice(0, 120)

    cond do
      value == "" -> :empty
      sensitive_binary?(value) -> :unsafe
      String.match?(value, @safe_value) -> {:ok, value}
      true -> :unsafe
    end
  end

  defp safe_value_result(_value), do: :unsafe

  defp metadata_bool(metadata, key) do
    case metadata_value(metadata, key) do
      value when is_boolean(value) -> value
      _value -> nil
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp normalize_key(nil), do: nil

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
  end

  defp sensitive_binary?(value) do
    String.match?(value, ~r/sk-cxp-[a-f0-9]{12}-[A-Za-z0-9_-]+/) or
      String.match?(value, ~r/(?i)bearer\s+[A-Za-z0-9._~+\/-]+=*/) or
      String.match?(value, ~r/\Ask-(?!cxp-[a-f0-9]{12}\z)[A-Za-z0-9_-]{24,}\z/)
  end
end
