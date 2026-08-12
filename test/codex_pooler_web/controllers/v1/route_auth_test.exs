defmodule CodexPoolerWeb.V1.RouteAuthTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPoolerWeb.GatewayControllerHelpers
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Path, as: IngressPath
  alias CodexPoolerWeb.V1.UnsupportedRoutes

  @supported_routes [
    {:get, "/v1/models", nil},
    {:get, "/v1/responses", nil},
    {:post, "/v1/responses", %{"model" => "gpt-fixture-text", "input" => "synthetic text"}},
    {:post, "/v1/responses/compact",
     %{"model" => "gpt-fixture-text", "input" => "synthetic text"}},
    {:post, "/v1/chat/completions",
     %{
       "model" => "gpt-fixture-text",
       "messages" => [%{"role" => "user", "content" => "synthetic text"}]
     }},
    {:get, "/v1/usage", nil},
    {:get, "/v1/files", nil},
    {:post, "/v1/files", %{"purpose" => "user_data"}},
    {:post, "/v1/audio/transcriptions", %{"model" => "gpt-4o-transcribe"}},
    {:post, "/v1/images/generations",
     %{"model" => "gpt-image-1", "prompt" => "synthetic image request"}},
    {:post, "/v1/images/edits", %{"model" => "gpt-image-1", "prompt" => "synthetic edit request"}}
  ]

  @unsupported_routes UnsupportedRoutes.test_routes()

  describe "shared /v1 authorization characterization" do
    test "fresh valid bearer returns the enabled pool auth context", %{conn: conn} do
      setup = active_api_key_fixture()

      assert {:ok, auth} =
               conn
               |> auth(setup)
               |> GatewayControllerHelpers.authenticate_v1()

      assert auth.api_key_id == setup.api_key.id
      assert auth.pool_id == setup.pool.id
    end

    test "cached valid auth returns the enabled pool auth context", %{conn: conn} do
      setup = active_api_key_fixture()

      assert {:ok, auth} =
               conn
               |> auth(setup)
               |> GatewayControllerHelpers.authenticate_v1()

      assert {:ok, ^auth} =
               conn
               |> put_private(:runtime_api_auth, auth)
               |> GatewayControllerHelpers.authenticate_v1()
    end

    test "invalid bearer remains a 401 before pool compatibility authorization", %{conn: conn} do
      assert {:error, error} =
               conn
               |> put_req_header("authorization", "Bearer sk-cxp-invalid-fixture")
               |> GatewayControllerHelpers.authenticate_v1()

      assert error.status == 401
      assert error.code == :api_key_missing
    end
  end

  describe "shared /v1 compatibility authorization" do
    test "fresh valid bearer is denied when pool compatibility is disabled", %{conn: conn} do
      setup = active_api_key_fixture()
      disable_v1_compatibility(setup)

      assert {:error, error} =
               conn
               |> auth(setup)
               |> GatewayControllerHelpers.authenticate_v1()

      assert_v1_compatibility_disabled(error)
    end

    test "cached valid auth is denied when pool compatibility is disabled", %{conn: conn} do
      setup = active_api_key_fixture()

      assert {:ok, auth} =
               conn
               |> auth(setup)
               |> GatewayControllerHelpers.authenticate_v1()

      disable_v1_compatibility(setup)

      assert {:error, error} =
               conn
               |> put_private(:runtime_api_auth, auth)
               |> GatewayControllerHelpers.authenticate_v1()

      assert_v1_compatibility_disabled(error)
    end

    test "cached inactive pool auth is denied", %{conn: conn} do
      setup = active_api_key_fixture()

      assert {:ok, auth} =
               conn
               |> auth(setup)
               |> GatewayControllerHelpers.authenticate_v1()

      inactive_auth = %{auth | pool: %{auth.pool | status: "disabled"}}

      assert {:error, error} =
               conn
               |> put_private(:runtime_api_auth, inactive_auth)
               |> GatewayControllerHelpers.authenticate_v1()

      assert_v1_compatibility_disabled(error)
    end
  end

  describe "mandatory /v1 bearer API-key auth" do
    test "unauthenticated /v1 requests return OpenAI-shaped 401", %{conn: conn} do
      for {method, path, body} <- @supported_routes do
        conn = conn |> recycle() |> dispatch_v1(method, path, body)

        assert_openai_error(conn, 401,
          code: "api_key_missing",
          message: "Pool API key is required or invalid"
        )
      end

      assert_no_gateway_side_effects()
    end

    test "unauthenticated transcription alias and lists fail before multipart parsing", %{
      conn: _conn
    } do
      upstream = start_upstream(FakeUpstream.json_response(%{"text" => "must not dispatch"}))
      _setup = gateway_setup(upstream)

      with_isolated_plug_tmpdir(fn tmp_root ->
        {conn, log} =
          with_log(fn ->
            Plug.Test.conn(
              "POST",
              "/v1/audio/transcriptions",
              transcription_multipart_body()
            )
            |> put_req_header(
              "content-type",
              "multipart/form-data; boundary=#{transcription_boundary()}"
            )
            |> @endpoint.call(@endpoint.init([]))
          end)

        assert_openai_error(conn, 401,
          code: "api_key_missing",
          message: "Pool API key is required or invalid"
        )

        assert FakeUpstream.count(upstream) == 0
        assert_no_gateway_side_effects()
        assert Repo.aggregate(LedgerEntry, :count) == 0
        assert tmpdir_paths(tmp_root) == []

        for sentinel <- unauthenticated_transcription_sentinels() do
          refute log =~ sentinel
          refute conn.resp_body =~ sentinel
        end
      end)
    end

    test "invalid bearer keys return OpenAI-shaped 401", %{conn: conn} do
      for path <- ["/v1/models", "/v1/responses"] do
        conn =
          conn
          |> recycle()
          |> put_req_header("authorization", "Bearer sk-cxp-invalid-fixture")
          |> get(path)

        assert_openai_error(conn, 401,
          code: "api_key_missing",
          message: "Pool API key is required or invalid"
        )
      end

      assert_no_gateway_side_effects()
    end

    test "websocket upgrade-shaped GET /v1/responses denies missing and invalid bearer before upgrade",
         %{conn: conn} do
      missing_bearer =
        conn
        |> websocket_upgrade_headers()
        |> get("/v1/responses")

      assert_openai_error(missing_bearer, 401,
        code: "api_key_missing",
        message: "Pool API key is required or invalid"
      )

      invalid_bearer =
        build_conn()
        |> websocket_upgrade_headers()
        |> put_req_header("authorization", "Bearer sk-cxp-invalid-fixture")
        |> get("/v1/responses")

      assert_openai_error(invalid_bearer, 401,
        code: "api_key_missing",
        message: "Pool API key is required or invalid"
      )

      assert get_resp_header(missing_bearer, "sec-websocket-accept") == []
      assert get_resp_header(invalid_bearer, "sec-websocket-accept") == []
      assert_no_gateway_side_effects()
    end

    test "disabled API keys return OpenAI-shaped 401", %{conn: conn} do
      setup = paused_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> get("/v1/models")

      assert_openai_error(conn, 401,
        code: "api_key_disabled",
        message: "Pool API key is required or invalid"
      )

      assert_no_gateway_side_effects()
    end

    test "valid enabled API keys reject unsupported fields with OpenAI-shaped 400", %{conn: conn} do
      setup = active_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => "gpt-fixture-text",
          "input" => "synthetic text",
          "logprobs" => true
        })

      assert_openai_error(conn, 400,
        code: "unsupported_parameter",
        param: "logprobs",
        message: "Unsupported parameter: logprobs"
      )

      assert_no_gateway_side_effects()
    end

    @tag :disabled_pool
    test "valid keys for disabled pools fail before returning an auth context", %{conn: conn} do
      setup = active_api_key_fixture()

      setup.pool
      |> Ecto.Changeset.change(%{status: "disabled"})
      |> Repo.update!()

      conn =
        conn
        |> auth(setup)
        |> get("/v1/models")

      assert_openai_error(conn, 401,
        code: "api_key_missing",
        message: "Pool API key is required or invalid"
      )

      assert_no_gateway_side_effects()
    end

    test "active pools with v1 compatibility disabled return OpenAI-shaped 403", %{conn: conn} do
      setup = active_api_key_fixture()
      disable_v1_compatibility(setup)

      conn =
        conn
        |> auth(setup)
        |> get("/v1/models")

      assert_openai_error(conn, 403,
        code: "v1_compatibility_disabled",
        message: "Compatibility access is disabled for this Pool"
      )

      assert_no_gateway_side_effects()
    end

    test "invalid bearer stays 401 when another pool has v1 compatibility disabled", %{conn: conn} do
      setup = active_api_key_fixture()
      disable_v1_compatibility(setup)

      conn =
        conn
        |> put_req_header("authorization", "Bearer sk-cxp-invalid-fixture")
        |> get("/v1/models")

      assert_openai_error(conn, 401,
        code: "api_key_missing",
        message: "Pool API key is required or invalid"
      )

      assert_no_gateway_side_effects()
    end

    test "v1 compatibility denial precedes malformed supported JSON parsing", %{conn: conn} do
      setup = active_api_key_fixture()
      disable_v1_compatibility(setup)

      conn =
        conn
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/responses", "{not-json")

      assert_openai_error(conn, 403,
        code: "v1_compatibility_disabled",
        message: "Compatibility access is disabled for this Pool"
      )

      assert_no_gateway_side_effects()
    end

    test "v1 compatibility denial blocks supported, unsupported, multipart, and websocket work",
         %{conn: conn} do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
      setup = gateway_setup(upstream)
      disable_v1_compatibility(setup)

      with_isolated_plug_tmpdir(fn tmp_root ->
        supported =
          conn
          |> auth(setup)
          |> post("/v1/responses", %{
            "model" => "gpt-fixture-text",
            "input" => "synthetic text"
          })

        assert_openai_error(supported, 403,
          code: "v1_compatibility_disabled",
          message: "Compatibility access is disabled for this Pool"
        )

        unsupported =
          build_conn()
          |> auth(setup)
          |> post("/v1/embeddings", %{})

        assert_openai_error(unsupported, 403,
          code: "v1_compatibility_disabled",
          message: "Compatibility access is disabled for this Pool"
        )

        multipart =
          build_conn()
          |> auth(setup)
          |> put_req_header("content-type", "multipart/form-data; boundary=missing-boundary")
          |> post("/v1/audio/transcriptions", "not a valid multipart body")

        assert_openai_error(multipart, 403,
          code: "v1_compatibility_disabled",
          message: "Compatibility access is disabled for this Pool"
        )

        websocket =
          build_conn()
          |> auth(setup)
          |> websocket_upgrade_headers()
          |> get("/v1/responses")

        assert_openai_error(websocket, 403,
          code: "v1_compatibility_disabled",
          message: "Compatibility access is disabled for this Pool"
        )

        assert get_resp_header(websocket, "sec-websocket-accept") == []
        assert FakeUpstream.count(upstream) == 0
        assert_no_gateway_side_effects()
        assert Repo.aggregate(LedgerEntry, :count) == 0
        assert tmpdir_paths(tmp_root) == []
      end)
    end
  end

  describe "unsupported /v1 public OpenAI surfaces" do
    test "unsupported route matching uses the canonical path view with direct fallback" do
      direct = Plug.Test.conn(:post, "/v1/%69mages/variations")

      cached =
        direct
        |> IngressPath.populate()
        |> Map.put(:path_info, ["unrelated"])

      assert UnsupportedRoutes.unsupported?(direct)
      assert UnsupportedRoutes.unsupported?(cached)
    end

    test "encoded unsupported route spelling returns the deterministic OpenAI error", %{
      conn: conn
    } do
      setup = active_api_key_fixture()

      conn = conn |> auth(setup) |> post("/v1/%69mages/variations", %{})

      assert_openai_error(conn, 404,
        code: "unsupported_endpoint",
        message: "Unsupported OpenAI /v1 endpoint"
      )
    end

    test "unsupported route registry lists the SDK-probed endpoint shapes exactly" do
      assert @unsupported_routes == [
               {:post, "/v1/images/variations"},
               {:post, "/v1/content_provenance_checks"},
               {:post, "/v1/embeddings"},
               {:post, "/v1/batches"},
               {:post, "/v1/moderations"},
               {:post, "/v1/fine_tuning/jobs"},
               {:get, "/v1/responses/resp_fixture"},
               {:post, "/v1/responses/resp_fixture/cancel"},
               {:delete, "/v1/responses/resp_fixture"}
             ]
    end

    test "/v1/realtime remains outside the public route surface", %{conn: conn} do
      setup = active_api_key_fixture()

      for path <- ["/v1/realtime", "/v1/realtime/sessions"] do
        conn = conn |> recycle() |> auth(setup) |> get(path)

        assert html_response(conn, 404) =~ "Not Found"
        refute get_resp_header(conn, "content-type") |> Enum.join(" ") |> String.contains?("json")
      end

      assert_no_gateway_side_effects()
    end

    test "legacy public OpenAI endpoints return deterministic OpenAI-shaped 404", %{conn: conn} do
      setup = active_api_key_fixture()

      for {method, path} <- @unsupported_routes do
        conn = conn |> recycle() |> auth(setup) |> dispatch_v1(method, path, %{})

        assert_openai_error(conn, 404,
          code: "unsupported_endpoint",
          message: "Unsupported OpenAI /v1 endpoint"
        )

        assert [content_type] = get_resp_header(conn, "content-type")
        assert content_type =~ "application/json"
      end

      assert_no_gateway_side_effects()
    end

    test "unsupported POST routes reject malformed JSON before body parsing", %{conn: conn} do
      setup = active_api_key_fixture()

      for {_method, path} <- Enum.filter(@unsupported_routes, &match?({:post, _path}, &1)) do
        conn =
          conn
          |> recycle()
          |> auth(setup)
          |> put_req_header("content-type", "application/json")
          |> post(path, "{not-json")

        assert_openai_error(conn, 404,
          code: "unsupported_endpoint",
          message: "Unsupported OpenAI /v1 endpoint"
        )
      end

      assert_no_gateway_side_effects()
    end

    test "unsupported POST routes preserve auth and compatibility gates before oversized parsing",
         %{
           conn: conn
         } do
      setup = active_api_key_fixture()
      oversized_body = "{" <> String.duplicate("x", 9_000_000)

      unauthenticated =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/v1/embeddings", oversized_body)

      assert_openai_error(unauthenticated, 401,
        code: "api_key_missing",
        message: "Pool API key is required or invalid"
      )

      setup.pool
      |> Ecto.Changeset.change(%{status: "disabled"})
      |> Repo.update!()

      disabled_pool =
        build_conn()
        |> auth(setup)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/batches", oversized_body)

      assert_openai_error(disabled_pool, 401,
        code: "api_key_missing",
        message: "Pool API key is required or invalid"
      )

      assert_no_gateway_side_effects()
    end

    test "content provenance checks reject malformed multipart before parsing or dispatch", %{
      conn: conn
    } do
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
      setup = gateway_setup(upstream)

      with_isolated_plug_tmpdir(fn tmp_root ->
        conn = conn |> auth(setup) |> post_malformed_content_provenance()

        assert json_response(conn, 404) == %{
                 "error" => %{
                   "message" => "Unsupported OpenAI /v1 endpoint",
                   "type" => "invalid_request_error",
                   "code" => "unsupported_endpoint",
                   "param" => nil
                 }
               }

        assert [content_type] = get_resp_header(conn, "content-type")
        assert content_type =~ "application/json"
        assert FakeUpstream.requests(upstream) == []
        assert_no_gateway_side_effects()
        assert Repo.aggregate(LedgerEntry, :count) == 0
        assert tmpdir_paths(tmp_root) == []
      end)
    end

    test "content provenance checks preserve auth and pool gates before multipart parsing", %{
      conn: conn
    } do
      disabled_pool_setup = active_api_key_fixture()

      disabled_pool_setup.pool
      |> Ecto.Changeset.change(%{status: "disabled"})
      |> Repo.update!()

      compatibility_disabled_setup = active_api_key_fixture()

      compatibility_disabled_setup.pool
      |> Pools.ensure_routing_settings()
      |> Ecto.Changeset.change(%{v1_compatibility_enabled: false})
      |> Repo.update!()

      with_isolated_plug_tmpdir(fn tmp_root ->
        unauthenticated = post_malformed_content_provenance(conn)

        assert_openai_error(unauthenticated, 401,
          code: "api_key_missing",
          message: "Pool API key is required or invalid"
        )

        disabled_pool =
          build_conn()
          |> auth(disabled_pool_setup)
          |> post_malformed_content_provenance()

        assert_openai_error(disabled_pool, 401,
          code: "api_key_missing",
          message: "Pool API key is required or invalid"
        )

        compatibility_disabled =
          build_conn()
          |> auth(compatibility_disabled_setup)
          |> post_malformed_content_provenance()

        assert_openai_error(compatibility_disabled, 403,
          code: "v1_compatibility_disabled",
          message: "Compatibility access is disabled for this Pool"
        )

        assert_no_gateway_side_effects()
        assert Repo.aggregate(LedgerEntry, :count) == 0
        assert tmpdir_paths(tmp_root) == []
      end)
    end

    test "unsupported multipart routes return deterministic errors before multipart parsing", %{
      conn: conn
    } do
      setup = active_api_key_fixture()

      conn =
        conn
        |> auth(setup)
        |> put_req_header("content-type", "multipart/form-data; boundary=missing-boundary")
        |> post("/v1/images/variations", "not a valid multipart body")

      assert_openai_error(conn, 404,
        code: "unsupported_endpoint",
        message: "Unsupported OpenAI /v1 endpoint"
      )

      assert_no_gateway_side_effects()
    end
  end

  describe "legacy admin and dashboard surfaces stay blocked" do
    test "/api/admin/* remains blocked as standard non-runtime 404", %{conn: conn} do
      conn = get(conn, "/api/admin/pools")

      assert html_response(conn, 404) =~ "Not Found"
      refute get_resp_header(conn, "content-type") |> Enum.join(" ") |> String.contains?("json")
    end

    test "/dashboard/* remains blocked as standard non-runtime 404", %{conn: conn} do
      conn = get(conn, "/dashboard")

      assert html_response(conn, 404) =~ "Not Found"
      refute get_resp_header(conn, "content-type") |> Enum.join(" ") |> String.contains?("json")
    end

    test "dashboard JSON API paths remain blocked as standard non-runtime 404", %{conn: conn} do
      for path <- ["/dashboard/api/requests", "/dashboard/api/pools", "/api/dashboard/requests"] do
        conn = conn |> recycle() |> get(path)

        assert html_response(conn, 404) =~ "Not Found"
        refute get_resp_header(conn, "content-type") |> Enum.join(" ") |> String.contains?("json")
      end
    end
  end

  defp dispatch_v1(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_v1(conn, :post, path, body), do: post(conn, path, body || %{})
  defp dispatch_v1(conn, :delete, path, _body), do: delete(conn, path)

  defp auth(conn, setup), do: put_req_header(conn, "authorization", setup.authorization)

  defp websocket_upgrade_headers(conn) do
    conn
    |> put_req_header("connection", "upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-version", "13")
    |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
  end

  defp assert_openai_error(conn, status, opts) do
    assert %{"error" => error} = json_response(conn, status)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == Keyword.fetch!(opts, :code)
    assert error["message"] == Keyword.fetch!(opts, :message)
    assert error["param"] == Keyword.get(opts, :param)
  end

  defp assert_no_gateway_side_effects do
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  defp assert_v1_compatibility_disabled(error) do
    assert error == %{
             status: 403,
             code: "v1_compatibility_disabled",
             message: "Compatibility access is disabled for this Pool"
           }
  end

  defp disable_v1_compatibility(setup) do
    setup.pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{v1_compatibility_enabled: false})
    |> Repo.update!()
  end

  defp post_malformed_content_provenance(conn) do
    conn
    |> put_req_header("content-type", "multipart/form-data; boundary=missing-boundary")
    |> post("/v1/content_provenance_checks", "not a valid multipart body")
  end

  defp transcription_boundary, do: "v1-auth-transcription-boundary"

  defp unauthenticated_transcription_sentinels do
    [
      "gpt-transcribe",
      "auth keyword sentinel",
      "auth language sentinel",
      "auth-audio.wav",
      "auth audio sentinel"
    ]
  end

  defp transcription_multipart_body do
    boundary = transcription_boundary()

    [
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"model\"\r\n\r\n",
      "gpt-transcribe\r\n",
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"keywords[]\"\r\n\r\n",
      "auth keyword sentinel\r\n",
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"languages[]\"\r\n\r\n",
      "auth language sentinel\r\n",
      "--#{boundary}\r\n",
      "content-disposition: form-data; name=\"file\"; filename=\"auth-audio.wav\"\r\n",
      "content-type: audio/wav\r\n\r\n",
      "auth audio sentinel\r\n",
      "--#{boundary}--\r\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp with_isolated_plug_tmpdir(fun) do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-v1-auth-tmp-#{System.unique_integer([:positive])}"
      )

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
