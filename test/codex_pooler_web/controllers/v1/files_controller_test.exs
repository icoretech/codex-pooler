defmodule CodexPoolerWeb.V1.FilesControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Transports.FileBridge
  alias CodexPooler.Repo

  setup do
    old_files_config = Application.get_env(:codex_pooler, Files, [])
    old_bridge_config = Application.get_env(:codex_pooler, FileBridge, [])

    Application.put_env(:codex_pooler, Files,
      max_file_size_bytes: 64,
      file_ttl_seconds: 60
    )

    Application.put_env(:codex_pooler, FileBridge,
      finalize_retry_timeout_ms: 1_000,
      finalize_retry_interval_ms: 0
    )

    on_exit(fn ->
      Application.put_env(:codex_pooler, Files, old_files_config)
      Application.put_env(:codex_pooler, FileBridge, old_bridge_config)
    end)

    :ok
  end

  @tag :multipart_lifecycle
  test "multipart create uploads bytes upstream, finalizes metadata, and exposes scoped file objects",
       %{
         conn: conn
       } do
    setup = active_api_key_fixture()
    file_id = "file_v1_lifecycle_#{System.unique_integer([:positive])}"
    file_contents = "synthetic v1 file bytes"
    file_size = byte_size(file_contents)
    upload_url = stub_upload_put(file_id)

    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        file_name: "v1-lifecycle.txt",
        mime_type: "text/plain",
        upload_url: upload_url
      )
    )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_v1_file_lifecycle",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "v1-file-lifecycle-token"
    })

    upload = upload_fixture("v1-lifecycle.txt", "text/plain", file_contents)

    create_conn =
      conn
      |> auth(setup)
      |> post("/v1/files", %{"purpose" => "user_data", "file" => upload})

    assert %{
             "id" => ^file_id,
             "object" => "file",
             "bytes" => ^file_size,
             "filename" => "v1-lifecycle.txt",
             "purpose" => "user_data",
             "status" => "uploaded"
           } = create_body = json_response(create_conn, 200)

    refute Map.has_key?(create_body, "upload_url")
    refute inspect(create_body) =~ upload_url

    file = Repo.get_by!(FileRecord, file_id: file_id)
    assert file.pool_id == setup.pool.id
    assert file.api_key_id == setup.api_key.id
    assert file.purpose == "user_data"
    assert file.status == "uploaded"
    assert file.finalize_status == "succeeded"
    assert file.byte_size == file_size
    refute inspect(file) =~ file_contents
    refute inspect(file) =~ upload_url

    show_conn = build_conn() |> auth(setup) |> get("/v1/files/#{file_id}")
    assert json_response(show_conn, 200)["id"] == file_id

    list_conn = build_conn() |> auth(setup) |> get("/v1/files")
    assert %{"object" => "list", "data" => [listed]} = json_response(list_conn, 200)
    assert listed["id"] == file_id

    content_conn = build_conn() |> auth(setup) |> get("/v1/files/#{file_id}/content")
    assert json_response(content_conn, 404)["error"]["code"] == "unsupported_endpoint"

    binary_content_conn =
      build_conn()
      |> put_req_header("accept", "application/binary")
      |> auth(setup)
      |> get("/v1/files/#{file_id}/content")

    assert json_response(binary_content_conn, 404)["error"]["code"] == "unsupported_endpoint"

    delete_conn = build_conn() |> auth(setup) |> delete("/v1/files/#{file_id}")
    assert json_response(delete_conn, 404)["error"]["code"] == "unsupported_endpoint"

    assert [create_request, finalize_request] = FakeUpstream.requests(upstream)
    assert create_request.path == "/backend-api/files"
    assert finalize_request.path == "/backend-api/files/#{file_id}/uploaded"
    assert_upload_put(file_id, "/upload/#{file_id}", file_contents, "text/plain")

    requests = Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)

    public_create_request =
      Enum.find(
        requests,
        &(&1.endpoint == "/v1/files" and &1.status == "succeeded" and
            &1.request_metadata["operation"] == "uploaded")
      )

    assert public_create_request

    assert get_in(public_create_request.request_metadata, ["routing", "route_class"]) ==
             "file_upload"

    assert Enum.any?(requests, &(&1.endpoint == "/v1/files/content" and &1.status == "failed"))
    assert Enum.any?(requests, &(&1.endpoint == "/v1/files/delete" and &1.status == "failed"))
    refute inspect(requests) =~ file_contents
    refute inspect(requests) =~ setup.raw_key
    refute inspect(requests) =~ upload_url
  end

  @tag :unauthorized_file
  test "missing and cross-key file access return OpenAI-shaped not found without leaking content",
       %{
         conn: conn
       } do
    first = active_api_key_fixture()
    second = active_api_key_fixture(first.pool)
    file_id = "file_v1_owned_#{System.unique_integer([:positive])}"
    file_contents = "owned v1 file bytes"
    upload_url = stub_upload_put(file_id)

    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        file_name: "owned.txt",
        upload_url: upload_url
      )
    )

    active_upstream_assignment_fixture(first.pool, %{
      chatgpt_account_id: "acct_v1_file_owned",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "v1-file-owned-token"
    })

    create_conn =
      conn
      |> auth(first)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("owned.txt", "text/plain", file_contents)
      })

    assert json_response(create_conn, 200)["id"] == file_id
    assert_upload_put(file_id, "/upload/#{file_id}", file_contents, "text/plain")

    denied_show = build_conn() |> auth(second) |> get("/v1/files/#{file_id}")
    assert_openai_error(denied_show, 404, code: "file_not_found", message: "file was not found")

    denied_content = build_conn() |> auth(second) |> get("/v1/files/#{file_id}/content")

    assert_openai_error(denied_content, 404,
      code: "file_not_found",
      message: "file was not found"
    )

    missing = build_conn() |> auth(first) |> get("/v1/files/file_missing_private_token")
    assert_openai_error(missing, 404, code: "file_not_found", message: "file was not found")

    requests = Repo.all(from request in Request, where: request.pool_id == ^first.pool.id)
    refute inspect(requests) =~ file_contents
    refute inspect(requests) =~ "file_missing_private_token"
  end

  test "invalid purpose and oversized multipart create fail before upstream calls or file rows",
       %{conn: conn} do
    setup = active_api_key_fixture()
    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: "file_invalid_v1"))

    active_upstream_assignment_fixture(setup.pool, %{
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "v1-file-invalid-token"
    })

    file_count_before = Repo.aggregate(FileRecord, :count)
    request_count_before = Repo.aggregate(Request, :count)

    invalid_purpose =
      conn
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "unsupported-purpose",
        "file" => upload_fixture("invalid.txt", "text/plain", "invalid bytes")
      })

    assert_openai_error(invalid_purpose, 400,
      code: "invalid_request",
      param: "purpose",
      message: "file purpose is not supported"
    )

    oversized =
      build_conn()
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("large.txt", "text/plain", String.duplicate("x", 65))
      })

    assert_openai_error(oversized, 400,
      code: "invalid_request",
      param: "file_size",
      message: "file_size exceeds the supported limit"
    )

    assert Repo.aggregate(FileRecord, :count) == file_count_before
    assert Repo.aggregate(Request, :count) == request_count_before
    assert FakeUpstream.requests(upstream) == []
  end

  @tag :file_bridge_upload_transport
  test "upstream direct PUT failure records failed public create and abandons file", %{conn: conn} do
    setup = active_api_key_fixture()
    file_id = "file_v1_put_failure_#{System.unique_integer([:positive])}"
    file_contents = "synthetic put failure bytes"
    upload_url = stub_upload_put(file_id, status: 415, response_body: "unsupported media type")

    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        upload_url: upload_url
      )
    )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_v1_file_put_failure",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "v1-file-put-failure-token"
    })

    conn =
      conn
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("put-failure.txt", "text/plain", file_contents)
      })

    assert_openai_error(conn, 502,
      code: "upstream_file_upload_failed",
      message: "upstream file upload failed with status 415"
    )

    assert [create_request] = FakeUpstream.requests(upstream)
    assert create_request.path == "/backend-api/files"
    assert_upload_put(file_id, "/upload/#{file_id}", file_contents, "text/plain")

    file = Repo.get_by!(FileRecord, file_id: file_id)
    assert file.status == "abandoned"
    assert file.finalize_status == "failed"
    refute inspect(file) =~ file_contents
    refute inspect(file) =~ upload_url
    refute inspect(file) =~ "unsupported media type"

    requests = Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)
    refute Enum.any?(requests, &(&1.endpoint == "/v1/files" and &1.status == "succeeded"))

    assert Enum.any?(requests, fn request ->
             request.endpoint == "/v1/files" and request.status == "failed" and
               request.response_status_code == 502 and
               request.request_metadata["error_code"] == "upstream_file_upload_failed"
           end)

    refute inspect(requests) =~ file_contents
    refute inspect(requests) =~ setup.raw_key
    refute inspect(requests) =~ upload_url
    refute inspect(requests) =~ "unsupported media type"
  end

  @tag :file_bridge_upload_transport
  test "direct upload does not follow 307 redirect to http loopback", %{conn: conn} do
    assert_upload_redirect_not_followed(conn, 307, "http")
  end

  @tag :file_bridge_upload_transport
  test "direct upload does not follow 302 redirect to https loopback", %{conn: conn} do
    assert_upload_redirect_not_followed(conn, 302, "https")
  end

  @tag :file_bridge_upload_transport
  test "direct upload sends only safe headers and bytes to public HTTPS upload URL", %{
    conn: conn
  } do
    setup = active_api_key_fixture()
    file_id = "file_v1_safe_upload_headers_#{System.unique_integer([:positive])}"
    upload_path = "/upload/#{file_id}"
    file_contents = ~s({"safe":"upload","bytes":true})
    access_token = "v1-file-safe-upload-upstream-token"
    upload_url = stub_upload_put(file_id)

    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        upload_url: upload_url
      )
    )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_v1_file_safe_upload_headers",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: access_token
    })

    conn =
      conn
      |> put_req_header("cookie", "client-cookie-sentinel=1")
      |> put_req_header("x-raw-client-header", "raw-client-header-sentinel")
      |> put_req_header("x-pool-api-key", setup.raw_key)
      |> put_req_header("x-upstream-access-token", access_token)
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("safe-upload.json", "application/json", file_contents)
      })

    assert %{"id" => ^file_id, "status" => "uploaded"} = json_response(conn, 200)

    assert_receive {:upload_put, ^file_id, "PUT", ^upload_path, ^file_contents, headers},
                   1_000

    assert_exact_safe_upload_headers(headers, "application/json")

    header_text = inspect(headers)
    refute header_text =~ setup.raw_key
    refute header_text =~ access_token
    refute header_text =~ "client-cookie-sentinel"
    refute header_text =~ "raw-client-header-sentinel"

    assert [create_request, finalize_request] = FakeUpstream.requests(upstream)
    assert create_request.path == "/backend-api/files"
    assert finalize_request.path == "/backend-api/files/#{file_id}/uploaded"
  end

  @tag :upload_url_policy
  test "unsafe upstream upload URL create response fails before direct PUT or file row", %{
    conn: conn
  } do
    setup = active_api_key_fixture()
    file_id = "file_v1_unsafe_upload_url_#{System.unique_integer([:positive])}"
    file_contents = "synthetic unsafe upload url bytes"
    injected_header = "Host:127.0.0.1"
    unsafe_upload_url = "https://upload.example.invalid/upload/#{file_id}\r\n#{injected_header}"
    stub_upload_put(file_id)

    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        upload_url: unsafe_upload_url
      )
    )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_v1_file_unsafe_upload_url",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "v1-file-unsafe-upload-url-token"
    })

    {conn, log} =
      with_log(fn ->
        conn
        |> auth(setup)
        |> post("/v1/files", %{
          "purpose" => "user_data",
          "file" => upload_fixture("put-transport.txt", "text/plain", file_contents)
        })
      end)

    refute log =~ "file bridge transport failed"
    refute log =~ "operation=upload"
    refute log =~ "endpoint=/v1/files/upload"
    refute log =~ file_contents
    refute log =~ setup.raw_key
    refute log =~ unsafe_upload_url
    refute log =~ injected_header

    assert_openai_error(conn, 502,
      code: "upstream_file_bridge_invalid_response",
      message: "upstream file create returned an invalid upload_url"
    )

    assert [%{path: "/backend-api/files"}] = FakeUpstream.requests(upstream)
    refute_received {:upload_put, ^file_id, _method, _path, _body, _headers}

    refute Repo.get_by(FileRecord, file_id: file_id)

    requests = Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)

    refute Enum.any?(
             requests,
             &(&1.endpoint == "/v1/files" and &1.status == "succeeded")
           )

    refute inspect(requests) =~ file_contents
    refute inspect(requests) =~ setup.raw_key
    refute inspect(requests) =~ unsafe_upload_url
    refute inspect(requests) =~ injected_header
  end

  defp upload_fixture(filename, content_type, contents) do
    path =
      Path.join(System.tmp_dir!(), "codex-pooler-v1-file-#{System.unique_integer([:positive])}")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp stub_upload_put(file_id, opts \\ []) do
    response_status = Keyword.get(opts, :status, 201)
    response_body = Keyword.get(opts, :response_body, "")
    stub_name = {__MODULE__, :upload_put, file_id}
    test_pid = self()

    Req.Test.stub(stub_name, fn conn ->
      send(test_pid, {
        :upload_put,
        file_id,
        conn.method,
        conn.request_path,
        Req.Test.raw_body(conn),
        conn.req_headers
      })

      conn
      |> Plug.Conn.put_status(response_status)
      |> Req.Test.text(response_body)
    end)

    current_bridge_config = Application.get_env(:codex_pooler, FileBridge, [])

    Application.put_env(
      :codex_pooler,
      FileBridge,
      Keyword.merge(current_bridge_config, upload_req_options: [plug: {Req.Test, stub_name}])
    )

    "https://upload.example.invalid/upload/#{file_id}?sig=fake-upload"
  end

  defp stub_upload_redirect(file_id, status, location) do
    stub_name = {__MODULE__, :upload_redirect, file_id}
    test_pid = self()

    Req.Test.stub(stub_name, fn conn ->
      case conn.request_path do
        "/upload/" <> _ ->
          send(test_pid, {
            :upload_redirect,
            file_id,
            conn.method,
            conn.scheme,
            conn.host,
            conn.request_path,
            Req.Test.raw_body(conn),
            conn.req_headers
          })

          conn
          |> Plug.Conn.put_status(status)
          |> Plug.Conn.put_resp_header("location", location)
          |> Req.Test.text("redirect target blocked")

        "/private/" <> _ ->
          send(test_pid, {
            :upload_private_target,
            file_id,
            conn.method,
            conn.scheme,
            conn.host,
            conn.request_path,
            Req.Test.raw_body(conn),
            conn.req_headers
          })

          conn
          |> Plug.Conn.put_status(204)
          |> Req.Test.text("")

        _path ->
          send(test_pid, {:upload_unexpected_path, file_id, conn.request_path})

          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.text("")
      end
    end)

    current_bridge_config = Application.get_env(:codex_pooler, FileBridge, [])

    Application.put_env(
      :codex_pooler,
      FileBridge,
      Keyword.merge(current_bridge_config, upload_req_options: [plug: {Req.Test, stub_name}])
    )

    "https://upload.example.invalid/upload/#{file_id}?sig=fake-upload"
  end

  defp assert_upload_put(file_id, path, body, content_type) do
    assert_receive {:upload_put, ^file_id, "PUT", ^path, ^body, headers}, 1_000
    assert header!(headers, "content-type") == content_type
    assert header!(headers, "x-ms-blob-type") == "BlockBlob"
    refute Enum.any?(headers, fn {name, _value} -> name in ["authorization", "cookie"] end)
  end

  defp assert_upload_redirect_not_followed(conn, status, scheme) do
    setup = active_api_key_fixture()
    file_id = "file_v1_upload_redirect_#{status}_#{System.unique_integer([:positive])}"
    upload_path = "/upload/#{file_id}"
    file_contents = "synthetic redirect upload bytes #{status}"
    private_location = "#{scheme}://127.0.0.1/private/#{file_id}"
    upload_url = stub_upload_redirect(file_id, status, private_location)

    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        upload_url: upload_url
      )
    )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_v1_file_upload_redirect_#{status}",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "v1-file-upload-redirect-token-#{status}"
    })

    conn =
      conn
      |> put_req_header("cookie", "redirect-cookie-sentinel=1")
      |> put_req_header("x-raw-client-header", "redirect-client-header-sentinel")
      |> auth(setup)
      |> post("/v1/files", %{
        "purpose" => "user_data",
        "file" => upload_fixture("redirect.txt", "text/plain", file_contents)
      })

    assert_openai_error(conn, 502,
      code: "upstream_file_upload_failed",
      message: "upstream file upload failed with status #{status}"
    )

    assert_receive {:upload_redirect, ^file_id, "PUT", :https, "upload.example.invalid",
                    ^upload_path, ^file_contents, headers},
                   1_000

    assert_exact_safe_upload_headers(headers, "text/plain")

    refute_received {:upload_private_target, ^file_id, _method, _scheme, _host, _path, _body,
                     _headers}

    assert [%{path: "/backend-api/files"}] = FakeUpstream.requests(upstream)

    file = Repo.get_by!(FileRecord, file_id: file_id)
    assert file.status == "abandoned"
    assert file.finalize_status == "failed"

    requests = Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)
    refute Enum.any?(requests, &(&1.endpoint == "/v1/files" and &1.status == "succeeded"))
    refute inspect(requests) =~ file_contents
    refute inspect(requests) =~ setup.raw_key
    refute inspect(requests) =~ upload_url
    refute inspect(requests) =~ private_location
  end

  defp assert_exact_safe_upload_headers(headers, content_type) do
    assert headers |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [
             "content-type",
             "x-ms-blob-type"
           ]

    assert header!(headers, "content-type") == content_type
    assert header!(headers, "x-ms-blob-type") == "BlockBlob"
  end

  defp header!(headers, name) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      _other -> nil
    end)
    |> case do
      nil -> flunk("missing header #{name}")
      value -> value
    end
  end

  defp assert_openai_error(conn, status, opts) do
    assert %{"error" => error} = json_response(conn, status)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == Keyword.fetch!(opts, :code)
    assert error["message"] == Keyword.fetch!(opts, :message)
    assert error["param"] == Keyword.get(opts, :param)
  end
end
