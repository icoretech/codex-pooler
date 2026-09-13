defmodule CodexPoolerWeb.Runtime.BackendFileControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Persistence.IdempotencyKey
  alias CodexPooler.Gateway.Transports.FileBridge
  alias CodexPooler.Repo

  setup do
    old_config = Application.get_env(:codex_pooler, Files, [])
    CodexPooler.TestAppEnv.restore_on_exit(FileBridge)

    Application.put_env(:codex_pooler, Files,
      max_file_size_bytes: 64,
      file_ttl_seconds: 60
    )

    Application.put_env(:codex_pooler, FileBridge,
      finalize_retry_timeout_ms: 1_000,
      finalize_retry_interval_ms: 0
    )

    on_exit(fn -> Application.put_env(:codex_pooler, Files, old_config) end)

    :ok
  end

  # findings#191: the file bridge relays an upstream create status verbatim, so
  # this is the real path on which Codex Pooler authors an error envelope at a
  # status it did not choose. Every one of these used to render
  # `invalid_request_error` -- the terminal class -- including the throttle and
  # the two server-side failures, which is the whole defect the ticket names.
  @tag :file_bridge_error_classification
  test "a relayed upstream file-create status renders the class that status implies" do
    for {upstream_status, expected_type} <- [
          {429, "rate_limit_error"},
          {502, "server_error"},
          {503, "server_error"},
          {403, "invalid_request_error"}
        ] do
      setup = active_api_key_fixture()

      upstream =
        start_upstream(
          FakeUpstream.file_protocol_create_error(upstream_status,
            file_id: "file_relayed_#{upstream_status}"
          )
        )

      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_relayed_#{upstream_status}",
        metadata: %{"base_url" => FakeUpstream.url(upstream)},
        access_token: "file-relayed-#{upstream_status}-token"
      })

      conn =
        Phoenix.ConnTest.build_conn()
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/backend-api/files", %{"file_name" => "sample.txt", "file_size" => 12})

      assert %{"error" => %{"code" => code, "type" => type}} =
               json_response(conn, upstream_status)

      assert code == "upstream_file_bridge_failed"

      assert type == expected_type,
             "upstream #{upstream_status} rendered #{type}, expected #{expected_type}"
    end
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

    assert upload_url =~ "fake-upload.invalid"

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

    assert download_url =~ "fake-download.invalid"

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

    assert first_upload_url =~ "fake-upload.invalid"

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

    assert second_upload_url =~ "fake-upload.invalid"
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
end
