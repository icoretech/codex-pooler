defmodule CodexPoolerWeb.Plugs.RuntimeIngress.Firewall do
  @moduledoc false

  import Plug.Conn

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.OperationalSettings.IPRules
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP
  alias CodexPoolerWeb.Plugs.RuntimeIngress.ForwardedClientIP.Resolution

  @type conn :: Plug.Conn.t()
  @type firewall_error :: %{
          required(:status) => 403,
          required(:code) => String.t(),
          required(:message) => String.t()
        }
  @type settings :: OperationalSettings.t()

  @spec enforce(conn(), settings()) :: {:ok, conn()} | {:error, firewall_error()}
  def enforce(conn, settings) do
    if OperationalSettings.firewall_enabled?(settings) do
      with {:ok, allowlist} <- settings.firewall_allowlist_compiled,
           {conn, %Resolution{status: :ok, client_ip: client_ip}} <-
             client_ip_resolution(conn, settings),
           true <- IPRules.allowed?(client_ip, allowlist) do
        {:ok, %{conn | remote_ip: client_ip}}
      else
        _denied -> access_denied()
      end
    else
      {:ok, conn}
    end
  end

  defp client_ip_resolution(
         %Plug.Conn{private: %{codex_pooler_client_ip_resolution: %Resolution{} = resolution}} =
           conn,
         _settings
       ) do
    {conn, resolution}
  end

  defp client_ip_resolution(conn, settings) do
    peer_ip = conn.private[:codex_pooler_peer_ip] || conn.remote_ip
    resolution = ForwardedClientIP.resolve(%{conn | remote_ip: peer_ip}, settings)

    conn =
      conn
      |> put_private(:codex_pooler_peer_ip, peer_ip)
      |> put_private(:codex_pooler_client_ip_resolution, resolution)

    {conn, resolution}
  end

  defp access_denied do
    {:error, %{status: 403, code: "access_denied", message: "client IP is not allowed"}}
  end
end
