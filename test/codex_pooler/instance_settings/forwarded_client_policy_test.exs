defmodule CodexPooler.InstanceSettings.ForwardedClientPolicyTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.{Classification, Defaults, Settings}

  setup do
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)

    :ok
  end

  test "baseline characterization preserves existing ingress JSON through load and save" do
    settings = InstanceSettings.ensure_singleton!()

    Repo.query!(
      "UPDATE instance_settings SET ingress = ingress - 'forwarded_client_ip_source' - 'forwarded_proxy_depth'"
    )

    loaded = InstanceSettings.get!()
    assert loaded.ingress.firewall_allowlist == settings.ingress.firewall_allowlist
    assert loaded.ingress.trusted_proxies == settings.ingress.trusted_proxies
    assert loaded.ingress.decompression_algorithms == settings.ingress.decompression_algorithms

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(loaded, %{
               "ingress" => %{"max_compressed_body_bytes" => 1_234_567}
             })

    assert updated.ingress.max_compressed_body_bytes == 1_234_567
    assert updated.ingress.firewall_allowlist == settings.ingress.firewall_allowlist
    assert updated.ingress.trusted_proxies == settings.ingress.trusted_proxies
  end

  test "declares exact forwarded client defaults and cached classification" do
    settings = Settings.default()

    assert settings.ingress.forwarded_client_ip_source == :x_forwarded_for
    assert settings.ingress.forwarded_proxy_depth == 0

    assert Defaults.ingress()["forwarded_client_ip_source"] == :x_forwarded_for
    assert Defaults.ingress()["forwarded_proxy_depth"] == 0

    assert %OperationalSettings{
             forwarded_client_ip_source: :x_forwarded_for,
             forwarded_proxy_depth: 0
           } = OperationalSettings.from_instance_settings(settings)

    assert Classification.fetch!(:forwarded_client_ip_source) == %{
             key: :forwarded_client_ip_source,
             bucket: :db_runtime_cached,
             group: :ingress,
             label: "Forwarded client IP source",
             env_names: [],
             storage: :database,
             reloadability: :cached,
             notes: "Selects the single trusted source used to resolve the runtime client IP."
           }

    assert Classification.fetch!(:forwarded_proxy_depth) == %{
             key: :forwarded_proxy_depth,
             bucket: :db_runtime_cached,
             group: :ingress,
             label: "Forwarded proxy depth",
             env_names: [],
             storage: :database,
             reloadability: :cached,
             notes:
               "Uses a fixed X-Forwarded-For proxy depth, while zero keeps trusted-CIDR walking."
           }
  end

  test "accepts only the explicit source and depth matrix" do
    settings = Settings.default()

    for {source, depth} <- [peer: 0, x_real_ip: 0, x_forwarded_for: 0, x_forwarded_for: 16] do
      assert Settings.changeset(settings, %{
               "ingress" => %{
                 "forwarded_client_ip_source" => source,
                 "forwarded_proxy_depth" => depth
               }
             }).valid?
    end

    for {source, depth} <- [peer: 1, x_real_ip: 1, x_forwarded_for: -1, x_forwarded_for: 17] do
      changeset =
        Settings.changeset(settings, %{
          "ingress" => %{
            "forwarded_client_ip_source" => source,
            "forwarded_proxy_depth" => depth
          }
        })

      refute changeset.valid?
      assert errors_on(changeset).ingress.forwarded_proxy_depth != []
    end

    changeset =
      Settings.changeset(settings, %{
        "ingress" => %{
          "forwarded_client_ip_source" => :none,
          "forwarded_proxy_depth" => 0
        }
      })

    refute changeset.valid?
    assert "is invalid" in errors_on(changeset).ingress.forwarded_client_ip_source
  end

  test "loads declared defaults from old ingress JSON and persists them on the next save" do
    InstanceSettings.ensure_singleton!()

    Repo.query!(
      "UPDATE instance_settings SET ingress = ingress - 'forwarded_client_ip_source' - 'forwarded_proxy_depth'"
    )

    InstanceSettings.reset_cache_for_test()
    loaded = InstanceSettings.get!()

    assert loaded.ingress.forwarded_client_ip_source == :x_forwarded_for
    assert loaded.ingress.forwarded_proxy_depth == 0

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(loaded, %{
               "files" => %{"upload_ttl_seconds" => 600}
             })

    assert updated.files.upload_ttl_seconds == 600
    assert updated.ingress.forwarded_client_ip_source == :x_forwarded_for
    assert updated.ingress.forwarded_proxy_depth == 0

    reloaded = InstanceSettings.get!()
    assert reloaded.ingress.forwarded_client_ip_source == :x_forwarded_for
    assert reloaded.ingress.forwarded_proxy_depth == 0
  end
end
