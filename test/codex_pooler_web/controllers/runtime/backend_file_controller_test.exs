defmodule CodexPoolerWeb.Runtime.BackendFileControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, start_public_endpoint!: 0, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Persistence.IdempotencyKey
  alias CodexPooler.Gateway.Transports.FileBridge
  alias CodexPooler.Repo

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

  @tag :schema_bridge_metadata
  @tag :json_upstream_bridge_happy_path
  test "creates bridge metadata only and finalizes it idempotently", %{conn: conn} do
    setup = active_api_key_fixture()

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_metadata_bridge",
          file_name: "sample.txt",
          mime_type: "text/plain"
        )
      )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_file_metadata_bridge",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "file-metadata-bridge-token"
    })

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{"file_name" => "sample.txt", "file_size" => 12})

    assert %{
             "file_id" => file_id,
             "upload_url" => upload_url
           } = json_response(conn, 200)

    assert upload_url =~ "/file-capabilities/"
    refute upload_url =~ "fake-upload.invalid"
    refute upload_url =~ "sig=fake-upload"

    file = Repo.get_by!(FileRecord, file_id: file_id)
    assert file.pool_id == setup.pool.id
    assert file.api_key_id == setup.api_key.id
    assert file.status == "pending_upload"
    assert file.finalize_status == "pending"
    refute is_nil(file.pool_upstream_assignment_id)
    refute is_nil(file.upstream_identity_id)
    assert file.filename == "sample.txt"
    assert file.purpose == "codex"
    assert file.byte_size == 12
    assert file.metadata == %{"source" => "backend-api/files/upstream"}

    conn =
      build_conn()
      |> auth(setup)
      |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

    assert %{
             "status" => "success",
             "download_url" => download_url,
             "file_name" => "sample.txt",
             "mime_type" => "text/plain"
           } = json_response(conn, 200)

    assert download_url =~ "/file-capabilities/"
    refute download_url =~ "fake-download.invalid"
    refute download_url =~ "sig=fake-download"

    finalized_file = Repo.get!(FileRecord, file.id)
    assert finalized_file.status == "uploaded"
    assert finalized_file.finalize_status == "succeeded"

    duplicate_conn =
      build_conn()
      |> auth(setup)
      |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

    assert %{
             "id" => ^file_id,
             "filename" => "sample.txt",
             "purpose" => "codex",
             "status" => "uploaded"
           } = json_response(duplicate_conn, 200)

    file_requests =
      Repo.all(
        from(request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.api_key_id == ^setup.api_key.id and
              request.endpoint in ["/backend-api/files", "/backend-api/files/uploaded"],
          order_by: [asc: request.admitted_at]
        )
      )

    create_request = Enum.find(file_requests, &(&1.endpoint == "/backend-api/files"))

    finalize_request =
      Enum.find(file_requests, fn request ->
        request.endpoint == "/backend-api/files/uploaded" and
          get_in(request.request_metadata, ["upstream_status"]) == "success"
      end)

    assert get_in(create_request.request_metadata, ["routing", "route_class"]) == "file_upload"

    assert get_in(create_request.request_metadata, ["request", "request_content_type"]) ==
             "application/json"

    assert get_in(create_request.request_metadata, ["request", "request_bytes"]) > 0

    assert get_in(create_request.request_metadata, ["routing", "selected_bridge_candidate_id"]) ==
             file.pool_upstream_assignment_id

    assert get_in(finalize_request.request_metadata, ["routing", "route_class"]) == "file_upload"

    assert get_in(finalize_request.request_metadata, ["routing", "selected_bridge_candidate_id"]) ==
             file.pool_upstream_assignment_id
  end

  @tag :denies_cross_key_finalize_ownership
  test "denies cross-key finalize ownership", %{conn: conn} do
    first = active_api_key_fixture()
    second = active_api_key_fixture(first.pool)

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_owned_bridge",
          file_name: "owned.txt",
          mime_type: "text/plain"
        )
      )

    active_upstream_assignment_fixture(first.pool, %{
      chatgpt_account_id: "acct_file_owned_bridge",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "file-owned-bridge-token"
    })

    conn =
      conn
      |> auth(first)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "owned.txt",
        "file_size" => 11,
        "use_case" => "codex"
      })

    file_id = json_response(conn, 200)["file_id"]

    denied_conn =
      build_conn()
      |> auth(second)
      |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

    assert json_response(denied_conn, 404)["error"]["code"] == "file_not_found"
    assert Repo.get_by!(FileRecord, file_id: file_id).status == "pending_upload"
  end

  @tag :file_affinity_metadata
  test "assignment affinities only accept finalized upstream file ids", %{conn: conn} do
    setup = active_api_key_fixture()

    success_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_affinity_success",
          file_name: "affinity-success.txt",
          mime_type: "text/plain"
        )
      )

    success_assignment =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_affinity_success",
        metadata: %{"base_url" => FakeUpstream.url(success_upstream)},
        access_token: "file-affinity-success-token"
      })

    create_conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "affinity-success.txt",
        "file_size" => 12,
        "use_case" => "codex"
      })

    file_id = json_response(create_conn, 200)["file_id"]

    file = Repo.get_by!(FileRecord, file_id: file_id)
    assert file.status == "pending_upload"
    assert file.finalize_status == "pending"

    assert {:error, %{code: :file_not_found}} = Files.assignment_affinities(setup, [file_id])

    assert {:error, %{code: :file_not_ready, status: 409}} =
             Files.response_assignment_affinities(setup, [file_id])

    finalize_conn =
      build_conn()
      |> auth(setup)
      |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

    assert %{"status" => "success"} = json_response(finalize_conn, 200)

    assert {:ok, %{^file_id => assignment_id}} = Files.assignment_affinities(setup, [file_id])

    assert {:ok, %{^file_id => ^assignment_id}} =
             Files.response_assignment_affinities(setup, [file_id])

    assert assignment_id == success_assignment.assignment.id

    failed_setup = active_api_key_fixture()

    failed_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_affinity_failed",
          file_name: "affinity-failed.txt",
          mime_type: "text/plain"
        )
      )

    _failed_assignment =
      active_upstream_assignment_fixture(failed_setup.pool, %{
        chatgpt_account_id: "acct_file_affinity_failed",
        metadata: %{"base_url" => FakeUpstream.url(failed_upstream)},
        access_token: "file-affinity-failed-token"
      })

    failed_create_conn =
      conn
      |> auth(failed_setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "affinity-failed.txt",
        "file_size" => 11,
        "use_case" => "codex"
      })

    failed_file_id = json_response(failed_create_conn, 200)["file_id"]

    Repo.get_by!(FileRecord, file_id: failed_file_id)
    |> Ecto.Changeset.change(%{status: "abandoned", finalize_status: "failed"})
    |> Repo.update!()

    failed_file = Repo.get_by!(FileRecord, file_id: failed_file_id)
    assert failed_file.status == "abandoned"
    assert failed_file.finalize_status == "failed"

    assert {:error, %{code: :file_not_found}} =
             Files.assignment_affinities(failed_setup, [failed_file_id])

    assert {:error, %{code: :file_not_ready, status: 409}} =
             Files.response_assignment_affinities(failed_setup, [failed_file_id])
  end

  @tag :schema_bridge_metadata
  test "does not replay backend file create idempotency because upload urls are response-only secrets",
       %{
         conn: conn
       } do
    setup = active_api_key_fixture()
    idempotency_key = "file-create-replay-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_create_replay_#{System.unique_integer([:positive])}",
          file_name: "first.txt",
          mime_type: "text/plain"
        )
      )

    upstream_assignment =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_create_replay",
        metadata: %{"base_url" => FakeUpstream.url(upstream)},
        access_token: "file-create-replay-token"
      })

    first_conn =
      conn
      |> auth(setup)
      |> put_req_header("idempotency-key", idempotency_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{"file_name" => "first.txt", "file_size" => 10})

    assert %{"file_id" => first_file_id, "upload_url" => first_upload_url} =
             json_response(first_conn, 200)

    assert first_upload_url =~ "/file-capabilities/cpfc_"
    refute first_upload_url =~ "fake-upload.invalid"

    second_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_create_replay_second_#{System.unique_integer([:positive])}",
          file_name: "second.txt",
          mime_type: "text/plain"
        )
      )

    upstream_assignment.assignment
    |> Ecto.Changeset.change(%{metadata: %{"base_url" => FakeUpstream.url(second_upstream)}})
    |> Repo.update!()

    second_conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("idempotency-key", idempotency_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{"file_name" => "second.txt", "file_size" => 11})

    assert %{"file_id" => second_file_id, "upload_url" => second_upload_url} =
             json_response(second_conn, 200)

    assert second_upload_url =~ "/file-capabilities/cpfc_"
    refute second_upload_url =~ "fake-upload.invalid"
    refute second_file_id == first_file_id

    assert Repo.aggregate(
             from(file in FileRecord,
               where: file.pool_id == ^setup.pool.id and file.api_key_id == ^setup.api_key.id
             ),
             :count
           ) == 2

    assert Repo.aggregate(
             from(request in Request,
               where:
                 request.pool_id == ^setup.pool.id and request.api_key_id == ^setup.api_key.id
             ),
             :count
           ) == 2

    requests = Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)
    assert Enum.all?(requests, &is_nil(&1.idempotency_key))
    assert Repo.aggregate(IdempotencyKey, :count) == 0
    refute inspect(requests) =~ idempotency_key
    refute inspect(requests) =~ "first body"
    refute inspect(requests) =~ "second body"
  end

  test "replays duplicate finalize with same idempotency key without duplicate request index errors",
       %{
         conn: conn
       } do
    setup = active_api_key_fixture()
    idempotency_key = "file-finalize-replay-#{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_finalize_replay_#{System.unique_integer([:positive])}",
          file_name: "finalize.txt",
          mime_type: "text/plain"
        )
      )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_file_finalize_replay",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "file-finalize-replay-token"
    })

    create_conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "finalize.txt",
        "file_size" => 13,
        "use_case" => "codex"
      })

    file_id = json_response(create_conn, 200)["file_id"]

    first_conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("idempotency-key", idempotency_key)
      |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

    assert %{"status" => "success", "file_name" => "finalize.txt"} =
             json_response(first_conn, 200)

    second_conn =
      build_conn()
      |> auth(setup)
      |> put_req_header("idempotency-key", idempotency_key)
      |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

    assert %{
             "id" => ^file_id,
             "filename" => "finalize.txt",
             "purpose" => "codex",
             "status" => "uploaded"
           } = json_response(second_conn, 200)

    finalize_requests =
      Repo.all(
        from(request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.api_key_id == ^setup.api_key.id and
              request.endpoint == "/backend-api/files/uploaded",
          order_by: [asc: request.admitted_at]
        )
      )

    assert length(finalize_requests) == 2
    assert Enum.all?(finalize_requests, &is_nil(&1.idempotency_key))
    refute inspect(Enum.map(finalize_requests, & &1.request_metadata)) =~ idempotency_key
    refute inspect(Enum.map(finalize_requests, & &1.request_metadata)) =~ "finalize body"
  end

  test "router-level capabilities proxy exact bytes without exposing or accepting scoped secrets" do
    setup = active_api_key_fixture()
    other_key = active_api_key_fixture(setup.pool)
    other_pool_key = active_api_key_fixture()
    file_id = "file_native_capability_#{System.unique_integer([:positive])}"
    upload_bytes = Jason.encode!("1234567890")
    download_bytes = "return-bytes"
    assert byte_size(upload_bytes) == 12
    assert byte_size(download_bytes) == 12

    provider_upload =
      "https://provider-upload.example.invalid/upload/#{file_id}?sig=UPLOAD_SIGNATURE_SENTINEL"

    provider_download =
      "https://provider-download.example.invalid/download/#{file_id}?sig=DOWNLOAD_SIGNATURE_SENTINEL"

    provider_sentinel = "acct_provider_private_file_sentinel"

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: file_id,
          file_name: "native.txt",
          mime_type: "text/plain",
          upload_url: provider_upload,
          download_url: provider_download,
          create_extra: %{"provider_account" => provider_sentinel},
          finalize_extra: %{"provider_account" => provider_sentinel}
        )
      )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_native_capability_assignment",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "native-capability-upstream-token"
    })

    stub = {__MODULE__, :native_capability, file_id}
    test_pid = self()

    Req.Test.stub(stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"PUT", "/upload/" <> _file_id} ->
          send(test_pid, {:capability_provider_upload, Req.Test.raw_body(conn), conn.req_headers})

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.text("")

        {"GET", "/download/" <> _file_id} ->
          send(test_pid, :capability_provider_download)

          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.put_resp_header(
            "content-length",
            Integer.to_string(byte_size(download_bytes))
          )
          |> Req.Test.text(download_bytes)

        _unexpected ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.text("")
      end
    end)

    bridge_config = Application.get_env(:codex_pooler, FileBridge, [])

    Application.put_env(
      :codex_pooler,
      FileBridge,
      Keyword.merge(bridge_config,
        upload_req_options: [plug: {Req.Test, stub}],
        download_req_options: [plug: {Req.Test, stub}]
      )
    )

    port = start_public_endpoint!()
    origin = "http://127.0.0.1:#{port}"

    create =
      Req.post!(origin <> "/backend-api/files",
        headers: [{"authorization", setup.authorization}],
        json: %{"file_name" => "native.txt", "file_size" => 12},
        retry: false
      )

    assert create.status == 200
    assert %{"file_id" => ^file_id, "upload_url" => upload_url} = create.body
    assert String.starts_with?(upload_url, origin <> "/file-capabilities/cpfc_")

    public_create = inspect(create.body)
    refute public_create =~ "provider-upload"
    refute public_create =~ "UPLOAD_SIGNATURE_SENTINEL"
    refute public_create =~ provider_sentinel

    for denied_key <- [other_key, other_pool_key] do
      wrong_scope =
        Req.put!(upload_url,
          headers: [
            {"authorization", denied_key.authorization},
            {"content-type", "text/plain"}
          ],
          body: upload_bytes,
          retry: false
        )

      assert wrong_scope.status == 404
    end

    refute_received {:capability_provider_upload, _body, _headers}

    last = String.last(upload_url)
    tampered = String.replace_suffix(upload_url, last, if(last == "x", do: "y", else: "x"))
    assert Req.put!(tampered, body: upload_bytes, retry: false).status == 404
    refute_received {:capability_provider_upload, _body, _headers}

    assert Req.get!(upload_url, retry: false).status == 404
    refute_received :capability_provider_download

    assert Req.put!(upload_url, body: upload_bytes <> "x", retry: false).status == 413
    assert Req.put!(upload_url, body: "short", retry: false).status == 400
    refute_received {:capability_provider_upload, _body, _headers}

    encoded =
      Req.put!(upload_url,
        headers: [
          {"content-type", "application/octet-stream"},
          {"content-encoding", "gzip"}
        ],
        body: upload_bytes,
        retry: false
      )

    assert encoded.status == 415
    assert encoded.body["error"]["code"] == "unsupported_content_encoding"
    refute_received {:capability_provider_upload, _body, _headers}

    uploaded =
      Req.put!(upload_url,
        headers: [{"content-type", "application/json"}],
        body: upload_bytes,
        retry: false
      )

    assert uploaded.status == 201
    assert_receive {:capability_provider_upload, ^upload_bytes, upload_headers}, 1_000
    assert {"content-type", "application/json"} in upload_headers

    finalized =
      Req.post!(origin <> "/backend-api/files/#{file_id}/uploaded",
        headers: [{"authorization", setup.authorization}],
        json: %{},
        retry: false
      )

    assert finalized.status == 200
    assert %{"status" => "success", "download_url" => download_url} = finalized.body
    assert String.starts_with?(download_url, origin <> "/file-capabilities/cpfc_")

    public_finalize = inspect(finalized.body)
    refute public_finalize =~ "provider-download"
    refute public_finalize =~ "DOWNLOAD_SIGNATURE_SENTINEL"
    refute public_finalize =~ provider_sentinel

    for denied_key <- [other_key, other_pool_key] do
      denied_download =
        Req.get!(download_url,
          headers: [{"authorization", denied_key.authorization}],
          retry: false
        )

      assert denied_download.status == 404
    end

    refute_received :capability_provider_download

    downloaded = Req.get!(download_url, retry: false)
    assert downloaded.status == 200
    assert downloaded.body == download_bytes
    assert_receive :capability_provider_download, 1_000

    stored = inspect(Repo.all(from record in FileRecord, where: record.file_id == ^file_id))
    refute stored =~ provider_upload
    refute stored =~ provider_download
    refute stored =~ upload_bytes
    refute stored =~ download_bytes

    requests =
      inspect(Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id))

    refute requests =~ provider_upload
    refute requests =~ provider_download
    refute requests =~ upload_bytes
    refute requests =~ download_bytes
  end
end
