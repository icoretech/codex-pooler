defmodule CodexPooler.Admin.Stats.Aggregates do
  @moduledoc false

  @spec sum_integer([map()], atom()) :: integer()
  def sum_integer(rows, field) do
    Enum.reduce(rows, 0, fn row, acc -> acc + (Map.get(row, field) || 0) end)
  end

  @spec sum_decimal_integer([map()], atom()) :: integer()
  def sum_decimal_integer(rows, field) do
    Enum.reduce(rows, 0, fn row, acc -> acc + decimal_to_integer(Map.get(row, field)) end)
  end

  @spec empty_token_usage() :: map()
  def empty_token_usage do
    %{
      cached_input_tokens: 0,
      input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 0
    }
  end

  @spec decimal_to_integer(Decimal.t() | integer() | nil) :: integer()
  def decimal_to_integer(nil), do: 0

  def decimal_to_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()

  def decimal_to_integer(value) when is_integer(value), do: value

  @spec micros_to_usd_decimal(integer()) :: Decimal.t() | nil
  def micros_to_usd_decimal(0), do: nil

  def micros_to_usd_decimal(micros) do
    micros
    |> Decimal.new()
    |> Decimal.div(Decimal.new(1_000_000))
    |> Decimal.round(6)
  end

  @spec percentage(number(), number()) :: float() | nil
  def percentage(_numerator, 0), do: nil
  def percentage(numerator, denominator), do: Float.round(numerator / denominator * 100, 1)
end
