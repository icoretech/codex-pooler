defmodule CodexPoolerWeb.Plugs.TrustedProxyRemoteIp do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP.Resolution

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @spec immediate_peer_ip(Plug.Conn.t()) :: :inet.ip_address() | nil
  def immediate_peer_ip(%Plug.Conn{private: %{codex_pooler_peer_ip: peer_ip}}) do
    if :inet.is_ip_address(peer_ip), do: peer_ip, else: nil
  end

  def immediate_peer_ip(%Plug.Conn{
        private: %{codex_pooler_client_ip_resolution: _resolution}
      }),
      do: nil

  def immediate_peer_ip(%Plug.Conn{remote_ip: remote_ip}), do: remote_ip

  @spec peer_provenance(Plug.Conn.t()) :: map()
  def peer_provenance(
        %Plug.Conn{
          private: %{
            codex_pooler_client_ip_resolution: %Resolution{
              status: :ok,
              peer_ip: peer_ip,
              client_ip: client_ip,
              source: source,
              inspected_hops: inspected_hops
            }
          },
          remote_ip: client_ip
        } = conn
      )
      when source in [:x_forwarded_for, :x_real_ip] and is_integer(inspected_hops) and
             inspected_hops >= 0 do
    case immediate_peer_ip(conn) do
      ^peer_ip ->
        %{
          immediate_peer_ip: peer_ip |> :inet.ntoa() |> to_string(),
          client_ip_source: Atom.to_string(source),
          inspected_hops: min(inspected_hops, 32)
        }

      _other ->
        %{}
    end
  end

  def peer_provenance(_conn), do: %{}

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
