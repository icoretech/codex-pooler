defmodule CodexPoolerWeb.Plugs.RuntimeIngress.BodyReader do
  @moduledoc false

  import Plug.Conn
  require Logger

  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Path

  @chunk_bytes 65_536
  @timeout_private_key :codex_pooler_body_read_timeout
  @methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS CONNECT TRACE)
  @encodings ~w(identity gzip deflate zstd)

  @type read_result ::
          {:ok | :more, binary(), Plug.Conn.t()}
          | {:error, term(), Plug.Conn.t()}

  @spec read(Plug.Conn.t(), pos_integer(), non_neg_integer(), keyword()) :: read_result()
  def read(conn, limit, timeout_ms, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    read_chunks(conn, limit, timeout_ms, opts, started_at, [], 0)
  end

  @spec timeout_error() :: %{status: pos_integer(), code: String.t(), message: String.t()}
  def timeout_error do
    %{status: 408, code: "request_body_read_timeout", message: "request body read timed out"}
  end

  defp read_chunks(conn, limit, timeout_ms, opts, started_at, acc, completed_bytes) do
    # The extra byte distinguishes a body exactly at the limit from an oversized
    # chunked body whose terminating zero chunk has not been read yet.
    read_length = min(@chunk_bytes, limit - completed_bytes + 1)

    read_opts =
      opts
      |> Keyword.put(:length, read_length)
      |> Keyword.put(:read_length, read_length)
      |> Keyword.put(:read_timeout, timeout_ms)

    case read_chunk(conn, read_opts) do
      {result, chunk, conn} when result in [:ok, :more] ->
        completed_bytes = completed_bytes + byte_size(chunk)
        acc = [chunk | acc]

        cond do
          completed_bytes > limit -> {:more, body(acc), put_resp_header(conn, "connection", "close")}
          result == :ok -> {:ok, body(acc), conn}
          true -> read_chunks(conn, limit, timeout_ms, opts, started_at, acc, completed_bytes)
        end

      {:error, :timeout} ->
        log_timeout(conn, timeout_ms, started_at, completed_bytes)

        conn =
          conn
          |> put_resp_header("connection", "close")
          |> put_private(@timeout_private_key, true)

        {:error, :timeout, conn}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp read_chunk(conn, opts) do
    Plug.Conn.read_body(conn, opts)
  rescue
    error in Bandit.HTTPError ->
      if error.plug_status in [:request_timeout, 408] do
        {:error, :timeout}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp body(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp log_timeout(conn, timeout_ms, started_at, completed_bytes) do
    request_id = conn |> get_resp_header("x-request-id") |> List.first() |> DiagnosticTaxonomy.safe_correlator()
    method = if conn.method in @methods, do: conn.method, else: "other"
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    previous_metadata = Logger.metadata()

    try do
      Logger.reset_metadata(request_id: request_id)

      Logger.warning(
        "ingress body read timed out " <>
          "route=#{canonical_route(conn)} method=#{method} request_id=#{request_id} " <>
          "content_encoding=#{content_encoding(conn)} framing=#{framing(conn)} " <>
          "declared_content_length=#{declared_content_length(conn)} elapsed_ms=#{elapsed_ms} " <>
          "timeout_ms=#{timeout_ms} completed_body_bytes=#{completed_bytes}"
      )
    after
      Logger.reset_metadata(previous_metadata)
    end
  end

  defp canonical_route(conn) do
    case Phoenix.Router.route_info(CodexPoolerWeb.Router, conn.method, Path.decoded_segments(conn), conn.host) do
      %{route: route} -> route
      :error -> "unmatched"
    end
  end

  defp content_encoding(conn) do
    case normalized_header(conn, "content-encoding") do
      :absent -> "identity"
      encoding when encoding in @encodings -> encoding
      _other -> "other"
    end
  end

  defp framing(conn) do
    case normalized_header(conn, "transfer-encoding") do
      "chunked" -> "chunked"
      :absent -> if get_req_header(conn, "content-length") == [], do: "unspecified", else: "content_length"
      _other -> "other"
    end
  end

  defp normalized_header(conn, name) do
    case get_req_header(conn, name) do
      [] -> :absent
      [value] when byte_size(value) <= 32 -> value |> String.downcase(:ascii) |> String.trim()
      _other -> :other
    end
  end

  defp declared_content_length(conn) do
    case get_req_header(conn, "content-length") do
      [value] when byte_size(value) in 1..19 ->
        if value =~ ~r/\A[0-9]+\z/, do: String.to_integer(value), else: "unknown"

      _other ->
        "unknown"
    end
  end
end
