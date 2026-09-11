defmodule CodexPooler.Platform.OutboundHTTPTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Gateway.Payloads.TransportEnvelope
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Platform.OutboundHTTP
  alias CodexPooler.Status.FeedClient

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

  # Req 0.7.4 hashes the complete `finch:` pool option tuple into one Finch
  # instance under `Req.FinchSupervisor`; `pool_timeout`, `receive_timeout`,
  # `request_timeout`, and `pool_strategy` are per-request options outside the
  # hash. `pool_max_idle_time` stays unset, so every distinct tuple keeps its
  # instance until restart. Other tests in this VM start instances too, so the
  # tests count only the children they start.
  test "each distinct saved idle bound starts one Finch instance per caller option shape" do
    url = start_upstream!()
    [first, second, third] = unused_values(3)
    initial = finch_children()

    save_gateway_settings!(%{"upstream_conn_max_idle_time_ms" => first})
    assert started_children(fn -> plain_request!(url) end) == 1
    assert started_children(fn -> plain_request!(url) end) == 0
    # The status feed adds a fixed connect timeout as `conn_opts`: one more tuple.
    assert started_children(fn -> feed_request!(url) end) == 1
    assert started_children(fn -> feed_request!(url) end) == 0

    save_gateway_settings!(%{"upstream_conn_max_idle_time_ms" => second})
    assert started_children(fn -> plain_request!(url) end) == 1
    assert started_children(fn -> feed_request!(url) end) == 1

    save_gateway_settings!(%{"upstream_conn_max_idle_time_ms" => third})
    assert started_children(fn -> plain_request!(url) end) == 1

    # Saving an earlier value again repeats its tuples.
    save_gateway_settings!(%{"upstream_conn_max_idle_time_ms" => first})
    assert started_children(fn -> plain_request!(url) end) == 0
    assert started_children(fn -> feed_request!(url) end) == 0

    assert_started_alive(initial, 5)
  end

  test "the saved gateway connect timeout is part of the dispatch Finch option tuple" do
    url = start_upstream!()
    [idle_a, idle_b] = unused_values(2)
    [connect_a, connect_b] = unused_values(2)
    [pool_timeout] = unused_values(1)
    initial = finch_children()

    save_gateway_settings!(%{
      "upstream_conn_max_idle_time_ms" => idle_a,
      "upstream_connect_timeout_ms" => connect_a
    })

    assert started_children(fn -> gateway_request!(url) end) == 1
    assert started_children(fn -> gateway_request!(url) end) == 0

    # The pool timeout is a per-request option, so it starts no instance.
    save_gateway_settings!(%{"upstream_pool_timeout_ms" => pool_timeout})
    assert started_children(fn -> gateway_request!(url) end) == 0

    save_gateway_settings!(%{"upstream_connect_timeout_ms" => connect_b})
    assert started_children(fn -> gateway_request!(url) end) == 1

    save_gateway_settings!(%{"upstream_conn_max_idle_time_ms" => idle_b})
    assert started_children(fn -> gateway_request!(url) end) == 1

    save_gateway_settings!(%{
      "upstream_conn_max_idle_time_ms" => idle_a,
      "upstream_connect_timeout_ms" => connect_a
    })

    assert started_children(fn -> gateway_request!(url) end) == 0

    assert_started_alive(initial, 3)
  end

  defp start_upstream! do
    {:ok, upstream} = FakeUpstream.start_link({:raw_body, 304, "", [{"etag", "\"feed-v1\""}]})
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    FakeUpstream.url(upstream) <> "/feed.rss"
  end

  defp save_gateway_settings!(gateway) do
    assert {:ok, _settings} =
             InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
               "gateway" => gateway
             })

    current = OperationalSettings.current()

    for {key, value} <- gateway do
      assert Map.fetch!(current, String.to_existing_atom(key)) == value
    end
  end

  defp plain_request!(url) do
    assert {:ok, %Req.Response{status: 304}} =
             Req.get(url: url, retry: false, finch: OutboundHTTP.pool_options())
  end

  defp feed_request!(url) do
    assert {:not_modified, %{etag: "\"feed-v1\""}} = FeedClient.fetch(%{}, url: url)
  end

  defp gateway_request!(url) do
    options = TransportEnvelope.req_timeout_options(TimeoutConfig.build([]))
    assert {:ok, %Req.Response{status: 304}} = Req.get(url, [retry: false] ++ options)
  end

  defp started_children(fun) do
    before = finch_children()
    fun.()
    length(finch_children() -- before)
  end

  defp assert_started_alive(initial, expected) do
    started = finch_children() -- initial
    assert length(started) == expected
    assert Enum.all?(started, &Process.alive?/1)
  end

  defp finch_children do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(Req.FinchSupervisor),
        is_pid(pid),
        do: pid
  end

  # Other tests use round values (0, 15_000, 45_000, ...); consecutive values
  # ending in 101..10x cannot repeat a tuple another test started.
  defp unused_values(count) do
    base = 1_000 * (1 + :rand.uniform(3_000)) + 101
    Enum.map(0..(count - 1), &(base + &1))
  end
end
