defmodule CodexPoolerWeb.Admin.SystemLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  import Ecto.Query
  import CodexPooler.AccountsFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.FakeUpstream
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings}
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  @mcp_version "2025-11-25"

  setup do
    previous_dev_features_enabled = Application.get_env(:codex_pooler, :dev_features_enabled)

    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      restore_env(:dev_features_enabled, previous_dev_features_enabled)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "denies instance admins before loading global settings or MCP counts", %{scope: scope} do
    assert {:ok, _settings} =
             InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
               "files" => %{"upload_ttl_seconds" => 777}
             })

    owner_settings = InstanceSettings.get!()

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "system-denied-admin@example.com",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, html} = live(admin_conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    assert has_element?(
             view,
             "#admin-system-owner-denied",
             "System settings require owner access"
           )

    refute has_element?(view, "#system-workspace")
    refute has_element?(view, "#system-settings-panel")
    refute has_element?(view, "#instance-settings-gateway-form")
    refute has_element?(view, "#admin-nav-system")
    refute has_element?(view, "#admin-nav-jobs")
    refute html =~ "777"
    refute html =~ "MCP keys exist in this system"

    state = :sys.get_state(view.pid)
    refute state.socket.assigns.owner_authorized?
    refute Map.has_key?(state.socket.assigns, :settings)
    refute Map.has_key?(state.socket.assigns, :mcp_key_count)

    assert InstanceSettings.get!().lock_version == owner_settings.lock_version
  end

  test "forged instance-admin system events deny without global side effects", %{scope: scope} do
    Application.put_env(:codex_pooler, :dev_features_enabled, true)

    assert {:ok, settings} =
             InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
               "files" => %{"upload_ttl_seconds" => 321},
               "mcp" => %{"enabled" => false}
             })

    pool_count = Repo.aggregate(Pool, :count)
    pricing_snapshot_count = Repo.aggregate(PricingSnapshot, :count)

    %{user: admin, temporary_password: temporary_password} =
      operator_fixture(scope, %{
        "email" => "system-forged-admin@example.com",
        "password_change_required" => "false"
      })

    assert {:ok, %{token: token}} =
             Accounts.login_user(%{"email" => admin.email, "password" => temporary_password})

    admin_conn = log_in_user(build_conn(), admin, token)
    {:ok, view, _html} = live(admin_conn, ~p"/admin/system?#{%{"tab" => "development"}}")

    admin_audit_count =
      Repo.aggregate(from(event in AuditEvent, where: event.actor_user_id == ^admin.id), :count)

    for {event, params} <- [
          {"validate_instance_settings",
           %{"instance_settings" => %{"files" => %{"upload_ttl_seconds" => "999"}}}},
          {"save_instance_settings",
           %{"instance_settings" => %{"files" => %{"upload_ttl_seconds" => "999"}}}},
          {"autosave_instance_settings",
           %{"instance_settings" => %{"mcp" => %{"enabled" => "true"}}}},
          {"test_smtp", %{}},
          {"import_sample_data", %{}},
          {"import_pricing_catalog", %{}}
        ] do
      html = render_click(view, event, params)
      assert html =~ "Only instance owners can manage system settings"
      assert has_element?(view, "#admin-system-owner-denied")
    end

    current = InstanceSettings.get!()
    assert current.lock_version == settings.lock_version
    assert current.files.upload_ttl_seconds == 321
    assert current.mcp.enabled == false
    assert Repo.aggregate(Pool, :count) == pool_count
    assert Repo.aggregate(PricingSnapshot, :count) == pricing_snapshot_count

    assert Repo.aggregate(
             from(event in AuditEvent, where: event.actor_user_id == ^admin.id),
             :count
           ) ==
             admin_audit_count
  end

  test "renders system setting tabs and scopes cards to the selected tab", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/system")

    assert has_element?(view, "#admin-system-live")
    assert has_element?(view, "#admin-nav-system[aria-current='page']")
    assert has_element?(view, "#admin-nav-system", "System Settings")
    assert has_element?(view, "#system-tabs[role='tablist']")
    assert has_element?(view, "#system-tab-smtp[aria-selected='true']", "SMTP")
    assert has_element?(view, "#system-tab-mcp", "MCP")
    assert has_element?(view, "#system-tab-metrics", "Metrics")
    assert has_element?(view, "#system-tab-gateway", "Gateway")
    refute has_element?(view, "#system-tab-development")
    assert has_element?(view, "#system-settings-panel")
    assert has_element?(view, "#system-settings-panel[data-selected-tab='smtp']")
    refute has_element?(view, "#instance-settings-form")

    assert has_element?(view, "#instance-settings-smtp-form")
    assert has_element?(view, "#instance-settings-smtp-submit")
    assert has_element?(view, "#instance-settings-smtp-errors")
    assert has_element?(view, "#instance-settings-smtp-status")

    refute has_element?(view, "#instance-settings-gateway-form")
    refute has_element?(view, "#instance-settings-mcp-form")
    refute has_element?(view, "#instance-settings-metrics-form")
    refute has_element?(view, "#instance-settings-development-form")
    assert has_element?(view, "#instance-settings-smtp-password[type='password']")
    assert has_element?(view, "#instance-settings-smtp-password-status", "Stored password")
    assert has_element?(view, "#instance-settings-smtp-password-clear[type='checkbox']")
    assert has_element?(view, "#instance-settings-smtp-enabled.toggle[type='checkbox']")
    assert has_element?(view, "#instance-settings-smtp-ssl.toggle[type='checkbox']")
    assert html =~ "SMTP username"
    assert has_element?(view, "#instance-settings-smtp-test", "Send test email to me")
    assert has_element?(view, "#instance-settings-smtp-test-status")

    {:ok, gateway_view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")
    assert has_element?(gateway_view, "#system-tab-gateway[aria-selected='true']", "Gateway")
    assert has_element?(gateway_view, "#system-settings-panel[data-selected-tab='gateway']")

    for group <- ~w(gateway ingress files transcription operator catalog) do
      assert has_element?(gateway_view, "#instance-settings-#{group}-form")
      assert has_element?(gateway_view, "#instance-settings-#{group}-submit")
      assert has_element?(gateway_view, "#instance-settings-#{group}-errors")
      assert has_element?(gateway_view, "#instance-settings-#{group}-status")
    end

    refute has_element?(gateway_view, "#instance-settings-smtp-form")
    refute has_element?(gateway_view, "#instance-settings-mcp-form")
    refute has_element?(gateway_view, "#instance-settings-metrics-form")

    {:ok, mcp_view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "mcp"}}")
    assert has_element?(mcp_view, "#system-tab-mcp[aria-selected='true']", "MCP")
    assert has_element?(mcp_view, "#instance-settings-mcp-form")
    refute has_element?(mcp_view, "#instance-settings-gateway-form")

    {:ok, metrics_view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "metrics"}}")
    assert has_element?(metrics_view, "#system-tab-metrics[aria-selected='true']", "Metrics")
    assert has_element?(metrics_view, "#instance-settings-metrics-form")
    assert has_element?(metrics_view, "#instance-settings-metrics-token[type='password']")

    assert has_element?(
             metrics_view,
             "#instance-settings-metrics-token-status",
             "Stored token"
           )

    assert has_element?(metrics_view, "#instance-settings-metrics-token-clear[type='checkbox']")
    refute has_element?(metrics_view, "#instance-settings-gateway-form")
  end

  test "hides development helpers when dev features are disabled even if the setting is true", %{
    conn: conn
  } do
    Application.put_env(:codex_pooler, :dev_features_enabled, false)

    assert {:ok, _settings} =
             InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
               "development" => %{
                 "impeccable_live_enabled" => true,
                 "account_reconciliation_paused" => true
               }
             })

    {:ok, view, html} = live(conn, ~p"/admin/system?#{%{"tab" => "development"}}")

    assert has_element?(view, "#system-tab-smtp[aria-selected='true']", "SMTP")
    refute has_element?(view, "#system-tab-development")
    refute has_element?(view, "#instance-settings-development-form")
    refute has_element?(view, "#instance-settings-impeccable-live-enabled")
    refute has_element?(view, "#instance-settings-account-reconciliation-paused")
    refute has_element?(view, "#instance-settings-import-sample-data")
    refute has_element?(view, "#instance-settings-import-pricing-catalog")
    refute html =~ "http://localhost:8400/live.js"
  end

  test "renders and saves the development helper toggle only behind the dev feature gate", %{
    conn: conn,
    user: user
  } do
    Application.put_env(:codex_pooler, :dev_features_enabled, true)

    {:ok, view, html} = live(conn, ~p"/admin/system?#{%{"tab" => "development"}}")

    assert has_element?(view, "#system-tab-development[aria-selected='true']", "Development")
    assert has_element?(view, "#instance-settings-development-form")
    refute has_element?(view, "#instance-settings-development-submit")
    assert has_element?(view, "#instance-settings-development-errors")
    assert has_element?(view, "#instance-settings-development-status")

    assert has_element?(
             view,
             "#instance-settings-development-status",
             "Changes save automatically."
           )

    assert has_element?(
             view,
             "#instance-settings-development",
             "Development-only local safeguards"
           )

    assert has_element?(
             view,
             "#instance-settings-development",
             "Controls local-only helpers and pauses fake-account jobs that would otherwise call upstream accounts."
           )

    assert has_element?(
             view,
             "#instance-settings-development",
             "Pause account reconciliation jobs"
           )

    assert has_element?(
             view,
             "#instance-settings-development",
             "Enable Impeccable live helper"
           )

    assert has_element?(
             view,
             "#instance-settings-development",
             "Requires a local Impeccable server at http://localhost:8400."
           )

    assert has_element?(
             view,
             "#instance-settings-account-reconciliation-paused.toggle[type='checkbox']"
           )

    assert has_element?(view, "#instance-settings-import-sample-data", "Import Sample Data")
    assert has_element?(view, "#instance-settings-import-pricing-catalog", "Import Pricing")

    assert has_element?(
             view,
             "#instance-settings-development-actions",
             "Development data imports"
           )

    assert has_element?(
             view,
             "#instance-settings-development-pricing-url[href='#{InstanceSettings.get!().catalog.openai_pricing_url}']"
           )

    assert has_element?(
             view,
             "#instance-settings-development-catalog-link[href='/admin/system?tab=gateway']",
             "Gateway settings"
           )

    assert has_element?(
             view,
             "#instance-settings-development-action-status",
             "Ready to import"
           )

    assert has_element?(
             view,
             "#instance-settings-development-action-status",
             "Run a development import when you need fresh fake data or pricing snapshots."
           )

    assert has_element?(
             view,
             "#instance-settings-impeccable-live-enabled.toggle[type='checkbox']"
           )

    refute has_element?(view, "#instance-settings-impeccable-live-enabled[checked]")
    refute has_element?(view, "#instance-settings-account-reconciliation-paused[checked]")
    refute html =~ "http://localhost:8400/live.js"

    html =
      view
      |> element("#instance-settings-development-form")
      |> render_change(%{
        "instance_settings" => %{
          "development" => %{
            "impeccable_live_enabled" => "true",
            "account_reconciliation_paused" => "true"
          }
        }
      })

    assert html =~ "Saved"
    assert InstanceSettings.get!().development.impeccable_live_enabled == true
    assert InstanceSettings.get!().development.account_reconciliation_paused == true
    assert has_element?(view, "#instance-settings-development-status", "Saved")
    assert has_element?(view, "#instance-settings-impeccable-live-enabled[checked]")
    assert has_element?(view, "#instance-settings-account-reconciliation-paused[checked]")

    event = Repo.get_by!(AuditEvent, action: "instance_settings.update", actor_user_id: user.id)

    assert get_in(event.details, ["changed_keys"]) == [
             "development.account_reconciliation_paused",
             "development.impeccable_live_enabled"
           ]
  end

  test "imports sample data from the development action", %{conn: conn} do
    Application.put_env(:codex_pooler, :dev_features_enabled, true)

    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "development"}}")

    html =
      view
      |> element("#instance-settings-import-sample-data")
      |> render_click()

    assert html =~ "Sample data imported"
    assert has_element?(view, "#instance-settings-development-action-status", "2 pools")

    assert Repo.aggregate(
             from(pool in Pool, where: pool.slug in ["dev-primary", "dev-disabled"]),
             :count
           ) == 2
  end

  test "imports pricing catalog from the development action using the saved catalog URL", %{
    conn: conn
  } do
    Application.put_env(:codex_pooler, :dev_features_enabled, true)

    pricing_payload = %{
      "generated_at" => "2026-05-23T12:00:00Z",
      "models" => %{
        "gpt-system-live-pricing" => %{
          "model" => "gpt-system-live-pricing",
          "pricing_type" => "per_1m_tokens",
          "prices" => %{
            "standard" => %{
              "default" => %{"input" => 1.25, "output" => 10.0}
            }
          }
        }
      }
    }

    upstream = start_upstream(FakeUpstream.json_response(pricing_payload))
    source_url = FakeUpstream.url(upstream)

    assert {:ok, _settings} =
             InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
               "catalog" => %{"openai_pricing_url" => source_url}
             })

    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "development"}}")

    assert has_element?(view, "#instance-settings-development-pricing-url[href='#{source_url}']")

    html =
      view
      |> element("#instance-settings-import-pricing-catalog")
      |> render_click()

    assert html =~ "Pricing catalog imported"
    assert has_element?(view, "#instance-settings-development-action-status", "Pricing imported")

    assert Repo.exists?(
             from snapshot in PricingSnapshot,
               where:
                 snapshot.model_identifier == "gpt-system-live-pricing" and
                   snapshot.price_version == "2026-05-23T12:00:00Z:importer-format-1" and
                   snapshot.source_url == ^source_url
           )

    assert [%{method: "GET", path: "/"}] = FakeUpstream.requests(upstream)
  end

  test "renders the global MCP service switch with metadata-only operator copy", %{
    conn: conn,
    user: user
  } do
    operator = operator_fixture(user)
    assert {:ok, _token} = MCP.create_operator_token(user, %{label: "Owner MCP"})
    assert {:ok, _token} = MCP.create_operator_token(operator.user, %{label: "Operator MCP"})

    {:ok, view, html} = live(conn, ~p"/admin/system?#{%{"tab" => "mcp"}}")

    assert has_element?(view, "#system-tab-mcp[aria-selected='true']", "MCP")
    assert has_element?(view, "#instance-settings-mcp-form")
    refute has_element?(view, "#instance-settings-mcp-submit")
    assert has_element?(view, "#instance-settings-mcp-errors")
    assert has_element?(view, "#instance-settings-mcp-status")
    assert has_element?(view, "#instance-settings-mcp-status", "Changes save automatically.")
    assert has_element?(view, "#instance-settings-mcp", "MCP service")
    assert has_element?(view, "#instance-settings-mcp-enabled.toggle[type='checkbox']")

    assert has_element?(
             view,
             "#instance-settings-mcp-enabled-control.w-full[data-state='disabled']"
           )

    refute has_element?(view, "#instance-settings-mcp-enabled[checked]")

    assert has_element?(
             view,
             "#instance-settings-mcp",
             "Controls whether operator MCP bearer tokens can use the metadata-only /mcp endpoint."
           )

    assert has_element?(
             view,
             "#instance-settings-mcp",
             "Manage your own MCP keys in"
           )

    assert has_element?(
             view,
             "#instance-settings-mcp-account-settings-link[href='/admin/settings?tab=account']",
             "account settings"
           )

    assert has_element?(
             view,
             "#instance-settings-mcp",
             "2 MCP keys exist in this system."
           )

    assert has_element?(
             view,
             "#instance-settings-mcp",
             "When off, existing MCP tokens are rejected."
           )

    refute html =~ "mcp-cxp"
    refute html =~ "key_hash"
    refute html =~ "key_prefix"
  end

  test "autosaves the global MCP switch on change and clears the saved confirmation", %{
    conn: conn,
    user: user
  } do
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(user, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(user, %{label: "System UI MCP autosave"})

    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "mcp"}}")

    html =
      view
      |> element("#instance-settings-mcp-form")
      |> render_change(%{
        "instance_settings" => %{
          "mcp" => %{"enabled" => "true"}
        }
      })

    assert html =~ "Saved"
    assert InstanceSettings.get!().mcp.enabled == true
    assert has_element?(view, "#instance-settings-mcp-enabled[checked]")
    assert has_element?(view, "#instance-settings-mcp-enabled-control[data-state='enabled']")
    assert_mcp_initialize(conn, raw_token, 200, @mcp_version)

    event = Repo.get_by!(AuditEvent, action: "instance_settings.update", actor_user_id: user.id)
    assert get_in(event.details, ["changed_keys"]) == ["mcp.enabled"]
    assert get_in(event.details, ["changed_categories"]) == ["mcp"]

    send(view.pid, {:clear_card_status, "mcp"})
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#instance-settings-mcp-status", "Saved")
    assert has_element?(view, "#instance-settings-mcp-status", "Changes save automatically.")
  end

  test "renders and saves the pricing catalog source", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    assert has_element?(view, "#system-tab-gateway[aria-selected='true']", "Gateway")
    assert has_element?(view, "#instance-settings-catalog-form")
    assert has_element?(view, "#instance-settings-catalog-submit", "Save catalog source")
    assert has_element?(view, "#instance-settings-catalog", "Pricing catalog source")

    assert has_element?(
             view,
             "#instance-settings-openai-pricing-url[value='https://icoretech.github.io/openai-json-pricing/pricing.json']"
           )

    assert html =~ "the scheduler resolves this URL when each pricing import job runs"
    assert html =~ "the vendored JSON file"

    saved_html =
      view
      |> element("#instance-settings-catalog-form")
      |> render_submit(%{
        "instance_settings" => %{
          "catalog" => %{"openai_pricing_url" => "https://pricing.example.com/pricing.json"}
        }
      })

    assert saved_html =~ "Pricing catalog source saved"

    assert InstanceSettings.get!().catalog.openai_pricing_url ==
             "https://pricing.example.com/pricing.json"

    assert has_element?(view, "#instance-settings-catalog-status", "Saved")

    event = Repo.get_by!(AuditEvent, action: "instance_settings.update", actor_user_id: user.id)
    assert get_in(event.details, ["changed_keys"]) == ["catalog.openai_pricing_url"]
    assert get_in(event.details, ["changed_categories"]) == ["catalog"]
  end

  test "saving the pricing catalog source ignores missing legacy development helper flags", %{
    conn: conn,
    user: user
  } do
    legacy = InstanceSettings.ensure_singleton!()

    Repo.query!("""
    UPDATE instance_settings
    SET catalog = '{"openai_pricing_url": "https://pricing.example.com/catalog.json"}'::jsonb,
        development = '{"impeccable_live_enabled": false}'::jsonb
    """)

    InstanceSettings.reset_cache_for_test()

    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    html =
      view
      |> element("#instance-settings-catalog-form")
      |> render_submit(%{
        "instance_settings" => %{
          "lock_version" => Integer.to_string(legacy.lock_version),
          "catalog" => %{
            "openai_pricing_url" => "https://icoretech.github.io/openai-json-pricing/pricing.json"
          }
        }
      })

    assert html =~ "Pricing catalog source saved"
    assert has_element?(view, "#instance-settings-catalog-status", "Saved")

    refute has_element?(
             view,
             "#instance-settings-catalog-errors",
             "Development Account reconciliation paused can't be blank"
           )

    refute has_element?(view, "#instance-settings-catalog-errors", "Review this card")

    settings = InstanceSettings.get!()

    assert settings.catalog.openai_pricing_url ==
             "https://icoretech.github.io/openai-json-pricing/pricing.json"

    assert settings.development.impeccable_live_enabled == false
    assert settings.development.account_reconciliation_paused == false

    event = Repo.get_by!(AuditEvent, action: "instance_settings.update", actor_user_id: user.id)
    assert get_in(event.details, ["changed_keys"]) == ["catalog.openai_pricing_url"]
  end

  test "saves the global MCP switch, audits only the setting, and gates valid tokens live", %{
    conn: conn,
    user: user
  } do
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)

    assert {:ok, _operator_settings} = MCP.set_operator_mcp_enabled(user, true)

    assert {:ok, %{raw_token: raw_token}} =
             MCP.create_operator_token(user, %{label: "System UI MCP"})

    raw_token_prefix = raw_token |> String.split("-") |> Enum.take(3) |> Enum.join("-")

    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "mcp"}}")

    enabled_html =
      view
      |> element("#instance-settings-mcp-form")
      |> render_change(%{
        "instance_settings" => %{
          "mcp" => %{"enabled" => "true"}
        }
      })

    assert enabled_html =~ "Saved"
    assert InstanceSettings.get!().mcp.enabled == true
    assert has_element?(view, "#instance-settings-mcp-status", "Saved")
    assert has_element?(view, "#instance-settings-mcp-enabled[checked]")
    assert_mcp_initialize(conn, raw_token, 200, @mcp_version)

    enabled_event =
      Repo.get_by!(AuditEvent, action: "instance_settings.update", actor_user_id: user.id)

    assert get_in(enabled_event.details, ["changed_keys"]) == ["mcp.enabled"]
    assert get_in(enabled_event.details, ["changed_categories"]) == ["mcp"]

    disabled_html =
      view
      |> element("#instance-settings-mcp-form")
      |> render_change(%{
        "instance_settings" => %{
          "mcp" => %{"enabled" => "false"}
        }
      })

    assert disabled_html =~ "Saved"
    assert InstanceSettings.get!().mcp.enabled == false
    refute has_element?(view, "#instance-settings-mcp-enabled[checked]")
    assert_mcp_initialize(conn, raw_token, 403, "MCP service is disabled")

    reenabled_html =
      view
      |> element("#instance-settings-mcp-form")
      |> render_change(%{
        "instance_settings" => %{
          "mcp" => %{"enabled" => "true"}
        }
      })

    assert reenabled_html =~ "Saved"
    assert InstanceSettings.get!().mcp.enabled == true
    assert has_element?(view, "#instance-settings-mcp-enabled[checked]")
    assert_mcp_initialize(conn, raw_token, 200, @mcp_version)

    settings_events =
      Enum.filter(Repo.all(AuditEvent), &(&1.action == "instance_settings.update"))

    for rendered <- [enabled_html, disabled_html, reenabled_html], event <- settings_events do
      refute rendered =~ raw_token
      refute rendered =~ raw_token_prefix
      refute rendered =~ "key_hash"
      refute rendered =~ "key_prefix"
      refute inspect(event.details) =~ raw_token
      refute inspect(event.details) =~ raw_token_prefix
      refute inspect(event.details) =~ "key_hash"
      refute inspect(event.details) =~ "key_prefix"
    end
  end

  test "renders operational hints and realistic IP placeholders", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    for selector <- [
          "#admin-system-live",
          "#system-tabs",
          "#system-settings-panel",
          "#instance-settings-ingress-form",
          "#instance-settings-ingress-submit"
        ] do
      assert has_element?(view, selector)
    end

    {:ok, smtp_view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "smtp"}}")
    assert has_element?(smtp_view, "#instance-settings-smtp-test")
    assert has_element?(smtp_view, "#instance-settings-smtp-test-status")

    for placeholder <- [
          "198.51.100.10/32",
          "203.0.113.0/24",
          "2001:db8::/32",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "2001:db8:10::/48"
        ] do
      assert html =~ placeholder
    end

    refute html =~ "198.51.100.10/32\\n203.0.113.0/24"
    refute html =~ "Operator login URL"
    assert html =~ "Public operator app URL"
    assert html =~ "Operator emails append /login to this value."

    for hint <- [
          "Records sanitized request/attempt routing metadata for new gateway requests.",
          "Interval for downstream SSE heartbeat events; 0 disables heartbeats.",
          "Maximum time allowed to establish a connection to an upstream account.",
          "Maximum time a gateway request may wait for an available pooled connection.",
          "Maximum idle receive window while waiting for upstream response data.",
          "How long expired response aliases stay available for continuity lookups.",
          "How long a bridge owner lease remains valid without renewal.",
          "How often active bridge owners renew their lease while work is running.",
          "Consecutive failed attempts needed before opening an upstream circuit.",
          "How long an opened circuit stays closed to normal traffic before probing.",
          "Concurrent probe attempts allowed while testing a half-open circuit.",
          "Successful probes required before closing a previously opened circuit.",
          "Per route-class concurrency, queue length, and queue timeout policy as JSON.",
          "Model-specific context window sizes used when upstream metadata is missing or needs correction."
        ] do
      assert html =~ hint
    end
  end

  test "renders constrained compressed JSON encoding controls and help copy", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    assert has_element?(view, "#instance-settings-decompression-algorithms")

    refute has_element?(
             view,
             "textarea#instance-settings-decompression-algorithms"
           )

    assert has_element?(
             view,
             "#instance-settings-decompression-algorithms",
             "Accepted compressed JSON encodings"
           )

    assert has_element?(
             view,
             "#instance-settings-decompression-algorithms-help",
             "Uncompressed JSON is always accepted."
           )

    assert has_element?(
             view,
             "#instance-settings-decompression-algorithms-help",
             "Compressed JSON must declare one of these values in Content-Encoding."
           )

    assert has_element?(
             view,
             "#instance-settings-decompression-algorithms-help",
             "If no encodings are selected, compressed JSON requests return 415."
           )

    for encoding <- ~w(gzip deflate zstd) do
      assert has_element?(
               view,
               "#instance-settings-decompression-algorithms-#{encoding}[type='checkbox'][name='instance_settings[ingress][decompression_algorithms][]'][value='#{encoding}'][checked]"
             )

      assert html =~ "instance-settings-decompression-algorithms-#{encoding}-option"
    end

    refute html =~ "Decompression algorithms"
  end

  test "saves empty compressed JSON encoding selection through the ingress card", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    html =
      view
      |> element("#instance-settings-ingress-form")
      |> render_submit(%{
        "instance_settings" => %{
          "ingress" => %{"decompression_algorithms" => [""]}
        }
      })

    assert html =~ "Runtime ingress saved"
    assert InstanceSettings.get!().ingress.decompression_algorithms == []
    refute has_element?(view, "#instance-settings-decompression-algorithms-gzip[checked]")
    refute has_element?(view, "#instance-settings-decompression-algorithms-deflate[checked]")
    refute has_element?(view, "#instance-settings-decompression-algorithms-zstd[checked]")
  end

  test "rejects unknown compressed JSON encodings even when posted outside the UI", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    html =
      view
      |> element("#instance-settings-ingress-form")
      |> render_submit(%{
        "instance_settings" => %{
          "ingress" => %{"decompression_algorithms" => ["gzip", "br"]}
        }
      })

    assert html =~ "Runtime ingress could not be saved"
    assert has_element?(view, "#instance-settings-ingress-errors", "has an invalid entry")
    assert InstanceSettings.get!().ingress.decompression_algorithms == ["gzip", "deflate", "zstd"]
  end

  test "keeps circuit controls exposed with unchanged default values", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    assert has_element?(view, "#instance-settings-circuit-failure-threshold[value='3']")
    assert has_element?(view, "#instance-settings-circuit-open-seconds[value='60']")
    assert has_element?(view, "#instance-settings-circuit-half-open-probe-limit[value='1']")
    assert has_element?(view, "#instance-settings-circuit-success-threshold[value='1']")

    assert has_element?(
             view,
             "label[for=\"instance-settings-circuit-failure-threshold\"]",
             "Circuit failure threshold"
           )

    assert has_element?(
             view,
             "label[for=\"instance-settings-circuit-open-seconds\"]",
             "Circuit open window"
           )

    assert has_element?(
             view,
             "label[for=\"instance-settings-circuit-half-open-probe-limit\"]",
             "Half-open probe limit"
           )

    assert has_element?(
             view,
             "label[for=\"instance-settings-circuit-success-threshold\"]",
             "Circuit close successes"
           )
  end

  test "saves one settings card with current scope attribution", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    html =
      view
      |> element("#instance-settings-files-form")
      |> render_submit(%{
        "instance_settings" => %{
          "files" => %{"upload_ttl_seconds" => "321"}
        }
      })

    assert html =~ "File bridge limits saved"
    updated = InstanceSettings.get!()
    assert updated.files.upload_ttl_seconds == 321
    assert updated.operator.login_base_url == "http://localhost"
    assert updated.updated_by_user_id == user.id
    assert has_element?(view, "#instance-settings-upload-ttl-seconds[value='321']")
    assert has_element?(view, "#instance-settings-files-status", "Saved")

    event = Repo.get_by!(AuditEvent, action: "instance_settings.update", actor_user_id: user.id)
    assert get_in(event.details, ["changed_keys"]) == ["files.upload_ttl_seconds"]
  end

  test "invalid card submit renders only that card changeset errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    html =
      view
      |> element("#instance-settings-files-form")
      |> render_submit(%{
        "instance_settings" => %{
          "files" => %{"upload_ttl_seconds" => "-1"}
        }
      })

    assert html =~ "File bridge limits could not be saved"
    assert has_element?(view, "#instance-settings-files-errors")
    assert has_element?(view, "#instance-settings-files-errors", "must be greater than 0")
    refute has_element?(view, "#instance-settings-operator-errors", "has invalid format")

    refute has_element?(
             view,
             "#instance-settings-smtp-errors",
             "must be present when SMTP is enabled"
           )
  end

  test "saving ingress does not validate or overwrite dirty SMTP metrics or operator cards", %{
    conn: conn,
    user: user
  } do
    metrics_token = "ingress-isolation-metrics-#{System.unique_integer([:positive])}"
    smtp_password = "ingress-isolation-smtp-#{System.unique_integer([:positive])}"

    assert {:ok, _configured} =
             InstanceSettings.update_system_settings(
               InstanceSettings.ensure_singleton!(),
               %{
                 "smtp" => %{
                   "enabled" => true,
                   "host" => "stored.smtp.example",
                   "port" => 2525,
                   "username" => "stored-user",
                   "from" => "stored@example.com",
                   "ssl" => false,
                   "tls" => "never",
                   "retries" => 1
                 }
               }
               |> InstanceSettings.put_metrics_bearer_token(metrics_token)
               |> InstanceSettings.put_smtp_password(smtp_password)
             )

    before = InstanceSettings.get!()
    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    assert {:ok, _other_card_update} =
             InstanceSettings.update_system_settings(InstanceSettings.get!(), %{
               "files" => %{"upload_ttl_seconds" => 777}
             })

    select_system_tab(view, "smtp")

    view
    |> element("#instance-settings-smtp-form")
    |> render_change(%{
      "instance_settings" => %{
        "smtp" => %{
          "enabled" => "true",
          "host" => "",
          "port" => "2526",
          "username" => "dirty-user",
          "from" => "dirty@example.com",
          "ssl" => "false",
          "tls" => "never",
          "retries" => "2",
          "password" => ""
        }
      }
    })

    select_system_tab(view, "gateway")

    view
    |> element("#instance-settings-operator-form")
    |> render_change(%{
      "instance_settings" => %{
        "operator" => %{"login_base_url" => "https://dirty-operator.example.com"}
      }
    })

    html =
      view
      |> element("#instance-settings-ingress-form")
      |> render_submit(%{
        "instance_settings" => %{
          "ingress" => %{"max_compressed_body_bytes" => "123456"}
        }
      })

    assert html =~ "Runtime ingress saved"

    select_system_tab(view, "smtp")
    assert has_element?(view, "#instance-settings-smtp-username[value='dirty-user']")

    assert has_element?(
             view,
             "#instance-settings-smtp-status",
             "Unsaved changes, not saved by this action"
           )

    select_system_tab(view, "gateway")

    assert has_element?(
             view,
             "#instance-settings-operator-login-base-url[value='https://dirty-operator.example.com']"
           )

    assert has_element?(
             view,
             "#instance-settings-operator-status",
             "Unsaved changes, not saved by this action"
           )

    refute has_element?(
             view,
             "#instance-settings-smtp-errors",
             "must be present when SMTP is enabled"
           )

    updated = InstanceSettings.get!()
    assert updated.ingress.max_compressed_body_bytes == 123_456
    assert updated.files.upload_ttl_seconds == 777
    assert updated.smtp.host == before.smtp.host
    assert updated.smtp.username == before.smtp.username
    assert updated.smtp.password_ciphertext == before.smtp.password_ciphertext
    assert InstanceSettings.metrics_token_matches?(updated, metrics_token)
    assert {:ok, ^smtp_password} = InstanceSettings.decrypt_smtp_password(updated)

    event = Repo.get_by!(AuditEvent, action: "instance_settings.update", actor_user_id: user.id)
    assert get_in(event.details, ["changed_keys"]) == ["ingress.max_compressed_body_bytes"]
  end

  test "stale update shows reload guidance and does not overwrite newer settings", %{conn: conn} do
    stale = InstanceSettings.ensure_singleton!()
    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(InstanceSettings.get!(), %{
               "files" => %{"upload_ttl_seconds" => 444}
             })

    html =
      view
      |> element("#instance-settings-files-form")
      |> render_submit(%{
        "instance_settings" => %{
          "lock_version" => stale.lock_version,
          "files" => %{"upload_ttl_seconds" => "888"}
        }
      })

    assert html =~ "Reload and retry"

    assert has_element?(
             view,
             "#instance-settings-files-errors",
             "was updated by another operator"
           )

    assert InstanceSettings.get!().files.upload_ttl_seconds == 444
  end

  test "metrics token and smtp password are write-only across card saves, preserve, clear, and remount",
       %{
         conn: conn
       } do
    metrics_token = "ui-metrics-token-#{System.unique_integer([:positive])}"
    smtp_password = "ui-smtp-password-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "metrics"}}")

    metrics_html =
      view
      |> element("#instance-settings-metrics-form")
      |> render_submit(%{
        "instance_settings" => %{
          "metrics" => %{"bearer_token" => metrics_token}
        }
      })

    select_system_tab(view, "smtp")

    smtp_html =
      view
      |> element("#instance-settings-smtp-form")
      |> render_submit(%{
        "instance_settings" => %{
          "smtp" => %{
            "enabled" => "true",
            "host" => "smtp.example.com",
            "username" => "mailer",
            "from" => "sender@example.com",
            "password" => smtp_password
          }
        }
      })

    refute metrics_html =~ metrics_token
    refute smtp_html =~ smtp_password

    configured = InstanceSettings.get!()
    assert configured.metrics.bearer_token_status == :configured
    assert configured.smtp.password_status == :configured
    assert InstanceSettings.metrics_token_matches?(configured, metrics_token)
    assert {:ok, ^smtp_password} = InstanceSettings.decrypt_smtp_password(configured)
    refute inspect(Repo.all(AuditEvent)) =~ metrics_token
    refute inspect(Repo.all(AuditEvent)) =~ smtp_password

    {:ok, remounted_view, remounted_html} = live(conn, ~p"/admin/system?#{%{"tab" => "metrics"}}")
    refute remounted_html =~ metrics_token
    refute remounted_html =~ smtp_password
    assert has_element?(remounted_view, "#instance-settings-metrics-token-status", "configured")
    assert has_element?(remounted_view, "#instance-settings-metrics-token[value='']")

    select_system_tab(remounted_view, "smtp")
    assert has_element?(remounted_view, "#instance-settings-smtp-password-status", "configured")
    assert has_element?(remounted_view, "#instance-settings-smtp-password[value='']")

    select_system_tab(remounted_view, "gateway")

    remounted_view
    |> element("#instance-settings-files-form")
    |> render_submit(%{
      "instance_settings" => %{
        "files" => %{"upload_ttl_seconds" => "654"}
      }
    })

    preserved = InstanceSettings.get!()
    assert preserved.files.upload_ttl_seconds == 654
    assert InstanceSettings.metrics_token_matches?(preserved, metrics_token)
    assert {:ok, ^smtp_password} = InstanceSettings.decrypt_smtp_password(preserved)

    select_system_tab(remounted_view, "metrics")

    remounted_view
    |> element("#instance-settings-metrics-form")
    |> render_submit(%{
      "instance_settings" => %{
        "metrics" => %{"bearer_token_action" => "clear"}
      }
    })

    select_system_tab(remounted_view, "smtp")

    remounted_view
    |> element("#instance-settings-smtp-form")
    |> render_submit(%{
      "instance_settings" => %{
        "smtp" => %{"enabled" => "false", "username" => "", "password_action" => "clear"}
      }
    })

    cleared = InstanceSettings.get!()
    refute InstanceSettings.metrics_token_matches?(cleared, metrics_token)
    assert cleared.metrics.bearer_token_status == :intentionally_unset
    assert cleared.smtp.password_status == :intentionally_unset
  end

  test "smtp test button sends a deterministic email to the signed-in operator with unsaved values and does not persist them",
       %{
         conn: conn,
         user: user
       } do
    stored_password = "stored-password-#{System.unique_integer([:positive])}"

    assert {:ok, _configured} =
             InstanceSettings.update_system_settings(
               InstanceSettings.ensure_singleton!(),
               %{
                 "smtp" => %{
                   "enabled" => true,
                   "host" => "stored.example.test",
                   "port" => 2526,
                   "username" => "stored-user",
                   "from" => "stored@example.com",
                   "ssl" => false,
                   "tls" => "never",
                   "retries" => 1
                 }
               }
               |> InstanceSettings.put_smtp_password(stored_password)
             )

    before = InstanceSettings.get!()

    server_name =
      String.to_atom("codex_pooler_system_test_email_#{System.unique_integer([:positive])}")

    port = free_port()

    assert {:ok, _pid} =
             :gen_smtp_server.start(server_name, :smtp_server_example, [
               {:port, port},
               {:sessionoptions, [{:callbackoptions, [{:auth, true}]}]}
             ])

    on_exit(fn ->
      :ok = :gen_smtp_server.stop(server_name)
    end)

    telemetry_ref = make_ref()
    telemetry_id = "system-live-smtp-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:swoosh, :deliver, :start],
        fn _event, _measurements, metadata, pid ->
          send(pid, {telemetry_ref, metadata})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(telemetry_id)
    end)

    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "smtp"}}")

    view
    |> element("#instance-settings-smtp-form")
    |> render_change(%{
      "instance_settings" => %{
        "smtp" => %{
          "enabled" => "true",
          "host" => "localhost",
          "port" => Integer.to_string(port),
          "username" => "username",
          "from" => "candidate@example.com",
          "ssl" => "false",
          "tls" => "never",
          "retries" => "2",
          "password" => ""
        }
      }
    })

    success_html = view |> element("#instance-settings-smtp-test") |> render_click()

    assert success_html =~ "Test email sent to #{user.email}"
    refute success_html =~ stored_password

    assert_received {^telemetry_ref, metadata}
    assert metadata.email.to == [{"", user.email}]
    assert metadata.email.from == {"Codex Pooler", "candidate@example.com"}
    assert metadata.email.subject == "Codex Pooler SMTP test email"

    assert metadata.email.text_body ==
             "This test email confirms Codex Pooler can send email with the current SMTP settings."

    assert metadata.config[:relay] == "localhost"
    assert metadata.config[:port] == port
    assert metadata.config[:username] == "username"
    assert metadata.config[:adapter] == Swoosh.Adapters.SMTP

    assert :crypto.hash(:sha256, metadata.config[:password]) ==
             :crypto.hash(:sha256, stored_password)

    refute_received {^telemetry_ref, _metadata}

    current = InstanceSettings.get!()
    assert current.smtp.enabled == before.smtp.enabled
    assert current.smtp.host == before.smtp.host
    assert current.smtp.port == before.smtp.port
    assert current.smtp.username == before.smtp.username
    assert current.smtp.from == before.smtp.from
    assert current.smtp.password_ciphertext == before.smtp.password_ciphertext
    assert current.lock_version == before.lock_version
  end

  test "smtp test button renders sanitized failure status without leaking secrets", %{
    conn: conn
  } do
    port = free_port()

    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "metrics"}}")

    view
    |> element("#instance-settings-metrics-form")
    |> render_change(%{
      "instance_settings" => %{
        "metrics" => %{"bearer_token" => "metrics-bearer-token-should-not-leak"}
      }
    })

    select_system_tab(view, "smtp")

    view
    |> element("#instance-settings-smtp-form")
    |> render_change(%{
      "instance_settings" => %{
        "smtp" => %{
          "enabled" => "true",
          "host" => "localhost",
          "port" => Integer.to_string(port),
          "username" => "username",
          "from" => "probe@example.com",
          "ssl" => "false",
          "tls" => "never",
          "retries" => "2",
          "password" => "super-secret-smtp-password"
        }
      }
    })

    failure_html = view |> element("#instance-settings-smtp-test") |> render_click()
    assert failure_html =~ "SMTP connection failed"
    refute failure_html =~ "super-secret-smtp-password"
    refute failure_html =~ "metrics-bearer-token-should-not-leak"
    refute failure_html =~ "auth-json-should-not-leak"
    refute failure_html =~ "access-token-should-not-leak"
    refute failure_html =~ "refresh-token-should-not-leak"
    assert InstanceSettings.get!().smtp.enabled == false
  end

  test "smtp test button shows a clear sanitized error when the signed-in operator email is blank",
       %{
         conn: conn,
         user: user
       } do
    assert {:ok, _updated_user} =
             user
             |> Ecto.Changeset.change(email: "   ")
             |> Repo.update()

    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "smtp"}}")

    view
    |> element("#instance-settings-smtp-form")
    |> render_change(%{
      "instance_settings" => %{
        "smtp" => %{
          "enabled" => "true",
          "host" => "smtp.example.com",
          "port" => "587",
          "from" => "sender@example.com",
          "ssl" => "false",
          "tls" => "never",
          "retries" => "2"
        }
      }
    })

    html = view |> element("#instance-settings-smtp-test") |> render_click()

    assert has_element?(
             view,
             "#instance-settings-smtp-test-status",
             "Signed-in operator email is required for SMTP test email"
           )

    refute html =~ user.email
    assert_no_email_sent()
  end

  defp select_system_tab(view, tab) do
    view
    |> element("#system-tab-#{tab}")
    |> render_click()
  end

  defp assert_mcp_initialize(conn, raw_token, expected_status, expected_value) do
    response =
      conn
      |> recycle()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @mcp_version)
      |> put_req_header("authorization", "Bearer #{raw_token}")
      |> post("/mcp", Jason.encode!(initialize_request()))
      |> json_response(expected_status)

    if expected_status == 200 do
      assert response["result"]["protocolVersion"] == expected_value
    else
      assert response["error"]["message"] == expected_value
    end

    raw_token_prefix = raw_token |> String.split("-") |> Enum.take(3) |> Enum.join("-")

    refute inspect(response) =~ raw_token
    refute inspect(response) =~ raw_token_prefix
  end

  defp initialize_request do
    %{
      "jsonrpc" => "2.0",
      "id" => "init-1",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @mcp_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "example-client", "version" => "0.0.1"}
      }
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:codex_pooler, key)
  defp restore_env(key, value), do: Application.put_env(:codex_pooler, key, value)

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
