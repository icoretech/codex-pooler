defmodule CodexPoolerWeb.Plugs.TrustedProxyRemoteIp do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    settings = OperationalSettings.current()
    peer_ip = conn.remote_ip
    resolution = ForwardedClientIP.resolve(conn, settings)

    conn
    |> Plug.Conn.put_private(:codex_pooler_runtime_ingress_settings, settings)
    |> Plug.Conn.put_private(:codex_pooler_peer_ip, peer_ip)
    |> Plug.Conn.put_private(:codex_pooler_client_ip_resolution, resolution)
    |> then(&%{&1 | remote_ip: resolution.client_ip})
  end
end
