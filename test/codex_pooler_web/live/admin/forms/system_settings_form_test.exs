defmodule CodexPoolerWeb.Admin.SystemSettingsFormTest do
  use CodexPooler.DataCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.SystemPageComponents.Gateway
  alias CodexPoolerWeb.Admin.SystemSettingsForm

  setup do
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn -> InstanceSettings.reset_cache_for_test() end)

    :ok
  end

  test "owns settings params, snapshots, forms, and stale-group checks" do
    settings = InstanceSettings.ensure_singleton!()
    params = SystemSettingsForm.params_from_settings(settings)

    assert %Phoenix.HTML.Form{} = SystemSettingsForm.forms(settings, params)["ingress"]
    assert get_in(params, ["gateway", "websocket_idle_timeout_ms"]) == 1_800_000
    assert get_in(params, ["gateway", "websocket_owner_idle_timeout_ms"]) == 1_800_000
    assert get_in(params, ["ingress", "forwarded_client_ip_source"]) == :x_forwarded_for
    assert get_in(params, ["ingress", "forwarded_proxy_depth"]) == 0

    assert SystemSettingsForm.forwarded_client_ip_source_options() == [
             {"Peer connection", "peer"},
             {"X-Forwarded-For", "x_forwarded_for"},
             {"X-Real-IP", "x_real_ip"}
           ]

    forms = SystemSettingsForm.forms(settings, params)
    card_statuses = SystemSettingsForm.initial_card_statuses()

    assigns = %{forms: forms, params: params, settings: settings, card_statuses: card_statuses}

    html =
      rendered_to_string(~H"""
      <Gateway.cards
        selected_tab="gateway"
        forms={@forms}
        form_params={@params}
        settings={@settings}
        card_statuses={@card_statuses}
      />
      """)

    assert html =~ ~s(id="instance-settings-websocket-idle-timeout-ms")
    assert html =~ "Websocket idle timeout (ms)"
    assert html =~ ~s(id="instance-settings-websocket-owner-idle-timeout-ms")
    assert html =~ "Websocket owner post-detach retention (ms)"
    assert html =~ "Running owners keep the value captured when they were created."
    assert html =~ ~s(id="instance-settings-forwarded-client-ip-source")
    assert html =~ ~s(id="instance-settings-forwarded-proxy-depth")

    assert html =~
             "number of proxies between the internet and the pooler, including the one connected directly; 0 uses trusted-CIDR walking."

    submitted_params = %{
      "_group" => "ingress",
      "lock_version" => params["lock_version"],
      "ingress" => %{
        "firewall_allowlist" => "198.51.100.10/32\n203.0.113.0/24",
        "decompression_algorithms" => ["gzip", "", "zstd"]
      }
    }

    normalized_params =
      submitted_params
      |> SystemSettingsForm.strip_form_meta()
      |> SystemSettingsForm.normalize_params()

    assert SystemSettingsForm.submitted_group(submitted_params) == "ingress"

    assert get_in(normalized_params, ["ingress", "firewall_allowlist"]) == [
             "198.51.100.10/32",
             "203.0.113.0/24"
           ]

    assert get_in(normalized_params, ["ingress", "decompression_algorithms"]) == ["gzip", "zstd"]

    form_params = SystemSettingsForm.merge_group_params(params, "ingress", normalized_params)
    snapshots = SystemSettingsForm.group_snapshots(params)

    assert SystemSettingsForm.dirty_card_status(form_params, snapshots, "ingress") == %{
             tone: :warning,
             message: "Unsaved changes"
           }

    refute SystemSettingsForm.group_stale?(snapshots, settings, "ingress")

    latest_settings = %{
      settings
      | ingress: %{
          settings.ingress
          | max_decompressed_body_bytes: settings.ingress.max_decompressed_body_bytes + 1
        }
    }

    assert SystemSettingsForm.group_stale?(snapshots, latest_settings, "ingress")
  end

  test "returns inline changeset errors for invalid forwarded source and depth combinations" do
    settings = InstanceSettings.ensure_singleton!()
    params = SystemSettingsForm.params_from_settings(settings)

    for {source, depth} <- [
          {"peer", "1"},
          {"x_real_ip", "1"},
          {"x_forwarded_for", "17"},
          {"none", "0"}
        ] do
      ingress_params =
        params["ingress"]
        |> Map.put("forwarded_client_ip_source", source)
        |> Map.put("forwarded_proxy_depth", depth)

      changeset =
        SystemSettingsForm.group_changeset(settings, %{"ingress" => ingress_params}, "ingress")

      refute changeset.valid?
      assert errors_on(changeset).ingress != %{}
    end

    assert InstanceSettings.get!().lock_version == settings.lock_version
    assert InstanceSettings.get!().ingress.forwarded_client_ip_source == :x_forwarded_for
    assert InstanceSettings.get!().ingress.forwarded_proxy_depth == 0
  end
end
