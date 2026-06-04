defmodule CodexPooler.Gateway.Transports.FileBridgeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Payloads.RequestOptions
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
    path = upload_tempfile!("")
    %{url: upload_url, served_ref: served_ref} = start_invalid_content_length_server!()

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

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
        send(parent, {served_ref, :served})
      end)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listen_socket)
    end)

    %{url: "http://127.0.0.1:#{port}/upload", served_ref: served_ref}
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
        case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, "\r\n" <> headers,
               capture: :all_but_first
             ) do
          [length] -> byte_size(body) >= String.to_integer(length)
          nil -> true
        end

      _incomplete ->
        false
    end
  end
end
