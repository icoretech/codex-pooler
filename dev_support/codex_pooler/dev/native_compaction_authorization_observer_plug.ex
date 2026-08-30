defmodule CodexPooler.Dev.NativeCompactionAuthorizationObserver.Plug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias CodexPooler.Dev.NativeCompactionAuthorizationObserver

  @identity_header_name "x-native-compaction-authorization-observer"
  @identity_header_value "pooler-native-compaction-v1"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: []} = conn, _opts),
    do: json(conn, 200, NativeCompactionAuthorizationObserver.captures())

  def call(%Plug.Conn{method: "GET", path_info: ["status"]} = conn, _opts),
    do: json(conn, 200, NativeCompactionAuthorizationObserver.status())

  def call(%Plug.Conn{method: "POST", path_info: ["reset"]} = conn, _opts) do
    :ok = NativeCompactionAuthorizationObserver.arm()
    json(conn, 200, %{"status" => "reset"})
  end

  def call(%Plug.Conn{method: "POST", path_info: ["project"]} = conn, _opts) do
    with {:ok, decoded, conn} <- decode_json_body(conn),
         %{"breakMode" => break_mode} <- decoded,
         ["breakMode"] <- Map.keys(decoded),
         :ok <- NativeCompactionAuthorizationObserver.project(break_mode) do
      json(conn, 200, %{"breakMode" => break_mode, "status" => "projected"})
    else
      _invalid -> json(conn, 400, %{"error" => "invalid_break_mode"})
    end
  end

  def call(%Plug.Conn{method: "POST", path_info: ["disarm"]} = conn, _opts) do
    :ok = NativeCompactionAuthorizationObserver.disarm()
    json(conn, 200, Map.put(NativeCompactionAuthorizationObserver.status(), "status", "disarmed"))
  end

  def call(conn, _opts), do: json(conn, 404, %{"error" => "not_found"})

  defp decode_json_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        with {:ok, body, conn} <- read_body(conn),
             {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
          {:ok, decoded, conn}
        end

      decoded when is_map(decoded) ->
        {:ok, decoded, conn}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_header(@identity_header_name, @identity_header_value)
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
