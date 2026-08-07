defmodule CodexPooler.Gateway.OperationalSettings.IPRulesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OperationalSettings.IPRules
  alias CodexPooler.Gateway.OperationalSettings.IPRules.Rule

  @mapped_client {0, 0, 0, 0, 0, 65_535, 49_152, 641}

  test "compile/1 accepts ASCII space and tab around an exact IPv4 rule" do
    assert {:ok, [%Rule{network: {192, 0, 2, 10}, prefix: 32}]} =
             IPRules.compile([" \t192.0.2.10\t "])
  end

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

  test "compile/1 accepts ASCII OWS around CIDR components and canonicalizes a /0 network" do
    assert {:ok, [%Rule{network: {0, 0, 0, 0}, prefix: 0}]} =
             IPRules.compile([" \t203.0.113.45 \t/ \t0\t "])
  end

  test "compile/1 rejects non-ASCII or control whitespace, legacy IPv4, and noncanonical prefixes" do
    invalid_rules = [
      "\n203.0.113.10",
      <<0xC2, 0xA0, "203.0.113.10"::binary>>,
      "203.0.113.10/\n24",
      "001.002.003.004",
      "203.113",
      "3405803786",
      "0xCB.0x00.0x71.0x0A",
      "203.0.113.10/032",
      "203.0.113.10/+32",
      "203.0.113.10/-0"
    ]

    for rule <- invalid_rules do
      assert IPRules.compile([rule]) == {:error, :invalid_rule}
    end
  end

  test "compile/1 normalizes IPv4-mapped IPv6 rules and candidates to IPv4" do
    assert {:ok, [%Rule{network: {192, 0, 2, 129}, prefix: 32}] = rules} =
             IPRules.compile(["::ffff:192.0.2.129"])

    assert IPRules.allowed?({192, 0, 2, 129}, rules)
    assert IPRules.allowed?(@mapped_client, rules)
    assert {:ok, {192, 0, 2, 129}} = IPRules.parse_candidate(" \t::ffff:192.0.2.129\t ")
  end

  test "compile/1 translates mapped CIDR prefixes and rejects mapped prefixes below 96" do
    assert {:ok, [%Rule{network: {192, 0, 2, 0}, prefix: 24}] = rules} =
             IPRules.compile(["::ffff:192.0.2.129/120"])

    assert IPRules.allowed?({192, 0, 2, 200}, rules)
    refute IPRules.allowed?({192, 0, 3, 1}, rules)
    assert IPRules.compile(["::ffff:192.0.2.129/95"]) == {:error, :invalid_rule}
  end

  test "compile/1 rejects an entire list when one rule is invalid" do
    assert IPRules.compile(["203.0.113.10", "203.0.113.10/032"]) ==
             {:error, :invalid_rule}
  end

  test "allowed?/2 rejects raw nonempty rule lists" do
    assert_raise FunctionClauseError, fn ->
      IPRules.allowed?({192, 0, 2, 10}, ["192.0.2.10"])
    end
  end
end
