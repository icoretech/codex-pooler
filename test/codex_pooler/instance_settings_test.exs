defmodule CodexPooler.InstanceSettingsTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.AccountsFixtures
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.{Cache, Settings}
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall

  defmodule FailingRepo do
    def insert(_struct, _opts),
      do: raise(DBConnection.ConnectionError, message: "settings db unavailable")

    def get!(_schema, _id),
      do: raise(DBConnection.ConnectionError, message: "settings db unavailable")
  end

  defmodule ScriptedRepo do
    def insert(settings, _opts) do
      notify(:insert)
      maybe_fail!(:load)
      {:ok, settings}
    end

    def get!(Settings, true) do
      notify(:get)
      maybe_fail!(:load)
      Keyword.fetch!(config(), :settings)
    end

    def one(_query) do
      notify(:lock_version)
      maybe_fail!(:lock_version)
      config() |> Keyword.fetch!(:settings) |> Map.fetch!(:lock_version)
    end

    defp maybe_fail!(operation) do
      if Keyword.fetch!(config(), :failure) in [:all, operation] do
        raise DBConnection.ConnectionError, message: "settings db unavailable"
      end
    end

    defp notify(operation), do: send(Keyword.fetch!(config(), :owner), {__MODULE__, operation})
    defp config, do: Application.fetch_env!(:codex_pooler, __MODULE__)
  end

  defmodule TestTimer do
    def send_after(destination, message, delay) do
      ref = make_ref()
      send(owner(), {__MODULE__, :scheduled, ref, destination, message, delay})
      ref
    end

    def cancel_timer(ref) do
      send(owner(), {__MODULE__, :cancelled, ref})
      false
    end

    defp owner do
      :codex_pooler
      |> Application.fetch_env!(__MODULE__)
      |> Keyword.fetch!(:owner)
    end
  end

  defmodule PeerRepo do
    def insert(settings, _opts), do: {:ok, settings}

    def get!(Settings, true) do
      case Application.fetch_env!(:codex_pooler, __MODULE__) do
        %{settings: settings, observer: observer, barrier_ref: barrier_ref} ->
          send(observer, {:peer_settings_load_blocked, node(), barrier_ref})

          receive do
            {:release_peer_settings_load, ^barrier_ref} -> settings
          end

        %Settings{} = settings ->
          settings
      end
    end

    def one(_query), do: current_settings().lock_version

    defp current_settings do
      case Application.fetch_env!(:codex_pooler, __MODULE__) do
        %{settings: settings} -> settings
        %Settings{} = settings -> settings
      end
    end
  end

  defmodule PeerHarness do
    def start(settings) do
      Application.put_env(:codex_pooler, InstanceSettings, repo: PeerRepo)
      Application.put_env(:codex_pooler, PeerRepo, settings)

      {:ok, supervisor} =
        Supervisor.start_link(
          [
            {Phoenix.PubSub, name: CodexPooler.PubSub},
            Cache
          ],
          strategy: :one_for_one
        )

      Process.unlink(supervisor)
      supervisor
    end

    def replace_repo_settings(settings) do
      Application.put_env(:codex_pooler, PeerRepo, settings)
    end

    def block_next_repo_load(settings, observer, barrier_ref) do
      Application.put_env(:codex_pooler, PeerRepo, %{
        settings: settings,
        observer: observer,
        barrier_ref: barrier_ref
      })
    end

    def release_repo_load(barrier_ref) do
      send(Process.whereis(Cache), {:release_peer_settings_load, barrier_ref})
      :ok
    end

    def firewall_decision(client_ip) do
      settings =
        InstanceSettings.current()
        |> OperationalSettings.from_instance_settings()

      client_ip
      |> Firewall.evaluate_client_ip(settings)
      |> Map.take([:outcome, :reason])
    end

    def current_lock_version do
      InstanceSettings.current().lock_version
    end

    def hide_cache_name do
      Process.unregister(Cache)
    end

    def start_applied_forwarder(observer) do
      spawn(fn ->
        :ok = Cache.subscribe_applied()
        send(observer, {:peer_applied_subscribed, node()})
        forward_applied(observer)
      end)
    end

    defp forward_applied(observer) do
      receive do
        {Cache, {:applied, lock_version}} ->
          current_lock_version = InstanceSettings.current().lock_version
          send(observer, {:peer_applied, node(), lock_version, current_lock_version})
          forward_applied(observer)
      end
    end
  end

  setup do
    previous = Application.get_env(:codex_pooler, InstanceSettings, [])
    previous_cache = Application.get_env(:codex_pooler, Cache, [])
    previous_test_timer = Application.get_env(:codex_pooler, TestTimer)
    previous_scripted_repo = Application.get_env(:codex_pooler, ScriptedRepo)
    Application.put_env(:codex_pooler, InstanceSettings, Keyword.delete(previous, :repo))
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      Application.put_env(:codex_pooler, InstanceSettings, previous)
      restore_application_env(Cache, previous_cache)
      InstanceSettings.reset_cache_for_test()
      restore_application_env(TestTimer, previous_test_timer)
      restore_application_env(ScriptedRepo, previous_scripted_repo)
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
    assert settings.gateway.websocket_idle_timeout_ms == 1_800_000
    assert Map.get(settings.gateway, :websocket_owner_idle_timeout_ms) == 1_800_000
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

  test "baseline characterization preserves downstream websocket idle timeout and persistence round-trip" do
    settings = InstanceSettings.ensure_singleton!()

    assert InstanceSettings.current().gateway.websocket_idle_timeout_ms == 1_800_000
    assert settings.gateway.websocket_idle_timeout_ms == 1_800_000

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(settings, %{
               "gateway" => %{"websocket_idle_timeout_ms" => 444_000}
             })

    assert updated.gateway.websocket_idle_timeout_ms == 444_000
    assert InstanceSettings.get!().gateway.websocket_idle_timeout_ms == 444_000
    assert InstanceSettings.current().gateway.websocket_idle_timeout_ms == 444_000
  end

  test "baseline characterization publishes a cache put before its distributed invalidation" do
    settings = InstanceSettings.current()
    :ok = Cache.subscribe()
    updated = %{settings | lock_version: settings.lock_version + 1}

    assert :ok = Cache.put(updated)
    assert InstanceSettings.current().lock_version == updated.lock_version

    assert :ok = Cache.broadcast_update(updated)
    assert_receive {Cache, {:updated, lock_version}}
    assert lock_version == updated.lock_version
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
      InstanceSettings.change(dynamic_term(%{"gateway" => %{"gateway_debug" => true}}))
    end

    assert Repo.aggregate(Settings, :count) == 0

    changeset = InstanceSettings.change_current(%{"gateway" => %{"gateway_debug" => true}})

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :gateway).changes.gateway_debug == true
    assert Repo.aggregate(Settings, :count) == 1
  end

  defp dynamic_term(term), do: term |> :erlang.term_to_binary() |> :erlang.binary_to_term()

  test "changeset rejects invalid CIDR, negative TTL, invalid TLS, invalid model overrides, malformed bulkheads, and invalid websocket idle timeout" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:error, changeset} =
             InstanceSettings.update_system_settings(settings, %{
               "ingress" => %{"firewall_allowlist" => ["not-an-ip"]},
               "files" => %{"upload_ttl_seconds" => -1},
               "smtp" => %{"tls" => "sometimes"},
               "gateway" => %{
                 "websocket_idle_timeout_ms" => 0,
                 "model_context_window_overrides" => %{"gpt-example" => 0},
                 "bulkheads" => %{"proxy_http" => %{"max_concurrency" => 0}}
               }
             })

    assert errors_on(changeset).files != []
    assert errors_on(changeset).ingress != []
    assert errors_on(changeset).smtp != []
    assert errors_on(changeset).gateway != []
  end

  test "changeset rejects websocket idle timeout values outside the bounded range" do
    settings = InstanceSettings.ensure_singleton!()

    for invalid <- [0, 59_999, 3_600_001, "not-a-number"] do
      assert {:error, changeset} =
               InstanceSettings.update_system_settings(settings, %{
                 "gateway" => %{"websocket_idle_timeout_ms" => invalid}
               })

      assert errors_on(changeset).gateway.websocket_idle_timeout_ms != []
    end
  end

  test "changeset accepts inclusive owner idle timeout bounds independently of downstream idle timeout" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, minimum} =
             InstanceSettings.update_system_settings(settings, %{
               "gateway" => %{
                 "websocket_idle_timeout_ms" => 444_000,
                 "websocket_owner_idle_timeout_ms" => 60_000
               }
             })

    assert Map.get(minimum.gateway, :websocket_owner_idle_timeout_ms) == 60_000
    assert minimum.gateway.websocket_idle_timeout_ms == 444_000

    assert {:ok, maximum} =
             InstanceSettings.update_system_settings(InstanceSettings.get!(), %{
               "gateway" => %{"websocket_owner_idle_timeout_ms" => 3_600_000}
             })

    assert Map.get(maximum.gateway, :websocket_owner_idle_timeout_ms) == 3_600_000
    assert maximum.gateway.websocket_idle_timeout_ms == 444_000
  end

  test "changeset rejects owner idle timeout values outside the bounded range" do
    settings = InstanceSettings.ensure_singleton!()

    for invalid <- [59_999, 3_600_001, "not-a-number"] do
      assert {:error, changeset} =
               InstanceSettings.update_system_settings(settings, %{
                 "gateway" => %{"websocket_owner_idle_timeout_ms" => invalid}
               })

      assert Map.get(errors_on(changeset).gateway, :websocket_owner_idle_timeout_ms) != []
    end
  end

  test "development helper setting is boolean-only and rejects stored script URLs" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(settings, %{
               "development" => %{"impeccable_live_enabled" => true}
             })

    assert updated.development.impeccable_live_enabled == true

    assert {:error, changeset} =
             InstanceSettings.update_system_settings(updated, %{
               "development" => %{"impeccable_live_enabled" => "http://localhost:8400/live.js"}
             })

    assert "is invalid" in errors_on(changeset).development.impeccable_live_enabled
  end

  test "operator app URL stores the public app root and rejects login paths" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(settings, %{
               "operator" => %{"login_base_url" => "https://codex-pooler.example.com/"}
             })

    assert updated.operator.login_base_url == "https://codex-pooler.example.com"

    for login_url <- [
          "https://codex-pooler.example.com/login",
          "https://codex-pooler.example.com/login/"
        ] do
      assert {:error, changeset} =
               InstanceSettings.update_system_settings(updated, %{
                 "operator" => %{"login_base_url" => login_url}
               })

      assert "must be the public app URL without /login" in errors_on(changeset).operator.login_base_url
    end

    assert {:error, changeset} =
             InstanceSettings.update_system_settings(updated, %{
               "operator" => %{"login_base_url" => "ftp://pooler.example.com"}
             })

    assert "has invalid format" in errors_on(changeset).operator.login_base_url
  end

  test "catalog pricing URL stores the hourly pricing source and rejects non-HTTP URLs" do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(settings, %{
               "catalog" => %{
                 "openai_pricing_url" => " https://pricing.example.com/catalog.json "
               }
             })

    assert updated.catalog.openai_pricing_url == "https://pricing.example.com/catalog.json"

    assert {:error, changeset} =
             InstanceSettings.update_system_settings(updated, %{
               "catalog" => %{"openai_pricing_url" => "s3://pricing/catalog.json"}
             })

    assert "has invalid format" in errors_on(changeset).catalog.openai_pricing_url
  end

  test "mcp service setting defaults disabled and applies through cache broadcasts" do
    settings = InstanceSettings.current()
    :ok = Cache.subscribe()

    assert settings.mcp.enabled == false

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(settings, %{
               "mcp" => %{"enabled" => true}
             })

    assert_receive {Cache, {:updated, lock_version}}
    assert lock_version == updated.lock_version
    assert InstanceSettings.current().mcp.enabled == true

    assert {:ok, disabled} =
             InstanceSettings.update_system_settings(InstanceSettings.get!(), %{
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
             InstanceSettings.update_system_settings(Repo.reload!(legacy), %{
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
             InstanceSettings.update_system_settings(Repo.reload!(legacy), %{
               "files" => %{"upload_ttl_seconds" => 600}
             })

    assert updated.files.upload_ttl_seconds == 600
    assert updated.mcp.enabled == false
  end

  test "legacy singleton settings rows backfill forwarded client policy without losing updates" do
    legacy = InstanceSettings.ensure_singleton!()

    Repo.query!(
      "UPDATE instance_settings SET ingress = ingress - 'forwarded_client_ip_source' - 'forwarded_proxy_depth'"
    )

    InstanceSettings.reset_cache_for_test()

    current = InstanceSettings.current()
    assert current.ingress.forwarded_client_ip_source == :x_forwarded_for
    assert current.ingress.forwarded_proxy_depth == 0

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(Repo.reload!(legacy), %{
               "files" => %{"upload_ttl_seconds" => 600}
             })

    assert updated.files.upload_ttl_seconds == 600
    assert updated.ingress.forwarded_client_ip_source == :x_forwarded_for
    assert updated.ingress.forwarded_proxy_depth == 0
  end

  test "legacy singleton settings rows backfill the websocket idle timeout without losing updates" do
    legacy = InstanceSettings.ensure_singleton!()

    Repo.query!("UPDATE instance_settings SET gateway = gateway - 'websocket_idle_timeout_ms'")
    InstanceSettings.reset_cache_for_test()

    assert InstanceSettings.current().gateway.websocket_idle_timeout_ms == 1_800_000

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(Repo.reload!(legacy), %{
               "files" => %{"upload_ttl_seconds" => 600}
             })

    assert updated.files.upload_ttl_seconds == 600
    assert updated.gateway.websocket_idle_timeout_ms == 1_800_000
  end

  test "legacy singleton settings rows backfill the websocket owner idle timeout without losing updates" do
    legacy = InstanceSettings.ensure_singleton!()

    Repo.query!(
      "UPDATE instance_settings SET gateway = gateway - 'websocket_owner_idle_timeout_ms'"
    )

    InstanceSettings.reset_cache_for_test()

    current = InstanceSettings.current()
    assert Map.get(current.gateway, :websocket_owner_idle_timeout_ms) == 1_800_000
    assert current.gateway.websocket_idle_timeout_ms == 1_800_000

    assert {:ok, updated} =
             InstanceSettings.update_system_settings(Repo.reload!(legacy), %{
               "files" => %{"upload_ttl_seconds" => 600}
             })

    assert updated.files.upload_ttl_seconds == 600
    assert Map.get(updated.gateway, :websocket_owner_idle_timeout_ms) == 1_800_000
    assert updated.gateway.websocket_idle_timeout_ms == 1_800_000
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
             InstanceSettings.update_system_settings(Repo.reload!(legacy), %{
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
             InstanceSettings.update_system_settings(settings, %{
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
                 InstanceSettings.update_system_settings(settings, %{
                   "gateway" => %{"gateway_debug" => true}
                 })

        _ = :sys.get_state(Cache)
      end)

    refute log =~ "instance settings db load failed"
    assert InstanceSettings.current().gateway.gateway_debug == true
  end

  test "primed current/0 reads do not require a synchronous cache process call" do
    expected = InstanceSettings.current()
    cache = Process.whereis(Cache)
    Process.unregister(Cache)

    try do
      assert InstanceSettings.current() == expected
    after
      if is_pid(cache), do: Process.register(cache, Cache)
    end
  end

  test "cache publication clears virtual secret inputs and actions" do
    settings = InstanceSettings.current()

    candidate = %{
      settings
      | metrics: %{
          settings.metrics
          | bearer_token: "transient-metrics-token",
            bearer_token_action: "set"
        },
        smtp: %{settings.smtp | password: "transient-smtp-password", password_action: "set"}
    }

    assert :ok = Cache.put(candidate)

    published = InstanceSettings.current()
    assert published.metrics.bearer_token == nil
    assert published.metrics.bearer_token_action == nil
    assert published.smtp.password == nil
    assert published.smtp.password_action == nil
  end

  test "local applied events observe the published writer snapshot" do
    settings = InstanceSettings.current()
    updated = %{settings | lock_version: settings.lock_version + 1}
    parent = self()

    observer =
      spawn(fn ->
        :ok = Cache.subscribe_applied()
        send(parent, {:applied_observer_ready, self()})

        receive do
          {Cache, {:applied, lock_version}} ->
            send(
              parent,
              {:applied_observer_result, lock_version, InstanceSettings.current().lock_version}
            )
        end
      end)

    assert_receive {:applied_observer_ready, ^observer}
    assert :ok = Cache.put(updated)

    assert_receive {:applied_observer_result, lock_version, current_lock_version}
    assert lock_version == updated.lock_version
    assert current_lock_version == updated.lock_version
  end

  test "cache misses and incompatible publication versions reload through the writer" do
    settings = InstanceSettings.current()
    :persistent_term.put({Cache, :current}, {0, %{settings | lock_version: 999}})

    assert InstanceSettings.current().lock_version == settings.lock_version

    cache = Process.whereis(Cache)
    Process.unregister(Cache)

    try do
      assert InstanceSettings.current().lock_version == settings.lock_version
    after
      if is_pid(cache), do: Process.register(cache, Cache)
    end
  end

  test "cache reset erases the published value" do
    _settings = InstanceSettings.current()
    assert :ok = InstanceSettings.reset_cache_for_test()

    cache = Process.whereis(Cache)
    Process.unregister(Cache)

    try do
      assert InstanceSettings.current().source == :fallback_defaults
    after
      if is_pid(cache), do: Process.register(cache, Cache)
    end
  end

  @tag :distributed
  test "PubSub invalidation converges a peer only after its local snapshot is applied" do
    settings = InstanceSettings.current()
    peer = start_instance_settings_peer!(settings)

    on_exit(fn -> stop_instance_settings_peer(peer) end)

    assert forwarder =
             :erpc.call(peer.node, PeerHarness, :start_applied_forwarder, [self()])

    assert is_pid(forwarder)
    assert_receive {:peer_applied_subscribed, peer_node}
    assert peer_node == peer.node

    updated = %{settings | lock_version: settings.lock_version + 1}
    assert :ok = :erpc.call(peer.node, PeerHarness, :replace_repo_settings, [updated])
    assert :ok = Cache.broadcast_update(updated)

    assert_receive {:peer_applied, peer_node, applied_lock_version, current_lock_version}, 2_000
    assert peer_node == peer.node
    assert applied_lock_version == updated.lock_version
    assert current_lock_version == updated.lock_version
  end

  @tag :distributed
  test "a peer enforces a firewall update only after publishing its local applied snapshot" do
    client_ip = {198, 51, 100, 20}
    settings = InstanceSettings.current()
    initial = %{settings | ingress: %{settings.ingress | firewall_allowlist: ["198.51.100.20"]}}
    peer = start_instance_settings_peer!(initial)

    on_exit(fn -> stop_instance_settings_peer(peer) end)

    assert %{outcome: :allow, reason: nil} =
             :erpc.call(peer.node, PeerHarness, :firewall_decision, [client_ip])

    forwarder = :erpc.call(peer.node, PeerHarness, :start_applied_forwarder, [self()])
    assert is_pid(forwarder)
    assert_receive {:peer_applied_subscribed, peer_node}
    assert peer_node == peer.node

    updated = %{
      initial
      | lock_version: initial.lock_version + 1,
        ingress: %{initial.ingress | firewall_allowlist: ["203.0.113.10"]}
    }

    barrier_ref = make_ref()

    assert :ok =
             :erpc.call(peer.node, PeerHarness, :block_next_repo_load, [
               updated,
               self(),
               barrier_ref
             ])

    assert :ok = Cache.broadcast_update(updated)
    assert_receive {:peer_settings_load_blocked, peer_node, ^barrier_ref}
    assert peer_node == peer.node

    assert %{outcome: :allow, reason: nil} =
             :erpc.call(peer.node, PeerHarness, :firewall_decision, [client_ip])

    assert :ok = :erpc.call(peer.node, PeerHarness, :release_repo_load, [barrier_ref])

    assert_receive {:peer_applied, peer_node, applied_version, current_version}, 2_000
    assert peer_node == peer.node
    assert applied_version == updated.lock_version
    assert current_version == updated.lock_version

    assert %{outcome: :deny, reason: :not_allowed} =
             :erpc.call(peer.node, PeerHarness, :firewall_decision, [client_ip])
  end

  @tag :failure_modes
  test "current/0 returns fallback defaults before the cache process starts" do
    cache = Process.whereis(Cache)
    Process.unregister(Cache)

    try do
      settings = InstanceSettings.current()

      assert settings.source == :fallback_defaults
      assert settings.db_available? == false
      assert settings.secrets_available? == false
      assert settings.files.max_size_bytes == 25 * 1024 * 1024
      assert settings.metrics.bearer_token_status == :unavailable
      assert settings.smtp.password_status == :unavailable
      assert :persistent_term.get({Cache, :current}) == {1, settings}
    after
      if is_pid(cache), do: Process.register(cache, Cache)
    end
  end

  @tag :failure_modes
  test "warm-cache DB failure returns last-known-good settings" do
    settings = Settings.default() |> Map.put(:lock_version, 7)
    configure_scripted_cache(settings)
    settings = InstanceSettings.current()
    assert settings.source == :database
    assert settings.mcp.enabled == false
    assert_receive {ScriptedRepo, :insert}
    assert_receive {ScriptedRepo, :get}

    configure_scripted_repo(settings, :load)

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

    state = :sys.get_state(Cache)
    assert state.health == :degraded
    assert state.cached.lock_version == settings.lock_version
    assert state.desired_lock_version == settings.lock_version + 1
    assert %{attempt: 0} = state.retry_timer
    assert_receive {TestTimer, :scheduled, _ref, _cache, {Cache, {:retry, _generation}}, 10}
  end

  @tag :failure_modes
  test "cold-cache DB failure publishes unavailable defaults and one retry recovers" do
    database_settings = Settings.default() |> Map.put(:lock_version, 11)
    configure_scripted_cache(database_settings, :load)
    :ok = Cache.subscribe_applied()

    {settings, log} = capture_instance_settings_db_failure(fn -> InstanceSettings.current() end)

    assert log =~ "instance settings db load failed warm_cache=false"
    assert settings.source == :fallback_defaults
    assert settings.db_available? == false
    assert settings.secrets_available? == false
    assert settings.files.max_size_bytes == 25 * 1024 * 1024
    assert settings.mcp.enabled == false
    assert settings.metrics.bearer_token_status == :unavailable
    assert settings.smtp.password_status == :unavailable
    assert :persistent_term.get({Cache, :current}) == {1, settings}

    assert_receive {TestTimer, :scheduled, _ref, cache, {Cache, {:retry, generation}}, 10}
    assert cache == Process.whereis(Cache)

    configure_scripted_repo(database_settings, :none)
    send(Cache, {Cache, {:retry, generation}})

    assert_receive {Cache, {:applied, lock_version}}
    assert lock_version == database_settings.lock_version
    assert InstanceSettings.current().lock_version == database_settings.lock_version
    assert InstanceSettings.current().source == :database

    state = :sys.get_state(Cache)
    assert state.health == :ready
    assert state.retry_timer == nil
    assert state.retry_attempt == 0
    assert %{generation: _generation} = state.reconciliation_timer
  end

  @tag :failure_modes
  test "retry backoff caps, keeps one timer, and resets after success" do
    database_settings = Settings.default() |> Map.put(:lock_version, 15)
    configure_scripted_cache(database_settings, :load)

    _fallback = InstanceSettings.current()

    assert_receive {TestTimer, :scheduled, _ref1, _cache, {Cache, {:retry, generation1}}, 10}
    assert %{attempt: 0, generation: ^generation1} = :sys.get_state(Cache).retry_timer

    send(Cache, {Cache, {:retry, generation1}})
    assert_receive {TestTimer, :scheduled, _ref2, _cache, {Cache, {:retry, generation2}}, 20}
    assert %{attempt: 1, generation: ^generation2} = :sys.get_state(Cache).retry_timer

    send(Cache, {Cache, {:retry, generation2}})
    assert_receive {TestTimer, :scheduled, _ref3, _cache, {Cache, {:retry, generation3}}, 30}
    assert %{attempt: 2, generation: ^generation3} = :sys.get_state(Cache).retry_timer

    send(Cache, {Cache, {:retry, generation3}})
    assert_receive {TestTimer, :scheduled, _ref4, _cache, {Cache, {:retry, generation4}}, 30}
    assert %{attempt: 3, generation: ^generation4} = :sys.get_state(Cache).retry_timer

    refute_received {TestTimer, :scheduled, _ref, _destination, {Cache, {:retry, _generation}},
                     _delay}

    configure_scripted_repo(database_settings, :none)
    send(Cache, {Cache, {:retry, generation4}})
    _ = :sys.get_state(Cache)

    state = :sys.get_state(Cache)
    assert state.retry_timer == nil
    assert state.retry_attempt == 0
    assert state.health == :ready
    assert %{generation: _generation} = state.reconciliation_timer
  end

  @tag :failure_modes
  test "stale retry generations cannot reload or schedule another timer" do
    database_settings = Settings.default() |> Map.put(:lock_version, 21)
    configure_scripted_cache(database_settings, :load)
    _fallback = InstanceSettings.current()

    assert_receive {TestTimer, :scheduled, retry_ref, _cache, {Cache, {:retry, stale_generation}},
                    10}

    send(Cache, {Cache, {:updated, database_settings.lock_version + 1}})
    _ = :sys.get_state(Cache)

    assert_receive {TestTimer, :cancelled, ^retry_ref}

    assert_receive {TestTimer, :scheduled, _new_ref, _cache,
                    {Cache, {:retry, current_generation}}, 10}

    refute current_generation == stale_generation
    flush_scripted_repo_calls()

    send(Cache, {Cache, {:retry, stale_generation}})
    _ = :sys.get_state(Cache)

    refute_received {ScriptedRepo, _operation}

    refute_received {TestTimer, :scheduled, _ref, _destination, {Cache, {:retry, _generation}},
                     _delay}

    assert %{generation: ^current_generation} = :sys.get_state(Cache).retry_timer
  end

  test "reconciliation repairs a missed invalidation using the persisted lock version" do
    initial = Settings.default() |> Map.put(:lock_version, 31)
    configure_scripted_cache(initial)
    :ok = Cache.subscribe_applied()
    assert InstanceSettings.current().lock_version == initial.lock_version
    flush_scripted_repo_calls()
    flush_applied_events()

    updated = %{initial | lock_version: initial.lock_version + 1}
    configure_scripted_repo(updated, :none)
    %{generation: generation} = :sys.get_state(Cache).reconciliation_timer

    send(Cache, {Cache, {:reconcile, generation}})

    assert_receive {ScriptedRepo, :lock_version}
    assert_receive {ScriptedRepo, :insert}
    assert_receive {ScriptedRepo, :get}
    assert_receive {Cache, {:applied, lock_version}}
    assert lock_version == updated.lock_version
    assert InstanceSettings.current().lock_version == updated.lock_version
  end

  @tag :failure_modes
  test "cache process absence publishes cold fallback and restart recovers from the database" do
    database_settings = Settings.default() |> Map.put(:lock_version, 41)
    configure_scripted_cache(database_settings)
    assert InstanceSettings.current().lock_version == database_settings.lock_version
    :ok = Cache.subscribe_applied()
    flush_applied_events()

    assert :ok = Supervisor.terminate_child(CodexPooler.Supervisor, Cache)
    :persistent_term.erase({Cache, :current})

    fallback = InstanceSettings.current()
    assert fallback.source == :fallback_defaults
    assert fallback.db_available? == false
    assert :persistent_term.get({Cache, :current}) == {1, fallback}

    assert {:ok, restarted} = Supervisor.restart_child(CodexPooler.Supervisor, Cache)
    assert is_pid(restarted)
    assert_receive {Cache, {:applied, lock_version}}
    assert lock_version == database_settings.lock_version
    assert InstanceSettings.current().lock_version == database_settings.lock_version
    assert InstanceSettings.current().source == :database
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

    assert {:ok, updated} = InstanceSettings.update_system_settings(settings, attrs)
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

    assert {:ok, configured} = InstanceSettings.update_system_settings(settings, attrs)
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

    assert {:ok, preserved} = InstanceSettings.update_system_settings(configured, preserve_attrs)
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

    assert {:ok, cleared} = InstanceSettings.update_system_settings(preserved, clear_attrs)
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
             InstanceSettings.update_system_settings(settings, %{
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

    assert {:ok, configured} = InstanceSettings.update_system_settings(settings, configured_attrs)
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
             |> InstanceSettings.update_system_settings(
               InstanceSettings.put_metrics_bearer_token(%{}, token)
             )

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
             InstanceSettings.update_system_settings(fresh, %{
               "files" => %{"upload_ttl_seconds" => 300}
             })

    assert {:error, changeset} =
             InstanceSettings.update_system_settings(stale, %{
               "files" => %{"upload_ttl_seconds" => 600}
             })

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

  defp configure_scripted_cache(settings, failure \\ :none) do
    Application.put_env(:codex_pooler, InstanceSettings, repo: ScriptedRepo)
    configure_scripted_repo(settings, failure)
    Application.put_env(:codex_pooler, TestTimer, owner: self())

    Application.put_env(:codex_pooler, Cache,
      timer_module: TestTimer,
      retry_initial_interval_ms: 10,
      retry_max_interval_ms: 30,
      reconciliation_interval_ms: 100
    )

    assert :ok = InstanceSettings.reset_cache_for_test()

    assert_receive {TestTimer, :scheduled, _ref, cache, {Cache, {:reconcile, _generation}}, 100}
    assert cache == Process.whereis(Cache)
    flush_timer_cancellations()
    :ok
  end

  defp configure_scripted_repo(settings, failure) do
    Application.put_env(:codex_pooler, ScriptedRepo,
      owner: self(),
      settings: settings,
      failure: failure
    )
  end

  defp flush_scripted_repo_calls do
    receive do
      {ScriptedRepo, _operation} -> flush_scripted_repo_calls()
    after
      0 -> :ok
    end
  end

  defp flush_applied_events do
    receive do
      {Cache, {:applied, _lock_version}} -> flush_applied_events()
    after
      0 -> :ok
    end
  end

  defp flush_timer_cancellations do
    receive do
      {TestTimer, :cancelled, _ref} -> flush_timer_cancellations()
    after
      0 -> :ok
    end
  end

  defp restore_application_env(module, nil), do: Application.delete_env(:codex_pooler, module)

  defp restore_application_env(module, value),
    do: Application.put_env(:codex_pooler, module, value)

  defp start_instance_settings_peer!(settings) do
    distribution = ensure_test_distribution_started!()
    peer_name = String.to_atom("instance_settings_peer_#{System.unique_integer([:positive])}")

    assert {:ok, peer_pid, peer_node} =
             :peer.start_link(%{
               name: peer_name,
               args: [~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
             })

    Process.unlink(peer_pid)
    assert :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    assert {:ok, _applications} =
             :erpc.call(peer_node, Application, :ensure_all_started, [:elixir])

    assert [{PeerRepo, _repo_beam}, {PeerHarness, _harness_beam}] =
             :erpc.call(peer_node, Code, :compile_string, [peer_harness_source()])

    assert {:ok, _applications} =
             :erpc.call(peer_node, Application, :ensure_all_started, [:phoenix_pubsub])

    supervisor = :erpc.call(peer_node, PeerHarness, :start, [settings])
    assert is_pid(supervisor)

    %{
      distribution: distribution,
      node: peer_node,
      pid: peer_pid,
      supervisor: supervisor
    }
  end

  defp stop_instance_settings_peer(%{pid: peer_pid, distribution: distribution}) do
    if Process.alive?(peer_pid), do: :peer.stop(peer_pid)

    if distribution.node_started? do
      :ok = :net_kernel.stop()
      restore_partition_guard(distribution.previous_partition_guard)
    end

    if distribution.epmd_started?, do: System.cmd("epmd", ["-kill"])
    :ok
  end

  defp ensure_test_distribution_started! do
    case Node.alive?() do
      true ->
        %{epmd_started?: false, node_started?: false, previous_partition_guard: :unchanged}

      false ->
        epmd_started? = ensure_epmd_started!()
        previous_partition_guard = Application.fetch_env(:kernel, :prevent_overlapping_partitions)
        Application.put_env(:kernel, :prevent_overlapping_partitions, false)
        node_name = String.to_atom("instance_settings_test_#{System.unique_integer([:positive])}")
        assert {:ok, _pid} = :net_kernel.start([node_name, :shortnames])

        %{
          epmd_started?: epmd_started?,
          node_started?: true,
          previous_partition_guard: previous_partition_guard
        }
    end
  end

  defp ensure_epmd_started! do
    case :erl_epmd.names() do
      {:ok, _names} ->
        false

      {:error, _reason} ->
        assert {_output, 0} = System.cmd("epmd", ["-daemon"])
        true
    end
  end

  defp restore_partition_guard({:ok, value}) do
    Application.put_env(:kernel, :prevent_overlapping_partitions, value)
  end

  defp restore_partition_guard(:error) do
    Application.delete_env(:kernel, :prevent_overlapping_partitions)
  end

  defp restore_partition_guard(:unchanged), do: :ok

  defp peer_harness_source do
    """
    defmodule #{inspect(PeerRepo)} do
      def insert(settings, _opts), do: {:ok, settings}

      def get!(CodexPooler.InstanceSettings.Settings, true) do
        case Application.fetch_env!(:codex_pooler, __MODULE__) do
          %{settings: settings, observer: observer, barrier_ref: barrier_ref} ->
            send(observer, {:peer_settings_load_blocked, node(), barrier_ref})

            receive do
              {:release_peer_settings_load, ^barrier_ref} -> settings
            end

          %CodexPooler.InstanceSettings.Settings{} = settings ->
            settings
        end
      end

      def one(_query), do: current_settings().lock_version

      defp current_settings do
        case Application.fetch_env!(:codex_pooler, __MODULE__) do
          %{settings: settings} -> settings
          %CodexPooler.InstanceSettings.Settings{} = settings -> settings
        end
      end
    end

    defmodule #{inspect(PeerHarness)} do
      alias CodexPooler.InstanceSettings
      alias CodexPooler.InstanceSettings.Cache
      alias #{inspect(PeerRepo)}

      def start(settings) do
        Application.put_env(:codex_pooler, InstanceSettings, repo: PeerRepo)
        Application.put_env(:codex_pooler, PeerRepo, settings)

        {:ok, supervisor} =
          Supervisor.start_link(
            [{Phoenix.PubSub, name: CodexPooler.PubSub}, Cache],
            strategy: :one_for_one
          )

        Process.unlink(supervisor)
        supervisor
      end

      def replace_repo_settings(settings) do
        Application.put_env(:codex_pooler, PeerRepo, settings)
      end

      def block_next_repo_load(settings, observer, barrier_ref) do
        Application.put_env(:codex_pooler, PeerRepo, %{
          settings: settings,
          observer: observer,
          barrier_ref: barrier_ref
        })
      end

      def release_repo_load(barrier_ref) do
        send(Process.whereis(Cache), {:release_peer_settings_load, barrier_ref})
        :ok
      end

      def firewall_decision(client_ip) do
        settings =
          InstanceSettings.current()
          |> CodexPooler.Gateway.OperationalSettings.from_instance_settings()

        client_ip
        |> CodexPoolerWeb.Plugs.RuntimeIngress.Firewall.evaluate_client_ip(
          settings
        )
        |> Map.take([:outcome, :reason])
      end

      def current_lock_version do
        InstanceSettings.current().lock_version
      end

      def hide_cache_name do
        Process.unregister(Cache)
      end

      def start_applied_forwarder(observer) do
        spawn(fn ->
          :ok = Cache.subscribe_applied()
          send(observer, {:peer_applied_subscribed, node()})
          forward_applied(observer)
        end)
      end

      defp forward_applied(observer) do
        receive do
          {Cache, {:applied, lock_version}} ->
            current_lock_version = InstanceSettings.current().lock_version
            send(observer, {:peer_applied, node(), lock_version, current_lock_version})
            forward_applied(observer)
        end
      end
    end
    """
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
