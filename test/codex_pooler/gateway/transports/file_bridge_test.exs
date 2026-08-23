defmodule CodexPooler.Gateway.Transports.FileBridgeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Payloads.{RequestOptions, TransportEnvelope}
  alias CodexPooler.Gateway.Transports.FileBridge

  test "logs upload transport failures with safe request context" do
    request_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    identity_id = Ecto.UUID.generate()
    path = upload_tempfile!("sample upload")

    request_options =
      %{request_id: request_id}
      |> RequestOptions.build("/v1/files", %{})
      |> RequestOptions.put_file_bridge(
        operation: :upload,
        endpoint: "/v1/files/upload",
        pool_upstream_assignment_id: assignment_id,
        upstream_identity_id: identity_id,
        route_metadata: %{"route_class" => "file_upload", "routing_strategy" => "test_strategy"}
      )

    log =
      capture_log(fn ->
        assert {:error, %{code: "upstream_file_upload_failed"}} =
                 FileBridge.upload_file(
                   "http://127.0.0.1:1/upload",
                   %{"path" => path, "content_type" => "text/plain"},
                   request_options
                 )
      end)

    assert log =~ "file bridge transport failed"
    assert log =~ "operation=upload"
    assert log =~ "endpoint=/v1/files/upload"
    assert log =~ "request_id=#{request_id}"
    assert log =~ "pool_upstream_assignment_id=#{assignment_id}"
    assert log =~ "upstream_identity_id=#{identity_id}"
    assert log =~ "route_class=file_upload"
    assert log =~ "routing_strategy=test_strategy"
    assert log =~ "exception="
    assert log =~ "reason="
    refute log =~ "sample upload"
  end

  test "logs upload HTTP protocol failures with safe request context" do
    request_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    identity_id = Ecto.UUID.generate()
    path = upload_tempfile!(String.duplicate("x", 32_768))

    %{url: upload_url, served_ref: served_ref, server_pid: server_pid} =
      start_invalid_content_length_server!()

    request_options =
      %{request_id: request_id}
      |> RequestOptions.build("/v1/files", %{})
      |> RequestOptions.put_file_bridge(
        operation: :upload,
        endpoint: "/v1/files/upload",
        pool_upstream_assignment_id: assignment_id,
        upstream_identity_id: identity_id,
        route_metadata: %{"route_class" => "file_upload", "routing_strategy" => "test_strategy"}
      )

    log =
      capture_log(fn ->
        assert {:error, %{code: "upstream_file_upload_failed"}} =
                 FileBridge.upload_file(
                   upload_url,
                   %{"path" => path, "content_type" => "text/plain"},
                   request_options
                 )
      end)

    assert_receive {^served_ref, :served}, 1_000

    assert log =~ "file bridge transport failed"
    assert log =~ "operation=upload"
    assert log =~ "endpoint=/v1/files/upload"
    assert log =~ "request_id=#{request_id}"
    assert log =~ "pool_upstream_assignment_id=#{assignment_id}"
    assert log =~ "upstream_identity_id=#{identity_id}"
    assert log =~ "route_class=file_upload"
    assert log =~ "routing_strategy=test_strategy"
    assert log =~ "exception=Req.HTTPError"
    assert log =~ "reason=invalid_content_length_header"
    refute log =~ "authorization"
    send(server_pid, :close)
  end

  test "presigned upload sends only storage protocol headers" do
    contents = "synthetic direct upload bytes"
    path = upload_tempfile!(contents)

    %{url: upload_url, served_ref: served_ref} = start_upload_capture_server!()

    request_options =
      %{request_id: Ecto.UUID.generate()}
      |> RequestOptions.build("/v1/files", %{})
      |> RequestOptions.put_file_bridge(
        operation: :upload,
        endpoint: "/v1/files/upload",
        forwarded_headers: [
          {"x-openai-internal-codex-residency", "must-not-reach-storage"}
        ]
      )

    log =
      capture_log(fn ->
        assert :ok =
                 FileBridge.upload_file(
                   upload_url,
                   %{"path" => path, "content_type" => "text/plain"},
                   request_options
                 )
      end)

    assert_receive {^served_ref, request}, 1_000
    {request_head, encoded_request_body} = split_raw_http_request!(request)
    request_body = decode_request_body!(request_head, encoded_request_body)

    assert String.starts_with?(request_head, "PUT /upload HTTP/1.1\r\n")
    assert raw_header_values(request_head, "content-type") == ["text/plain"]

    assert raw_header_values(request_head, "content-length") == [
             Integer.to_string(byte_size(contents))
           ]

    assert raw_header_values(request_head, "transfer-encoding") == []
    assert raw_header_values(request_head, "x-ms-blob-type") == ["BlockBlob"]
    assert raw_header_values(request_head, "x-openai-internal-codex-residency") == []
    assert raw_header_values(request_head, "authorization") == []
    assert byte_size(request_body) == byte_size(contents)
    assert :crypto.hash(:sha256, request_body) == :crypto.hash(:sha256, contents)
    refute log =~ "file bridge transport failed"
  end

  test "file control-plane envelope removes mixed-case residency forwarding" do
    headers =
      TransportEnvelope.headers(
        %{chatgpt_account_id: "synthetic-account"},
        residency_token("file-region-authoritative"),
        [{"accept", "application/json"}],
        forwarded_headers: [
          {"X-OpenAI-Internal-Codex-Residency", "caller-copy-one"},
          {"x-OPENAI-internal-codex-residency", "caller-copy-two"}
        ]
      )

    assert header_values(headers, "x-openai-internal-codex-residency") == [
             "file-region-authoritative"
           ]
  end

  defp upload_tempfile!(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-upload-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, contents)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end

  defp residency_token(value) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)

    payload =
      Base.url_encode64(Jason.encode!(%{"chatgpt_compute_residency" => value}), padding: false)

    Enum.join([header, payload, "signature"], ".")
  end

  defp header_values(headers, expected_name) do
    for {name, value} <- headers, String.downcase(name) == expected_name, do: value
  end

  defp start_invalid_content_length_server! do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    parent = self()
    served_ref = make_ref()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        _request = read_raw_http_request(socket)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: application/json\r\n",
            "content-length: +0\r\n",
            "connection: close\r\n\r\n"
          ])

        send(parent, {served_ref, :served})

        receive do
          :close -> :ok
        end

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listen_socket)
    end)

    %{
      url: "http://127.0.0.1:#{port}/upload",
      served_ref: served_ref,
      server_pid: pid
    }
  end

  defp start_upload_capture_server! do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    parent = self()
    served_ref = make_ref()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        request = read_raw_http_request(socket)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-length: 0\r\n",
            "connection: close\r\n\r\n"
          ])

        send(parent, {served_ref, request})
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listen_socket)
    end)

    %{url: "http://127.0.0.1:#{port}/upload", served_ref: served_ref}
  end

  defp split_raw_http_request!(request) do
    case :binary.split(request, "\r\n\r\n") do
      [head, body] -> {head <> "\r\n", body}
      _other -> flunk("captured upload request was incomplete")
    end
  end

  defp raw_header_values(request_head, expected_name) do
    request_head
    |> String.split("\r\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(&matching_header_values(&1, expected_name))
  end

  defp matching_header_values(line, expected_name) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> matching_header_value(name, value, expected_name)
      _other -> []
    end
  end

  defp matching_header_value(name, value, expected_name) do
    if String.downcase(name) == expected_name, do: [String.trim(value)], else: []
  end

  defp decode_request_body!(request_head, body) do
    if raw_header_values(request_head, "transfer-encoding") == ["chunked"] do
      decode_chunked_body!(body, [])
    else
      body
    end
  end

  defp decode_chunked_body!("0\r\n\r\n", chunks),
    do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_chunked_body!(body, chunks) do
    with [hex_size, rest] <- :binary.split(body, "\r\n"),
         {size, ""} <- Integer.parse(hex_size, 16),
         <<chunk::binary-size(^size), "\r\n", remaining::binary>> <- rest do
      decode_chunked_body!(remaining, [chunk | chunks])
    else
      _other -> flunk("captured upload request had invalid chunk framing")
    end
  end

  defp read_raw_http_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        acc = acc <> data

        if raw_http_request_complete?(acc) do
          acc
        else
          read_raw_http_request(socket, acc)
        end

      {:error, _reason} ->
        acc
    end
  end

  defp raw_http_request_complete?(data) do
    case :binary.split(data, "\r\n\r\n") do
      [headers, body] ->
        if chunked_request?(headers) do
          String.ends_with?(body, "0\r\n\r\n")
        else
          content_length_body_complete?(headers, body)
        end

      _incomplete ->
        false
    end
  end

  defp chunked_request?(headers) do
    Regex.match?(~r/\r\ntransfer-encoding:\s*chunked(?:\r\n|$)/i, "\r\n" <> headers)
  end

  defp content_length_body_complete?(headers, body) do
    case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, "\r\n" <> headers, capture: :all_but_first) do
      [length] -> byte_size(body) >= String.to_integer(length)
      nil -> true
    end
  end
end
