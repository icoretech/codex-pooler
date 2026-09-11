defmodule CodexPooler.Status.FeedClient do
  @moduledoc "Req boundary for the fixed OpenAI status RSS feed."
  alias CodexPooler.Platform.OutboundHTTP
  alias CodexPooler.Status.FeedParser
  @url "https://status.openai.com/feed.rss"
  @max_bytes 1_000_000

  @spec fetch(map(), keyword()) :: {:ok, map()} | {:not_modified, map()} | {:error, map()}
  def fetch(state \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    headers =
      []
      |> maybe_header("if-none-match", Map.get(state, :etag))
      |> maybe_header("if-modified-since", Map.get(state, :last_modified))

    request = [
      url: Keyword.get(opts, :url, @url),
      headers: headers,
      decode_body: false,
      retry: false,
      receive_timeout: timeout,
      # Req refuses `connect_options` together with `finch`, so the connect
      # timeout travels as Finch `conn_opts` next to the idle bound.
      finch: [conn_opts: [transport_opts: [timeout: timeout]]] ++ OutboundHTTP.pool_options(),
      redirect: false
    ]

    Req.get(request) |> handle_response(state, opts)
  end

  defp handle_response({:ok, %{status: 200, headers: headers, body: body}}, _state, opts)
       when is_binary(body),
       do: handle_success(body, headers, opts)

  defp handle_response({:ok, %{status: 304, headers: headers}}, state, _opts),
    do: not_modified(headers, state)

  defp handle_response({:ok, %{status: status}}, _state, _opts) when status in 300..399,
    do: error(:redirect_rejected, "feed redirect rejected")

  defp handle_response({:ok, %{status: status}}, _state, _opts) when status >= 500,
    do: error(:upstream_unavailable, "feed upstream unavailable")

  defp handle_response({:ok, %{status: _status}}, _state, _opts),
    do: error(:http_error, "feed returned an unexpected HTTP status")

  defp handle_response({:error, _}, _state, _opts),
    do: error(:network_error, "feed transport failed")

  defp handle_success(body, headers, opts) do
    cond do
      byte_size(body) > @max_bytes -> error(:body_too_large, "feed body exceeds limit")
      content_type_allowed?(headers) -> parse_response(body, headers, opts)
      true -> error(:invalid_content_type, "feed content type is not XML")
    end
  end

  defp not_modified(headers, state) do
    {:not_modified,
     %{
       etag: header(headers, "etag") || Map.get(state, :etag),
       last_modified: header(headers, "last-modified") || Map.get(state, :last_modified)
     }}
  end

  defp parse_response(body, headers, opts) do
    case FeedParser.parse(body, now: Keyword.get(opts, :now, DateTime.utc_now())) do
      {:ok, parsed} ->
        {:ok,
         Map.merge(parsed, %{
           etag: header(headers, "etag"),
           last_modified: header(headers, "last-modified")
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_type_allowed?(headers) do
    case header(headers, "content-type") do
      nil ->
        true

      value ->
        content_type =
          value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

        content_type in ["application/rss+xml", "application/xml", "text/xml"]
    end
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value) when is_binary(value), do: [{name, value} | headers]
  defp maybe_header(headers, _name, _), do: headers

  defp header(headers, name) when is_map(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: first_header(value)
    end)
  end

  defp first_header(value) when is_list(value), do: value |> List.first() |> first_header()

  defp first_header(value) when is_binary(value),
    do: if(byte_size(value) <= 2_048 and String.valid?(value), do: value)

  defp first_header(_), do: nil

  defp error(code, message), do: {:error, %{code: code, message: message}}
end
