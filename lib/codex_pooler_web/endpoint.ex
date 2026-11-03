defmodule CodexPoolerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :codex_pooler

  alias CodexPoolerWeb.Plugs.RuntimeIngress.CompressedBody

  alias CodexPoolerWeb.Plugs.{
    BackendFilesMultipartGuard,
    RejectDuplicateHost,
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

  plug RejectDuplicateHost

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

  @ordinary_parser_opts Plug.Parsers.init(
                          parsers: [:urlencoded, :multipart, {CodexPoolerWeb.Plugs.RuntimeJsonParser, body_reader: {__MODULE__, :read_plain_json_body, []}}],
                          pass: ["*/*"],
                          json_decoder: Phoenix.json_library()
                        )
  @media_parser_opts Plug.Parsers.init(
                       parsers: [:urlencoded, {:multipart, length: @multipart_parser_length}, {CodexPoolerWeb.Plugs.RuntimeJsonParser, body_reader: {__MODULE__, :read_plain_json_body, []}}],
                       pass: ["*/*"],
                       json_decoder: Phoenix.json_library()
                     )

  plug :parse_body

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug :dispatch_router

  def multipart_parser_length, do: @multipart_parser_length

  @doc false
  @spec read_plain_json_body(Plug.Conn.t(), keyword()) ::
          CompressedBody.read_result()
  def read_plain_json_body(conn, opts) do
    # Trusted-proxy resolution also stores settings on browser requests; only the ingress parser scope selects runtime limits.
    if Map.has_key?(conn.private, :codex_pooler_json_parse_error_scope) do
      CompressedBody.read_plain_json_body(conn, opts)
    else
      Plug.Conn.read_body(conn, opts)
    end
  end

  defp parse_body(conn, _opts) do
    opts = if RuntimeIngress.authenticated_multipart_media_request?(conn), do: @media_parser_opts, else: @ordinary_parser_opts

    conn
    |> Plug.Parsers.call(opts)
    |> RuntimeIngress.handle_body_read_timeout()
  rescue
    error in [Plug.Parsers.ParseError, Plug.Parsers.RequestTooLargeError, Plug.Conn.InvalidQueryError] ->
      case RuntimeIngress.handle_parser_error(conn, error) do
        {:ok, conn} -> conn
        :unhandled -> reraise error, __STACKTRACE__
      end
  end

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
end
