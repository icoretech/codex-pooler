defmodule CodexPoolerWeb.Admin.PoolFilterFormTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Admin.PoolForm

  test "normalizes valid string-map input" do
    assert PoolForm.filter(%{
             "query" => "  Dev  ",
             "status" => "active",
             "traffic_window" => "7d"
           }) == %{
             "query" => "Dev",
             "status" => "active",
             "traffic_window" => "7d"
           }
  end

  test "supports atom-map and keyword input" do
    expected = %{"query" => "Dev", "status" => "disabled", "traffic_window" => "5h"}

    assert PoolForm.filter(%{query: " Dev ", status: "disabled", traffic_window: "5h"}) ==
             expected

    assert PoolForm.filter(query: " Dev ", status: "disabled", traffic_window: "5h") ==
             expected
  end

  test "falls back from falsey string keys to atom keys while preferring truthy strings" do
    assert PoolForm.filter(%{
             "query" => nil,
             "status" => false,
             "traffic_window" => nil,
             query: "Atom",
             status: "active",
             traffic_window: "7d"
           }) == %{
             "query" => "Atom",
             "status" => "active",
             "traffic_window" => "7d"
           }

    assert PoolForm.filter(%{
             "query" => "String",
             "status" => "disabled",
             "traffic_window" => "1h",
             query: "Atom",
             status: "active",
             traffic_window: "7d"
           }) == %{
             "query" => "String",
             "status" => "disabled",
             "traffic_window" => "1h"
           }
  end

  test "uses deterministic defaults" do
    assert PoolForm.filter() == %{"query" => "", "status" => "all", "traffic_window" => "24h"}
  end

  test "keeps status and traffic-window allowlists" do
    assert PoolForm.filter(%{"status" => "archived", "traffic_window" => "1h"}) == %{
             "query" => "",
             "status" => "archived",
             "traffic_window" => "1h"
           }

    assert PoolForm.filter(%{"status" => "unknown", "traffic_window" => "10d"}) == %{
             "query" => "",
             "status" => "all",
             "traffic_window" => "24h"
           }
  end

  test "falls back safely for malformed values and top-level inputs" do
    defaults = %{"query" => "", "status" => "all", "traffic_window" => "24h"}

    assert PoolForm.filter(%{
             "query" => %{"nested" => "value"},
             "status" => ["active"],
             "traffic_window" => 7
           }) == defaults

    assert PoolForm.filter(%{"query" => ["Dev"], "status" => nil, "traffic_window" => nil}) ==
             defaults

    assert PoolForm.filter(["bad"]) == defaults
    assert PoolForm.filter("bad") == defaults
    assert PoolForm.filter(42) == defaults
    assert PoolForm.filter(nil) == defaults
  end

  test "serializes only non-default canonical URL params" do
    assert PoolForm.query_params(%{}) == %{}

    assert PoolForm.query_params(query: " Dev ", status: "active", traffic_window: "7d") == %{
             "query" => "Dev",
             "status" => "active",
             "traffic_window" => "7d"
           }

    assert PoolForm.query_params(%{
             "query" => "  Dev  ",
             "status" => "active",
             "traffic_window" => "7d",
             "unknown" => "ignored"
           }) == %{
             "query" => "Dev",
             "status" => "active",
             "traffic_window" => "7d"
           }

    assert PoolForm.query_params(%{"query" => "", "status" => "all", "traffic_window" => "24h"}) ==
             %{}
  end
end
