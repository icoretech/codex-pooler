defmodule CodexPooler.InstanceSettings.StaticDefaultsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.InstanceSettings.Defaults
  alias CodexPooler.InstanceSettings.StaticDefaults

  test "public defaults delegate catalog and development values to a dependency-free leaf" do
    assert StaticDefaults.catalog() == Defaults.catalog()
    assert StaticDefaults.development() == Defaults.development()

    assert StaticDefaults.development() == %{
             "account_reconciliation_paused" => false,
             "impeccable_live_enabled" => false
           }
  end
end
