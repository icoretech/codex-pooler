defmodule CodexPoolerWeb.Admin.SystemSettingsFormTest do
  use CodexPooler.DataCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.Admin.SystemPageComponents.{Firewall, Gateway}
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

    gateway_html =
      rendered_to_string(~H"""
      <Gateway.cards
        selected_tab="gateway"
        forms={@forms}
        form_params={@params}
        settings={@settings}
        card_statuses={@card_statuses}
      />
      """)

    firewall_html =
      rendered_to_string(~H"""
      <Firewall.cards
        selected_tab="firewall"
        forms={@forms}
        form_params={@params}
        settings={@settings}
        card_statuses={@card_statuses}
      />
      """)

    assert gateway_html =~ ~s(id="instance-settings-websocket-idle-timeout-ms")
    assert gateway_html =~ "Websocket idle timeout (ms)"
    assert gateway_html =~ ~s(id="instance-settings-websocket-owner-idle-timeout-ms")
    assert gateway_html =~ "Websocket owner post-detach retention (ms)"
    assert gateway_html =~ "Running owners keep the value captured when they were created."
    assert firewall_html =~ ~s(id="instance-settings-forwarded-client-ip-source")
    assert firewall_html =~ ~s(id="instance-settings-forwarded-proxy-depth")

    assert firewall_html =~
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

  test "treats gateway file and transcription values as one form boundary" do
    settings = InstanceSettings.ensure_singleton!()
    params = SystemSettingsForm.params_from_settings(settings)
    snapshots = SystemSettingsForm.group_snapshots(params)

    submitted = %{
      "lock_version" => params["lock_version"],
      "gateway" => Map.put(params["gateway"], "upstream_pool_timeout_ms", "16000"),
      "files" => Map.put(params["files"], "upload_ttl_seconds", "321"),
      "transcription" => Map.put(params["transcription"], "max_upload_bytes", "30000000")
    }

    merged = SystemSettingsForm.merge_group_params(params, "gateway", submitted)

    assert get_in(merged, ["gateway", "upstream_pool_timeout_ms"]) == "16000"
    assert get_in(merged, ["files", "upload_ttl_seconds"]) == "321"
    assert get_in(merged, ["transcription", "max_upload_bytes"]) == "30000000"

    assert SystemSettingsForm.dirty_card_status(merged, snapshots, "gateway") == %{
             tone: :warning,
             message: "Unsaved changes"
           }

    assert SystemSettingsForm.group_changeset(settings, merged, "gateway").valid?

    persisted_params = SystemSettingsForm.group_only_params(settings, merged, "gateway")
    assert get_in(persisted_params, ["gateway", "upstream_pool_timeout_ms"]) == "16000"
    assert get_in(persisted_params, ["files", "upload_ttl_seconds"]) == "321"
    assert get_in(persisted_params, ["transcription", "max_upload_bytes"]) == "30000000"

    latest_settings = %{
      settings
      | files: %{settings.files | upload_ttl_seconds: settings.files.upload_ttl_seconds + 1}
    }

    assert SystemSettingsForm.group_stale?(snapshots, latest_settings, "gateway")
  end

  test "normalizes structured bulkhead inputs without accepting malformed numbers" do
    params = %{
      "gateway" => %{
        "bulkheads" => %{
          RouteClass.proxy_http() => %{
            "_unused_max_concurrency" => "",
            "_unused_queue_limit" => "",
            "_unused_queue_timeout_ms" => "",
            "max_concurrency" => " 64 ",
            "queue_limit" => "256",
            "queue_timeout_ms" => "not-a-number",
            "unexpected" => "still-invalid"
          }
        }
      }
    }

    normalized = SystemSettingsForm.normalize_params(params)

    assert get_in(normalized, [
             "gateway",
             "bulkheads",
             RouteClass.proxy_http(),
             "max_concurrency"
           ]) == 64

    assert get_in(normalized, [
             "gateway",
             "bulkheads",
             RouteClass.proxy_http(),
             "queue_limit"
           ]) == 256

    assert get_in(normalized, [
             "gateway",
             "bulkheads",
             RouteClass.proxy_http(),
             "queue_timeout_ms"
           ]) == "not-a-number"

    normalized_config =
      get_in(normalized, ["gateway", "bulkheads", RouteClass.proxy_http()])

    refute Map.has_key?(normalized_config, "_unused_max_concurrency")
    refute Map.has_key?(normalized_config, "_unused_queue_limit")
    refute Map.has_key?(normalized_config, "_unused_queue_timeout_ms")
    assert normalized_config["unexpected"] == "still-invalid"
  end

  test "bulkhead presets change concurrency and queue only and preserve the reserved lane" do
    settings = InstanceSettings.ensure_singleton!()
    params = SystemSettingsForm.params_from_settings(settings)

    customized =
      params
      |> put_in(
        ["gateway", "bulkheads", RouteClass.proxy_http(), "queue_timeout_ms"],
        12_345
      )
      |> put_in(
        ["gateway", "bulkheads", RouteClass.proxy_control(), "max_concurrency"],
        9
      )
      |> put_in(["gateway", "bulkheads", RouteClass.proxy_control(), "queue_limit"], 18)

    assert {:ok, medium} = SystemSettingsForm.apply_bulkhead_preset(customized, "medium")

    assert get_in(medium, [
             "gateway",
             "bulkheads",
             RouteClass.proxy_http(),
             "max_concurrency"
           ]) == 64

    assert get_in(medium, [
             "gateway",
             "bulkheads",
             RouteClass.proxy_http(),
             "queue_limit"
           ]) == 256

    assert get_in(medium, [
             "gateway",
             "bulkheads",
             RouteClass.proxy_http(),
             "queue_timeout_ms"
           ]) == 12_345

    assert get_in(medium, [
             "gateway",
             "bulkheads",
             RouteClass.proxy_control(),
             "max_concurrency"
           ]) == 9

    assert get_in(medium, [
             "gateway",
             "bulkheads",
             RouteClass.proxy_control(),
             "queue_limit"
           ]) == 18

    assert SystemSettingsForm.bulkhead_preset(get_in(medium, ["gateway", "bulkheads"])) ==
             :medium

    custom =
      put_in(
        medium,
        ["gateway", "bulkheads", RouteClass.proxy_stream(), "queue_limit"],
        123
      )

    assert SystemSettingsForm.bulkhead_preset(get_in(custom, ["gateway", "bulkheads"])) ==
             :custom

    assert :error = SystemSettingsForm.apply_bulkhead_preset(customized, "unsupported")
  end

  test "restores only allowlisted runtime limit groups to canonical defaults" do
    settings = InstanceSettings.ensure_singleton!()

    customized =
      settings
      |> SystemSettingsForm.params_from_settings()
      |> put_in(["gateway", "upstream_pool_timeout_ms"], 99_999)
      |> put_in(["gateway", "gateway_debug"], true)
      |> put_in(["files", "upload_ttl_seconds"], 123)
      |> put_in(["transcription", "max_upload_bytes"], 456)

    assert {:ok, restored} =
             SystemSettingsForm.restore_gateway_group_defaults(customized, "upstream")

    assert get_in(restored, ["gateway", "upstream_connect_timeout_ms"]) == 15_000
    assert get_in(restored, ["gateway", "upstream_pool_timeout_ms"]) == 15_000
    assert get_in(restored, ["gateway", "upstream_receive_timeout_ms"]) == 300_000
    assert get_in(restored, ["gateway", "gateway_debug"]) == true

    assert {:ok, restored_files} =
             SystemSettingsForm.restore_gateway_group_defaults(customized, "files")

    assert get_in(restored_files, ["files", "max_size_bytes"]) == 26_214_400
    assert get_in(restored_files, ["files", "upload_ttl_seconds"]) == 86_400

    assert get_in(restored_files, [
             "files",
             "abandoned_upload_cleanup_interval_seconds"
           ]) == 900

    assert get_in(restored_files, ["transcription", "max_upload_bytes"]) == 456

    assert {:ok, restored_transcription} =
             SystemSettingsForm.restore_gateway_group_defaults(customized, "transcription")

    assert get_in(restored_transcription, ["transcription", "max_upload_bytes"]) ==
             26_214_400

    assert get_in(restored_transcription, ["files", "upload_ttl_seconds"]) == 123

    assert :error =
             SystemSettingsForm.restore_gateway_group_defaults(customized, "gateway_debug")

    assert :error = SystemSettingsForm.restore_gateway_group_defaults(customized, "unknown")
  end
end
