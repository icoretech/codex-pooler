defmodule CodexPoolerWeb.Runtime.BackendFileController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Access
  alias CodexPooler.Files
  alias CodexPooler.Files.CapabilitySpool
  alias CodexPooler.Gateway.Facade.FileCapability
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.FileBridge
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Firewall.Decision

  @download_receive_timeout_ms 30_000

  def create(conn, _params) do
    with_authenticated_file_admission(conn, "/backend-api/files", fn auth ->
      create_authenticated(conn, auth)
    end)
  end

  def uploaded(conn, %{"file_id" => file_id}) do
    with_authenticated_file_admission(conn, "/backend-api/files/uploaded", fn auth ->
      with {:ok, result} <-
             Gateway.mark_uploaded(
               auth,
               file_id,
               request_options(conn, "/backend-api/files/uploaded", %{})
             ),
           {:ok, body} <- public_finalize_body(result, capability_origin(conn)) do
        {:ok,
         %{
           status: 200,
           headers: [],
           body: body
         }}
      end
    end)
  end

  def upload_capability(conn, %{"capability" => capability}) do
    with_capability_firewall(conn, fn conn ->
      result =
        GatewayHelpers.admit(
          conn,
          RouteClass.file_upload(),
          %{endpoint: "/file-capabilities/upload"},
          fn -> proxy_upload_capability(conn, capability) end
        )

      case result do
        {:ok, gateway_result, %Plug.Conn{} = read_conn} ->
          GatewayHelpers.send_or_error(read_conn, {:ok, gateway_result})

        {:error, reason, %Plug.Conn{} = read_conn} ->
          GatewayHelpers.send_error(read_conn, reason)

        {:error, reason} ->
          GatewayHelpers.send_error(conn, reason)
      end
    end)
  end

  def download_capability(conn, %{"capability" => capability}) do
    with_capability_firewall(conn, fn conn ->
      conn
      |> GatewayHelpers.admit(
        RouteClass.file_upload(),
        %{endpoint: "/file-capabilities/download"},
        fn -> proxy_download_capability(conn, capability) end
      )
      |> then(&GatewayHelpers.send_or_error(conn, &1))
    end)
  end

  defp with_authenticated_file_admission(conn, endpoint, fun) when is_function(fun, 1) do
    case GatewayHelpers.authenticate(conn) do
      {:ok, auth} ->
        result =
          GatewayHelpers.admit(conn, RouteClass.file_upload(), %{endpoint: endpoint}, fn ->
            fun.(auth)
          end)

        GatewayHelpers.send_or_error(conn, result)

      {:error, reason} ->
        GatewayHelpers.send_error(conn, reason)
    end
  end

  defp create_authenticated(conn, auth) do
    with :ok <- reject_multipart_create(conn),
         :ok <- require_json_content_type(conn),
         {:ok, payload} <- GatewayHelpers.read_json_body(conn),
         {:ok, %{body: body, file: file}} <-
           Gateway.create_upstream_file(
             auth,
             payload,
             request_options(conn, "/backend-api/files", payload)
           ),
         {:ok, body} <- public_create_body(body, file, capability_origin(conn)) do
      {:ok, %{status: 200, headers: [], body: body}}
    end
  end

  defp public_create_body(%{"file_id" => file_id, "upload_url" => upload_url}, file, origin)
       when is_binary(file_id) do
    case FileCapability.mint(upload_url, file, :upload, origin: origin) do
      {:ok, local_url} -> {:ok, %{"file_id" => file_id, "upload_url" => local_url}}
      {:error, :invalid} -> {:error, invalid_upstream_file_url()}
    end
  end

  defp public_create_body(_body, _file, _origin), do: {:error, invalid_upstream_file_url()}

  defp public_finalize_body(
         %{body: %{"status" => status, "download_url" => download_url} = body, file: file},
         origin
       )
       when is_binary(status) do
    with :ok <- optional_binary(body, "file_name"),
         :ok <- optional_binary(body, "mime_type"),
         {:ok, local_url} <- FileCapability.mint(download_url, file, :download, origin: origin) do
      {:ok,
       body
       |> Map.take(~w(status file_name mime_type))
       |> Map.put("download_url", local_url)}
    else
      _invalid -> {:error, invalid_upstream_file_url()}
    end
  end

  defp public_finalize_body(%{body: %{"status" => "retry"}}, _origin),
    do: {:ok, %{"status" => "retry"}}

  defp public_finalize_body(%{file: file}, _origin), do: {:ok, Files.response_shape(file)}
  defp public_finalize_body(_result, _origin), do: {:error, invalid_upstream_file_url()}

  defp optional_binary(map, key) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> :ok
      _wrong_type -> {:error, :invalid}
    end
  end

  defp proxy_upload_capability(conn, capability) do
    with :ok <- reject_capability_content_encoding(conn),
         {:ok, resolution, file_context} <- resolve_capability(conn, capability, :upload),
         :ok <- validate_content_length(conn, file_context.file.byte_size),
         {:ok, path, read_conn} <- spool_upload(conn, file_context.file.byte_size) do
      try do
        upload_options =
          capability_request_options(
            read_conn,
            file_context.file,
            :upload,
            "/file-capabilities/upload"
          )

        case FileBridge.upload_file(
               resolution.url,
               %{"path" => path, "content_type" => upload_content_type(read_conn)},
               upload_options
             ) do
          :ok ->
            {:ok, %{status: 201, headers: [], raw_body: ""}, read_conn}

          {:error, reason} ->
            {:error, reason, read_conn}
        end
      after
        CapabilitySpool.remove(path)
      end
    else
      {:error, reason, %Plug.Conn{} = read_conn} -> {:error, reason, read_conn}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp reject_capability_content_encoding(conn) do
    case get_req_header(conn, "content-encoding") do
      [] -> :ok
      _present -> {:error, unsupported_capability_content_encoding()}
    end
  end

  defp proxy_download_capability(conn, capability) do
    with {:ok, resolution, file_context} <- resolve_capability(conn, capability, :download),
         request_options =
           capability_request_options(
             conn,
             file_context.file,
             :download,
             "/file-capabilities/download"
           ),
         {:ok, response} <- FileBridge.open_download(resolution.url, request_options),
         :ok <- validate_download_length(response, file_context.file.byte_size) do
      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/octet-stream"}],
         stream: download_stream(response, file_context.file.byte_size)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_capability(conn, capability, kind) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, resolution} <- FileCapability.resolve(capability, kind),
         {:ok, file_context} <- Files.resolve_capability_file(resolution, kind, now),
         :ok <- authorize_present_pool_key(conn, resolution) do
      {:ok, resolution, file_context}
    else
      _invalid -> {:error, invalid_file_capability()}
    end
  end

  defp authorize_present_pool_key(conn, resolution) do
    case get_req_header(conn, "authorization") do
      [] ->
        :ok

      [authorization] ->
        case Access.authenticate_authorization_header(authorization) do
          {:ok, auth} ->
            if secure_equal?(auth.pool.id, resolution.pool_id) and
                 secure_equal?(auth.api_key.id, resolution.api_key_id),
               do: :ok,
               else: {:error, :scope_mismatch}

          {:error, _reason} ->
            {:error, :scope_mismatch}
        end

      _multiple ->
        {:error, :scope_mismatch}
    end
  end

  defp validate_content_length(conn, expected_bytes) do
    case get_req_header(conn, "content-length") do
      [] ->
        :ok

      [value] ->
        case Integer.parse(value) do
          {^expected_bytes, ""} -> :ok
          {bytes, ""} when bytes > expected_bytes -> {:error, upload_too_large()}
          _mismatch -> {:error, upload_size_mismatch()}
        end

      _multiple ->
        {:error, upload_size_mismatch()}
    end
  end

  defp spool_upload(conn, expected_bytes) do
    with {:ok, path, io} <- open_temp_upload() do
      result = read_upload_body(conn, io, expected_bytes, 0)
      File.close(io)

      case result do
        {:ok, read_conn, ^expected_bytes} ->
          {:ok, path, read_conn}

        {:ok, read_conn, _short} ->
          CapabilitySpool.remove(path)
          {:error, upload_size_mismatch(), read_conn}

        {:error, reason, read_conn} ->
          CapabilitySpool.remove(path)
          {:error, reason, read_conn}
      end
    end
  end

  defp open_temp_upload do
    case CapabilitySpool.open() do
      {:ok, path, io} -> {:ok, path, io}
      {:error, :unavailable} -> {:error, upload_unavailable()}
    end
  end

  defp read_upload_body(conn, io, expected_bytes, seen_bytes) do
    remaining = max(expected_bytes - seen_bytes, 0)

    read_opts = [
      length: remaining + 1,
      read_length: min(max(remaining + 1, 1), 64 * 1024),
      read_timeout: OperationalSettings.current().decompression_timeout_ms
    ]

    case Plug.Conn.read_body(conn, read_opts) do
      {:ok, chunk, read_conn} ->
        write_upload_chunk(io, chunk, read_conn, expected_bytes, seen_bytes, false)

      {:more, chunk, read_conn} ->
        write_upload_chunk(io, chunk, read_conn, expected_bytes, seen_bytes, true)

      {:error, :timeout} ->
        {:error, upload_timeout(), conn}

      {:error, _reason} ->
        {:error, upload_unavailable(), conn}
    end
  end

  defp write_upload_chunk(io, chunk, conn, expected_bytes, seen_bytes, more?) do
    next_seen = seen_bytes + byte_size(chunk)

    cond do
      next_seen > expected_bytes ->
        {:error, upload_too_large(), conn}

      IO.binwrite(io, chunk) != :ok ->
        {:error, upload_unavailable(), conn}

      more? ->
        read_upload_body(conn, io, expected_bytes, next_seen)

      true ->
        {:ok, conn, next_seen}
    end
  end

  defp validate_download_length(%Req.Response{} = response, expected_bytes) do
    case Req.Response.get_header(response, "content-length") do
      [] ->
        :ok

      [value] ->
        case Integer.parse(value) do
          {^expected_bytes, ""} ->
            :ok

          _mismatch ->
            cancel_download(response)
            {:error, invalid_download_size()}
        end

      _multiple ->
        cancel_download(response)
        {:error, invalid_download_size()}
    end
  end

  defp download_stream(%Req.Response{body: body}, expected_bytes)
       when is_binary(body) do
    fn conn ->
      if byte_size(body) == expected_bytes do
        case Plug.Conn.chunk(conn, body) do
          {:ok, conn} -> {:ok, conn}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, invalid_download_size()}
      end
    end
  end

  defp download_stream(%Req.Response{body: %Req.Response.Async{}} = response, expected_bytes) do
    fn conn -> relay_download(conn, response, expected_bytes, 0) end
  end

  defp download_stream(response, _expected_bytes) do
    fn _conn ->
      cancel_download(response)
      {:error, invalid_download_size()}
    end
  end

  defp relay_download(
         conn,
         %Req.Response{body: %Req.Response.Async{ref: ref}} = response,
         expected,
         seen
       ) do
    receive do
      {^ref, _part} = message ->
        case Req.parse_message(response, message) do
          {:ok, parts} ->
            relay_download_parts(parts, conn, response, expected, seen)

          {:error, _reason} ->
            cancel_download(response)
            {:error, download_failed()}

          :unknown ->
            relay_download(conn, response, expected, seen)
        end
    after
      @download_receive_timeout_ms ->
        cancel_download(response)
        {:error, download_failed()}
    end
  end

  defp relay_download_parts([], conn, response, expected, seen),
    do: relay_download(conn, response, expected, seen)

  defp relay_download_parts([{:data, data} | rest], conn, response, expected, seen)
       when is_binary(data) do
    next_seen = seen + byte_size(data)

    cond do
      next_seen > expected ->
        cancel_download(response)
        {:error, invalid_download_size()}

      true ->
        case Plug.Conn.chunk(conn, data) do
          {:ok, next_conn} ->
            relay_download_parts(rest, next_conn, response, expected, next_seen)

          {:error, reason} ->
            cancel_download(response)
            {:error, reason}
        end
    end
  end

  defp relay_download_parts([{:trailers, _headers} | rest], conn, response, expected, seen),
    do: relay_download_parts(rest, conn, response, expected, seen)

  defp relay_download_parts([:done | _rest], conn, _response, expected, expected),
    do: {:ok, conn}

  defp relay_download_parts([:done | _rest], _conn, _response, _expected, _seen),
    do: {:error, invalid_download_size()}

  defp relay_download_parts([_unexpected | _rest], _conn, response, _expected, _seen) do
    cancel_download(response)
    {:error, download_failed()}
  end

  defp cancel_download(%Req.Response{body: %Req.Response.Async{}} = response) do
    Req.cancel_async_response(response)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp cancel_download(_response), do: :ok

  defp capability_request_options(conn, file, operation, endpoint) do
    conn
    |> GatewayHelpers.request_opts()
    |> RequestOptions.for_file_bridge(endpoint, %{},
      operation: operation,
      endpoint: endpoint,
      pool_upstream_assignment_id: file.pool_upstream_assignment_id,
      upstream_identity_id: file.upstream_identity_id,
      route_metadata: %{"route_class" => RouteClass.file_upload()}
    )
  end

  defp upload_content_type(conn) do
    conn
    |> get_req_header("content-type")
    |> List.first()
    |> case do
      value when is_binary(value) and byte_size(value) <= 256 -> value
      _value -> "application/octet-stream"
    end
  end

  defp capability_origin(%Plug.Conn{scheme: scheme, host: host, port: port})
       when scheme in [:http, :https] and is_binary(host) and is_integer(port) do
    URI.to_string(%URI{scheme: Atom.to_string(scheme), host: host, port: port})
  end

  defp with_capability_firewall(conn, fun) when is_function(fun, 1) do
    case Firewall.evaluate(conn, OperationalSettings.current()) do
      {conn, %Decision{outcome: :allow}} ->
        fun.(conn)

      {conn, %Decision{} = decision} ->
        :ok = Firewall.observe_denial(decision, :runtime)

        error =
          if decision.reason == :settings_unavailable,
            do: %{
              status: 503,
              code: "settings_unavailable",
              message: "runtime settings are temporarily unavailable"
            },
            else: %{status: 403, code: "access_denied", message: "client IP is not allowed"}

        GatewayHelpers.send_error(conn, error)
    end
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp invalid_upstream_file_url,
    do: %{
      status: 502,
      code: :upstream_file_bridge_invalid_response,
      message: "upstream file bridge returned an invalid URL"
    }

  defp invalid_file_capability,
    do: %{
      status: 404,
      code: :invalid_file_capability,
      message: "file capability is invalid or expired"
    }

  defp upload_too_large,
    do: %{
      status: 413,
      code: :file_upload_too_large,
      message: "file upload exceeds the declared size"
    }

  defp upload_size_mismatch,
    do: %{
      status: 400,
      code: :file_upload_size_mismatch,
      message: "file upload size does not match the declared size"
    }

  defp upload_timeout,
    do: %{status: 408, code: :file_upload_timeout, message: "file upload timed out"}

  defp upload_unavailable,
    do: %{status: 500, code: :file_upload_failed, message: "file upload could not be processed"}

  defp unsupported_capability_content_encoding,
    do: %{
      status: 415,
      code: :unsupported_content_encoding,
      message: "content encoding is not supported"
    }

  defp invalid_download_size,
    do: %{
      status: 502,
      code: :upstream_file_download_failed,
      message: "upstream file download returned an invalid size"
    }

  defp download_failed,
    do: %{
      status: 502,
      code: :upstream_file_download_failed,
      message: "upstream file download failed"
    }

  defp request_options(conn, endpoint, payload) do
    conn
    |> GatewayHelpers.request_opts()
    |> RequestOptions.from_conn_metadata(endpoint, payload)
  end

  defp reject_multipart_create(conn) do
    if multipart_content_type?(conn) do
      {:error,
       %{
         status: 400,
         code: "unsupported_multipart_file_create",
         message: "multipart file create is not supported on this route"
       }}
    else
      :ok
    end
  end

  defp require_json_content_type(conn) do
    if json_content_type?(conn) do
      :ok
    else
      {:error,
       %{
         status: 400,
         code: "invalid_request",
         message: "request body must be a JSON object"
       }}
    end
  end

  defp json_content_type?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> List.first()
    |> case do
      nil -> false
      content_type -> content_type |> String.downcase() |> String.starts_with?("application/json")
    end
  end

  defp multipart_content_type?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> List.first()
    |> case do
      nil ->
        false

      content_type ->
        content_type |> String.downcase() |> String.starts_with?("multipart/form-data")
    end
  end
end
