defmodule CodexPooler.ServiceTierTest do
  use ExUnit.Case, async: true

  alias CodexPooler.ServiceTier

  test "canonicalizes fast while preserving other normalized tiers" do
    assert ServiceTier.canonicalize(" FAST ") == "priority"
    assert ServiceTier.canonicalize(" priority ") == "priority"
    assert ServiceTier.canonicalize(" DeFaUlT ") == "default"
    assert ServiceTier.canonicalize(" latency_preview ") == "latency_preview"
  end

  test "canonicalization is idempotent" do
    for tier <- [nil, "", " FAST ", "priority", "latency_preview", 1, %{}] do
      assert ServiceTier.canonicalize(ServiceTier.canonicalize(tier)) ==
               ServiceTier.canonicalize(tier)
    end
  end

  test "canonicalization returns nil for absent, blank, and non-binary values" do
    assert ServiceTier.canonicalize(nil) == nil
    assert ServiceTier.canonicalize(" \t\n ") == nil

    for tier <- [1, 1.0, true, :priority, [], %{}] do
      assert ServiceTier.canonicalize(tier) == nil
    end
  end

  test "fast mode recognizes only canonical priority" do
    assert ServiceTier.fast_mode?(" FAST ")
    assert ServiceTier.fast_mode?("priority")

    refute ServiceTier.fast_mode?("latency_preview")
    refute ServiceTier.fast_mode?(nil)
    refute ServiceTier.fast_mode?(" ")
    refute ServiceTier.fast_mode?(1)
  end

  test "pricing aliases cover fast spellings and unknown normalized tiers" do
    assert ServiceTier.pricing_aliases(" FAST ") == ["priority", "fast"]
    assert ServiceTier.pricing_aliases("priority") == ["priority", "fast"]
    assert ServiceTier.pricing_aliases(" latency_preview ") == ["latency_preview"]
    assert ServiceTier.pricing_aliases("default") == ["default"]
  end

  test "pricing aliases are empty for absent, blank, and non-binary values" do
    assert ServiceTier.pricing_aliases(nil) == []
    assert ServiceTier.pricing_aliases(" \t\n ") == []

    for tier <- [1, 1.0, true, :priority, [], %{}] do
      assert ServiceTier.pricing_aliases(tier) == []
    end
  end

  test "canonicalization never creates atoms from tier input" do
    tier = "unseen_service_tier_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(tier) end
    assert ServiceTier.canonicalize(tier) == tier
    assert ServiceTier.pricing_aliases(tier) == [tier]

    assert_raise ArgumentError, fn -> String.to_existing_atom(tier) end
  end
end
