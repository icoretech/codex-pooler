defmodule CodexPoolerWeb.Browser.BrowserSecurityHeadersTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo

  @codex_desktop_user_agent "Mozilla/5.0 Codex/26.519.81530 Chrome/148.0.7778.97 Electron/42.1.0 Safari/537.36"
  @codex_desktop_in_app_browser_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"

  setup do
    previous_csp_sources = Application.get_env(:codex_pooler, :browser_csp_extra_sources)
    previous_dev_features_enabled = Application.get_env(:codex_pooler, :dev_features_enabled)

    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      restore_env(:browser_csp_extra_sources, previous_csp_sources)
      restore_env(:dev_features_enabled, previous_dev_features_enabled)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "browser CSP includes configured extra sources without allowing structural directives to expand",
       %{
         conn: conn
       } do
    Application.put_env(:codex_pooler, :browser_csp_extra_sources,
      connect_src: ["https://events.example.com"],
      img_src: ["blob:"],
      script_src: ["https://assets.example.com"],
      style_src: ["https://styles.example.com"],
      base_uri: ["https://bad.example.com"],
      frame_ancestors: ["*"],
      default_src: ["https://bad.example.com"]
    )

    conn = get(conn, ~p"/login")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    directives = csp_directives(csp)

    assert directives["connect-src"] =~ "https://events.example.com"
    assert directives["img-src"] =~ "blob:"
    assert directives["script-src"] =~ "https://assets.example.com"
    assert directives["style-src"] =~ "https://styles.example.com"
    assert directives["base-uri"] == "'self'"
    assert directives["frame-ancestors"] == "'self'"
    refute csp =~ "https://bad.example.com"
    refute csp =~ "frame-ancestors *"
    refute csp =~ "http://localhost:8400"
  end

  test "local Codex Desktop browser CSP allows annotation script injection", %{conn: conn} do
    conn =
      conn
      |> local_host()
      |> put_req_header("user-agent", @codex_desktop_user_agent)
      |> get(~p"/login")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    directives = csp_directives(csp)

    assert directives["script-src"] == "'self' 'unsafe-inline' 'unsafe-eval' blob:"
  end

  test "local Codex Desktop in-app browser CSP allows annotation script injection", %{conn: conn} do
    conn =
      conn
      |> local_host()
      |> put_req_header("user-agent", @codex_desktop_in_app_browser_user_agent)
      |> get(~p"/login")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    directives = csp_directives(csp)

    assert directives["script-src"] == "'self' 'unsafe-inline' 'unsafe-eval' blob:"
  end

  test "Codex Desktop browser CSP annotation allowances stay local-only", %{conn: conn} do
    conn =
      conn
      |> remote_host()
      |> put_req_header("user-agent", @codex_desktop_user_agent)
      |> get(~p"/login")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    directives = csp_directives(csp)

    refute directives["script-src"] =~ "'unsafe-eval'"
    refute directives["script-src"] =~ "blob:"
  end

  test "Codex Desktop in-app browser CSP annotation allowances stay local-only", %{conn: conn} do
    conn =
      conn
      |> remote_host()
      |> put_req_header("user-agent", @codex_desktop_in_app_browser_user_agent)
      |> get(~p"/login")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    directives = csp_directives(csp)

    refute directives["script-src"] =~ "'unsafe-eval'"
    refute directives["script-src"] =~ "blob:"
  end

  test "Codex Desktop browser CSP annotation allowances reject spoofed localhost hosts", %{
    conn: conn
  } do
    conn =
      conn
      |> local_host()
      |> remote_ip()
      |> put_req_header("user-agent", @codex_desktop_user_agent)
      |> get(~p"/login")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    directives = csp_directives(csp)

    refute directives["script-src"] =~ "'unsafe-eval'"
    refute directives["script-src"] =~ "blob:"
  end

  test "local Impeccable helper CSP stays disabled when persisted setting is true but dev features are off",
       %{conn: conn} do
    Application.put_env(:codex_pooler, :dev_features_enabled, false)

    assert {:ok, _settings} =
             InstanceSettings.update_system_settings(InstanceSettings.ensure_singleton!(), %{
               "development" => %{"impeccable_live_enabled" => true}
             })

    conn = get(conn, ~p"/login")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    refute csp =~ "http://localhost:8400"
    refute csp =~ "blob:"
    refute conn.resp_body =~ "http://localhost:8400/live.js"
    refute conn.resp_body =~ "impeccable-live"
  end

  test "Plug.SSL trusts Traefik websocket requests forwarded as wss without redirecting" do
    opts =
      Plug.SSL.init(
        rewrite_on: [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto],
        exclude: [
          hosts: ["localhost", "127.0.0.1"],
          conn: {CodexPoolerWeb.Plugs.ForwardedSSL, :websocket_over_forwarded_ssl?, []}
        ]
      )

    conn =
      build_conn(:get, "/live/websocket")
      |> put_req_header("connection", "keep-alive, Upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("x-forwarded-host", "codex-pooler.icorete.ch")
      |> put_req_header("x-forwarded-port", "443")
      |> put_req_header("x-forwarded-proto", "wss")

    conn = Plug.SSL.call(conn, opts)

    refute conn.halted
    refute conn.status == 301
  end

  test "production Plug.SSL allows internal metrics scrapes without redirecting" do
    opts = Plug.SSL.init(production_force_ssl_options!())

    conn = build_conn(:get, "/metrics")

    conn = Plug.SSL.call(conn, opts)

    refute conn.halted
    refute conn.status == 301
  end

  test "Plug.SSL still redirects non-websocket forwarded HTTP requests" do
    opts =
      Plug.SSL.init(
        rewrite_on: [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto],
        exclude: [
          hosts: ["localhost", "127.0.0.1"],
          conn: {CodexPoolerWeb.Plugs.ForwardedSSL, :websocket_over_forwarded_ssl?, []}
        ]
      )

    conn =
      build_conn(:get, "/admin/pools")
      |> put_req_header("x-forwarded-host", "codex-pooler.icorete.ch")
      |> put_req_header("x-forwarded-port", "80")
      |> put_req_header("x-forwarded-proto", "http")

    conn = Plug.SSL.call(conn, opts)

    assert conn.halted
    assert conn.status == 301
    assert ["https://codex-pooler.icorete.ch/admin/pools"] = get_resp_header(conn, "location")
  end

  test "browser root layout does not include local live helper scaffolding", %{conn: conn} do
    conn = get(conn, ~p"/login")

    refute conn.resp_body =~ "http://localhost:8400/live.js"
    refute conn.resp_body =~ "impeccable-live"
  end

  test "robots.txt disallows crawling the whole site", %{conn: conn} do
    conn = get(conn, ~p"/robots.txt")

    assert response(conn, 200) == "User-agent: *\nDisallow: /\n"
  end

  test "tracked top-level static assets are served without a digest manifest", %{conn: conn} do
    for logical_path <- [
          "favicon.ico",
          "favicon-16x16.png",
          "favicon-32x32.png",
          "apple-touch-icon.png",
          "site.webmanifest",
          "robots.txt"
        ] do
      asset_conn = conn |> recycle() |> get("/" <> logical_path)

      assert asset_conn.status == 200

      if logical_path == "robots.txt" do
        assert response(asset_conn, 200) == "User-agent: *\nDisallow: /\n"
      end
    end
  end

  defp csp_directives(csp) do
    csp
    |> String.split(";")
    |> Enum.reduce(%{}, fn directive, acc ->
      directive = String.trim(directive)

      case String.split(directive, ~r/\s+/, parts: 2) do
        [name, value] -> Map.put(acc, name, value)
        [name] -> Map.put(acc, name, "")
      end
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:codex_pooler, key)
  defp restore_env(key, value), do: Application.put_env(:codex_pooler, key, value)

  defp local_host(conn) do
    %{conn | host: "localhost"}
  end

  defp remote_host(conn) do
    %{conn | host: "codex-pooler.example.com"}
  end

  defp remote_ip(conn) do
    %{conn | remote_ip: {203, 0, 113, 10}}
  end

  defp production_force_ssl_options! do
    endpoint_config =
      File.cwd!()
      |> Path.join("config/prod.exs")
      |> Config.Reader.read!()
      |> Keyword.fetch!(:codex_pooler)
      |> Keyword.fetch!(CodexPoolerWeb.Endpoint)

    Keyword.fetch!(endpoint_config, :force_ssl)
  end
end
