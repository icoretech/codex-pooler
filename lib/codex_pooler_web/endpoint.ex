defmodule CodexPoolerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :codex_pooler
  use Plug.ErrorHandler

  alias CodexPoolerWeb.Plugs.{
    BackendFilesMultipartGuard,
    RuntimeIngress,
    TrustedProxyRemoteIp
  }

  @multipart_parser_length 2_147_483_647

  @session_options [
    store: :cookie,
    key: "_codex_pooler_key",
    signing_salt: "J9frPjlr",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :codex_pooler,
    gzip: not code_reloading?,
    only: CodexPoolerWeb.static_paths(),
    only_matching: CodexPoolerWeb.digested_static_path_prefixes(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug :maybe_live_reloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :codex_pooler
  end

  if code_reloading? do
    plug Phoenix.LiveDashboard.RequestLogger,
      param_key: "request_logger",
      cookie_key: "request_logger"
  end

  plug Plug.RequestId
  plug :trusted_proxy_remote_ip

  plug Plug.Telemetry,
    event_prefix: [:phoenix, :endpoint],
    log: {__MODULE__, :request_log_level, []}

  plug :runtime_ingress
  plug :backend_files_multipart_guard

  plug Plug.Parsers,
    parsers: [
      :urlencoded,
      {:multipart, length: @multipart_parser_length},
      {CodexPoolerWeb.Plugs.RuntimeJsonParser,
       body_reader:
         {CodexPoolerWeb.Plugs.RuntimeIngress.CompressedBody, :read_plain_json_body, []}}
    ],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug :dispatch_router

  def multipart_parser_length, do: @multipart_parser_length

  defp trusted_proxy_remote_ip(conn, opts), do: TrustedProxyRemoteIp.call(conn, opts)
  defp runtime_ingress(conn, opts), do: RuntimeIngress.call(conn, opts)

  defp backend_files_multipart_guard(conn, opts),
    do: BackendFilesMultipartGuard.call(conn, opts)

  defp dispatch_router(conn, opts), do: CodexPoolerWeb.Router.call(conn, opts)

  def maybe_live_reloader(conn, opts) do
    if CodexPoolerWeb.BrowserSecurity.codex_desktop_browser?(conn) or
         CodexPoolerWeb.BrowserSecurity.local_browser_annotation_client?(conn) do
      conn
    else
      Module.concat(Phoenix, LiveReloader).call(conn, opts)
    end
  end

  def request_log_level(%Plug.Conn{path_info: [path]}) when path in ["healthz", "readyz"],
    do: false

  def request_log_level(_conn), do: :info

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: %Plug.Parsers.ParseError{}}) do
    cond do
      RuntimeIngress.protected_backend_json_request?(conn) ->
        RuntimeIngress.send_parse_error(conn)

      RuntimeIngress.mcp_request?(conn) ->
        RuntimeIngress.send_mcp_parse_error(conn)

      true ->
        Plug.Conn.send_resp(conn, conn.status || 400, "Bad Request")
    end
  end
end
