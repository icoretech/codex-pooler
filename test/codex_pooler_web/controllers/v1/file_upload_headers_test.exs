defmodule CodexPoolerWeb.V1.FileUploadHeadersTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Files.UploadUrlPolicy
  alias CodexPooler.Gateway.Transports.{FileBridge, PinnedUpload}
  alias CodexPooler.Platform.OutboundHTTP
  alias CodexPooler.Repo

  defmodule LoopbackAdapter do
    @moduledoc false
    def run(request) do
      {_validated_address, remaining} = Req.Request.get_private(request, :codex_pooler_pinned_upload)
      # Change only the test connection; retain the signed host, port, path and query.
      PinnedUpload.run(%{request | url: %{request.url | scheme: "http"}}, {127, 0, 0, 1}, remaining)
    end
  end

  defmodule Storage do
    @moduledoc false
    def init(options), do: options

    def call(conn, state) do
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)

      status =
        Agent.get_and_update(state, fn %{expected: expected, statuses: [status | rest], receipts: receipts} = data ->
          matches = Enum.all?(expected, fn {name, value} -> Plug.Conn.get_req_header(conn, name) == [value] end)
          credential_free = Enum.all?(~w(authorization chatgpt-account-id cookie x-pool-api-key x-upstream-access-token), &(Plug.Conn.get_req_header(conn, &1) == []))
          receipt = %{required_headers: matches, credential_free: credential_free, bytes: byte_size(bytes), sha256: :crypto.hash(:sha256, bytes), method: conn.method, path: conn.request_path, query: conn.query_string, host: conn.host}
          {if(matches, do: status, else: 403), %{data | statuses: rest, receipts: receipts ++ [receipt]}}
        end)

      Plug.Conn.send_resp(conn, status, "")
    end
  end

  setup do
    for key <- [FileBridge, UploadUrlPolicy, OutboundHTTP], do: CodexPooler.TestAppEnv.restore_on_exit(key)
    Application.put_env(:codex_pooler, UploadUrlPolicy, resolver: fn _host, family -> if family == :inet, do: {:ok, [{93, 184, 216, 34}]}, else: {:error, :nxdomain} end)
    Application.put_env(:codex_pooler, OutboundHTTP, proxy_config: %{http: [], https: [], no_proxy: []})
    Application.put_env(:codex_pooler, FileBridge, upload_req_options: [adapter: LoopbackAdapter], upload_retry_interval_ms: 0)
    :ok
  end

  test "multipart upload forwards storage-required provider headers through the real pinned transport" do
    headers = %{"x-amz-tagging" => "purpose=synthetic-storage-header"}
    fixture = upload_context(headers, [201])

    response = upload(fixture)

    assert [receipt] = Agent.get(fixture.storage, & &1.receipts)
    assert receipt.required_headers, "storage PUT omitted required provider header (public HTTP #{response.status})"
    assert response.status == 200
    assert receipt.credential_free
    assert receipt.sha256 == :crypto.hash(:sha256, fixture.contents)
    assert receipt.bytes == byte_size(fixture.contents)
    assert receipt.method == "PUT"
    assert receipt.path == "/upload/#{fixture.file_id}"
    assert receipt.query == "signature=synthetic"
    assert receipt.host == "upload.example"
    assert [%{path: "/backend-api/files"}, %{path: finalize}] = FakeUpstream.requests(fixture.upstream)
    assert finalize == "/backend-api/files/#{fixture.file_id}/uploaded"
    assert_private_metadata(fixture, [response.resp_body])
  end

  test "storage retries retain provider overrides and exact bytes after a 503" do
    headers = %{"Content-Type" => "application/x-synthetic-storage", "Content-Disposition" => "attachment; filename=storage.txt", "x-amz-tagging" => "scope=retry", "X-Ms-Blob-Type" => "AppendBlob"}
    fixture = upload_context(headers, [503, 201])

    response = upload(fixture)

    assert response.status == 200
    assert [first, second] = Agent.get(fixture.storage, & &1.receipts)

    for receipt <- [first, second] do
      assert receipt.required_headers
      assert receipt.credential_free
      assert receipt.bytes == byte_size(fixture.contents)
      assert receipt.sha256 == :crypto.hash(:sha256, fixture.contents)
    end

    assert length(FakeUpstream.requests(fixture.upstream)) == 2
    assert_private_metadata(fixture, [response.resp_body])
  end

  for headers <- [:absent, nil, %{}] do
    @headers headers
    test "#{inspect(headers)} upload_headers retains legacy storage defaults" do
      fixture = upload_context(@headers, [201])

      response = upload(fixture)

      assert response.status == 200
      assert [%{required_headers: true, credential_free: true}] = Agent.get(fixture.storage, & &1.receipts)
      assert length(FakeUpstream.requests(fixture.upstream)) == 2
    end
  end

  test "permanent storage refusal abandons the file without finalization" do
    fixture = upload_context(%{"x-amz-tagging" => "scope=refusal"}, [403])

    response = upload(fixture)

    assert response.status == 502
    assert json_response(response, 502)["error"]["code"] == "upstream_file_upload_failed"
    assert [%{required_headers: true, credential_free: true}] = Agent.get(fixture.storage, & &1.receipts)
    assert [%{path: "/backend-api/files"}] = FakeUpstream.requests(fixture.upstream)
    file = Repo.get_by!(FileRecord, file_id: fixture.file_id)
    assert file.status == "abandoned"
    assert file.finalize_status == "failed"
    assert_private_metadata(fixture, [response.resp_body])
  end

  test "credential instructions fail before storage dispatch or file persistence" do
    fixture = upload_context(%{"Authorization" => "synthetic-storage-credential"}, [201])

    response = upload(fixture)

    assert response.status == 502
    assert json_response(response, 502)["error"]["code"] == "upstream_file_bridge_invalid_response"
    assert Agent.get(fixture.storage, & &1.receipts) == []
    refute Repo.get_by(FileRecord, file_id: fixture.file_id)
    assert [%{path: "/backend-api/files"}] = FakeUpstream.requests(fixture.upstream)
  end

  test "native create preserves upload_headers for the client without issuing storage PUT" do
    headers = %{"Content-Disposition" => "attachment; filename=native.txt", "x-amz-tagging" => "scope=native"}
    fixture = upload_context(headers, [201])

    response = build_conn() |> auth(fixture.auth) |> put_req_header("content-type", "application/json") |> post("/backend-api/files", %{"file_name" => "native.txt", "file_size" => byte_size(fixture.contents), "use_case" => "codex"})

    assert response.status == 200
    body = json_response(response, 200)
    assert Map.equal?(body["upload_headers"], headers), "native create altered upload instructions"
    assert body["file_id"] == fixture.file_id
    assert Agent.get(fixture.storage, & &1.receipts) == []
    assert [%{path: "/backend-api/files"}] = FakeUpstream.requests(fixture.upstream)
    # The native response intentionally carries the instructions; persistence must not.
    assert_private_metadata(fixture, [])
  end

  defp upload_context(headers, statuses) do
    defaults = %{"content-type" => "text/plain", "x-ms-blob-type" => "BlockBlob"}
    normalized = if is_map(headers), do: Map.new(headers, fn {key, value} -> {String.downcase(key), value} end), else: %{}
    contents = "synthetic storage-boundary file bytes"
    expected = defaults |> Map.merge(normalized) |> Map.put("content-length", Integer.to_string(byte_size(contents)))
    storage = start_supervised!({Agent, fn -> %{expected: expected, statuses: statuses, receipts: []} end})
    server = start_supervised!({Bandit, plug: {Storage, storage}, ip: {127, 0, 0, 1}, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    file_id = "file_headers_#{System.unique_integer([:positive])}"
    url = "https://upload.example:#{port}/upload/#{file_id}?signature=synthetic"
    create = %{"file_id" => file_id, "upload_url" => url}
    create = if headers == :absent, do: create, else: Map.put(create, "upload_headers", headers)
    upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.json_response(create), FakeUpstream.json_response(%{"status" => "success", "download_url" => "https://download.example/synthetic-file"})]))
    auth = active_api_key_fixture()
    assignment = active_upstream_assignment_fixture(auth.pool, %{metadata: %{"base_url" => FakeUpstream.url(upstream)}, chatgpt_account_id: "synthetic-storage-account", access_token: "synthetic-storage-upstream-token"})
    path = Path.join(System.tmp_dir!(), "pooler-upload-headers-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, contents)
    %{auth: auth, assignment: assignment, storage: storage, upstream: upstream, file_id: file_id, url: url, headers: headers, contents: contents, upload: %Plug.Upload{path: path, filename: "sample.txt", content_type: "text/plain"}}
  end

  defp upload(fixture) do
    build_conn()
    |> auth(fixture.auth)
    |> put_req_header("cookie", "synthetic-client-cookie")
    |> put_req_header("chatgpt-account-id", "synthetic-client-account")
    |> post("/v1/files", %{"purpose" => "user_data", "file" => fixture.upload})
  end

  defp assert_private_metadata(fixture, public_bodies) do
    file = Repo.get_by!(FileRecord, file_id: fixture.file_id)
    requests = Repo.all(from request in Request, where: request.api_key_id == ^fixture.auth.api_key.id)
    persisted = inspect({file, requests})

    for value <- Map.values(fixture.headers) ++ [fixture.url, fixture.contents, fixture.auth.raw_key, fixture.assignment.access_token] do
      assert not String.contains?(persisted, value), "file/accounting metadata retained private upload data"
      assert Enum.all?(public_bodies, &(not String.contains?(&1, value))), "public file projection retained private upload data"
    end
  end
end
