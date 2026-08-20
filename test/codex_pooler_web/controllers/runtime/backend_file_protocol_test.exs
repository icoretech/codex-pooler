defmodule CodexPoolerWeb.Runtime.BackendFileProtocolTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, start_upstream: 1]

  alias CodexPooler.Accounting.Request
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

  @tag :fake_upstream_file_protocol
  test "fake upstream file protocol captures create/finalize contract and error modes" do
    pool = pool_fixture()

    upstream_assignment =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct_file_protocol_#{System.unique_integer([:positive])}"
      })

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: "file_fake_protocol",
          file_name: "contract-fixture.txt",
          mime_type: "text/plain"
        )
      )

    headers = [
      {"authorization", "Bearer #{upstream_assignment.access_token}"},
      {"chatgpt-account-id", upstream_assignment.identity.chatgpt_account_id}
    ]

    create_response =
      Req.post!(FakeUpstream.url(upstream) <> "/backend-api/files",
        json: %{
          "file_name" => "contract-fixture.txt",
          "file_size" => 12,
          "use_case" => "user_data"
        },
        headers: headers
      )

    assert create_response.status == 200

    assert create_response.body == %{
             "file_id" => "file_fake_protocol",
             "upload_url" =>
               "https://fake-upload.invalid/upload/file_fake_protocol?sig=fake-upload"
           }

    finalize_response =
      Req.post!(FakeUpstream.url(upstream) <> "/backend-api/files/file_fake_protocol/uploaded",
        json: %{},
        headers: headers
      )

    assert finalize_response.status == 200

    assert finalize_response.body == %{
             "status" => "success",
             "download_url" =>
               "https://fake-download.invalid/download/file_fake_protocol?sig=fake-download",
             "file_name" => "contract-fixture.txt",
             "mime_type" => "text/plain"
           }

    assert [create_request, finalize_request] = FakeUpstream.requests(upstream)
    assert create_request.method == "POST"
    assert create_request.path == "/backend-api/files"

    assert create_request.json == %{
             "file_name" => "contract-fixture.txt",
             "file_size" => 12,
             "use_case" => "user_data"
           }

    assert finalize_request.path == "/backend-api/files/file_fake_protocol/uploaded"
    assert finalize_request.json == %{}

    assert header!(create_request.headers, "authorization") ==
             "Bearer #{upstream_assignment.access_token}"

    assert header!(create_request.headers, "chatgpt-account-id") ==
             upstream_assignment.identity.chatgpt_account_id

    refute header!(create_request.headers, "chatgpt-account-id") == "sentinel-account-id"

    unauthorized =
      start_upstream(FakeUpstream.file_protocol_unauthorized(file_id: "file_auth_error"))

    unauthorized_response =
      Req.post!(FakeUpstream.url(unauthorized) <> "/backend-api/files",
        json: %{"file_name" => "unauthorized.txt", "file_size" => 5, "use_case" => "user_data"},
        headers: headers,
        retry: false
      )

    assert unauthorized_response.status == 401
    assert unauthorized_response.body["error"]["code"] == "invalid_api_key"

    text_error =
      start_upstream(FakeUpstream.file_protocol_non_json_error(file_id: "file_text_error"))

    text_error_response =
      Req.post!(FakeUpstream.url(text_error) <> "/backend-api/files/file_text_error/uploaded",
        json: %{},
        headers: headers,
        decode_body: false,
        retry: false
      )

    assert text_error_response.status == 502
    assert text_error_response.body == "fake upstream file finalize failure"
  end

  @tag :fake_upstream_finalize_retry
  test "fake upstream finalize retry returns retry then success" do
    pool = pool_fixture()

    upstream_assignment =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct_file_retry_#{System.unique_integer([:positive])}"
      })

    upstream =
      start_upstream(
        FakeUpstream.file_protocol_finalize_retry(
          file_id: "file_retry_protocol",
          file_name: "retry-fixture.txt",
          mime_type: "text/plain"
        )
      )

    headers = [
      {"authorization", "Bearer #{upstream_assignment.access_token}"},
      {"chatgpt-account-id", upstream_assignment.identity.chatgpt_account_id}
    ]

    create_response =
      Req.post!(FakeUpstream.url(upstream) <> "/backend-api/files",
        json: %{"file_name" => "retry-fixture.txt", "file_size" => 21, "use_case" => "user_data"},
        headers: headers
      )

    assert create_response.body["file_id"] == "file_retry_protocol"

    first_finalize =
      Req.post!(FakeUpstream.url(upstream) <> "/backend-api/files/file_retry_protocol/uploaded",
        json: %{},
        headers: headers
      )

    assert first_finalize.status == 200
    assert first_finalize.body == %{"status" => "retry"}

    second_finalize =
      Req.post!(FakeUpstream.url(upstream) <> "/backend-api/files/file_retry_protocol/uploaded",
        json: %{},
        headers: headers
      )

    assert second_finalize.status == 200

    assert second_finalize.body == %{
             "status" => "success",
             "download_url" =>
               "https://fake-download.invalid/download/file_retry_protocol?sig=fake-download",
             "file_name" => "retry-fixture.txt",
             "mime_type" => "text/plain"
           }

    assert [create_request, first_finalize_request, second_finalize_request] =
             FakeUpstream.requests(upstream)

    assert create_request.path == "/backend-api/files"
    assert first_finalize_request.path == "/backend-api/files/file_retry_protocol/uploaded"
    assert second_finalize_request.path == "/backend-api/files/file_retry_protocol/uploaded"
  end

  test "backend file create and finalize derive residency from valid selected credentials", %{
    conn: conn
  } do
    cases = [
      {"namespaced", residency_token(:namespaced, "file-region-namespaced"),
       "file-region-namespaced"},
      {"root", residency_token(:root, "file-region-root"), "file-region-root"}
    ]

    Enum.each(cases, fn {label, token, expected_residency} ->
      setup = active_api_key_fixture()
      file_id = "file_residency_#{label}_#{System.unique_integer([:positive])}"

      upstream =
        start_upstream(
          FakeUpstream.file_protocol_success(
            file_id: file_id,
            file_name: "#{label}.txt",
            mime_type: "text/plain"
          )
        )

      assignment =
        active_upstream_assignment_fixture(setup.pool, %{
          chatgpt_account_id: "acct_file_residency_#{System.unique_integer([:positive])}",
          metadata: %{"base_url" => FakeUpstream.url(upstream)},
          access_token: token
        })

      create_conn =
        conn
        |> recycle()
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> put_req_header(
          "x-openai-internal-codex-residency",
          "caller-controlled-residency"
        )
        |> post(~p"/backend-api/files", %{
          "file_name" => "#{label}.txt",
          "file_size" => 12,
          "use_case" => "codex"
        })

      assert %{"file_id" => ^file_id} = json_response(create_conn, 200)

      finalize_conn =
        build_conn()
        |> auth(setup)
        |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

      assert %{"status" => "success"} = json_response(finalize_conn, 200)
      assert [create_request, finalize_request] = FakeUpstream.requests(upstream)

      for captured <- [create_request, finalize_request] do
        assert header_values(captured.headers, "x-openai-internal-codex-residency") == [
                 expected_residency
               ]

        assert header_values(captured.headers, "chatgpt-account-id") == [
                 assignment.identity.chatgpt_account_id
               ]
      end

      refute "caller-controlled-residency" in header_values(
               create_request.headers,
               "x-openai-internal-codex-residency"
             )

      persisted =
        inspect(%{
          file: Repo.get_by!(FileRecord, file_id: file_id),
          requests: Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)
        })

      refute persisted =~ token
      refute persisted =~ expected_residency
      refute persisted =~ "caller-controlled-residency"
    end)
  end

  test "backend file create and finalize omit residency for invalid selected credentials", %{
    conn: conn
  } do
    cases = [
      {"no-constraint", residency_token(:root, "no_constraint")},
      {"malformed", "malformed-selected-credential"},
      {"invalid-field-value", residency_token(:root, "invalid\r\nvalue")}
    ]

    Enum.each(cases, fn {label, token} ->
      setup = active_api_key_fixture()
      file_id = "file_no_residency_#{System.unique_integer([:positive])}"

      upstream =
        start_upstream(
          FakeUpstream.file_protocol_success(
            file_id: file_id,
            file_name: "#{label}.txt",
            mime_type: "text/plain"
          )
        )

      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_no_residency_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(upstream)},
        access_token: token
      })

      create_conn =
        conn
        |> recycle()
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> put_req_header(
          "x-openai-internal-codex-residency",
          "caller-controlled-residency"
        )
        |> post(~p"/backend-api/files", %{
          "file_name" => "#{label}.txt",
          "file_size" => 12,
          "use_case" => "codex"
        })

      assert %{"file_id" => ^file_id} = json_response(create_conn, 200)

      finalize_conn =
        build_conn()
        |> auth(setup)
        |> post(~p"/backend-api/files/#{file_id}/uploaded", %{})

      assert %{"status" => "success"} = json_response(finalize_conn, 200)

      assert [create_request, finalize_request] = FakeUpstream.requests(upstream)

      for captured <- [create_request, finalize_request] do
        assert header_values(captured.headers, "x-openai-internal-codex-residency") == []
      end

      persisted =
        inspect(%{
          file: Repo.get_by!(FileRecord, file_id: file_id),
          requests: Repo.all(from request in Request, where: request.pool_id == ^setup.pool.id)
        })

      refute persisted =~ token
      refute persisted =~ "caller-controlled-residency"
    end)
  end

  test "file control-plane requests do not reuse residency from a prior selected credential", %{
    conn: conn
  } do
    valid_setup = active_api_key_fixture()
    valid_file_id = "file_stale_valid_#{System.unique_integer([:positive])}"

    valid_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: valid_file_id,
          file_name: "valid.txt",
          mime_type: "text/plain"
        )
      )

    active_upstream_assignment_fixture(valid_setup.pool, %{
      metadata: %{"base_url" => FakeUpstream.url(valid_upstream)},
      access_token: residency_token(:root, "file-region-before-invalid")
    })

    valid_create =
      conn
      |> auth(valid_setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "valid.txt",
        "file_size" => 12,
        "use_case" => "codex"
      })

    assert %{"file_id" => ^valid_file_id} = json_response(valid_create, 200)

    valid_finalize =
      build_conn()
      |> auth(valid_setup)
      |> post(~p"/backend-api/files/#{valid_file_id}/uploaded", %{})

    assert %{"status" => "success"} = json_response(valid_finalize, 200)
    assert [valid_create_request, valid_finalize_request] = FakeUpstream.requests(valid_upstream)

    for captured <- [valid_create_request, valid_finalize_request] do
      assert length(header_values(captured.headers, "x-openai-internal-codex-residency")) == 1
    end

    invalid_setup = active_api_key_fixture()
    invalid_file_id = "file_stale_invalid_#{System.unique_integer([:positive])}"

    invalid_upstream =
      start_upstream(
        FakeUpstream.file_protocol_success(
          file_id: invalid_file_id,
          file_name: "invalid.txt",
          mime_type: "text/plain"
        )
      )

    active_upstream_assignment_fixture(invalid_setup.pool, %{
      metadata: %{"base_url" => FakeUpstream.url(invalid_upstream)},
      access_token: "malformed-selected-credential"
    })

    invalid_create =
      build_conn()
      |> auth(invalid_setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{
        "file_name" => "invalid.txt",
        "file_size" => 12,
        "use_case" => "codex"
      })

    assert %{"file_id" => ^invalid_file_id} = json_response(invalid_create, 200)

    invalid_finalize =
      build_conn()
      |> auth(invalid_setup)
      |> post(~p"/backend-api/files/#{invalid_file_id}/uploaded", %{})

    assert %{"status" => "success"} = json_response(invalid_finalize, 200)

    assert [invalid_create_request, invalid_finalize_request] =
             FakeUpstream.requests(invalid_upstream)

    for captured <- [invalid_create_request, invalid_finalize_request] do
      assert header_values(captured.headers, "x-openai-internal-codex-residency") == []
    end
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

  defp residency_token(:namespaced, value) do
    jwt(%{"https://api.openai.com/auth" => %{"chatgpt_compute_residency" => value}})
  end

  defp residency_token(:root, value), do: jwt(%{"chatgpt_compute_residency" => value})

  defp jwt(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    Enum.join([header, payload, "signature"], ".")
  end

  defp header_values(headers, expected_name) do
    for {name, value} <- headers, String.downcase(name) == expected_name, do: value
  end
end
