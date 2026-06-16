defmodule CodexPoolerWeb.Admin.SystemSettingsFormTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo
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
end
