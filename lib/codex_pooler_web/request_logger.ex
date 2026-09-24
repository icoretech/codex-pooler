defmodule CodexPoolerWeb.RequestLogger do
  @moduledoc false

  require Logger

  alias CodexPoolerWeb.Plugs.TrustedProxyRemoteIp
  alias Plug.Conn.Status

  @event [:phoenix, :endpoint, :stop]
  @usage_limit_private :codex_pooler_usage_limit
  @handler_id {__MODULE__, :endpoint_stop}
  @max_user_agent_bytes 160

  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_stop/4, :ok) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @spec handle_stop(list(atom()), map(), map(), term()) :: :ok
  def handle_stop(_event, %{duration: duration}, %{conn: conn}, _config) do
    case CodexPoolerWeb.Endpoint.request_log_level(conn) do
      false ->
        :ok

      level ->
        Logger.log(level, fn -> request_log_line(conn, duration) end)
    end
  end

  def handle_stop(_event, _measurements, _metadata, _config), do: :ok

  @spec request_log_line(Plug.Conn.t(), integer()) :: String.t()
  def request_log_line(conn, duration) do
    ([
       "request_completed",
       "method=#{safe_token(conn.method)}",
       "path=#{safe_token(conn.request_path)}",
       "status=#{safe_status(conn.status)}",
       "duration_ms=#{duration_ms(duration)}",
       "remote_ip=#{safe_token(remote_ip(conn.remote_ip))}"
     ] ++
       peer_provenance_fields(conn) ++
       usage_limit_fields(conn) ++
       ["user_agent=#{inspect(sanitize_user_agent(user_agent(conn)))}"])
    |> Enum.join(" ")
  end

  @doc """
  Keeps the reset an all-exhausted Pool's terminal answer advised on the
  connection, so the `request_completed` line names what the client was told
  (findings#206 row 206-553). Integers only; anything else is not recorded.
  """
  @spec put_usage_limit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def put_usage_limit(conn, %{"resets_at" => resets_at, "resets_in_seconds" => seconds})
      when is_integer(resets_at) and is_integer(seconds),
      do: Plug.Conn.put_private(conn, @usage_limit_private, {resets_at, seconds})

  def put_usage_limit(conn, _record), do: conn

  defp usage_limit_fields(%Plug.Conn{private: %{@usage_limit_private => {resets_at, seconds}}}),
    do: ["resets_at=#{resets_at}", "resets_in_seconds=#{seconds}"]

  defp usage_limit_fields(_conn), do: []

  @spec sanitize_user_agent(term()) :: String.t()
  def sanitize_user_agent(value) when is_binary(value) do
    value
    |> String.replace(~r/[[:cntrl:]]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_user_agent()
    |> blank_to_unknown()
  end

  def sanitize_user_agent(_value), do: "unknown"

  defp user_agent(conn), do: conn |> Plug.Conn.get_req_header("user-agent") |> List.first()

  defp safe_status(nil), do: "unknown"
  defp safe_status(status), do: status |> Status.code() |> Integer.to_string()

  defp duration_ms(duration) do
    duration
    |> System.convert_time_unit(:native, :microsecond)
    |> div(1000)
    |> Integer.to_string()
  end

  defp remote_ip(ip), do: ip |> :inet.ntoa() |> to_string()

  defp peer_provenance_fields(conn) do
    case TrustedProxyRemoteIp.peer_provenance(conn) do
      %{
        immediate_peer_ip: peer_ip,
        client_ip_source: source,
        inspected_hops: inspected_hops
      } ->
        [
          "immediate_peer_ip=#{safe_token(peer_ip)}",
          "client_ip_source=#{safe_token(source)}",
          "inspected_hops=#{inspected_hops}"
        ]

      _empty ->
        []
    end
  end

  defp safe_token(value) when is_binary(value) do
    value
    |> String.replace(~r/[[:cntrl:]]+/, "_")
    |> String.replace(~r/\s+/, "_")
    |> String.slice(0, 200)
    |> blank_to_unknown()
  end

  defp safe_token(_value), do: "unknown"

  defp truncate_user_agent(value) when byte_size(value) <= @max_user_agent_bytes, do: value

  defp truncate_user_agent(value) do
    value
    |> String.slice(0, @max_user_agent_bytes)
    |> String.trim()
  end

  defp blank_to_unknown(""), do: "unknown"
  defp blank_to_unknown(value), do: value
end
