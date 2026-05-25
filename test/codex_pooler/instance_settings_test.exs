defmodule CodexPooler.InstanceSettingsTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.AccountsFixtures
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.{Cache, Settings}

  defmodule FailingRepo do
    def insert(_struct, _opts),
      do: raise(DBConnection.ConnectionError, message: "settings db unavailable")

    def get!(_schema, _id),
      do: raise(DBConnection.ConnectionError, message: "settings db unavailable")
  end

  setup do
    previous = Application.get_env(:codex_pooler, InstanceSettings, [])
    Application.put_env(:codex_pooler, InstanceSettings, Keyword.delete(previous, :repo))
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      Application.put_env(:codex_pooler, InstanceSettings, previous)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "current/0 self-heals a missing row and returns code defaults" do
    Repo.delete_all(Settings)

    settings = InstanceSettings.current()

    assert settings.source == :database
    assert settings.db_available? == true
    assert settings.secrets_available? == true
    assert settings.gateway.gateway_debug == false
    assert settings.gateway.circuit_failure_threshold == 3
    assert settings.gateway.circuit_open_seconds == 60
    assert settings.gateway.circuit_half_open_probe_limit == 1
    assert settings.gateway.circuit_success_threshold == 1
    assert settings.files.max_size_bytes == 25 * 1024 * 1024
    assert settings.transcription.max_upload_bytes == 26_214_400

    assert settings.catalog.openai_pricing_url ==
             "https://icoretech.github.io/openai-json-pricing/pricing.json"

    assert settings.development.impeccable_live_enabled == false
    assert settings.mcp.enabled == false
    assert settings.metrics.bearer_token_status == :intentionally_unset
    assert settings.smtp.password_status == :intentionally_unset
    assert Repo.aggregate(Settings, :count) == 1
  end

  test "duplicate singleton rows are rejected by the database and ensure_singleton!/0 is idempotent" do
    first = InstanceSettings.ensure_singleton!()
    second = InstanceSettings.ensure_singleton!()

    assert first.singleton == true
    assert second.singleton == true
    assert Repo.aggregate(Settings, :count) == 1

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(Settings.default())
    end

    assert_raise Ecto.ConstraintError, fn ->
      Settings.default()
      |> Map.put(:singleton, false)
      |> Repo.insert!()
    end
  end

  test "change/1 is pure and change_current/1 names the singleton-loading path" do
    Repo.delete_all(Settings)

    assert_raise FunctionClauseError, fn ->
      InstanceSettings.change(%{"gateway" => %{"gateway_debug" => true}})
    end

    assert Repo.aggregate(Settings, :count) == 0

    changeset = InstanceSettings.change_current(%{"gateway" => %{"gateway_debug" => true}})

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :gateway).changes.gateway_debug == true
    assert Repo.aggregate(Settings, :count) == 1
  end

  test "changeset rejects invalid CIDR, negative TTL, invalid TLS, invalid model overrides, and malformed bulkheads" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:error, changeset} =
             InstanceSettings.update(settings, %{
               "ingress" => %{"firewall_allowlist" => ["not-an-ip"]},
               "files" => %{"upload_ttl_seconds" => -1},
               "smtp" => %{"tls" => "sometimes"},
               "gateway" => %{
                 "model_context_window_overrides" => %{"gpt-example" => 0},
                 "bulkheads" => %{"proxy_http" => %{"max_concurrency" => 0}}
               }
             })

    assert errors_on(changeset).files != []
    assert errors_on(changeset).ingress != []
    assert errors_on(changeset).smtp != []
    assert errors_on(changeset).gateway != []
  end

  test "development helper setting is boolean-only and rejects stored script URLs" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update(settings, %{
               "development" => %{"impeccable_live_enabled" => true}
             })

    assert updated.development.impeccable_live_enabled == true

    assert {:error, changeset} =
             InstanceSettings.update(updated, %{
               "development" => %{"impeccable_live_enabled" => "http://localhost:8400/live.js"}
             })

    assert "is invalid" in errors_on(changeset).development.impeccable_live_enabled
  end

  test "operator app URL stores the public app root and rejects login paths" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update(settings, %{
               "operator" => %{"login_base_url" => "https://pooler.example.com/"}
             })

    assert updated.operator.login_base_url == "https://pooler.example.com"

    for login_url <- ["https://pooler.example.com/login", "https://pooler.example.com/login/"] do
      assert {:error, changeset} =
               InstanceSettings.update(updated, %{
                 "operator" => %{"login_base_url" => login_url}
               })

      assert "must be the public app URL without /login" in errors_on(changeset).operator.login_base_url
    end

    assert {:error, changeset} =
             InstanceSettings.update(updated, %{
               "operator" => %{"login_base_url" => "ftp://pooler.example.com"}
             })

    assert "has invalid format" in errors_on(changeset).operator.login_base_url
  end

  test "catalog pricing URL stores the hourly pricing source and rejects non-HTTP URLs" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update(settings, %{
               "catalog" => %{
                 "openai_pricing_url" => " https://pricing.example.com/catalog.json "
               }
             })

    assert updated.catalog.openai_pricing_url == "https://pricing.example.com/catalog.json"

    assert {:error, changeset} =
             InstanceSettings.update(updated, %{
               "catalog" => %{"openai_pricing_url" => "s3://pricing/catalog.json"}
             })

    assert "has invalid format" in errors_on(changeset).catalog.openai_pricing_url
  end

  test "mcp service setting defaults disabled and applies through cache broadcasts" do
    settings = InstanceSettings.current()
    :ok = Cache.subscribe()

    assert settings.mcp.enabled == false

    assert {:ok, updated} =
             InstanceSettings.update(settings, %{
               "mcp" => %{"enabled" => true}
             })

    assert_receive {Cache, {:updated, lock_version}}
    assert lock_version == updated.lock_version
    assert InstanceSettings.current().mcp.enabled == true

    assert {:ok, disabled} =
             InstanceSettings.update(InstanceSettings.get!(), %{
               "mcp" => %{"enabled" => false}
             })

    assert_receive {Cache, {:updated, disabled_lock_version}}
    assert disabled_lock_version == disabled.lock_version
    assert InstanceSettings.current().mcp.enabled == false
  end

  test "legacy singleton settings rows backfill the catalog source setting without losing updates" do
    legacy = InstanceSettings.ensure_singleton!()

    Repo.query!("UPDATE instance_settings SET catalog = '{}'::jsonb")
    InstanceSettings.reset_cache_for_test()

    assert InstanceSettings.current().catalog.openai_pricing_url ==
             "https://icoretech.github.io/openai-json-pricing/pricing.json"

    assert {:ok, updated} =
             InstanceSettings.update(Repo.reload!(legacy), %{
               "files" => %{"upload_ttl_seconds" => 600}
             })

    assert updated.files.upload_ttl_seconds == 600

    assert updated.catalog.openai_pricing_url ==
             "https://icoretech.github.io/openai-json-pricing/pricing.json"
  end

  test "legacy singleton settings rows backfill the mcp service setting without losing updates" do
    legacy = InstanceSettings.ensure_singleton!()

    Repo.query!("UPDATE instance_settings SET mcp = '{}'::jsonb")
    InstanceSettings.reset_cache_for_test()

    assert InstanceSettings.current().mcp.enabled == false

    assert {:ok, updated} =
             InstanceSettings.update(Repo.reload!(legacy), %{
               "files" => %{"upload_ttl_seconds" => 600}
             })

    assert updated.files.upload_ttl_seconds == 600
    assert updated.mcp.enabled == false
  end

  test "legacy singleton settings rows backfill development helper flags without losing updates" do
    legacy = InstanceSettings.ensure_singleton!()

    Repo.query!(
      "UPDATE instance_settings SET development = '{\"impeccable_live_enabled\": false}'::jsonb"
    )

    InstanceSettings.reset_cache_for_test()

    assert InstanceSettings.current().development.impeccable_live_enabled == false
    assert InstanceSettings.current().development.account_reconciliation_paused == false

    assert {:ok, updated} =
             InstanceSettings.update(Repo.reload!(legacy), %{
               "catalog" => %{"openai_pricing_url" => "https://pricing.example.com/catalog.json"}
             })

    assert updated.catalog.openai_pricing_url == "https://pricing.example.com/catalog.json"
    assert updated.development.impeccable_live_enabled == false
    assert updated.development.account_reconciliation_paused == false
  end

  test "update/2 refreshes the cache and broadcasts deterministic invalidation" do
    settings = InstanceSettings.current()
    :ok = Cache.subscribe()

    assert {:ok, updated} =
             InstanceSettings.update(settings, %{
               "gateway" => %{"gateway_debug" => true},
               "files" => %{"upload_ttl_seconds" => 120}
             })

    assert_receive {Cache, {:updated, lock_version}}
    assert lock_version == updated.lock_version
    assert InstanceSettings.current().gateway.gateway_debug == true
    assert InstanceSettings.current().files.upload_ttl_seconds == 120
  end

  test "cache ignores its own already-applied update broadcast without noisy reload" do
    settings = InstanceSettings.current()

    log =
      capture_log(fn ->
        assert {:ok, _updated} =
                 InstanceSettings.update(settings, %{
                   "gateway" => %{"gateway_debug" => true}
                 })

        _ = :sys.get_state(Cache)
      end)

    refute log =~ "instance settings db load failed"
    assert InstanceSettings.current().gateway.gateway_debug == true
  end

  @tag :failure_modes
  test "warm-cache DB failure returns last-known-good settings" do
    settings = InstanceSettings.current()
    assert settings.source == :database
    assert settings.mcp.enabled == false

    Application.put_env(:codex_pooler, InstanceSettings, repo: FailingRepo)

    log =
      capture_log(fn ->
        send(Cache, {Cache, {:updated, settings.lock_version + 1}})
        _ = :sys.get_state(Cache)
      end)

    fallback = InstanceSettings.current()

    assert log =~ "instance settings db load failed warm_cache=true"
    assert fallback.source == :database
    assert fallback.db_available? == true
    assert fallback.files.max_size_bytes == settings.files.max_size_bytes
    assert fallback.metrics.bearer_token_status == :intentionally_unset
  end

  @tag :failure_modes
  test "cold-cache DB failure returns fallback defaults with unavailable secret statuses" do
    Application.put_env(:codex_pooler, InstanceSettings, repo: FailingRepo)
    InstanceSettings.reset_cache_for_test()

    {settings, log} = capture_instance_settings_db_failure(fn -> InstanceSettings.current() end)

    assert log =~ "instance settings db load failed warm_cache=false"
    assert settings.source == :fallback_defaults
    assert settings.db_available? == false
    assert settings.secrets_available? == false
    assert settings.files.max_size_bytes == 25 * 1024 * 1024
    assert settings.mcp.enabled == false
    assert settings.metrics.bearer_token_status == :unavailable
    assert settings.smtp.password_status == :unavailable
  end

  @tag :sensitive
  test "SMTP password is encrypted, recoverable through helper, and redacted from audit" do
    %{user: user} =
      AccountsFixtures.bootstrap_owner_fixture(%{"email" => AccountsFixtures.unique_user_email()})

    scope = Scope.for_user(user, ["instance_owner"])
    settings = InstanceSettings.ensure_singleton!()
    password = "smtp-secret-#{System.unique_integer([:positive])}"

    attrs =
      %{
        "smtp" => %{
          "enabled" => true,
          "host" => "smtp.example.com",
          "username" => "mailer",
          "from" => "no-reply@example.com"
        },
        :current_scope => scope
      }
      |> InstanceSettings.put_smtp_password(password)

    assert {:ok, updated} = InstanceSettings.update(settings, attrs)
    assert updated.smtp.password_status == :configured
    assert updated.smtp.password_ciphertext != password
    assert {:ok, ^password} = InstanceSettings.decrypt_smtp_password(updated)
    refute inspect(Repo.get!(Settings, true)) =~ password
    refute inspect(Repo.all(AuditEvent)) =~ password

    event =
      Repo.one!(
        from audit in AuditEvent,
          where: audit.action == "instance_settings.update" and audit.actor_user_id == ^user.id,
          order_by: [desc: audit.occurred_at],
          limit: 1
      )

    assert get_in(event.details, ["credential_changes", "smtp_auth_state"]) == "configured"
  end

  @tag :sensitive
  test "blank SMTP password preserves the stored secret and explicit clear removes it" do
    %{user: user} =
      AccountsFixtures.bootstrap_owner_fixture(%{"email" => AccountsFixtures.unique_user_email()})

    scope = Scope.for_user(user, ["instance_owner"])
    settings = InstanceSettings.ensure_singleton!()

    attrs =
      %{
        "smtp" => %{
          "enabled" => true,
          "host" => "smtp.example.com",
          "username" => "mailer",
          "from" => "no-reply@example.com"
        },
        :current_scope => scope
      }
      |> InstanceSettings.put_smtp_password("preserved-secret")

    assert {:ok, configured} = InstanceSettings.update(settings, attrs)
    assert {:ok, "preserved-secret"} = InstanceSettings.decrypt_smtp_password(configured)

    preserve_attrs =
      %{
        "smtp" => %{
          "enabled" => true,
          "host" => "smtp.example.com",
          "username" => "mailer-renamed",
          "from" => "no-reply@example.com"
        },
        :current_scope => scope
      }
      |> InstanceSettings.preserve_smtp_password()

    assert {:ok, preserved} = InstanceSettings.update(configured, preserve_attrs)
    assert {:ok, "preserved-secret"} = InstanceSettings.decrypt_smtp_password(preserved)
    assert preserved.smtp.username == "mailer-renamed"

    clear_attrs =
      %{
        "smtp" => %{
          "enabled" => false,
          "username" => nil
        },
        :current_scope => scope
      }
      |> InstanceSettings.clear_smtp_password()

    assert {:ok, cleared} = InstanceSettings.update(preserved, clear_attrs)
    assert cleared.smtp.password_status == :intentionally_unset

    assert {:error, %{code: :smtp_password_unavailable}} =
             InstanceSettings.decrypt_smtp_password(cleared)

    event =
      Repo.one(
        from audit in AuditEvent,
          where: audit.action == "instance_settings.update" and audit.actor_user_id == ^user.id,
          order_by: [desc: audit.occurred_at],
          limit: 1
      )

    assert get_in(event.details, ["credential_changes", "smtp_auth_state"]) == "cleared"
    refute inspect(event) =~ "preserved-secret"
  end

  test "SMTP validation requires a password when username auth is enabled" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:error, changeset} =
             InstanceSettings.update(settings, %{
               "smtp" => %{
                 "enabled" => true,
                 "host" => "smtp.example.com",
                 "username" => "mailer",
                 "from" => "sender@example.com"
               }
             })

    assert "must be present when SMTP username is set" in errors_on(changeset).smtp.password
  end

  test "send_smtp_test_email/3 uses unsaved values, preserves stored password, passes runtime config, and leaves the row unchanged" do
    %{user: user} =
      AccountsFixtures.bootstrap_owner_fixture(%{"email" => AccountsFixtures.unique_user_email()})

    scope = Scope.for_user(user, ["instance_owner"])
    server_name = String.to_atom("codex_pooler_probe_#{System.unique_integer([:positive])}")
    port = free_port()

    assert {:ok, _pid} =
             :gen_smtp_server.start(server_name, :smtp_server_example, [
               {:port, port},
               {:sessionoptions, [{:callbackoptions, [{:auth, true}]}]}
             ])

    on_exit(fn ->
      :ok = :gen_smtp_server.stop(server_name)
    end)

    settings = InstanceSettings.ensure_singleton!()

    configured_attrs =
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
      |> InstanceSettings.put_smtp_password("stored-password")

    assert {:ok, configured} = InstanceSettings.update(settings, configured_attrs)
    before = InstanceSettings.get!()
    expected_password_hash = :crypto.hash(:sha256, "stored-password")

    success_attrs = %{
      "smtp" => %{
        "enabled" => true,
        "host" => "localhost",
        "port" => port,
        "username" => "username",
        "from" => "probe@example.com",
        "ssl" => false,
        "tls" => "never",
        "retries" => 2,
        "password" => ""
      }
    }

    telemetry_ref = make_ref()
    telemetry_id = "instance-settings-smtp-test-email-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:swoosh, :deliver, :start],
        fn _event, _measurements, metadata, pid ->
          send(pid, {telemetry_ref, metadata.config})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(telemetry_id)
    end)

    assert {:ok, %{code: :smtp_test_email_sent}} =
             InstanceSettings.send_smtp_test_email(configured, success_attrs, scope)

    assert_received {^telemetry_ref, delivery_config}
    assert delivery_config[:relay] == "localhost"
    assert delivery_config[:port] == port
    assert delivery_config[:username] == "username"
    assert delivery_config[:adapter] == Swoosh.Adapters.SMTP
    assert :crypto.hash(:sha256, delivery_config[:password]) == expected_password_hash

    current = InstanceSettings.get!()
    assert current.smtp.enabled == before.smtp.enabled
    assert current.smtp.host == before.smtp.host
    assert current.smtp.port == before.smtp.port
    assert current.smtp.username == before.smtp.username
    assert current.smtp.from == before.smtp.from
    assert current.smtp.password_ciphertext == before.smtp.password_ciphertext
    assert current.lock_version == before.lock_version
  end

  test "send_smtp_test_email/3 returns validation errors when auth requires a usable password and clear is explicit" do
    %{user: user} =
      AccountsFixtures.bootstrap_owner_fixture(%{"email" => AccountsFixtures.unique_user_email()})

    scope = Scope.for_user(user, ["instance_owner"])
    settings = InstanceSettings.ensure_singleton!()

    attrs =
      %{
        "smtp" => %{
          "enabled" => true,
          "host" => "smtp.example.com",
          "port" => 587,
          "username" => "mailer",
          "from" => "sender@example.com",
          "ssl" => false,
          "tls" => "never",
          "retries" => 2
        }
      }
      |> InstanceSettings.clear_smtp_password()

    assert {:error, changeset} = InstanceSettings.send_smtp_test_email(settings, attrs, scope)
    assert "must be present when SMTP username is set" in errors_on(changeset).smtp.password
    assert_no_email_sent()
  end

  test "send_smtp_test_email/3 returns a sanitized error when the signed-in operator email is missing" do
    %{user: user} =
      AccountsFixtures.bootstrap_owner_fixture(%{"email" => AccountsFixtures.unique_user_email()})

    scope =
      user
      |> Scope.for_user(["instance_owner"])
      |> then(fn scope -> %{scope | user: %{scope.user | email: "  "}} end)

    settings = InstanceSettings.ensure_singleton!()

    attrs =
      %{
        "smtp" => %{
          "enabled" => true,
          "host" => "smtp.example.com",
          "port" => 587,
          "from" => "sender@example.com",
          "ssl" => false,
          "tls" => "never",
          "retries" => 2
        }
      }

    assert {:error, %{code: :smtp_test_email_recipient_missing, message: message} = error} =
             InstanceSettings.send_smtp_test_email(settings, attrs, scope)

    assert message == "Signed-in operator email is required for SMTP test email"
    refute inspect(error) =~ user.email
    assert_no_email_sent()
  end

  @tag :sensitive
  test "metrics token is HMAC-only, comparable, fingerprinted, and unrecoverable" do
    settings = InstanceSettings.ensure_singleton!()
    token = "metrics-token-#{System.unique_integer([:positive])}"

    assert {:ok, updated} =
             settings
             |> InstanceSettings.update(InstanceSettings.put_metrics_bearer_token(%{}, token))

    assert updated.metrics.bearer_token_status == :configured
    assert updated.metrics.bearer_token_fingerprint =~ "sha256:"
    assert InstanceSettings.metrics_token_matches?(updated, token)
    refute InstanceSettings.metrics_token_matches?(updated, token <> "-wrong")
    refute inspect(Repo.get!(Settings, true)) =~ token
  end

  @tag :concurrency
  test "stale concurrent updates fail with a changeset error and do not overwrite newer settings" do
    stale = InstanceSettings.ensure_singleton!()
    fresh = InstanceSettings.get!()

    assert {:ok, _updated} =
             InstanceSettings.update(fresh, %{"files" => %{"upload_ttl_seconds" => 300}})

    assert {:error, changeset} =
             InstanceSettings.update(stale, %{"files" => %{"upload_ttl_seconds" => 600}})

    assert "was updated by another operator" in errors_on(changeset).lock_version
    assert InstanceSettings.get!().files.upload_ttl_seconds == 300
  end

  defp capture_instance_settings_db_failure(fun) do
    ref = make_ref()

    log =
      capture_log(fn ->
        send(self(), {ref, fun.()})
      end)

    assert_received {^ref, result}
    {result, log}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
