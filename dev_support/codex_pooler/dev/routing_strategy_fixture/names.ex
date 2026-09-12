defmodule CodexPooler.Dev.RoutingStrategyFixture.Names do
  @moduledoc false

  @pool_slug "routing-strategy-smoke"

  @spec pool_slug() :: String.t()
  def pool_slug, do: @pool_slug

  @spec account_id(pos_integer()) :: String.t()
  def account_id(index) when is_integer(index) and index > 0,
    do: "#{@pool_slug}-#{index}"

  @spec account_ids(pos_integer()) :: [String.t()]
  def account_ids(count) when is_integer(count) and count > 0,
    do: Enum.map(1..count, &account_id/1)

  @spec correlation_id(pos_integer()) :: String.t()
  def correlation_id(index) when is_integer(index) and index > 0,
    do: "#{@pool_slug}-#{index}-#{System.unique_integer([:positive, :monotonic])}"
end
