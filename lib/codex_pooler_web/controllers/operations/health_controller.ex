defmodule CodexPoolerWeb.Operations.HealthController do
  use CodexPoolerWeb, :controller

  require Logger

  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL

  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @spec readiness(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def readiness(conn, _params) do
    if draining?() do
      unavailable(conn)
    else
      case readiness_probe().query(Repo, "select 1", [], timeout: 1_000) do
        {:ok, _result} ->
          json(conn, %{status: "ready"})

        {:error, reason} ->
          Logger.warning([
            "readiness probe failed path=/readyz reason_class=",
            reason_class(reason)
          ])

          unavailable(conn)
      end
    end
  end

  @spec draining?() :: boolean()
  defp draining? do
    marker_draining?() or RolloutDrain.draining?()
  end

  @spec marker_draining?() :: boolean()
  defp marker_draining? do
    case drain_marker_path() do
      path when is_binary(path) and path != "" -> File.exists?(path)
      _path -> false
    end
  end

  @spec drain_marker_path() :: String.t() | nil
  defp drain_marker_path do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:drain_marker_path)
  end

  defp readiness_probe do
    :codex_pooler
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:readiness_probe, SQL)
  end

  defp unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{status: "unavailable"})
  end

  defp reason_class(%module{}) when is_atom(module), do: inspect(module)
  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(_reason), do: "unknown"
end
