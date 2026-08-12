defmodule CodexPooler.Gateway.Transports.FileBridgeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Transports.FileBridge

  setup do
    old_config = Application.get_env(:codex_pooler, FileBridge, [])
    on_exit(fn -> Application.put_env(:codex_pooler, FileBridge, old_config) end)
    :ok
  end

  test "upload and download connect to a validated pinned address with the signed TLS hostname" do
    test_pid = self()
    stub = {:file_bridge_pinned_target, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      send(test_pid, {:pinned_request, conn.method, conn.host, conn.req_headers})

      case conn.method do
        "PUT" -> Plug.Conn.send_resp(conn, 201, "")
        "GET" -> Plug.Conn.send_resp(conn, 200, "download")
      end
    end)

    resolver = fn
      "signed-files.example.invalid", :inet -> {:ok, [{93, 184, 216, 34}]}
      "signed-files.example.invalid", :inet6 -> {:error, :nxdomain}
    end

    Application.put_env(
      :codex_pooler,
      FileBridge,
      upload_req_options: [plug: {Req.Test, stub}],
      download_req_options: [plug: {Req.Test, stub}],
      signed_url_resolver: resolver
    )

    path = upload_tempfile!("upload")
    signed_url = "https://signed-files.example.invalid/file?sig=secret-query"
    request_options = RequestOptions.build(%{}, "/file-capabilities/download", %{})

    assert :ok =
             FileBridge.upload_file(signed_url, %{
               "path" => path,
               "content_type" => "application/octet-stream"
             })

    assert {:ok, %Req.Response{body: %Req.Response.Async{}}} =
             FileBridge.open_download(signed_url, request_options)

    for method <- ["PUT", "GET"] do
      assert_receive {:pinned_request, ^method, "93.184.216.34", headers}
      assert {"host", "signed-files.example.invalid"} in headers
    end
  end

  test "a private rebinding answer fails locally before the configured adapter is invoked" do
    test_pid = self()
    stub = {:file_bridge_rebinding_target, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn conn ->
      send(test_pid, :unexpected_rebinding_request)
      Plug.Conn.send_resp(conn, 201, "")
    end)

    resolver = fn
      "rebind-files.example.invalid", :inet -> {:ok, [{10, 0, 0, 7}]}
      "rebind-files.example.invalid", :inet6 -> {:error, :nxdomain}
    end

    Application.put_env(
      :codex_pooler,
      FileBridge,
      upload_req_options: [plug: {Req.Test, stub}],
      signed_url_resolver: resolver
    )

    assert {:error, %{code: "upstream_file_upload_failed"}} =
             FileBridge.upload_file(
               "https://rebind-files.example.invalid/file?sig=never-log-this",
               %{
                 "path" => upload_tempfile!("upload"),
                 "content_type" => "application/octet-stream"
               }
             )

    refute_receive :unexpected_rebinding_request
  end

  test "logs upload transport failures with safe request context" do
    request_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    identity_id = Ecto.UUID.generate()
    path = upload_tempfile!("sample upload")
    stub = {:file_bridge_transport_failure, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn _conn -> raise Req.TransportError, reason: :econnrefused end)

    configure_signed_test_adapter!(stub)

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
                   "https://signed-files.example.invalid/upload",
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
    assert log =~ "reason=transport_error"
    refute log =~ "sample upload"
  end

  test "logs upload HTTP protocol failures with safe request context" do
    request_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    identity_id = Ecto.UUID.generate()
    path = upload_tempfile!(String.duplicate("x", 32_768))
    stub = {:file_bridge_http_failure, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn _conn ->
      raise Req.HTTPError, protocol: :http1, reason: :invalid_content_length_header
    end)

    configure_signed_test_adapter!(stub)

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
                   "https://signed-files.example.invalid/upload",
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
    assert log =~ "exception=Req.HTTPError"
    assert log =~ "reason=transport_error"
    refute log =~ "authorization"
  end

  test "never logs an arbitrary transport reason or signed URL query" do
    signature = "SUPER_PRIVATE_FILE_SIGNATURE_SENTINEL"
    reason = "reason-leaks-#{signature}"
    stub = {:file_bridge_secret_transport_reason, System.unique_integer([:positive])}

    Req.Test.stub(stub, fn _conn ->
      raise Req.TransportError, reason: reason
    end)

    resolver = fn
      "signed-secret.example.invalid", :inet -> {:ok, [{93, 184, 216, 34}]}
      "signed-secret.example.invalid", :inet6 -> {:error, :nxdomain}
    end

    Application.put_env(
      :codex_pooler,
      FileBridge,
      upload_req_options: [plug: {Req.Test, stub}],
      signed_url_resolver: resolver
    )

    log =
      capture_log(fn ->
        assert {:error, %{code: "upstream_file_upload_failed"}} =
                 FileBridge.upload_file(
                   "https://signed-secret.example.invalid/file?sig=#{signature}",
                   %{
                     "path" => upload_tempfile!("upload"),
                     "content_type" => "application/octet-stream"
                   },
                   RequestOptions.build(%{}, "/file-capabilities/upload", %{})
                 )
      end)

    assert log =~ "file bridge transport failed"
    assert log =~ "reason=transport_error"
    refute log =~ signature
    refute log =~ reason
    refute log =~ "signed-secret.example.invalid"
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

  defp configure_signed_test_adapter!(stub) do
    resolver = fn
      "signed-files.example.invalid", :inet -> {:ok, [{93, 184, 216, 34}]}
      "signed-files.example.invalid", :inet6 -> {:error, :nxdomain}
    end

    Application.put_env(
      :codex_pooler,
      FileBridge,
      upload_req_options: [plug: {Req.Test, stub}],
      signed_url_resolver: resolver
    )
  end
end
