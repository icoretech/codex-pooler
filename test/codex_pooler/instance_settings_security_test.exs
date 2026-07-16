defmodule CodexPooler.InstanceSettingsSecurityTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.AccountsFixtures
  alias CodexPooler.Audit
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  setup do
    Repo.delete_all(AuditEvent)
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "only owner scopes can update singleton settings through the context", %{
    scope: owner_scope
  } do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update(owner_scope, %{
               "files" => %{"upload_ttl_seconds" => 600}
             })

    assert updated.files.upload_ttl_seconds == 600

    %{user: admin} =
      AccountsFixtures.operator_fixture(owner_scope, %{
        "email" => AccountsFixtures.unique_user_email()
      })

    admin_scope = Scope.for_user(admin)
    assert admin_scope.roles == ["instance_admin"]

    assert {:error, %{code: :capability_denied}} =
             InstanceSettings.update(admin_scope, %{
               "files" => %{"upload_ttl_seconds" => 900}
             })

    assert InstanceSettings.get!().files.upload_ttl_seconds == 600
    assert InstanceSettings.get!().lock_version == updated.lock_version
    refute InstanceSettings.get!().lock_version == settings.lock_version
  end

  test "system settings LiveView rechecks owner capability before saving", %{
    conn: conn,
    user: user
  } do
    settings = InstanceSettings.ensure_singleton!()
    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "gateway"}}")

    {1, nil} =
      Repo.update_all(
        from(m in Membership,
          where: m.user_id == ^user.id and m.role == "instance_owner" and m.status == "active"
        ),
        set: [status: "revoked", revoked_at: DateTime.utc_now()]
      )

    html =
      view
      |> element("#instance-settings-files-form")
      |> render_submit(%{
        "instance_settings" => %{
          "files" => %{"upload_ttl_seconds" => "900"}
        }
      })

    assert html =~ "Only instance owners can manage system settings"

    current = InstanceSettings.get!()
    assert current.files.upload_ttl_seconds == settings.files.upload_ttl_seconds
    assert current.lock_version == settings.lock_version
  end

  test "only owner scopes can send SMTP test email through the context", %{scope: owner_scope} do
    settings = InstanceSettings.ensure_singleton!()

    %{user: admin} =
      AccountsFixtures.operator_fixture(owner_scope, %{
        "email" => AccountsFixtures.unique_user_email()
      })

    admin_scope = Scope.for_user(admin)

    assert {:error, %{code: :capability_denied}} =
             InstanceSettings.send_smtp_test_email(
               settings,
               %{"smtp" => %{"enabled" => true}},
               admin_scope
             )

    assert InstanceSettings.get!().lock_version == settings.lock_version
  end

  test "mcp service updates are audited as non-secret setting changes only", %{scope: scope} do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update(scope, settings, %{"mcp" => %{"enabled" => true}})

    assert updated.mcp.enabled == true

    event =
      Repo.one!(
        from audit in AuditEvent,
          where: audit.action == "instance_settings.update",
          order_by: [desc: audit.occurred_at],
          limit: 1
      )

    assert "mcp.enabled" in get_in(event.details, ["changed_keys"])
    assert "mcp" in get_in(event.details, ["changed_categories"])
    refute inspect(event.details) =~ "mcp-cxp"
    refute inspect(event.details) =~ "key_hash"
    refute inspect(event.details) =~ "key_prefix"
  end

  test "websocket owner idle timeout is audited as a non-secret gateway setting", %{
    scope: scope
  } do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update(scope, settings, %{
               "gateway" => %{"websocket_owner_idle_timeout_ms" => 1_800_001}
             })

    assert Map.get(updated.gateway, :websocket_owner_idle_timeout_ms) == 1_800_001

    event =
      Repo.one!(
        from audit in AuditEvent,
          where: audit.action == "instance_settings.update",
          order_by: [desc: audit.occurred_at],
          limit: 1
      )

    assert get_in(event.details, ["changed_keys"]) == [
             "gateway.websocket_owner_idle_timeout_ms"
           ]

    assert get_in(event.details, ["changed_categories"]) == ["gateway"]
    refute inspect(event.details) =~ "bearer_token"
    refute inspect(event.details) =~ "password"
    refute inspect(event.details) =~ "ciphertext"
  end

  test "system save, remount, and audit details keep metrics and smtp secrets redacted", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    metrics_token = "security-metrics-token-#{System.unique_integer([:positive])}"
    smtp_password = "security-smtp-password-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(conn, ~p"/admin/system?#{%{"tab" => "metrics"}}")

    metrics_html =
      view
      |> element("#instance-settings-metrics-form")
      |> render_submit(%{
        "instance_settings" => %{
          "metrics" => %{"bearer_token" => metrics_token}
        }
      })

    {:ok, smtp_view, _html} = live(conn, ~p"/admin/system")

    smtp_html =
      smtp_view
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

    updated = InstanceSettings.get!()
    assert updated.metrics.bearer_token_status == :configured
    assert updated.smtp.password_status == :configured
    assert InstanceSettings.metrics_token_matches?(updated, metrics_token)
    assert {:ok, ^smtp_password} = InstanceSettings.decrypt_smtp_password(updated)

    events =
      Repo.all(
        from audit in AuditEvent,
          where: audit.action == "instance_settings.update" and audit.actor_user_id == ^user.id,
          order_by: [asc: audit.occurred_at, asc: audit.id]
      )

    metrics_event =
      Enum.find(events, fn event ->
        "metrics.bearer_token_configured" in get_in(event.details, ["changed_keys"])
      end)

    smtp_event =
      Enum.find(events, fn event ->
        "smtp.password_configured" in get_in(event.details, ["changed_keys"])
      end)

    assert metrics_event
    assert smtp_event

    assert get_in(metrics_event.details, ["credential_changes", "metrics_auth_state"]) ==
             "configured"

    assert get_in(metrics_event.details, ["credential_changes", "smtp_auth_state"]) ==
             "unchanged_unset"

    assert get_in(smtp_event.details, ["credential_changes", "metrics_auth_state"]) ==
             "unchanged_configured"

    assert get_in(smtp_event.details, ["credential_changes", "smtp_auth_state"]) == "configured"

    assert get_in(smtp_event.details, ["credential_changes", "metrics_fingerprint"]) ==
             updated.metrics.bearer_token_fingerprint

    for event <- events do
      refute inspect(event.details) =~ metrics_token
      refute inspect(event.details) =~ smtp_password
      refute Jason.encode!(event.details) =~ metrics_token
      refute Jason.encode!(event.details) =~ smtp_password
    end

    listed_events =
      scope
      |> Audit.list_events_for_scope(filters: [action: "instance_settings.update"])
      |> Map.fetch!(:items)
      |> Enum.filter(&(&1.actor_user_id == user.id))

    for listed_event <- listed_events do
      refute inspect(listed_event.details) =~ metrics_token
      refute inspect(listed_event.details) =~ smtp_password
      refute Jason.encode!(listed_event.details) =~ metrics_token
      refute Jason.encode!(listed_event.details) =~ smtp_password
    end

    {:ok, remounted_view, remounted_html} = live(conn, ~p"/admin/system?#{%{"tab" => "metrics"}}")

    refute remounted_html =~ metrics_token
    refute remounted_html =~ smtp_password
    assert has_element?(remounted_view, "#instance-settings-metrics-token-status", "configured")
    assert has_element?(remounted_view, "#instance-settings-metrics-token[value='']")
    assert remounted_html =~ updated.metrics.bearer_token_fingerprint

    {:ok, remounted_smtp_view, remounted_smtp_html} = live(conn, ~p"/admin/system")

    refute remounted_smtp_html =~ metrics_token
    refute remounted_smtp_html =~ smtp_password

    assert has_element?(
             remounted_smtp_view,
             "#instance-settings-smtp-password-status",
             "configured"
           )

    assert has_element?(remounted_smtp_view, "#instance-settings-smtp-password[value='']")
  end
end
