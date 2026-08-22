defmodule CodexPooler.Dev.MultiAgentRoundProductObserver.Plug do
  @moduledoc """
  Loopback-only lifecycle and capture surface for the multi-agent round observer.
  """

  @behaviour Plug

  import Plug.Conn

  alias CodexPooler.Dev.MultiAgentRoundProductObserver

  @identity_header_name "x-multi-agent-round-product-observer"
  @identity_header_value "pooler-product-stage-v1"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: []} = conn, _opts) do
    json(conn, 200, MultiAgentRoundProductObserver.captures())
  end

  def call(%Plug.Conn{method: "GET", path_info: ["status"]} = conn, _opts) do
    json(conn, 200, MultiAgentRoundProductObserver.status())
  end

  def call(%Plug.Conn{method: "POST", path_info: ["reset"]} = conn, _opts) do
    :ok = MultiAgentRoundProductObserver.arm()
    json(conn, 200, %{"status" => "reset"})
  end

  def call(%Plug.Conn{method: "POST", path_info: ["disarm"]} = conn, _opts) do
    :ok = MultiAgentRoundProductObserver.disarm()
    json(conn, 200, Map.put(MultiAgentRoundProductObserver.status(), "status", "disarmed"))
  end

  def call(conn, _opts), do: json(conn, 404, %{"error" => "not_found"})

  defp json(conn, status, body) do
    conn
    |> put_resp_header(@identity_header_name, @identity_header_value)
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
