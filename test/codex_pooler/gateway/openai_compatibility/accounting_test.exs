defmodule CodexPooler.Gateway.OpenAICompatibilityAccountingTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Repo

  @raw_prompt_sentinel "TASK5_OPENAI_RAW_PROMPT_SENTINEL"
  @raw_multipart_sentinel "TASK5_MULTIPART_BODY_SENTINEL"
  @raw_file_sentinel "TASK5_FILE_BYTES_SENTINEL"
  @raw_audio_sentinel "TASK5_AUDIO_BYTES_SENTINEL"
  @raw_image_sentinel "TASK5_IMAGE_BYTES_SENTINEL"
  @raw_bearer_sentinel "Bearer TASK5_BEARER_TOKEN_SENTINEL"
  @raw_upload_url_sentinel "https://upload.example.invalid/TASK5_UPLOAD_URL_SENTINEL"
  @raw_websocket_sentinel "TASK5_WEBSOCKET_FRAME_SENTINEL"
  @raw_idempotency_sentinel "TASK5_RAW_IDEMPOTENCY_KEY_SENTINEL"
  @raw_secret_sentinel "TASK5_SECRET_SENTINEL"

  @tag :success_once
  test "Responses adapter gateway success records one request attempt and settlement", %{
    conn: _conn
  } do
    with_gateway_debug(fn ->
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_task5_success",
            "object" => "response",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 7, "total_tokens" => 12}
          })
        )

      setup = gateway_setup(upstream)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

      assert {:ok, result} =
               Responses.coerce(success_payload(setup),
                 request_id: "task5-success-once",
                 idempotency_key: @raw_idempotency_sentinel,
                 user_agent: "openai-task5-harness/1.0",
                 routing_attempt_metadata: sensitive_attempt_metadata()
               )

      assert {:ok, response} =
               Gateway.execute(auth, result.endpoint, result.payload, result.request_options)

      assert response.status == 200
      assert %{"id" => "resp_task5_success"} = Jason.decode!(response.raw_body)
      assert FakeUpstream.count(upstream) == 1

      assert_exactly_once_accounting!(setup.pool.id,
        request_status: "succeeded",
        attempt_status: "succeeded",
        usage_status: "usage_known",
        response_status_code: 200
      )

      assert_persisted_surfaces_exclude_raw_sentinels!(setup.pool)
    end)
  end

  @tag :success_once
  test "Responses adapter upstream validation failure records one failed attempt and settlement" do
    upstream =
      start_upstream(
        {:json_error, 400,
         %{
           "error" => %{
             "code" => "invalid_request_error",
             "message" => "synthetic upstream rejection"
           }
         }}
      )

    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    assert {:ok, result} =
             Responses.coerce(success_payload(setup),
               request_id: "task5-upstream-failure-once",
               user_agent: "openai-task5-harness/1.0",
               routing_attempt_metadata: sensitive_attempt_metadata()
             )

    assert {:ok, response} =
             Gateway.execute(auth, result.endpoint, result.payload, result.request_options)

    assert response.status == 400
    assert FakeUpstream.count(upstream) == 1

    assert_exactly_once_accounting!(setup.pool.id,
      request_status: "failed",
      attempt_status: "failed",
      usage_status: "usage_unknown",
      response_status_code: 400,
      last_error_code: "upstream_status"
    )

    assert_persisted_surfaces_exclude_raw_sentinels!(setup.pool)
  end

  @tag :rejected_no_side_effects
  test "auth preflight rejections create no accounting and do not contact configured upstream", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)
    paused = paused_api_key_fixture(setup.pool)

    cases = [
      {:get, "/v1/models", nil, [], 401, "api_key_missing"},
      {:post, "/v1/responses", rejected_payload(setup), [{"authorization", "Bearer invalid"}],
       401, "api_key_missing"},
      {:get, "/v1/models", nil, [{"authorization", paused.authorization}], 401,
       "api_key_disabled"}
    ]

    for {method, path, body, headers, status, code} <- cases do
      response = conn |> recycle() |> put_headers(headers) |> dispatch_v1(method, path, body)
      assert_openai_error(response, status, code)
    end

    assert_no_accounting_side_effects!()
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :rejected_no_side_effects
  test "disabled pool unsupported routes and invalid payloads create no accounting or dispatch",
       %{
         conn: conn
       } do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    setup.pool
    |> Ecto.Changeset.change(%{status: "disabled"})
    |> Repo.update!()

    disabled_response = conn |> recycle() |> auth(setup) |> get("/v1/models")
    assert_openai_error(disabled_response, 401, "api_key_missing")

    active_upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    active_setup = gateway_setup(active_upstream)

    cases = [
      {:post, "/v1/embeddings", rejected_payload(setup), 404, "unsupported_endpoint"},
      {:post, "/v1/images/variations", rejected_payload(setup), 404, "unsupported_endpoint"},
      {:post, "/v1/responses", Map.put(rejected_payload(setup), "logprobs", true), 400,
       "unsupported_parameter"},
      {:post, "/v1/files",
       %{"purpose" => "fine_tuning", "file" => %{"filename" => "upload", "bytes" => 12}}, 400,
       "invalid_request"},
      {:post, "/v1/images/generations",
       %{"model" => "gpt-image-1", "prompt" => @raw_prompt_sentinel, "size" => "2048x2048"}, 400,
       "invalid_request"}
    ]

    for {method, path, body, status, code} <- cases do
      response = build_conn() |> auth(active_setup) |> dispatch_v1(method, path, body)
      assert_openai_error(response, status, code)
    end

    assert_no_accounting_side_effects!()
    assert FakeUpstream.count(upstream) == 0
    assert FakeUpstream.count(active_upstream) == 0
  end

  @tag :rejected_no_side_effects
  test "rejected v1 responses do not persist or render raw OpenAI sentinels", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "should_not_dispatch"}))
    setup = gateway_setup(upstream)

    response =
      conn
      |> recycle()
      |> auth(setup)
      |> put_req_header("idempotency-key", @raw_idempotency_sentinel)
      |> post("/v1/responses", rejected_payload(setup))

    assert_openai_error(response, 400, "unsupported_parameter")
    assert_no_accounting_side_effects!()
    assert FakeUpstream.count(upstream) == 0

    response_text = response.resp_body || ""
    refute_contains_raw_sentinels!(response_text)
  end

  defp success_payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => @raw_prompt_sentinel,
      "stream" => false
    }
  end

  defp rejected_payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => @raw_prompt_sentinel,
      "logprobs" => true,
      "metadata" => %{
        "multipart_body" => @raw_multipart_sentinel,
        "file_bytes" => @raw_file_sentinel,
        "audio_bytes" => @raw_audio_sentinel,
        "image_bytes" => @raw_image_sentinel,
        "authorization" => @raw_bearer_sentinel,
        "upload_url" => @raw_upload_url_sentinel,
        "raw_websocket_frame_payload" => @raw_websocket_sentinel,
        "raw_idempotency_key_payload" => @raw_idempotency_sentinel,
        "secret" => @raw_secret_sentinel
      }
    }
  end

  defp sensitive_attempt_metadata do
    %{
      "multipart_body" => @raw_multipart_sentinel,
      "file_bytes" => @raw_file_sentinel,
      "audio_bytes" => @raw_audio_sentinel,
      "image_bytes" => @raw_image_sentinel,
      "authorization" => @raw_bearer_sentinel,
      "upload_url" => @raw_upload_url_sentinel,
      "raw_websocket_frame_payload" => @raw_websocket_sentinel,
      "raw_idempotency_key_payload" => @raw_idempotency_sentinel,
      "secret" => @raw_secret_sentinel
    }
  end

  defp assert_exactly_once_accounting!(pool_id, opts) do
    assert [request] = Repo.all(from r in Request, where: r.pool_id == ^pool_id)
    assert request.status == Keyword.fetch!(opts, :request_status)
    assert request.usage_status == Keyword.fetch!(opts, :usage_status)
    assert request.response_status_code == Keyword.fetch!(opts, :response_status_code)

    if last_error_code = Keyword.get(opts, :last_error_code) do
      assert request.last_error_code == last_error_code
    end

    assert [attempt] = Repo.all(from a in Attempt, where: a.request_id == ^request.id)
    assert attempt.status == Keyword.fetch!(opts, :attempt_status)
    assert attempt.usage_status == Keyword.fetch!(opts, :usage_status)

    assert ledger_kinds(request) == ["release", "reservation", "settlement"]
    assert settlement_count(request) == 1

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool_id)
    assert log.id == request.id
    assert log.status == request.status
  end

  defp ledger_kinds(request) do
    Repo.all(
      from entry in LedgerEntry,
        where: entry.request_id == ^request.id,
        order_by: [asc: entry.entry_kind],
        select: entry.entry_kind
    )
  end

  defp settlement_count(request) do
    Repo.aggregate(
      from(entry in LedgerEntry,
        where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
      ),
      :count
    )
  end

  defp assert_no_accounting_side_effects! do
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0
  end

  defp assert_persisted_surfaces_exclude_raw_sentinels!(pool) do
    persisted = %{
      requests:
        Repo.all(
          from r in Request,
            where: r.pool_id == ^pool.id,
            select: %{request_metadata: r.request_metadata}
        ),
      attempts:
        Repo.all(
          from a in Attempt,
            join: r in Request,
            on: r.id == a.request_id,
            where: r.pool_id == ^pool.id,
            select: %{response_metadata: a.response_metadata, error_message: a.error_message}
        ),
      request_logs: Accounting.list_request_logs(pool),
      audits: Repo.all(from event in AuditEvent, where: event.pool_id == ^pool.id)
    }

    refute_contains_raw_sentinels!(inspect(persisted))
  end

  defp refute_contains_raw_sentinels!(text) do
    for sentinel <- raw_sentinels() do
      refute text =~ sentinel
    end
  end

  defp raw_sentinels do
    [
      @raw_prompt_sentinel,
      @raw_multipart_sentinel,
      @raw_file_sentinel,
      @raw_audio_sentinel,
      @raw_image_sentinel,
      @raw_bearer_sentinel,
      @raw_upload_url_sentinel,
      @raw_websocket_sentinel,
      @raw_idempotency_sentinel,
      @raw_secret_sentinel
    ]
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)
  end

  defp dispatch_v1(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_v1(conn, :post, path, body), do: post(conn, path, body || %{})

  defp assert_openai_error(conn, status, code) do
    assert %{"error" => error} = json_response(conn, status)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == code
  end

  defp with_gateway_debug(fun) do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{gateway_debug?: true}
    )

    try do
      fun.()
    after
      if previous_env,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous_env),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end
  end
end
