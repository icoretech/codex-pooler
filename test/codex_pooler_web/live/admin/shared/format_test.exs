defmodule CodexPoolerWeb.Admin.FormatTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Admin.Format

  describe "money/1" do
    test "formats dollars with two decimal places" do
      assert Format.money(Decimal.new("1964.128867")) == "$1,964.13"
      assert Format.money(0) == "$0.00"
      assert Format.money_from_micros(7_396_090) == "$7.40"
    end
  end

  describe "token_count/1" do
    test "formats token values with compact suffixes" do
      assert Format.token_count(936) == "936"
      assert Format.token_count(1_500) == "1.5k"
      assert Format.token_count(1_500_000) == "1.5M"
      assert Format.token_count(2_500_000_000) == "2.5B"
    end
  end
end
