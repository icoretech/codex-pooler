defmodule CodexPoolerWeb.Runtime.BackendFileRoutingTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import Ecto.Query
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    RoutingCircuitState
  }

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

  @tag :upstream_file_create_bridge
  @tag :json_upstream_bridge_happy_path
  test "bridges JSON create and finalize through the selected upstream assignment", %{conn: conn} do
    setup = active_api_key_fixture()

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_finalize_retry(
          file_id: "file_upstream_bridge",
          file_name: "bridge-fixture.txt",
          mime_type: "text/plain"
        )
      )

    upstream_assignment =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_bridge_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(upstream)},
        access_token: "file-bridge-token"
      })

    secondary_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_upstream_bridge_secondary",
          file_name: "bridge-fixture-secondary.txt",
          mime_type: "text/plain"
        )
      )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "acct_file_bridge_secondary_#{System.unique_integer([:positive])}",
      metadata: %{"base_url" => FakeUpstream.url(secondary_upstream)},
      access_token: "file-bridge-secondary-token"
    })

    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(
               upstream_assignment.identity,
               [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("1"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh"
                 }
               ]
             )

    create_conn =
      conn
      |> auth(setup)
      |> put_req_header("user-agent", "codex-test-agent")
      |> put_req_header("x-openai-client", "codex-cli")
      |> put_req_header("x-codex-turn-state", "safe-turn-state")
      |> put_req_header("x-ignore-this", "not-forwarded")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "bridge-fixture.txt",
        "file_size" => 21
      })

    assert %{
             "file_id" => "file_upstream_bridge",
             "upload_url" =>
               "https://fake-upload.invalid/upload/file_upstream_bridge?sig=fake-upload"
           } = json_response(create_conn, 200)

    file = Repo.get_by!(FileRecord, file_id: "file_upstream_bridge")
    assert file.pool_id == setup.pool.id
    assert file.api_key_id == setup.api_key.id
    assert file.pool_upstream_assignment_id == upstream_assignment.assignment.id
    assert file.upstream_identity_id == upstream_assignment.identity.id
    assert file.status == "pending_upload"
    assert file.finalize_status == "pending"
    assert file.filename == "bridge-fixture.txt"
    assert file.byte_size == 21
    refute inspect(file) =~ "fake-upload.invalid"

    finalize_conn =
      build_conn()
      |> auth(setup)
      |> post(~p"/backend-api/files/file_upstream_bridge/uploaded", %{})

    assert %{
             "status" => "success",
             "download_url" =>
               "https://fake-download.invalid/download/file_upstream_bridge?sig=fake-download",
             "file_name" => "bridge-fixture.txt",
             "mime_type" => "text/plain"
           } = json_response(finalize_conn, 200)

    finalized_file = Repo.get!(FileRecord, file.id)
    assert finalized_file.status == "uploaded"
    assert finalized_file.finalize_status == "succeeded"
    refute inspect(finalized_file) =~ "fake-download.invalid"

    assert [create_request, first_finalize_request, second_finalize_request] =
             FakeUpstream.requests(upstream)

    assert create_request.path == "/backend-api/files"

    assert create_request.json == %{
             "file_name" => "bridge-fixture.txt",
             "file_size" => 21,
             "use_case" => "codex"
           }

    assert first_finalize_request.path == "/backend-api/files/file_upstream_bridge/uploaded"
    assert second_finalize_request.path == "/backend-api/files/file_upstream_bridge/uploaded"
    assert first_finalize_request.json == %{}
    assert second_finalize_request.json == %{}
    assert FakeUpstream.requests(secondary_upstream) == []

    assert header!(create_request.headers, "authorization") == "Bearer file-bridge-token"
    assert header!(create_request.headers, "accept") == "application/json"
    assert header!(create_request.headers, "content-type") == "application/json"

    assert header!(create_request.headers, "chatgpt-account-id") ==
             upstream_assignment.identity.chatgpt_account_id

    assert header!(create_request.headers, "user-agent") == "codex_cli_rs/0.0.0"
    assert header!(create_request.headers, "x-openai-client") == "codex-cli"
    assert header!(create_request.headers, "x-codex-turn-state") == "safe-turn-state"
    refute Enum.any?(create_request.headers, fn {name, _value} -> name == "x-ignore-this" end)
  end

  @tag :upstream_file_assignment_continuity
  test "multipart create uploads and finalizes through the selected file bridge assignment", %{
    conn: conn
  } do
    setup = active_api_key_fixture()
    file_id = "file_assignment_continuity_#{System.unique_integer([:positive])}"
    filename = "assignment-continuity-private.txt"
    file_contents = "synthetic assignment continuity bytes"
    file_size = byte_size(file_contents)

    fallback_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_assignment_continuity_fallback",
          file_name: "fallback.txt",
          mime_type: "text/plain"
        )
      )

    fallback_assignment =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_continuity_fallback_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(fallback_upstream)},
        access_token: "file-continuity-fallback-token"
      })

    selected_upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: file_id))

    FakeUpstream.set_mode(
      selected_upstream,
      FakeUpstream.file_protocol_success(
        file_id: file_id,
        file_name: filename,
        mime_type: "text/plain",
        upload_url: FakeUpstream.url(selected_upstream) <> "/upload/#{file_id}"
      )
    )

    selected_assignment =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_continuity_selected_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(selected_upstream)},
        access_token: "file-continuity-selected-token"
      })

    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(fallback_assignment.identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("100"),
                 reset_at: reset_at,
                 source: "codex_response_headers",
                 source_precision: "observed",
                 freshness_state: "fresh"
               }
             ])

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(selected_assignment.identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("1"),
                 reset_at: reset_at,
                 source: "codex_response_headers",
                 source_precision: "observed",
                 freshness_state: "fresh"
               }
             ])

    upload = upload_fixture(filename, "text/plain", file_contents)

    create_conn =
      conn
      |> auth(setup)
      |> post("/v1/files", %{"purpose" => "user_data", "file" => upload})

    assert %{
             "id" => ^file_id,
             "object" => "file",
             "bytes" => ^file_size,
             "filename" => ^filename,
             "purpose" => "user_data",
             "status" => "uploaded"
           } = create_body = json_response(create_conn, 200)

    refute Map.has_key?(create_body, "upload_url")

    file = Repo.get_by!(FileRecord, file_id: file_id)
    assert file.pool_upstream_assignment_id == selected_assignment.assignment.id
    assert file.upstream_identity_id == selected_assignment.identity.id
    assert file.status == "uploaded"
    assert file.finalize_status == "succeeded"

    assert [create_request, put_request, finalize_request] =
             FakeUpstream.requests(selected_upstream)

    assert create_request.path == "/backend-api/files"
    assert put_request.method == "PUT"
    assert put_request.path == "/upload/#{file_id}"
    assert put_request.body == file_contents
    assert finalize_request.path == "/backend-api/files/#{file_id}/uploaded"
    assert FakeUpstream.requests(fallback_upstream) == []

    public_create_request =
      Repo.one!(
        from request in Request,
          where:
            request.pool_id == ^setup.pool.id and request.api_key_id == ^setup.api_key.id and
              request.endpoint == "/v1/files" and request.status == "succeeded"
      )

    assert public_create_request.endpoint == "/v1/files"
    assert public_create_request.transport == "http_multipart"
    assert public_create_request.request_metadata["operation"] == "uploaded"

    routing_metadata = public_create_request.request_metadata["routing"]
    assert routing_metadata["route_class"] == "file_upload"

    assert routing_metadata["selected_bridge_candidate_id"] ==
             selected_assignment.assignment.id

    metadata_text = inspect(public_create_request.request_metadata)
    refute metadata_text =~ filename
    refute metadata_text =~ file_contents
    refute metadata_text =~ "upload_url"
    refute metadata_text =~ FakeUpstream.url(selected_upstream)
    refute metadata_text =~ setup.raw_key
    refute metadata_text =~ "file-continuity-selected-token"
    refute metadata_text =~ "file-continuity-fallback-token"
    refute metadata_text =~ "Bearer"
  end

  @tag :upstream_file_create_bridge
  test "prefers a quota-usable file bridge assignment when an earlier assignment is exhausted", %{
    conn: conn
  } do
    setup = active_api_key_fixture()

    exhausted_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_exhausted_assignment",
          file_name: "exhausted.txt",
          mime_type: "text/plain"
        )
      )

    exhausted_assignment =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_bridge_exhausted_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(exhausted_upstream)},
        access_token: "file-bridge-exhausted-token"
      })

    usable_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_usable_assignment",
          file_name: "usable.txt",
          mime_type: "text/plain"
        )
      )

    usable_assignment =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_bridge_usable_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(usable_upstream)},
        access_token: "file-bridge-usable-token"
      })

    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(
               exhausted_assignment.identity,
               [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("100"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh"
                 }
               ]
             )

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(
               usable_assignment.identity,
               [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("1"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh"
                 }
               ]
             )

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{"file_name" => "usable.txt", "file_size" => 12})

    assert %{"file_id" => "file_usable_assignment"} = json_response(conn, 200)
    assert FakeUpstream.requests(exhausted_upstream) == []
    assert [%{path: "/backend-api/files"}] = FakeUpstream.requests(usable_upstream)
  end

  @tag :upstream_file_create_bridge
  test "rejects file bridge create when all assignments are quota exhausted", %{conn: conn} do
    setup = active_api_key_fixture()

    first_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_exhausted_first",
          file_name: "exhausted-first.txt",
          mime_type: "text/plain"
        )
      )

    first_assignment =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_exhausted_first_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(first_upstream)},
        access_token: "file-exhausted-first-token"
      })

    second_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_exhausted_second",
          file_name: "exhausted-second.txt",
          mime_type: "text/plain"
        )
      )

    second_assignment =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_exhausted_second_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(second_upstream)},
        access_token: "file-exhausted-second-token"
      })

    reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

    for %{identity: identity} <- [first_assignment, second_assignment] do
      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("100"),
                   reset_at: reset_at,
                   source: "codex_response_headers",
                   source_precision: "observed",
                   freshness_state: "fresh"
                 }
               ])
    end

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{"file_name" => "quota.txt", "file_size" => 12})

    assert %{"error" => %{"code" => "quota_exhausted"}} = json_response(conn, 503)
    assert FakeUpstream.requests(first_upstream) == []
    assert FakeUpstream.requests(second_upstream) == []

    request = Repo.one!(from request in Request, where: request.pool_id == ^setup.pool.id)

    assert request.status == "failed"
    assert request.request_metadata["error_code"] == "quota_exhausted"

    assert [
             %{"reasons" => [%{"reason_codes" => first_reason_codes}]},
             %{"reasons" => [%{"reason_codes" => second_reason_codes}]}
           ] = request.request_metadata["candidate_exclusions"]

    assert "exhausted" in first_reason_codes
    assert "exhausted" in second_reason_codes
  end

  @tag :upstream_file_create_error
  test "maps upstream create errors safely without persisting URLs or raw upstream bodies", %{
    conn: conn
  } do
    setup = active_api_key_fixture()

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_unauthorized(
          file_id: "file_auth_error",
          unauthorized_payload: %{
            "error" => %{
              "code" => "invalid_api_key",
              "message" => "secret account detail redacted-marker"
            }
          }
        )
      )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: "email_sentinel@example.com",
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: "file-error-token"
    })

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "error-fixture.txt",
        "file_size" => 5,
        "use_case" => "codex"
      })

    body = json_response(conn, 401)
    assert body["error"]["code"] == "upstream_file_bridge_failed"
    assert body["error"]["message"] == "upstream file create failed"
    refute inspect(body) =~ "invalid_api_key"
    refute inspect(body) =~ "redacted-marker"
    refute Repo.get_by(FileRecord, file_id: "file_auth_error")

    assert [create_request] = FakeUpstream.requests(upstream)
    assert create_request.path == "/backend-api/files"
    assert header!(create_request.headers, "authorization") == "Bearer file-error-token"

    refute Enum.any?(create_request.headers, fn {name, _value} -> name == "chatgpt-account-id" end)

    requests = Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)
    refute inspect(requests) =~ "invalid_api_key"
    refute inspect(requests) =~ "redacted-marker"
    refute inspect(requests) =~ "file-error-token"
  end

  @tag :upstream_file_create_failure_routing_lifecycle
  test "records file bridge routing failure lifecycle for retryable create failures", %{
    conn: conn
  } do
    setup = active_api_key_fixture()
    upstream = start_upstream(FakeUpstream.http_500_json_error())

    %{assignment: assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id:
          "acct_file_bridge_create_failure_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(upstream)},
        access_token: "file-create-failure-token"
      })

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "retryable-create-failure.txt",
        "file_size" => 12,
        "use_case" => "codex"
      })

    body = json_response(conn, 500)
    assert body["error"]["code"] == "upstream_file_bridge_failed"

    assert %BridgeDemotion{reason_code: "file_bridge_upstream_file_bridge_failed"} =
             Repo.get_by(BridgeDemotion,
               pool_id: setup.pool.id,
               api_key_id: setup.api_key.id,
               model_identifier: "backend-api/files",
               pool_upstream_assignment_id: assignment.id,
               status: "active"
             )

    assert %RoutingCircuitState{
             reason_code: "file_bridge_upstream_file_bridge_failed",
             route_class: "file_upload",
             failure_count: 1
           } =
             file_upload_circuit_state(setup, assignment)
  end

  @tag :upstream_file_retry_timeout_affinity
  test "retry-timeout upstream files stay ineligible for response affinity", %{conn: conn} do
    setup = active_api_key_fixture()

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_finalize_retry(
          file_id: "file_retry_timeout_affinity",
          file_name: "retry-timeout.txt",
          mime_type: "text/plain"
        )
      )

    %{assignment: assignment} =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_retry_timeout_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(upstream)},
        access_token: "file-retry-timeout-token"
      })

    create_conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "retry-timeout.txt",
        "file_size" => 12,
        "use_case" => "codex"
      })

    assert %{"file_id" => file_id} = json_response(create_conn, 200)

    assert {:error, %{code: :file_not_found}} =
             Files.assignment_affinities(setup, [file_id])

    old_bridge_config = Application.get_env(:codex_pooler, FileBridge, [])

    Application.put_env(
      :codex_pooler,
      FileBridge,
      Keyword.merge(old_bridge_config,
        finalize_retry_timeout_ms: 0,
        finalize_retry_interval_ms: 0
      )
    )

    finalize_conn =
      build_conn()
      |> auth(setup)
      |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

    assert %{"status" => "retry"} = json_response(finalize_conn, 200)

    file = Repo.get_by!(FileRecord, file_id: file_id)
    assert file.status == "pending_upload"
    assert file.finalize_status == "pending"
    assert is_binary(file.pool_upstream_assignment_id)

    assert {:error, %{code: :file_not_found}} =
             Files.assignment_affinities(setup, [file_id])

    assert %BridgeDemotion{reason_code: "file_bridge_retry_timeout"} =
             Repo.get_by(BridgeDemotion,
               pool_id: setup.pool.id,
               api_key_id: setup.api_key.id,
               model_identifier: "backend-api/files",
               pool_upstream_assignment_id: assignment.id,
               status: "active"
             )

    assert %RoutingCircuitState{
             reason_code: "file_bridge_retry_timeout",
             route_class: "file_upload",
             failure_count: 1
           } =
             file_upload_circuit_state(setup, assignment)

    assert [create_request, finalize_request] = FakeUpstream.requests(upstream)
    assert create_request.path == "/backend-api/files"
    assert finalize_request.path == "/backend-api/files/file_retry_timeout_affinity/uploaded"
  end

  test "returns not found for missing files", %{conn: conn} do
    setup = active_api_key_fixture()
    missing_file_id = "file-missing-sensitive-token"

    conn =
      conn
      |> auth(setup)
      |> post(~p"/backend-api/files/#{missing_file_id}/uploaded", %{})

    assert json_response(conn, 404)["error"]["code"] == "file_not_found"

    failed_request =
      Repo.one!(
        from request in Request,
          where:
            request.pool_id == ^setup.pool.id and
              request.endpoint == "/backend-api/files/uploaded"
      )

    assert failed_request.status == "failed"
    assert failed_request.request_metadata["error_code"] == "file_not_found"
    refute inspect(failed_request.request_metadata) =~ missing_file_id
  end

  defp upload_fixture(filename, content_type, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-routing-file-#{System.unique_integer([:positive])}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
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

  defp file_upload_circuit_state(setup, assignment) do
    Repo.one(
      from state in RoutingCircuitState,
        where:
          state.pool_id == ^setup.pool.id and
            is_nil(state.api_key_id) and
            state.model_identifier == "backend-api/files" and
            state.pool_upstream_assignment_id == ^assignment.id and
            state.route_class == "file_upload"
    )
  end
end
