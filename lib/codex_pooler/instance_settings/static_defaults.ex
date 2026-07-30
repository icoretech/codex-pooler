defmodule CodexPooler.InstanceSettings.StaticDefaults do
  @moduledoc false

  @openai_pricing_url "https://icoretech.github.io/openai-json-pricing/pricing.json"

  @spec catalog() :: map()
  def catalog, do: %{"openai_pricing_url" => @openai_pricing_url}

  @spec development() :: map()
  def development do
    %{"impeccable_live_enabled" => false, "account_reconciliation_paused" => false}
  end
end
