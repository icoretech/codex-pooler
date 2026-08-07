defmodule CodexPoolerWeb.Plugs.TrustedProxyRemoteIp do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @spec immediate_peer_ip(Plug.Conn.t()) :: :inet.ip_address() | nil
  def immediate_peer_ip(%Plug.Conn{
        private: %{codex_pooler_peer_ip: peer_ip}
      })
      when is_tuple(peer_ip) and tuple_size(peer_ip) in [4, 8],
      do: peer_ip

  def immediate_peer_ip(%Plug.Conn{private: private})
      when is_map_key(private, :codex_pooler_peer_ip) or
             is_map_key(private, :codex_pooler_client_ip_resolution),
      do: nil

  def immediate_peer_ip(%Plug.Conn{remote_ip: remote_ip}), do: remote_ip

  @impl Plug
  def call(%Plug.Conn{request_path: path} = conn, _opts) when path in ["/healthz", "/readyz"],
    do: conn

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
