defmodule CodexPooler.InstanceSettings.IPRulesValidationTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.InstanceSettings

  setup do
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "ingress validation accepts canonical rules without rewriting their persisted strings" do
    settings = InstanceSettings.ensure_singleton!()
    rule = " \t203.0.113.45 \t/ \t0\t "

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(settings, %{
               "ingress" => %{"firewall_allowlist" => [rule]}
             })

    assert updated.ingress.firewall_allowlist == [rule]
  end

  test "ingress validation rejects the shared strict grammar and invalidates the complete list" do
    settings = InstanceSettings.ensure_singleton!()

    for rules <- [
          ["203.0.113.10/032"],
          ["::ffff:192.0.2.129/95"],
          ["203.0.113.10", "001.002.003.004"]
        ] do
      assert {:error, changeset} =
               InstanceSettings.update_system_settings(settings, %{
                 "ingress" => %{"firewall_allowlist" => rules}
               })

      assert errors_on(changeset).ingress.firewall_allowlist == [
               "contains an invalid IP or CIDR rule"
             ]
    end
  end
end
