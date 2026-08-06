defmodule CodexPooler.Gateway.OperationalSettings.IPRulesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OperationalSettings.IPRules
  alias CodexPooler.Gateway.OperationalSettings.IPRules.Rule

  test "compile/1 assigns full prefixes to exact IPv4 and IPv6 rules" do
    assert {:ok, rules} = IPRules.compile(["192.0.2.10", "2001:db8::a"])

    assert rules == [
             %Rule{network: {192, 0, 2, 10}, prefix: 32},
             %Rule{network: {8193, 3512, 0, 0, 0, 0, 0, 10}, prefix: 128}
           ]

    assert IPRules.allowed?({192, 0, 2, 10}, rules)
    assert IPRules.allowed?({8193, 3512, 0, 0, 0, 0, 0, 10}, rules)
    refute IPRules.allowed?({192, 0, 2, 11}, rules)
    refute IPRules.allowed?({8193, 3512, 0, 0, 0, 0, 0, 11}, rules)
  end

  test "allowed?/2 matches compiled IPv4 and IPv6 CIDR rules" do
    assert {:ok, rules} = IPRules.compile(["192.0.2.0/24", "2001:db8:abcd::/48"])

    assert IPRules.allowed?({192, 0, 2, 99}, rules)
    assert IPRules.allowed?({8193, 3512, 43_981, 0, 0, 0, 0, 99}, rules)
    refute IPRules.allowed?({198, 51, 100, 99}, rules)
    refute IPRules.allowed?({8193, 3512, 57_005, 0, 0, 0, 0, 99}, rules)
  end

  test "compile/1 preserves an empty compiled rule list" do
    assert IPRules.compile([]) == {:ok, []}
  end

  test "compile/1 rejects malformed rules and invalid prefixes" do
    for rules <- [["invalid-rule"], ["192.0.2.0/33"], ["2001:db8::/129"], [nil]] do
      assert IPRules.compile(rules) == {:error, :invalid_rule}
    end

    assert IPRules.compile(:invalid) == {:error, :invalid_rule}
  end

  test "allowed?/2 rejects raw nonempty rule lists" do
    assert_raise FunctionClauseError, fn ->
      IPRules.allowed?({192, 0, 2, 10}, ["192.0.2.10"])
    end
  end
end
