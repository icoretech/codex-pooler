defmodule CodexPooler.Accounting.PricingResolution.Costing do
  @moduledoc """
  Pricing reservation estimates, token estimates, and cost calculations.
  """

  alias CodexPooler.Catalog.PricingSnapshot

  @reservation_strategy "json_bytes_div_4_ceil"
  @default_price_bucket "default"
  @long_context_price_bucket "long_context"
  @long_context_input_token_threshold 272_000
  @default_output_reservation_tokens 512
  @opaque_context_output_reservation_tokens 2_048

  @spec reservation_estimate(map(), struct() | nil, term()) :: {:ok, map()}
  def reservation_estimate(payload, snapshot, policy) do
    input_tokens = estimate_input_tokens(payload)
    output_tokens = output_reservation_tokens(payload, snapshot, policy)
    total_tokens = input_tokens + output_tokens

    {:ok,
     %{
       input_tokens: input_tokens,
       cached_input_tokens: 0,
       output_tokens: output_tokens,
       reasoning_tokens: 0,
       total_tokens: total_tokens,
       estimated_cost_micros:
         cost_micros(snapshot, %{
           input_tokens: input_tokens,
           cached_input_tokens: 0,
           output_tokens: output_tokens,
           reasoning_tokens: 0
         }),
       strategy: @reservation_strategy
     }}
  end

  @spec cost_micros(struct() | nil, map()) :: Decimal.t() | nil
  def cost_micros(nil, _usage), do: nil

  def cost_micros(%PricingSnapshot{} = snapshot, usage) do
    input_tokens = usage_value(usage, :input_tokens)
    cached_input_tokens = usage_value(usage, :cached_input_tokens)
    cache_write_tokens = reported_usage_value(usage, :cache_write_tokens)
    output_tokens = usage_value(usage, :output_tokens)
    reasoning_tokens = usage_value(usage, :reasoning_tokens)
    billable_cached_input = min(cached_input_tokens, input_tokens)
    billable_cache_write = cache_write_tokens || 0

    billable_standard_input =
      max(input_tokens - billable_cached_input - billable_cache_write, 0)

    billable_reasoning = min(reasoning_tokens, output_tokens)
    billable_standard_output = max(output_tokens - billable_reasoning, 0)

    Decimal.new(billable_standard_input)
    |> Decimal.mult(snapshot.input_token_micros || Decimal.new(0))
    |> Decimal.add(
      Decimal.mult(
        Decimal.new(billable_cached_input),
        snapshot.cached_input_token_micros || Decimal.new(0)
      )
    )
    |> Decimal.add(
      Decimal.mult(
        Decimal.new(billable_cache_write),
        snapshot.cache_write_token_micros || Decimal.new(0)
      )
    )
    |> Decimal.add(
      Decimal.mult(
        Decimal.new(billable_standard_output),
        snapshot.output_token_micros || Decimal.new(0)
      )
    )
    |> Decimal.add(
      Decimal.mult(
        Decimal.new(billable_reasoning),
        snapshot.reasoning_token_micros || Decimal.new(0)
      )
    )
    |> Decimal.add(snapshot.request_base_micros || Decimal.new(0))
  end

  @spec price_bucket(map()) :: String.t()
  def price_bucket(payload) when is_map(payload) do
    payload
    |> estimate_input_tokens()
    |> price_bucket_for_input_tokens()
  end

  @spec price_bucket_for_input_tokens(term()) :: String.t()
  def price_bucket_for_input_tokens(input_tokens)
      when input_tokens > @long_context_input_token_threshold,
      do: @long_context_price_bucket

  def price_bucket_for_input_tokens(_input_tokens), do: @default_price_bucket

  defp estimate_input_tokens(payload) do
    payload
    |> prompt_payload()
    |> estimate_tokens()
  end

  defp output_reservation_tokens(payload, _snapshot, policy) do
    payload_cap =
      get_int(payload, [:max_output_tokens, "max_output_tokens", :max_tokens, "max_tokens"])

    policy_cap = policy && policy.max_output_tokens_per_request

    [payload_cap, policy_cap, conservative_output_default(payload)]
    |> Enum.reject(&is_nil/1)
    |> Enum.max()
  end

  defp conservative_output_default(payload) do
    if opaque_context_request?(payload),
      do: @opaque_context_output_reservation_tokens,
      else: @default_output_reservation_tokens
  end

  defp opaque_context_request?(payload) when is_map(payload) do
    has_nonblank_key?(payload, ["previous_response_id", :previous_response_id]) or
      has_nonblank_key?(payload, ["conversation", :conversation]) or
      contains_opaque_reference?(payload)
  end

  defp contains_opaque_reference?(%{} = value) do
    opaque_reference?(value) or Enum.any?(Map.values(value), &contains_opaque_reference?/1)
  end

  defp contains_opaque_reference?(values) when is_list(values) do
    Enum.any?(values, &contains_opaque_reference?/1)
  end

  defp contains_opaque_reference?(_value), do: false

  defp opaque_reference?(%{"type" => type} = value) when type in ["input_image", "input_file"] do
    has_nonblank_key?(value, ["file_id", :file_id, "image_url", :image_url])
  end

  defp opaque_reference?(%{type: type} = value) when type in ["input_image", "input_file"] do
    has_nonblank_key?(value, ["file_id", :file_id, "image_url", :image_url])
  end

  defp opaque_reference?(value) do
    has_nonblank_key?(value, ["file_id", :file_id]) or tool_result_continuation?(value)
  end

  defp tool_result_continuation?(%{} = value) do
    has_nonblank_key?(value, ["call_id", :call_id]) and
      Enum.any?(
        [
          "output",
          :output,
          "result",
          :result,
          "tool_output",
          :tool_output,
          "function_call_output",
          :function_call_output
        ],
        &Map.has_key?(value, &1)
      )
  end

  defp has_nonblank_key?(%{} = value, keys) do
    Enum.any?(keys, fn key ->
      case Map.get(value, key) do
        binary when is_binary(binary) -> String.trim(binary) != ""
        nil -> false
        _value -> true
      end
    end)
  end

  defp prompt_payload(payload) do
    Map.drop(payload, [
      "model",
      :model,
      "stream",
      :stream,
      "max_tokens",
      :max_tokens,
      "max_output_tokens",
      :max_output_tokens
    ])
  end

  defp estimate_tokens(payload) when map_size(payload) == 0, do: 0

  defp estimate_tokens(payload) do
    payload
    |> Jason.encode!()
    |> byte_size()
    |> then(&ceil_div(&1, 4))
  end

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp get_int(map, keys),
    do: keys |> Enum.find_value(fn key -> Map.get(map, key) end) |> int_value()

  defp int_value(nil), do: nil
  defp int_value(%Decimal{} = value), do: decimal_to_integer(value)
  defp int_value(value) when is_integer(value), do: value

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp int_value(_value), do: nil
  defp usage_value(usage, key), do: Map.get(usage, key) || Map.get(usage, to_string(key)) || 0

  defp reported_usage_value(usage, key) do
    case Map.fetch(usage, key) do
      {:ok, value} -> value
      :error -> Map.get(usage, to_string(key))
    end
  end

  defp decimal_to_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()
end
