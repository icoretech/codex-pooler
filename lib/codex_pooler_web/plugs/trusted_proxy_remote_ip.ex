defmodule CodexPoolerWeb.Plugs.TrustedProxyRemoteIp do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @spec immediate_peer_ip(Plug.Conn.t()) :: :inet.ip_address() | nil
  def immediate_peer_ip(%Plug.Conn{
        private: %{codex_pooler_peer_ip: {a, b, c, d} = peer_ip}
      })
      when is_integer(a) and a >= 0 and a <= 255 and
             is_integer(b) and b >= 0 and b <= 255 and
             is_integer(c) and c >= 0 and c <= 255 and
             is_integer(d) and d >= 0 and d <= 255,
      do: peer_ip

  def immediate_peer_ip(%Plug.Conn{
        private: %{codex_pooler_peer_ip: {a, b, c, d, e, f, g, h} = peer_ip}
      })
      when is_integer(a) and a >= 0 and a <= 65_535 and
             is_integer(b) and b >= 0 and b <= 65_535 and
             is_integer(c) and c >= 0 and c <= 65_535 and
             is_integer(d) and d >= 0 and d <= 65_535 and
             is_integer(e) and e >= 0 and e <= 65_535 and
             is_integer(f) and f >= 0 and f <= 65_535 and
             is_integer(g) and g >= 0 and g <= 65_535 and
             is_integer(h) and h >= 0 and h <= 65_535,
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
