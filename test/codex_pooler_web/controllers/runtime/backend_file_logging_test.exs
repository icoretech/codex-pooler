defmodule CodexPoolerWeb.Runtime.BackendFileLoggingTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, start_upstream: 1]

  alias CodexPooler.{Accounting, Audit}
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
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

  @tag :file_bridge_safe_logging
  @tag :file_bridge_upload_transport
  test "request logs and audit surfaces keep file bodies and bridge secrets out", %{
    conn: conn
  } do
    setup = active_api_key_fixture()
    filename = "private-name.txt"
    idempotency_key = "backend-file-idempotency-#{System.unique_integer([:positive])}"
    chatgpt_account_id = "acct_file_log_sanitization_#{System.unique_integer([:positive])}"
    access_token = "file-log-sanitization-token"

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_log_sanitization",
          file_name: filename,
          mime_type: "text/plain"
        )
      )

    active_upstream_assignment_fixture(setup.pool, %{
      chatgpt_account_id: chatgpt_account_id,
      metadata: %{"base_url" => FakeUpstream.url(upstream)},
      access_token: access_token
    })

    conn =
      conn
      |> auth(setup)
      |> put_req_header("idempotency-key", idempotency_key)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => filename,
        "file_size" => 19,
        "use_case" => "codex"
      })

    create_body = json_response(conn, 200)
    file_id = create_body["file_id"]
    upload_url = create_body["upload_url"]

    finalize_body =
      build_conn()
      |> auth(setup)
      |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})
      |> json_response(200)

    download_url = finalize_body["download_url"]

    assert is_binary(upload_url)
    assert is_binary(download_url)

    missing_file_id = "file-missing-private-token"

    build_conn()
    |> auth(setup)
    |> post(~p"/backend-api/files/#{missing_file_id}/uploaded", %{})
    |> json_response(404)

    assert %{items: logs, total: 3} = Accounting.list_request_logs(setup.pool)
    assert Enum.all?(logs, &(&1.transport == "http_json"))
    refute inspect(logs) =~ filename
    refute inspect(logs) =~ setup.raw_key
    refute inspect(logs) =~ idempotency_key
    refute inspect(logs) =~ missing_file_id
    refute inspect(logs) =~ upload_url
    refute inspect(logs) =~ download_url
    refute inspect(logs) =~ access_token
    refute inspect(logs) =~ chatgpt_account_id

    requests = Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)

    refute inspect(requests) =~ filename
    refute inspect(requests) =~ setup.raw_key
    refute inspect(requests) =~ idempotency_key
    refute inspect(requests) =~ missing_file_id
    refute inspect(requests) =~ upload_url
    refute inspect(requests) =~ download_url
    refute inspect(requests) =~ access_token
    refute inspect(requests) =~ chatgpt_account_id

    files = Repo.all(from file in FileRecord, where: file.pool_id == ^setup.pool.id)
    refute inspect(files) =~ upload_url
    refute inspect(files) =~ download_url
    refute inspect(files) =~ access_token
    refute inspect(files) =~ chatgpt_account_id

    assert {:ok, audit_event} =
             Audit.record_system_event(%{
               pool_id: setup.pool.id,
               action: "access.denied",
               target_type: "api_key",
               outcome: "failure",
               details: %{
                 "upload_url" => upload_url,
                 "download_url" => download_url,
                 "access_token" => access_token,
                 "chatgpt-account-id" => chatgpt_account_id,
                 "safe" => "visible"
               }
             })

    stored_event = Repo.get!(AuditEvent, audit_event.id)
    assert stored_event.details["upload_url"] == "[REDACTED]"
    assert stored_event.details["download_url"] == "[REDACTED]"
    assert stored_event.details["access_token"] == "[REDACTED]"
    assert stored_event.details["chatgpt-account-id"] == "[REDACTED]"
    assert stored_event.details["safe"] == "visible"
    refute inspect(stored_event) =~ upload_url
    refute inspect(stored_event) =~ download_url
    refute inspect(stored_event) =~ access_token
    refute inspect(stored_event) =~ chatgpt_account_id

    audit_events = Repo.all(from(event in AuditEvent, where: event.pool_id == ^setup.pool.id))

    refute inspect(audit_events) =~ upload_url
    refute inspect(audit_events) =~ download_url
    refute inspect(audit_events) =~ access_token
    refute inspect(audit_events) =~ chatgpt_account_id

    assert Enum.count(audit_events, &(&1.action == "access.denied")) == 1
  end
end
