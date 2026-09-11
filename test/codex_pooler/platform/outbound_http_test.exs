defmodule CodexPooler.Platform.OutboundHTTPTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Platform.OutboundHTTP

  setup do
    previous_instance_settings = Application.get_env(:codex_pooler, InstanceSettings, [])
    previous_operational_settings = Application.get_env(:codex_pooler, OperationalSettings, [])
    previous_outbound_http = Application.get_env(:codex_pooler, OutboundHTTP, [])

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

    Application.put_env(:codex_pooler, OutboundHTTP, use_instance_settings?: true)

    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      Application.put_env(:codex_pooler, InstanceSettings, previous_instance_settings)
      Application.put_env(:codex_pooler, OperationalSettings, previous_operational_settings)
      Application.put_env(:codex_pooler, OutboundHTTP, previous_outbound_http)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "pool_options/0 carries the saved Instance Setting and matches the gateway options" do
    assert OutboundHTTP.pool_options() == [conn_max_idle_time: 45_000]

    assert {:ok, _settings} =
             InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
               "gateway" => %{"upstream_conn_max_idle_time_ms" => 12_345}
             })

    assert OutboundHTTP.pool_options() == [conn_max_idle_time: 12_345]
    assert OperationalSettings.upstream_http_pool_options() == OutboundHTTP.pool_options()
  end

  test "the code default is the Instance Setting default" do
    assert OutboundHTTP.default_conn_max_idle_time_ms() ==
             Settings.default().gateway.upstream_conn_max_idle_time_ms

    assert OutboundHTTP.default_conn_max_idle_time_ms() ==
             %OperationalSettings{}.upstream_conn_max_idle_time_ms
  end

  test "conn_max_idle_time_ms/1 clamps values only a stale cache or hand-edited row can carry" do
    defaults = Settings.default()

    for {value, expected} <- [
          {0, 1_000},
          {999, 1_000},
          {1_000, 1_000},
          {3_600_000, 3_600_000},
          {3_600_001, 3_600_000},
          {nil, 45_000},
          {"30000", 45_000}
        ] do
      stale = %{defaults | gateway: %{defaults.gateway | upstream_conn_max_idle_time_ms: value}}
      assert OutboundHTTP.conn_max_idle_time_ms(stale) == expected
    end

    legacy = %{defaults | gateway: Map.delete(defaults.gateway, :upstream_conn_max_idle_time_ms)}
    assert OutboundHTTP.conn_max_idle_time_ms(legacy) == 45_000
  end

  test "pool_options/1 builds the Finch idle bound option from a snapshot value" do
    assert OutboundHTTP.pool_options(30_000) == [conn_max_idle_time: 30_000]
    assert_raise FunctionClauseError, fn -> OutboundHTTP.pool_options(-1) end
  end
end
