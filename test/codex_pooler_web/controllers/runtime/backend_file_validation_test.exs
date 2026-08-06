defmodule CodexPoolerWeb.Runtime.BackendFileValidationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Transports.FileBridge
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Plugs.BackendFilesMultipartGuard
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Path, as: IngressPath

  setup do
    old_config = Application.get_env(:codex_pooler, Files, [])
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
      Application.put_env(:codex_pooler, Files, old_config)
      Application.put_env(:codex_pooler, FileBridge, old_bridge_config)
    end)

    :ok
  end

  test "authenticated backend file create rejects malformed JSON before upstream dispatch", %{
    conn: _conn
  } do
    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: "file_malformed_json"))
    setup = active_api_key_fixture()

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_malformed_json_create",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "malformed-json-create-token"
    })

    request_count_before = Repo.aggregate(Request, :count)

    conn =
      Plug.Test.conn("POST", "/backend-api/files", ~s({"file_name":))
      |> put_req_header("content-type", "application/json")
      |> auth(setup)
      |> @endpoint.call(@endpoint.init([]))

    assert %{
             "error" => %{
               "code" => "invalid_request",
               "message" => "request body must be valid JSON"
             }
           } = json_response(conn, 400)

    assert FakeUpstream.requests(upstream) == []
    assert Repo.aggregate(Request, :count) == request_count_before
    assert Repo.aggregate(FileRecord, :count) == 0
  end

  test "rejects JSON two-step create when no upstream assignment is available", %{conn: conn} do
    setup = active_api_key_fixture()
    sensitive_filename = "private-json-name.txt"
    file_count_before = Repo.aggregate(FileRecord, :count)

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => sensitive_filename,
        "file_size" => 12,
        "use_case" => "codex"
      })

    response = json_response(conn, 503)
    assert response["error"]["code"] == "no_eligible_backend"
    refute Map.has_key?(response, "upload_url")
    refute Map.has_key?(response, "download_url")
    refute inspect(response) =~ sensitive_filename
    assert Repo.aggregate(FileRecord, :count) == file_count_before

    failed_request = Repo.one!(from request in Request, where: request.pool_id == ^setup.pool.id)
    assert failed_request.status == "failed"
    assert failed_request.transport == "http_json"
    assert failed_request.request_metadata["error_code"] == "no_eligible_backend"
    refute inspect(failed_request.request_metadata) =~ sensitive_filename
    refute inspect(failed_request.request_metadata) =~ "upload_url"
    refute inspect(failed_request.request_metadata) =~ "download_url"
  end

  test "logs sanitized file bridge transport exceptions", %{conn: conn} do
    setup = active_api_key_fixture()
    sensitive_filename = "private-transport-name.txt"
    sensitive_token = "sensitive-file-transport-token"

    %{assignment: assignment, identity: identity} =
      active_upstream_assignment_fixture(setup.pool, %{
        access_token: sensitive_token,
        metadata: %{"base_url" => "http://127.0.0.1:1"}
      })

    logs =
      capture_log(fn ->
        conn =
          conn
          |> auth(setup)
          |> put_req_header("content-type", "application/json")
          |> post(~p"/backend-api/files", %{
            "file_name" => sensitive_filename,
            "file_size" => 12,
            "use_case" => "codex"
          })

        assert json_response(conn, 502)["error"]["code"] == "upstream_request_failed"
      end)

    assert logs =~ "file bridge transport failed"
    assert logs =~ "operation=create"
    assert logs =~ "endpoint=/backend-api/files"
    assert logs =~ "pool_upstream_assignment_id=#{assignment.id}"
    assert logs =~ "upstream_identity_id=#{identity.id}"
    assert logs =~ "exception="
    refute logs =~ sensitive_filename
    refute logs =~ sensitive_token
    refute logs =~ "authorization"
  end

  @tag :file_bridge_auth_before_upstream
  test "unauthenticated create fails before file side effects", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: "file_unauth_create"))

    setup = active_api_key_fixture()

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_unauthenticated_create",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "unauthenticated-create-token"
    })

    file_count_before = Repo.aggregate(FileRecord, :count)
    request_count_before = Repo.aggregate(Request, :count)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "unauthenticated.txt",
        "file_size" => 20,
        "use_case" => "codex"
      })

    assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
    assert Repo.aggregate(FileRecord, :count) == file_count_before
    assert Repo.aggregate(Request, :count) == request_count_before
    assert FakeUpstream.requests(upstream) == []
  end

  @tag :file_bridge_auth_before_upstream
  test "unauthenticated finalize fails before upstream side effects", %{conn: conn} do
    setup = active_api_key_fixture()

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_unauth_finalize",
          file_name: "unauth-finalize.txt",
          mime_type: "text/plain"
        )
      )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_unauthenticated_finalize",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "unauthenticated-finalize-token"
    })

    create_conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "unauth-finalize.txt",
        "file_size" => 20,
        "use_case" => "codex"
      })

    file_id = json_response(create_conn, 200)["file_id"]
    request_count_before = Repo.aggregate(Request, :count)

    finalize_conn = post(build_conn(), ~p"/backend-api/files/#{file_id}/uploaded", %{})

    assert json_response(finalize_conn, 401)["error"]["code"] == "api_key_missing"
    assert Repo.aggregate(Request, :count) == request_count_before
    assert [%{path: "/backend-api/files"}] = FakeUpstream.requests(upstream)
    assert Repo.get_by!(FileRecord, file_id: file_id).status == "pending_upload"
  end

  test "rejects expired file finalize", %{conn: conn} do
    setup = active_api_key_fixture()

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_expired_bridge",
          file_name: "expired.txt",
          mime_type: "text/plain"
        )
      )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_file_expired_bridge",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "file-expired-bridge-token"
    })

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "expired.txt",
        "file_size" => 13,
        "use_case" => "codex"
      })

    file_id = json_response(conn, 200)["file_id"]

    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    Repo.get_by!(FileRecord, file_id: file_id)
    |> Ecto.Changeset.change(%{expires_at: expired_at})
    |> Repo.update!()

    conn =
      build_conn()
      |> auth(setup)
      |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

    assert json_response(conn, 410)["error"]["code"] == "file_expired"
    assert Repo.get_by!(FileRecord, file_id: file_id).status == "expired"

    failed_request =
      Repo.one!(
        from request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.endpoint == "/backend-api/files/uploaded",
          order_by: [desc: request.admitted_at],
          limit: 1
      )

    assert failed_request.status == "failed"
    assert failed_request.response_status_code == 410
    assert failed_request.request_metadata["error_code"] == "file_expired"
  end

  test "rejects oversized files before persistence", %{conn: conn} do
    setup = active_api_key_fixture()
    file_count_before = Repo.aggregate(FileRecord, :count)
    request_count_before = Repo.aggregate(Request, :count)

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "large.txt",
        "file_size" => 65,
        "use_case" => "codex"
      })

    assert json_response(conn, 400)["error"]["code"] == "invalid_request"
    assert Repo.aggregate(FileRecord, :count) == file_count_before
    assert Repo.aggregate(Request, :count) == request_count_before
  end

  test "rejects unsupported use_case", %{conn: conn} do
    setup = active_api_key_fixture()
    file_count_before = Repo.aggregate(FileRecord, :count)
    request_count_before = Repo.aggregate(Request, :count)

    purpose_conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "purpose.txt",
        "file_size" => 4,
        "use_case" => "user_data"
      })

    assert json_response(purpose_conn, 400)["error"]["code"] == "invalid_request"
    assert Repo.aggregate(FileRecord, :count) == file_count_before
    assert Repo.aggregate(Request, :count) == request_count_before
  end

  @tag :rejects_multipart_without_storage
  test "rejects multipart without local storage side effects" do
    setup = active_api_key_fixture()

    with_isolated_plug_tmpdir(fn tmp_root ->
      file_count_before = Repo.aggregate(FileRecord, :count)
      request_count_before = Repo.aggregate(Request, :count)
      audit_count_before = Repo.aggregate(AuditEvent, :count)

      conn =
        Plug.Test.conn(
          "POST",
          "/backend-api/files",
          multipart_body("private-upload.txt", "private multipart bytes")
        )
        |> put_req_header("content-type", "multipart/form-data; boundary=#{multipart_boundary()}")
        |> auth(setup)
        |> @endpoint.call(@endpoint.init([]))

      response = json_response(conn, 400)
      assert response["error"]["code"] == "unsupported_multipart_file_create"
      refute inspect(response) =~ "private-upload.txt"
      assert Repo.aggregate(FileRecord, :count) == file_count_before
      assert Repo.aggregate(Request, :count) == request_count_before
      assert Repo.aggregate(AuditEvent, :count) == audit_count_before
      assert tmpdir_paths(tmp_root) == []
    end)
  end

  test "unauthenticated multipart create fails with api_key_missing before parser side effects" do
    with_isolated_plug_tmpdir(fn tmp_root ->
      file_count_before = Repo.aggregate(FileRecord, :count)
      request_count_before = Repo.aggregate(Request, :count)

      conn =
        Plug.Test.conn(
          "POST",
          "/backend-api/files",
          multipart_body("unauthenticated.txt", "unauthenticated multipart body")
        )
        |> put_req_header("content-type", "multipart/form-data; boundary=#{multipart_boundary()}")
        |> @endpoint.call(@endpoint.init([]))

      assert json_response(conn, 401)["error"]["code"] == "api_key_missing"
      assert Repo.aggregate(FileRecord, :count) == file_count_before
      assert Repo.aggregate(Request, :count) == request_count_before
      assert tmpdir_paths(tmp_root) == []
    end)
  end

  test "encoded multipart file create reaches the same guard without parser side effects" do
    setup = active_api_key_fixture()

    with_isolated_plug_tmpdir(fn tmp_root ->
      file_count_before = Repo.aggregate(FileRecord, :count)
      request_count_before = Repo.aggregate(Request, :count)

      conn =
        Plug.Test.conn("POST", "/backend-api/%66iles", "invalid multipart fixture")
        |> put_req_header("content-type", "multipart/form-data; boundary=example")
        |> auth(setup)
        |> @endpoint.call(@endpoint.init([]))

      assert json_response(conn, 400)["error"]["code"] ==
               "unsupported_multipart_file_create"

      assert Repo.aggregate(FileRecord, :count) == file_count_before
      assert Repo.aggregate(Request, :count) == request_count_before
      assert tmpdir_paths(tmp_root) == []
    end)
  end

  test "multipart guard consumes the populated canonical path view" do
    setup = active_api_key_fixture()

    conn =
      Plug.Test.conn("POST", "/backend-api/%66iles", "invalid multipart fixture")
      |> put_req_header("content-type", "multipart/form-data; boundary=example")
      |> auth(setup)
      |> IngressPath.populate()
      |> Map.put(:path_info, ["unrelated"])
      |> BackendFilesMultipartGuard.call([])

    assert json_response(conn, 400)["error"]["code"] == "unsupported_multipart_file_create"
  end

  test "multipart guard reconstructs the canonical path when called directly" do
    setup = active_api_key_fixture()

    conn =
      Plug.Test.conn("POST", "/backend-api/%66iles", "invalid multipart fixture")
      |> put_req_header("content-type", "multipart/form-data; boundary=example")
      |> auth(setup)
      |> BackendFilesMultipartGuard.call([])

    assert json_response(conn, 400)["error"]["code"] == "unsupported_multipart_file_create"
  end

  test "cleanup marks expired file metadata rows", %{conn: conn} do
    setup = active_api_key_fixture()

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_cleanup_bridge",
          file_name: "cleanup.txt",
          mime_type: "text/plain"
        )
      )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_file_cleanup_bridge",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "file-cleanup-bridge-token"
    })

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "cleanup.txt",
        "file_size" => 7,
        "use_case" => "codex"
      })

    file_id = json_response(conn, 200)["file_id"]
    file = Repo.get_by!(FileRecord, file_id: file_id)

    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    file
    |> Ecto.Changeset.change(%{expires_at: expired_at})
    |> Repo.update!()

    assert {:ok, %{abandoned_files: 1, expired_files: 0}} =
             Files.cleanup_expired(DateTime.utc_now())

    assert Repo.get!(FileRecord, file.id).status == "abandoned"
  end

  defp multipart_boundary, do: "codex-pooler-multipart-boundary"

  defp multipart_body(filename, contents) do
    [
      "--#{multipart_boundary()}\r\n",
      "Content-Disposition: form-data; name=\"purpose\"\r\n\r\n",
      "user_data\r\n",
      "--#{multipart_boundary()}\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n",
      "Content-Type: text/plain\r\n\r\n",
      contents,
      "\r\n--#{multipart_boundary()}--\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp with_isolated_plug_tmpdir(fun) do
    tmp_root =
      Path.join(System.tmp_dir!(), "codex-pooler-plug-tmp-#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)

    previous_upload_term = :persistent_term.get(Plug.Upload)
    :persistent_term.put(Plug.Upload, {[tmp_root], "test-upload-suffix"})
    :ets.delete(Plug.Upload.Dir, self())
    :ets.delete(Plug.Upload.Path, self())

    try do
      fun.(tmp_root)
    after
      :ets.delete(Plug.Upload.Dir, self())
      :ets.delete(Plug.Upload.Path, self())
      :persistent_term.put(Plug.Upload, previous_upload_term)
      File.rm_rf!(tmp_root)
    end
  end

  defp tmpdir_paths(tmp_root) do
    case File.ls(tmp_root) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, :enoent} -> []
    end
  end
end
