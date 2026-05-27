defmodule CodexPooler.Gateway.OperationalSettingsTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.{Cache, Settings}

  setup do
    previous_instance_settings = Application.get_env(:codex_pooler, InstanceSettings, [])
    previous_operational_settings = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      InstanceSettings,
      Keyword.delete(previous_instance_settings, :repo)
    )

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous_operational_settings
      |> Keyword.delete(:settings)
      |> Keyword.put(:use_instance_settings?, true)
    )

    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      Application.put_env(:codex_pooler, InstanceSettings, previous_instance_settings)
      Application.put_env(:codex_pooler, OperationalSettings, previous_operational_settings)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "current/0 builds the gateway struct from instance settings defaults" do
    settings = OperationalSettings.current()

    assert settings.file_max_size_bytes == 25 * 1024 * 1024
    assert settings.upload_ttl_seconds == 24 * 60 * 60
    assert settings.abandoned_upload_cleanup_interval_seconds == 15 * 60
    assert settings.bridge_owner_lease_ttl_seconds == 45
    assert settings.bridge_owner_lease_renewal_seconds == 15
    assert settings.expired_alias_ttl_seconds == 24 * 60 * 60
    assert settings.firewall_allowlist == []
    refute OperationalSettings.firewall_enabled?(settings)
    assert settings.decompression_algorithms == ["gzip", "deflate", "zstd"]
    assert settings.zstd_supported?
    refute settings.gateway_debug?
    assert settings.bulkheads["file_upload"].max_concurrency > 0

    assert settings.bulkheads["proxy_control"] == %{
             max_concurrency: 8,
             queue_limit: 16,
             queue_timeout_ms: 5_000
           }

    assert settings.sse_keepalive_interval_ms == 10_000
    assert settings.circuit_failure_threshold == 3
    assert settings.upstream_connect_timeout_ms == 15_000
    assert settings.upstream_pool_timeout_ms == 15_000
    assert settings.upstream_receive_timeout_ms == 300_000
    assert settings.upstream_user_agent == "codex_cli_rs/0.0.0"
    assert settings.model_context_window_overrides == %{}
  end

  test "current/0 reflects singleton updates without restart while previous snapshots stay stable" do
    initial_snapshot = OperationalSettings.current()
    instance_settings = InstanceSettings.ensure_singleton!()
    bulkheads = string_keyed_map(instance_settings.gateway.bulkheads)
    bulkheads = put_in(bulkheads, ["file_upload", "max_concurrency"], 2)
    :ok = Cache.subscribe()

    assert {:ok, updated} =
             InstanceSettings.update(instance_settings, %{
               "files" => %{
                 "max_size_bytes" => 1024,
                 "upload_ttl_seconds" => 60,
                 "abandoned_upload_cleanup_interval_seconds" => 15
               },
               "ingress" => %{
                 "firewall_allowlist" => ["203.0.113.10", "203.0.113.11"],
                 "trusted_proxies" => ["10.0.0.1"],
                 "decompression_algorithms" => ["gzip", "deflate", "zstd"],
                 "max_compressed_body_bytes" => 2048,
                 "max_decompressed_body_bytes" => 4096,
                 "max_decompression_ratio" => 12,
                 "decompression_timeout_ms" => 250
               },
               "gateway" => %{
                 "gateway_debug" => true,
                 "sse_keepalive_interval_ms" => 0,
                 "upstream_connect_timeout_ms" => 111,
                 "upstream_pool_timeout_ms" => 222,
                 "upstream_receive_timeout_ms" => 333,
                 "upstream_user_agent" => "codex_cli_rs/9.9.9",
                 "expired_alias_ttl_seconds" => 120,
                 "bridge_owner_lease_ttl_seconds" => 45,
                 "bridge_owner_lease_renewal_seconds" => 15,
                 "circuit_failure_threshold" => 5,
                 "circuit_open_seconds" => 30,
                 "circuit_half_open_probe_limit" => 2,
                 "circuit_success_threshold" => 2,
                 "bulkheads" => bulkheads,
                 "model_context_window_overrides" => %{"gpt-test-model" => 131_072}
               }
             })

    assert_receive {Cache, {:updated, lock_version}}
    assert lock_version == updated.lock_version

    settings = OperationalSettings.current()

    refute initial_snapshot.gateway_debug?
    assert initial_snapshot.file_max_size_bytes == 25 * 1024 * 1024
    assert settings.file_max_size_bytes == 1024
    assert settings.upload_ttl_seconds == 60
    assert settings.abandoned_upload_cleanup_interval_seconds == 15
    assert settings.firewall_allowlist == ["203.0.113.10", "203.0.113.11"]
    assert OperationalSettings.firewall_enabled?(settings)
    assert settings.trusted_proxies == ["10.0.0.1"]
    assert settings.max_compressed_body_bytes == 2048
    assert settings.max_decompressed_body_bytes == 4096
    assert settings.max_decompression_ratio == 12
    assert settings.decompression_timeout_ms == 250
    assert settings.gateway_debug?
    assert settings.sse_keepalive_interval_ms == 0

    assert settings.bulkheads["file_upload"] == %{
             max_concurrency: 2,
             queue_limit: 8,
             queue_timeout_ms: 5_000
           }

    assert settings.circuit_failure_threshold == 5
    assert settings.circuit_open_seconds == 30
    assert settings.circuit_half_open_probe_limit == 2
    assert settings.circuit_success_threshold == 2
    assert settings.upstream_connect_timeout_ms == 111
    assert settings.upstream_pool_timeout_ms == 222
    assert settings.upstream_receive_timeout_ms == 333
    assert settings.upstream_user_agent == "codex_cli_rs/9.9.9"
    assert settings.model_context_window_overrides == %{"gpt-test-model" => 131_072}
  end

  test "from_instance_settings/1 accepts atom-keyed bulkhead config maps" do
    instance_settings = Settings.default()

    settings =
      OperationalSettings.from_instance_settings(%{
        instance_settings
        | gateway: %{
            instance_settings.gateway
            | bulkheads: %{
                proxy_http: %{
                  max_concurrency: 3,
                  queue_limit: 5,
                  queue_timeout_ms: 750
                }
              }
          }
      })

    assert settings.bulkheads["proxy_http"] == %{
             max_concurrency: 3,
             queue_limit: 5,
             queue_timeout_ms: 750
           }
  end

  test "current/0 maps cold fallback defaults into the gateway struct" do
    Application.put_env(:codex_pooler, InstanceSettings, repo: FailingRepo)
    InstanceSettings.reset_cache_for_test()

    {settings, log} = current_with_captured_log()

    assert log =~ "instance settings db load failed warm_cache=false"
    assert settings.file_max_size_bytes == 25 * 1024 * 1024
    refute settings.gateway_debug?
    assert settings.decompression_algorithms == ["gzip", "deflate", "zstd"]
    assert settings.bulkheads["proxy_control"].max_concurrency == 8
  end

  describe "websocket owner forwarding topology config" do
    test "defaults disabled when release env is absent and app env is unset" do
      with_websocket_owner_forwarding_env(nil, fn ->
        Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)

        refute OperationalSettings.parse_websocket_owner_forwarding_env!()
        refute OperationalSettings.websocket_owner_forwarding_enabled?()
        refute CodexPooler.Gateway.websocket_owner_forwarding_enabled?()

        assert CodexPooler.Gateway.require_websocket_owner_forwarding_enabled() ==
                 {:error, :owner_forwarding_disabled}

        assert {:ok, payload} =
                 WebsocketOwnerContract.safe_error_payload(
                   :owner_forwarding_disabled,
                   %{}
                 )

        assert payload.code == "owner_forwarding_disabled"
        assert payload.metadata.reason == "owner_forwarding_disabled"
      end)
    end

    test "parses enabled release env aliases" do
      for value <- ~w(true 1 yes on) do
        with_websocket_owner_forwarding_env(value, fn ->
          assert OperationalSettings.parse_websocket_owner_forwarding_env!()
        end)

        with_websocket_owner_forwarding_app_env(true, fn ->
          assert OperationalSettings.websocket_owner_forwarding_enabled?()
          assert CodexPooler.Gateway.websocket_owner_forwarding_enabled?()
          assert CodexPooler.Gateway.require_websocket_owner_forwarding_enabled() == :ok
        end)
      end
    end

    test "parses disabled release env aliases" do
      for value <- ~w(false 0 no off) do
        with_websocket_owner_forwarding_env(value, fn ->
          refute OperationalSettings.parse_websocket_owner_forwarding_env!()
        end)
      end
    end

    test "rejects invalid release env values with a sanitized allowed-values error" do
      with_websocket_owner_forwarding_env("maybe SECRET_SENTINEL_DO_NOT_STORE_123", fn ->
        assert_raise ArgumentError, fn ->
          OperationalSettings.parse_websocket_owner_forwarding_env!()
        end
      end)

      with_websocket_owner_forwarding_env("maybe SECRET_SENTINEL_DO_NOT_STORE_123", fn ->
        try do
          OperationalSettings.parse_websocket_owner_forwarding_env!()
        rescue
          error in ArgumentError ->
            message = Exception.message(error)

            assert message =~ "CODEX_POOLER_WEBSOCKET_OWNER_FORWARDING"
            assert message =~ "true,false,1,0,yes,no,on,off"
            refute message =~ "SECRET_SENTINEL_DO_NOT_STORE_123"
            refute message =~ "DATABASE_URL"
        end
      end)
    end
  end

  defmodule FailingRepo do
    def insert(_struct, _opts), do: raise("settings db unavailable")

    def get!(_schema, _id), do: raise("settings db unavailable")
  end

  defp with_websocket_owner_forwarding_env(value, fun) do
    env_name = OperationalSettings.websocket_owner_forwarding_env_name()
    previous = System.get_env(env_name)

    if is_nil(value), do: System.delete_env(env_name), else: System.put_env(env_name, value)

    try do
      fun.()
    after
      if is_nil(previous),
        do: System.delete_env(env_name),
        else: System.put_env(env_name, previous)
    end
  end

  defp with_websocket_owner_forwarding_app_env(value, fun) do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)

    try do
      fun.()
    after
      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end
  end

  defp current_with_captured_log do
    ref = make_ref()

    log =
      capture_log(fn ->
        send(self(), {ref, OperationalSettings.current()})
      end)

    assert_received {^ref, settings}
    {settings, log}
  end

  defp string_keyed_map(map), do: map |> Jason.encode!() |> Jason.decode!()
end
