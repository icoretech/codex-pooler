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
    previous_instance_settings = CodexPooler.TestAppEnv.restore_on_exit(InstanceSettings)
    previous_operational_settings = CodexPooler.TestAppEnv.restore_on_exit(OperationalSettings)
    CodexPooler.TestAppEnv.restore_on_exit(OutboundHTTP)

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

  test "the next POST uses a fresh connection while the timed-out response is still pending" do
    release_ref = make_ref()
    scenario = FakeUpstream.strict_sequence([FakeUpstream.timeout_before_headers(notify: self(), release_ref: release_ref), {:raw_body, 201, "", []}])
    name = __MODULE__.HeldResponseUpstream

    on_exit(fn ->
      if pid = Process.whereis(name), do: FakeUpstream.stop(%FakeUpstream{supervisor: pid})
    end)

    {:ok, upstream} = FakeUpstream.start_link(scenario, supervisor_name: name)
    Process.unlink(upstream.supervisor)
    url = FakeUpstream.url(upstream)
    options = [body: "", retry: false, finch: [size: 1, count: 1]]

    assert {:error, %Req.TransportError{reason: :timeout}} = OutboundHTTP.post(url, [receive_timeout: 200] ++ options)
    assert_receive {:fake_upstream_timeout_barrier, :before_headers, handler, ^release_ref}, 15_000

    try do
      # HTTP/1 cannot serve this response on the original socket while its first response is held.
      assert {:ok, %Req.Response{status: 201}} = OutboundHTTP.post(url, [receive_timeout: 2_000] ++ options)
      assert :ok = FakeUpstream.verify!(upstream)
    after
      send(handler, {:fake_upstream_release_timeout, release_ref})
    end
  end

  test "parses HTTP proxies and Basic credentials without retaining raw userinfo" do
    assert OutboundHTTP.parse_proxy_url!(nil) == []
    assert OutboundHTTP.parse_proxy_url!("") == []

    assert OutboundHTTP.parse_proxy_url!("http://proxy.example.com:3128") ==
             [proxy: {:http, "proxy.example.com", 3128, []}]

    assert OutboundHTTP.parse_proxy_url!("http://user:p%40ss@proxy.example.com/") == [
             proxy: {:http, "proxy.example.com", 80, []},
             proxy_headers: [{"proxy-authorization", "Basic " <> Base.encode64("user:p@ss")}]
           ]

    for invalid <- [
          "https://secret:password@proxy.example.com",
          "socks5://proxy.example.com:1080",
          "http://proxy.example.com/path",
          "http://proxy.example.com?mode=test",
          "http://proxy.example.com:65536",
          "proxy.example.com:3128"
        ] do
      error = assert_raise ArgumentError, fn -> OutboundHTTP.parse_proxy_url!(invalid) end
      refute Exception.message(error) =~ invalid
      refute Exception.message(error) =~ "secret"
      refute Exception.message(error) =~ "password"
    end
  end

  test "a response collector's exception propagates through the pooled adapter" do
    url = start_upstream!({:raw_body, 200, "chunk", []})

    assert_raise RuntimeError, "collector failed", fn ->
      OutboundHTTP.get(url, retry: false, into: fn {:data, _chunk}, _acc -> raise "collector failed" end)
    end
  end

  test "a caller trapping exits receives only the queued stream's error and can stream again" do
    ref = make_ref()
    held = FakeUpstream.timeout_after_sse_headers(notify: self(), release_ref: ref)
    url = start_upstream!(FakeUpstream.strict_sequence([held, {:raw_body, 200, "recovered", []}]))
    options = [into: :self, retry: false, finch: [size: 1, count: 1]]
    queued_options = Keyword.merge(options, finch: [size: 1, count: 1, pool_timeout: 25], finch_private: [test_checkout: ref])
    assert {:ok, occupant} = OutboundHTTP.get(url, options)
    assert_receive {:fake_upstream_timeout_barrier, :after_sse_headers, handler, ^ref}, 15_000
    on_exit(fn -> send(handler, {:fake_upstream_release_timeout, ref}) end)

    on_exit(fn -> :telemetry.detach(ref) end)
    :ok = :telemetry.attach(ref, [:finch, :queue, :start], &__MODULE__.report_checkout_worker/4, {self(), ref})
    previous = Process.flag(:trap_exit, true)

    try do
      for _ <- 1..2 do
        assert {:error, %Req.TransportError{reason: :pool_checkout_timeout}} =
                 OutboundHTTP.get(url, queued_options)

        assert_receive {:checkout_worker, ^ref, worker}, 15_000
        monitor = Process.monitor(worker)
        assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 15_000
        refute_received {:EXIT, ^worker, _reason}
      end

      send(handler, {:fake_upstream_release_timeout, ref})
      assert Enum.to_list(occupant.body) == []
      assert {:ok, recovered} = OutboundHTTP.get(url, options)
      assert Enum.join(recovered.body) == "recovered"
    after
      Process.flag(:trap_exit, previous)
    end
  end

  def report_checkout_worker(_event, _measurements, %{request: %{private: %{test_checkout: ref}}}, {owner, ref}) do
    send(owner, {:checkout_worker, ref, self()})
  end

  def report_checkout_worker(_event, _measurements, _metadata, _config), do: :ok

  test "selects proxies for HTTP, HTTPS, WS, and WSS while honoring no_proxy" do
    http_proxy = [proxy: {:http, "http-proxy.example.com", 8080, []}]

    https_proxy = [
      proxy: {:http, "secure-proxy.example.com", 3128, []},
      proxy_headers: [{"proxy-authorization", "Basic dXNlcjpwYXNz"}]
    ]

    Application.put_env(:codex_pooler, OutboundHTTP,
      proxy_config: %{
        http: http_proxy,
        https: https_proxy,
        no_proxy: [
          "localhost",
          "example.com",
          ".internal.example",
          "api.internal:8443",
          "127.0.0.1",
          "10.0.0.0/8",
          "[2001:db8::1]:443",
          "2001:db8:1::/48"
        ]
      }
    )

    assert OutboundHTTP.proxy_options_for_url("http://public.example/v1") == http_proxy
    assert OutboundHTTP.proxy_options_for_url("ws://public.example/v1") == http_proxy
    assert OutboundHTTP.proxy_options_for_url("https://public.example/v1") == https_proxy
    assert OutboundHTTP.proxy_options_for_url("wss://public.example/v1") == https_proxy

    assert OutboundHTTP.proxy_options_for_url("http://localhost/health") == []
    assert OutboundHTTP.proxy_options_for_url("https://example.com/v1") == []
    assert OutboundHTTP.proxy_options_for_url("https://sub.example.com/v1") == https_proxy
    assert OutboundHTTP.proxy_options_for_url("https://sub.internal.example/v1") == []
    assert OutboundHTTP.proxy_options_for_url("https://api.internal:8443/v1") == []
    assert OutboundHTTP.proxy_options_for_url("https://api.internal/v1") == https_proxy
    assert OutboundHTTP.proxy_options_for_url("http://10.23.45.67/v1") == []
    assert OutboundHTTP.proxy_options_for_url("https://[2001:db8::1]/v1") == []
    assert OutboundHTTP.proxy_options_for_url("http://[2001:db8:1::1234]/v1") == []

    assert OutboundHTTP.proxy_options_for_url(
             "https://public.example/v1",
             transport_opts: [timeout: 4321]
           ) == [
             proxy: {:http, "secure-proxy.example.com", 3128, [transport_opts: [timeout: 4321]]},
             proxy_headers: [{"proxy-authorization", "Basic dXNlcjpwYXNz"}]
           ]

    assert OutboundHTTP.proxy_options_for_url("relative/path") == []
  end

  test "lowercase proxy variables take precedence and an empty lowercase value disables fallback" do
    names = ~w(http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY)
    previous = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env("http_proxy", "")
    System.put_env("HTTP_PROXY", "http://ignored.example:8080")
    System.put_env("https_proxy", "http://lower.example:3128")
    System.put_env("HTTPS_PROXY", "http://ignored.example:3129")
    System.put_env("no_proxy", "localhost, .internal.example")
    System.put_env("NO_PROXY", "ignored.example")

    assert OutboundHTTP.proxy_config_from_env!() == %{
             http: [],
             https: [proxy: {:http, "lower.example", 3128, []}],
             no_proxy: ["localhost", ".internal.example"]
           }
  end

  test "Req sends an HTTP request through the configured forward proxy" do
    {:ok, proxy} = FakeUpstream.start_link({:raw_body, 204, "", []})
    on_exit(fn -> FakeUpstream.stop(proxy) end)
    proxy_uri = URI.parse(FakeUpstream.url(proxy))

    Application.put_env(:codex_pooler, OutboundHTTP,
      proxy_config: %{
        http: [proxy: {:http, proxy_uri.host, proxy_uri.port, []}],
        https: [],
        no_proxy: []
      }
    )

    assert {:ok, %Req.Response{status: 204}} =
             OutboundHTTP.get("http://unresolvable.invalid/proxy-check",
               retry: false,
               finch: OutboundHTTP.pool_options_for_url("http://unresolvable.invalid/proxy-check")
             )

    assert FakeUpstream.count(proxy) == 1
  end

  test "Req sends HTTPS CONNECT and Basic auth through the configured tunnel proxy" do
    {proxy_port, proxy_task} = start_connect_proxy(self())
    authorization = "Basic " <> Base.encode64("proxy-user:proxy-pass")

    Application.put_env(:codex_pooler, OutboundHTTP,
      proxy_config: %{
        http: [],
        https: [
          proxy: {:http, "127.0.0.1", proxy_port, []},
          proxy_headers: [{"proxy-authorization", authorization}]
        ],
        no_proxy: []
      }
    )

    assert {:error, _reason} =
             OutboundHTTP.get("https://unresolvable.invalid/proxy-check",
               retry: false,
               finch:
                 OutboundHTTP.pool_options_for_url(
                   "https://unresolvable.invalid/proxy-check",
                   transport_opts: [timeout: 1_000]
                 )
             )

    assert_receive {:proxy_request, request}, 5_000
    assert request =~ "CONNECT unresolvable.invalid:443 HTTP/1.1\r\n"
    assert String.downcase(request) =~ "proxy-authorization: #{String.downcase(authorization)}"
    Task.await(proxy_task, 5_000)
  end

  test "Req reselects no_proxy after an HTTP redirect" do
    {:ok, target} = FakeUpstream.start_link({:raw_body, 204, "", []})
    target_url = FakeUpstream.url(target) <> "/direct"

    {:ok, proxy} =
      FakeUpstream.start_link({:raw_body, 302, "", [{"location", target_url}]})

    on_exit(fn ->
      FakeUpstream.stop(proxy)
      FakeUpstream.stop(target)
    end)

    proxy_uri = URI.parse(FakeUpstream.url(proxy))
    target_uri = URI.parse(target_url)

    Application.put_env(:codex_pooler, OutboundHTTP,
      proxy_config: %{
        http: [proxy: {:http, proxy_uri.host, proxy_uri.port, []}],
        https: [],
        no_proxy: ["#{target_uri.host}:#{target_uri.port}"]
      }
    )

    initial_url = "http://unresolvable.invalid/redirect"

    assert {:ok, %Req.Response{status: 204}} =
             OutboundHTTP.get(initial_url,
               retry: false,
               finch: OutboundHTTP.pool_options_for_url(initial_url)
             )

    assert FakeUpstream.count(proxy) == 1
    assert FakeUpstream.count(target) == 1
  end

  # Req hashes the complete `finch:` pool option tuple into one Finch
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

  defp start_upstream!(scenario \\ {:raw_body, 304, "", [{"etag", "\"feed-v1\""}]}) do
    {:ok, upstream} = FakeUpstream.start_link(scenario)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    FakeUpstream.url(upstream) <> "/feed.rss"
  end

  defp start_connect_proxy(parent) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        request = recv_headers(socket, "")
        send(parent, {:proxy_request, request})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\n\r\n")
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {port, task}
  end

  defp recv_headers(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      buffer
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
      recv_headers(socket, buffer <> chunk)
    end
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
             OutboundHTTP.get(url: url, retry: false, finch: OutboundHTTP.pool_options())
  end

  defp feed_request!(url) do
    assert {:not_modified, %{etag: "\"feed-v1\""}} = FeedClient.fetch(%{}, url: url)
  end

  defp gateway_request!(url) do
    options = TransportEnvelope.req_timeout_options(TimeoutConfig.build([]))

    assert {:ok, %Req.Response{status: 304}} =
             OutboundHTTP.get(url, [retry: false] ++ options)
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
