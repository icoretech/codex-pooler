defmodule CodexPooler.Gateway.Transports.PinnedUpload do
  @moduledoc "One-shot HTTPS upload transport bound to an already validated network address."

  alias CodexPooler.Platform.OutboundHTTP

  @doc "Runs the Req module adapter using the caller's validated address and remaining budget."
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request) do
    {address, remaining_ms} = Req.Request.get_private(request, :codex_pooler_pinned_upload)
    run(request, address, remaining_ms)
  end

  @spec run(Req.Request.t(), :inet.ip_address(), pos_integer(), keyword()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(request, address, remaining_ms, conn_options \\ []) do
    deadline = System.monotonic_time(:millisecond) + remaining_ms
    options = connection_options(request.url, remaining_ms, conn_options)

    result =
      case Mint.HTTP.connect(scheme(String.downcase(request.url.scheme)), address, request.url.port, options) do
        {:ok, conn} ->
          try do
            upload(conn, request, deadline)
          after
            Mint.HTTP.close(conn)
          end

        {:error, error} ->
          {:error, error}
      end

    case result do
      {:ok, response} -> {request, response}
      {:error, %Mint.TransportError{reason: reason}} -> {request, %Req.TransportError{reason: reason}}
      {:error, %Mint.HTTPError{module: Mint.HTTP1, reason: reason}} -> {request, %Req.HTTPError{protocol: :http1, reason: reason}}
      {:error, error} -> {request, error}
    end
  end

  defp connection_options(uri, remaining_ms, options) do
    transport_options = Keyword.get(options, :transport_opts, [])
    timeout = min(Keyword.get(transport_options, :timeout, 15_000), remaining_ms)
    options = Keyword.put(options, :transport_opts, Keyword.put(transport_options, :timeout, timeout))

    proxy_options =
      uri
      |> OutboundHTTP.proxy_options_for_url(options)
      |> Enum.map(fn
        {:proxy, {scheme, host, port, proxy_opts}} ->
          {:proxy, {scheme, host, port, Keyword.put(proxy_opts, :tunnel_timeout, min(30_000, remaining_ms))}}

        option ->
          option
      end)

    options
    |> Keyword.merge(proxy_options)
    |> Keyword.put(:hostname, uri.host)
    |> Keyword.put(:protocols, [:http1])
    |> Keyword.put(:mode, :passive)
  end

  defp upload(conn, request, deadline) do
    headers = for {name, values} <- request.headers, value <- List.wrap(values), do: {name, value}
    path = if request.url.path in [nil, ""], do: "/", else: request.url.path
    path = if request.url.query, do: path <> "?" <> request.url.query, else: path

    with {:ok, conn, ref} <- Mint.HTTP.request(conn, request.method |> Atom.to_string() |> String.upcase(), path, headers, :stream),
         {:ok, conn} <- send_body(conn, ref, request.body, deadline) do
      receive_response(conn, ref, deadline, Req.Response.new(body: ""))
    else
      {:error, _conn, error} -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  defp send_body(conn, ref, body, deadline) do
    body
    |> body_chunks()
    |> Enum.reduce_while({:ok, conn}, fn chunk, {:ok, conn} ->
      result =
        if remaining(deadline) > 0 do
          Mint.HTTP.stream_request_body(conn, ref, chunk)
        else
          {:error, conn, %Mint.TransportError{reason: :timeout}}
        end

      case result do
        {:ok, conn} -> {:cont, {:ok, conn}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, conn} -> Mint.HTTP.stream_request_body(conn, ref, :eof)
      error -> error
    end
  end

  defp body_chunks(nil), do: []
  defp body_chunks(body) when is_binary(body) or is_list(body), do: [body]
  defp body_chunks(body), do: body

  defp receive_response(conn, ref, deadline, response) do
    result = if remaining(deadline) > 0, do: Mint.HTTP.recv(conn, 0, min(30_000, remaining(deadline))), else: {:error, conn, %Mint.TransportError{reason: :timeout}, []}

    case result do
      {:ok, conn, events} ->
        case consume_events(events, ref, response) do
          {:done, response} -> {:ok, response}
          {:more, response} -> receive_response(conn, ref, deadline, response)
          {:error, error} -> {:error, error}
        end

      {:error, _conn, error, _events} ->
        {:error, error}
    end
  end

  defp consume_events([], _ref, response), do: {:more, response}
  defp consume_events([{:status, ref, status} | events], ref, response), do: consume_events(events, ref, %{response | status: status})

  defp consume_events([{:headers, ref, headers} | events], ref, response) do
    incoming = Req.Response.new(headers: headers).headers
    headers = Map.merge(response.headers, incoming, fn _key, old, new -> old ++ new end)
    consume_events(events, ref, %{response | headers: headers})
  end

  defp consume_events([{:data, ref, _data} | events], ref, response), do: consume_events(events, ref, response)
  defp consume_events([{:done, ref} | _events], ref, response), do: {:done, response}
  defp consume_events([{:error, ref, error} | _events], ref, _response), do: {:error, error}

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp scheme("https"), do: :https
  defp scheme("http"), do: :http
end
