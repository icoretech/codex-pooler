defmodule CodexPooler.ServiceTier do
  @moduledoc false

  @spec canonicalize(term()) :: String.t() | nil
  def canonicalize(nil), do: nil

  def canonicalize(tier) when is_binary(tier) do
    case tier |> String.trim() |> String.downcase() do
      "" -> nil
      "fast" -> "priority"
      normalized -> normalized
    end
  end

  def canonicalize(_tier), do: nil

  @spec fast_mode?(term()) :: boolean()
  def fast_mode?(tier), do: canonicalize(tier) == "priority"

  @spec pricing_aliases(term()) :: [String.t()]
  def pricing_aliases(tier) do
    case canonicalize(tier) do
      "priority" -> ["priority", "fast"]
      nil -> []
      canonical -> [canonical]
    end
  end
end
