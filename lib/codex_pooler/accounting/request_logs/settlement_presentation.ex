defmodule CodexPooler.Accounting.RequestLogs.SettlementPresentation do
  @moduledoc false

  @type settlement_projection :: %{
          optional(:request_id) => Ecto.UUID.t(),
          optional(:usage_status) => String.t() | nil,
          optional(:input_tokens) => non_neg_integer() | nil,
          optional(:cached_input_tokens) => non_neg_integer() | nil,
          optional(:output_tokens) => non_neg_integer() | nil,
          optional(:reasoning_tokens) => non_neg_integer() | nil,
          optional(:total_tokens) => non_neg_integer() | nil,
          optional(:settled_cost_micros) => Decimal.t() | integer() | nil,
          optional(:cached_input_token_micros) => Decimal.t() | nil,
          optional(:details) => map() | nil
        }

  @type token_counts :: %{
          required(:input_tokens) => non_neg_integer() | nil,
          required(:cached_input_tokens) => non_neg_integer() | nil,
          required(:cached_input_cost_usd) => Decimal.t() | nil,
          required(:output_tokens) => non_neg_integer() | nil,
          required(:reasoning_tokens) => non_neg_integer() | nil,
          required(:total_tokens) => non_neg_integer() | nil,
          required(:usage_status) => String.t() | nil
        }

  @type cost :: %{required(:status) => String.t(), required(:usd) => Decimal.t() | nil}

  @usage_known "usage_known"

  @spec token_counts(nil | settlement_projection()) :: nil | token_counts()
  def token_counts(nil), do: nil

  def token_counts(settlement) do
    %{
      input_tokens: known_usage_value(settlement, :input_tokens),
      cached_input_tokens: known_usage_value(settlement, :cached_input_tokens),
      cached_input_cost_usd: known_usage_cached_input_cost_usd(settlement),
      output_tokens: known_usage_value(settlement, :output_tokens),
      reasoning_tokens: known_usage_value(settlement, :reasoning_tokens),
      total_tokens: known_usage_value(settlement, :total_tokens),
      usage_status: settlement.usage_status
    }
  end

  @spec cost(nil | settlement_projection()) :: cost()
  def cost(nil), do: %{status: "unavailable", usd: nil}

  def cost(settlement) do
    pricing_status = settlement.details && Map.get(settlement.details, "pricing_status")
    persisted_micros = settlement.details && Map.get(settlement.details, "settled_cost_micros")

    cond do
      not usage_known?(settlement) ->
        %{status: unpriced_status(pricing_status), usd: nil}

      is_binary(persisted_micros) ->
        %{status: "priced", usd: decimal_micros_to_usd(settlement.settled_cost_micros)}

      true ->
        %{status: unpriced_status(pricing_status), usd: nil}
    end
  end

  defp unpriced_status(status) when is_binary(status) do
    if String.starts_with?(status, "unpriced"), do: status, else: "unpriced"
  end

  defp unpriced_status(_status), do: "unpriced"

  defp known_usage_value(settlement, field) do
    if usage_known?(settlement), do: Map.get(settlement, field), else: nil
  end

  defp known_usage_cached_input_cost_usd(settlement) do
    if usage_known?(settlement), do: cached_input_cost_usd(settlement), else: nil
  end

  defp usage_known?(%{usage_status: @usage_known}), do: true
  defp usage_known?(_settlement), do: false

  defp cached_input_cost_usd(%{details: details}) do
    persisted_micros = details && Map.get(details, "cached_input_cost_micros")

    if is_binary(persisted_micros) do
      decimal_micros_to_usd(persisted_micros)
    else
      nil
    end
  end

  defp decimal_micros_to_usd(%Decimal{} = micros),
    do: micros |> Decimal.div(Decimal.new(1_000_000)) |> Decimal.round(6)

  defp decimal_micros_to_usd(value),
    do: Decimal.new(value || 0) |> Decimal.div(Decimal.new(1_000_000)) |> Decimal.round(6)
end
