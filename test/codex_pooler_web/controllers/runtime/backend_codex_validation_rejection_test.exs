defmodule CodexPoolerWeb.Runtime.BackendCodexValidationRejectionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @provider_sentinel "private-provider-validation-sentinel"
  @prompt_sentinel "private-validation-prompt-sentinel"

  @message_with_list "Unsupported value: '#{@provider_sentinel}' is not supported with this model. Supported values are: 'low', 'medium', and 'high'."
  @message_without_list "Unsupported value: '#{@provider_sentinel}' is not supported with this model."
  @message_with_unparseable_list "Unsupported value: '#{@provider_sentinel}' is not supported with this model. Supported values are: 'a value with spaces', 'another one'."

  test "native HTTP SSE 400 validation rejection relays bounded code, param, and an authored message",
       %{conn: conn} do
    upstream =
      start_upstream(
        # provenance: observed codex-pooler-findings#128 live probe (status 400, invalid_request_error, unsupported_value, reasoning.effort); message text synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            json: [valid: true, required: ["input"]],
            respond: validation_rejection(400, "unsupported_value", "reasoning.effort")
          )
        ])
      )

    setup = gateway_setup(upstream)

    response = post_native(conn, setup)

    assert response.status == 400
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "application/json"

    assert CodexPooler.JSON.decode(response.resp_body) ==
             {:ok,
              %{
                "error" => %{
                  "type" => "invalid_request_error",
                  "code" => "unsupported_value",
                  "param" => "reasoning.effort",
                  "message" => "upstream rejected parameter reasoning.effort (unsupported_value); supported values: low, medium, high"
                }
              }}

    refute response.resp_body =~ @provider_sentinel
    refute response.resp_body =~ @prompt_sentinel
    FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

    assert request.status == "failed"
    assert request.last_error_code == "upstream_status"
    assert request.response_status_code == 400
    assert request.retry_count == 0
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_status"
    assert attempt.upstream_status_code == 400
    assert attempt.response_metadata["rejection_error_code"] == "unsupported_value"
    assert attempt.response_metadata["rejection_error_type"] == "invalid_request_error"
    assert attempt.response_metadata["rejection_error_param"] == "reasoning.effort"
    assert attempt.response_metadata["rejection_supported_values"] == ~w(low medium high)
    assert attempt.response_metadata["rejection_supported_values_state"] == "present"
    refute inspect({request, attempt}) =~ @provider_sentinel
    refute inspect({request, attempt}) =~ @prompt_sentinel
    assert Repo.aggregate(BridgeDemotion, :count) == 0
    assert Repo.aggregate(RoutingCircuitState, :count) == 0
  end

  test "native HTTP SSE validation rejection without a valid param omits the param path", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond: validation_rejection(400, "invalid_value", "input[0]; " <> @prompt_sentinel)
          )
        ])
      )

    setup = gateway_setup(upstream)
    response = post_native(conn, setup)

    assert response.status == 400

    assert CodexPooler.JSON.decode(response.resp_body) ==
             {:ok,
              %{
                "error" => %{
                  "type" => "invalid_request_error",
                  "code" => "invalid_value",
                  "param" => nil,
                  "message" => "upstream rejected the request (invalid_value); supported values: low, medium, high"
                }
              }}

    refute response.resp_body =~ @prompt_sentinel
    FakeUpstream.verify!(upstream)
  end

  # A 400 outside the relayable validation set used to reach a streaming native
  # client as the 400 with an empty body (the drain leaves no public body), so
  # the released Codex client showed `error: ` with no text, and a
  # non-streaming one as the provider body verbatim. Both now answer the
  # Pooler-authored error the native websocket sends for the same refusal,
  # built from the sanitized tokens only; the provider message never travels
  # (findings#254 row 254-70).
  for stream? <- [true, false], refusal <- ~w(codeless codeless_param codeless_input_param unknown_code server_error_type missing_type detail_body) do
    @tag stream: stream?, refusal: refusal
    test "native HTTP answers a non-relayable 400 with the Pooler-authored refusal error (#{refusal}, stream: #{stream?})", %{conn: conn, stream: stream?, refusal: refusal} do
      {mode, expected_error} = refusal_case(refusal)
      upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: mode)]))
      setup = gateway_setup(upstream)
      response = post_native(conn, setup, stream?)

      assert response.status == 400
      assert [content_type] = get_resp_header(response, "content-type")
      assert content_type =~ "application/json"
      assert CodexPooler.JSON.decode(response.resp_body) == {:ok, %{"error" => expected_error}}
      refute response.resp_body =~ @provider_sentinel
      FakeUpstream.verify!(upstream)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "failed"
      assert request.last_error_code == "upstream_status"
      assert request.response_status_code == 400
      refute inspect(request) =~ @provider_sentinel
      assert Repo.aggregate(BridgeDemotion, :count) == 0
      assert Repo.aggregate(RoutingCircuitState, :count) == 0
    end
  end

  # A native refusal with another final 4xx used to keep its status (with an
  # empty streaming body): the released Codex client retries every
  # HTTP status but 400 as an unexpected status, and each retry was admitted
  # and reached the provider again, six provider requests per turn. It now
  # answers the Pooler-authored refusal error as a 400 naming the provider
  # status, as the native websocket does; the request row, the attempt and
  # route health keep the provider status (findings#254 row 254-80).
  for stream? <- [true, false], status <- [403, 404, 409, 413, 422] do
    @tag stream: stream?, provider_status: status
    test "native HTTP answers a final provider #{status} as the Pooler-authored 400 (stream: #{stream?})", %{conn: conn, stream: stream?, provider_status: status} do
      upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: codeless_rejection(status, nil))]))
      setup = gateway_setup(upstream)
      response = post_native(conn, setup, stream?)

      assert response.status == 400
      assert [content_type] = get_resp_header(response, "content-type")
      assert content_type =~ "application/json"
      assert CodexPooler.JSON.decode(response.resp_body) == {:ok, %{"error" => final_refusal_error(refusal_error("invalid_request", nil), status)}}
      refute response.resp_body =~ @provider_sentinel
      FakeUpstream.verify!(upstream)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert request.status == "failed"
      assert request.last_error_code == "upstream_status"
      assert request.response_status_code == status
      assert attempt.upstream_status_code == status
      assert attempt.response_metadata["rejection_error_type"] == "invalid_request_error"
      refute inspect(request) =~ @provider_sentinel
      assert Repo.aggregate(BridgeDemotion, :count) == 0
      assert Repo.aggregate(RoutingCircuitState, :count) == 0
    end
  end

  test "native HTTP final provider 404 keeps its code and the client's input index in the 400", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: validation_rejection(404, "provider_specific_code", "input[0].content"))]))
    setup = gateway_setup(upstream)
    response = post_native(conn, setup)

    assert response.status == 400
    assert json_response(response, 400) == %{"error" => final_refusal_error(refusal_error("provider_specific_code", "input[0].content"), 404)}
    FakeUpstream.verify!(upstream)
  end

  # Controls: a timeout keeps its status and body; a 403 whose code is a
  # credential failure is the upstream account's, like a 401, and still goes
  # through the auth refresh (a retryable 503 once exhausted) before any
  # projection.
  test "native HTTP keeps a provider 408 as it was", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: codeless_rejection(408, nil))]))
    setup = gateway_setup(upstream)
    response = post_native(conn, setup)

    assert response.status == 408
    assert response.resp_body == ""
    FakeUpstream.verify!(upstream)
  end

  test "native HTTP keeps a credential-coded provider 403 on the auth refresh path", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.repeat_last([validation_rejection(403, "invalid_api_key", nil)]))
    setup = gateway_setup(upstream)
    response = post_native(conn, setup)

    assert response.status == 503
    assert %{"error" => %{"code" => "upstream_unauthorized"}} = json_response(response, 503)
  end

  # `/v1` keeps its own answer for the same refusal: the status and the
  # redacted error.
  test "public /v1 keeps a provider 409 as its own redacted answer", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: codeless_rejection(409, nil))]))
    setup = gateway_setup(upstream)

    response =
      conn
      |> recycle()
      |> auth(setup)
      |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => @prompt_sentinel, "stream" => true})

    assert response.status == 409
    assert %{"error" => %{"message" => "upstream request failed", "code" => "upstream_status"}} = json_response(response, 409)
    FakeUpstream.verify!(upstream)
  end

  test "native HTTP SSE keeps the canonical 401 and 429 errors for validation-shaped bodies", %{
    conn: conn
  } do
    # A 401 exhausts the auth-refresh path into its fixed 503 error; a 429 keeps
    # the rate-limited status with the Pooler's throttle body, which carries no
    # provider token outside the ones the client classifies a 429 by
    # (findings#206 row 206-589; it used to go out with no body). That 503 is a server-side
    # failure whose own message says to retry, so it is `server_error`: a 5xx the
    # Pooler authors is never typed as a client error (findings#191).
    cases = [
      {401, 503,
       {:ok,
        %{
          "error" => %{
            "code" => "upstream_unauthorized",
            "message" => "upstream authentication failed; retry the request",
            "param" => nil,
            "type" => "server_error"
          }
        }}},
      {429, 429, {:ok, %{"error" => %{"code" => "upstream_rate_limited", "message" => "upstream rate limited the request", "type" => "rate_limit_error"}}}}
    ]

    for {status, expected_status, expected_body} <- cases do
      upstream =
        start_upstream(
          FakeUpstream.repeat_last([
            validation_rejection(status, "unsupported_value", "reasoning.effort")
          ])
        )

      setup = gateway_setup(upstream)
      response = post_native(conn, setup)

      assert response.status == expected_status, "status #{status}"
      assert CodexPooler.JSON.decode(response.resp_body) == expected_body, "status #{status}"
      refute response.resp_body =~ "unsupported_value", "status #{status}"

      refute response.resp_body =~ @provider_sentinel, "status #{status}"
    end
  end

  test "explicit Full override relays an allowlisted validation 400 with the same message as Lite",
       %{conn: conn} do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond: validation_rejection(400, "unsupported_value", "reasoning.effort")
          )
        ])
      )

    setup = gateway_setup(upstream)
    put_full_override!(setup)
    response = post_native(conn, setup)

    assert response.status == 400

    # The sentence is built from the sanitized code and param this body already
    # carries, so Full and the non-Full relay agree (codex-pooler-findings#173).
    # The supported-values suffix used to be withheld here because it was read
    # from the live provider body rather than from a persisted field
    # (codex-pooler-findings#161). It is now parsed once, persisted as bounded
    # attempt metadata, and rendered by the same constructor on both paths
    # (codex-pooler-findings#177), so Full — the mode that does not rewrite the
    # client's request — no longer tells the client less about it.
    assert CodexPooler.JSON.decode(response.resp_body) ==
             {:ok,
              %{
                "error" => %{
                  "type" => "invalid_request_error",
                  "code" => "unsupported_value",
                  "param" => "reasoning.effort",
                  "message" => "upstream rejected parameter reasoning.effort (unsupported_value); supported values: low, medium, high"
                }
              }}

    full_supported_values_example =
      CodexPooler.CompatibilityMatrix.fixture!(:upstream_validation_rejection_relay).full_supported_values_example

    assert CodexPooler.JSON.decode!(response.resp_body) == full_supported_values_example

    # Only the bounded parsed enumeration crosses; the surrounding provider
    # prose stays unrelayed and unpersisted on every path.
    refute response.resp_body =~ @provider_sentinel
    refute response.resp_body =~ @prompt_sentinel
    FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert request.last_error_code == "upstream_status"
    assert request.retry_count == 0
    assert attempt.network_error_code == "upstream_status"
    assert_full_override_witness!(attempt)
    assert attempt.response_metadata["rejection_error_code"] == "unsupported_value"
    assert attempt.response_metadata["rejection_error_param"] == "reasoning.effort"
    assert attempt.response_metadata["rejection_supported_values"] == ~w(low medium high)
    assert attempt.response_metadata["rejection_supported_values_state"] == "present"
    refute inspect({request, attempt}) =~ @provider_sentinel
    assert Repo.aggregate(BridgeDemotion, :count) == 0
    assert Repo.aggregate(RoutingCircuitState, :count) == 0
  end

  test "explicit Full override relays the supported values for a rejection carrying no param", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond: validation_rejection(400, "invalid_value", "input[0]; " <> @prompt_sentinel)
          )
        ])
      )

    setup = gateway_setup(upstream)
    put_full_override!(setup)
    response = post_native(conn, setup)

    assert response.status == 400

    assert CodexPooler.JSON.decode(response.resp_body) ==
             {:ok,
              %{
                "error" => %{
                  "type" => "invalid_request_error",
                  "code" => "invalid_value",
                  "param" => nil,
                  "message" => "upstream rejected the request (invalid_value); supported values: low, medium, high"
                }
              }}

    refute response.resp_body =~ @prompt_sentinel
    refute response.resp_body =~ @provider_sentinel
    FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert_full_override_witness!(attempt)
    refute Map.has_key?(attempt.response_metadata, "rejection_error_param")
    assert attempt.response_metadata["rejection_supported_values"] == ~w(low medium high)
    assert attempt.response_metadata["rejection_supported_values_state"] == "present"
  end

  # A parsed list, a provider message that states no list, and a message whose
  # list the bounded grammar refuses are three different facts. Collapsing them
  # into one absent field is the defect pattern codex-pooler-findings#165 named,
  # so each keeps its own persisted state and none of them invents a suffix.
  test "supported-values state stays distinct across present, none, and unparseable messages", %{
    conn: conn
  } do
    cases = [
      {"none", @message_without_list, nil, "none", "upstream rejected parameter reasoning.effort (unsupported_value)"},
      {"unparseable", @message_with_unparseable_list, nil, "unparseable", "upstream rejected parameter reasoning.effort (unsupported_value)"},
      {"present", @message_with_list, ~w(low medium high), "present", "upstream rejected parameter reasoning.effort (unsupported_value); supported values: low, medium, high"}
    ]

    for full? <- [false, true], {label, message, values, state, expected} <- cases do
      upstream =
        start_upstream(
          # provenance: synthetic_adversarial
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "POST",
              path: "/backend-api/codex/responses",
              respond: message_rejection(400, "unsupported_value", "reasoning.effort", message)
            )
          ])
        )

      setup = gateway_setup(upstream)
      if full?, do: put_full_override!(setup)
      response = post_native(conn, setup)

      context = "#{label} full?=#{full?}"

      assert response.status == 400, context
      assert {:ok, %{"error" => error}} = CodexPooler.JSON.decode(response.resp_body)
      assert error["message"] == expected, context
      refute response.resp_body =~ @provider_sentinel, context
      FakeUpstream.verify!(upstream)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      metadata = attempt.response_metadata

      assert metadata["rejection_supported_values_state"] == state, context
      assert Map.get(metadata, "rejection_supported_values") == values, context
      assert Map.has_key?(metadata, "rejection_supported_values") == (values != nil), context
      refute inspect(attempt) =~ @provider_sentinel, context
    end
  end

  # A relayable code that can never carry a list must leave the field out
  # entirely, which is a fourth state: not that the provider said nothing, but
  # that the question does not apply.
  test "a validation code outside the value-oriented pair persists no supported-values field", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond:
              message_rejection(
                400,
                "missing_required_parameter",
                "reasoning.effort",
                @message_with_list
              )
          )
        ])
      )

    setup = gateway_setup(upstream)
    response = post_native(conn, setup)

    assert response.status == 400

    assert {:ok, %{"error" => %{"message" => message}}} =
             CodexPooler.JSON.decode(response.resp_body)

    assert message == "upstream rejected parameter reasoning.effort (missing_required_parameter)"
    FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    refute Map.has_key?(attempt.response_metadata, "rejection_supported_values")
    refute Map.has_key?(attempt.response_metadata, "rejection_supported_values_state")
  end

  # 401/404 dominate the production `full_upstream_rejection` population and can
  # carry no list at all, so the Full projection must not grow a field there.
  test "a non-400 Full rejection persists no supported-values field", %{conn: conn} do
    upstream =
      start_upstream(
        # provenance: synthetic_adversarial
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond: message_rejection(404, "unsupported_value", "reasoning.effort", @message_with_list)
          )
        ])
      )

    setup = gateway_setup(upstream)
    put_full_override!(setup)
    response = post_native(conn, setup)

    # A native final 404 answers the Pooler-authored 400 (findings#254 row
    # 254-80); nothing of the provider's list travels.
    assert response.status == 400
    refute response.resp_body =~ "supported values"
    FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    refute Map.has_key?(attempt.response_metadata, "rejection_supported_values")
    refute Map.has_key?(attempt.response_metadata, "rejection_supported_values_state")
  end

  test "explicit Full override relays the sanitized rejection type and param with a code fallback",
       %{conn: conn} do
    upstream =
      start_upstream(
        # provenance: observed codex-pooler-findings#161 live probe on an explicit
        # Full override (status 400, invalid_request_error, param
        # tools.defer_loading, no error code, 79-byte provider message); the
        # message text here is synthetic and stays unpersisted and unrelayed.
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            json: [valid: true, required: ["input"]],
            respond: codeless_rejection(400, "tools.defer_loading")
          )
        ])
      )

    setup = gateway_setup(upstream)
    put_full_override!(setup)
    response = post_native(conn, setup)

    assert response.status == 400

    assert CodexPooler.JSON.decode(response.resp_body) ==
             {:ok,
              %{
                "error" => %{
                  "type" => "invalid_request_error",
                  "code" => "invalid_request",
                  "param" => "tools.defer_loading",
                  "message" => "upstream rejected parameter tools.defer_loading (invalid_request)"
                }
              }}

    refute response.resp_body =~ @provider_sentinel
    refute response.resp_body =~ @prompt_sentinel
    refute response.resp_body =~ "tool_search"
    FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert request.status == "failed"
    assert request.response_status_code == 400
    assert request.retry_count == 0
    assert request.last_error_code == "upstream_status"
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_status"
    assert attempt.response_metadata["rejection_error_type"] == "invalid_request_error"
    assert attempt.response_metadata["rejection_error_param"] == "tools.defer_loading"
    refute Map.has_key?(attempt.response_metadata, "rejection_error_code")
    assert attempt.response_metadata["rejection_message_present"] == true
    refute inspect({request, attempt}) =~ @provider_sentinel
    assert Repo.aggregate(BridgeDemotion, :count) == 0
    assert Repo.aggregate(RoutingCircuitState, :count) == 0
  end

  test "explicit Full override pins the code fallback vocabulary and keeps a typeless body generic",
       %{conn: conn} do
    # provenance: synthetic_adversarial. Pins the closed `type -> code` map so a
    # future member cannot silently land as the generic constant: an unmapped
    # type reuses the type itself, and only a rejection with no sanitized type
    # at all keeps the server-owned canonical body.
    cases = [
      {%{"type" => "insufficient_quota", "param" => "tools.defer_loading"},
       %{
         "type" => "insufficient_quota",
         "code" => "insufficient_quota",
         "param" => "tools.defer_loading",
         "message" => "upstream rejected parameter tools.defer_loading (insufficient_quota)"
       }},
      {%{"type" => "invalid_request_error"},
       %{
         "type" => "invalid_request_error",
         "code" => "invalid_request",
         "param" => nil,
         "message" => "upstream rejected the request (invalid_request)"
       }},
      {%{"param" => "tools.defer_loading"},
       %{
         "code" => "server_error",
         "message" => "upstream request failed",
         "type" => "server_error"
       }}
    ]

    for {error, expected} <- cases do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "POST",
              path: "/backend-api/codex/responses",
              respond: {:json_error, 400, %{"error" => Map.put(error, "message", @provider_sentinel)}}
            )
          ])
        )

      setup = gateway_setup(upstream)
      put_full_override!(setup)
      response = post_native(conn, setup)

      assert response.status == 400, inspect(error)

      assert CodexPooler.JSON.decode(response.resp_body) == {:ok, %{"error" => expected}},
             inspect(error)

      refute response.resp_body =~ @provider_sentinel, inspect(error)
      FakeUpstream.verify!(upstream)
    end
  end

  test "explicit Full override relays the provider rejection code on other non-429 4xx statuses",
       %{conn: conn} do
    # provenance: synthetic_adversarial (statuses invented to prove the relay
    # window matches the persisted rejection-metadata window, not one status).
    # On the native route a final 4xx answers as a 400 naming the provider
    # status whatever the serving mode, as the native websocket does, because
    # the released Codex client retries every other status (findings#254 row
    # 254-80); code and param stay the ones the Full body relays.
    cases = [
      {403, "unsupported_parameter", "tools.defer_loading"},
      {413, "string_above_max_length", "input[0].content[0].text"},
      {422, "invalid_value", "reasoning.effort"}
    ]

    for {status, code, param} <- cases do
      upstream =
        start_upstream(
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "POST",
              path: "/backend-api/codex/responses",
              respond: validation_rejection(status, code, param)
            )
          ])
        )

      setup = gateway_setup(upstream)
      put_full_override!(setup)
      response = post_native(conn, setup)

      assert response.status == 400, "status #{status}"

      assert CodexPooler.JSON.decode(response.resp_body) ==
               {:ok,
                %{
                  "error" => %{
                    "type" => "invalid_request_error",
                    "code" => code,
                    "param" => param,
                    "message" => "upstream rejected parameter #{param} (#{code}); upstream status #{status}"
                  }
                }},
             "status #{status}"

      refute response.resp_body =~ @provider_sentinel, "status #{status}"
      FakeUpstream.verify!(upstream)
    end
  end

  test "explicit Full override keeps the canonical failure outside the rejection-metadata window",
       %{conn: conn} do
    # provenance: synthetic_adversarial. 429 and 5xx are deliberately outside
    # the persisted rejection-metadata window, so nothing sanitized exists to
    # relay: a 5xx keeps the server-owned body byte-identical, and a 429 the
    # Pooler's throttle body in Full as in Lite (findings#206 row 206-589).
    for {status, expected_error} <- [
          {429, %{"code" => "upstream_rate_limited", "message" => "upstream rate limited the request", "type" => "rate_limit_error"}},
          {500, %{"code" => "server_error", "message" => "upstream request failed", "type" => "server_error"}}
        ] do
      upstream =
        start_upstream(FakeUpstream.repeat_last([validation_rejection(status, "invalid_value", "tools")]))

      setup = gateway_setup(upstream)
      put_full_override!(setup)
      response = post_native(conn, setup)

      assert response.status == status, "status #{status}"

      assert CodexPooler.JSON.decode(response.resp_body) == {:ok, %{"error" => expected_error}}, "status #{status}"

      refute response.resp_body =~ @provider_sentinel, "status #{status}"
      refute response.resp_body =~ "invalid_value", "status #{status}"
    end
  end

  test "explicit Full override leaves pre-dispatch Pooler rejections byte-identical", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"ok" => true}, 200))
    setup = gateway_setup(upstream)
    put_full_override!(setup)

    cases = [
      {%{"tools" => "defer_loading"}, "tools", "tools must be an array"},
      {%{"input" => @prompt_sentinel}, "input", "input must be an array"}
    ]

    for {overrides, param, message} <- cases do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post(
          "/backend-api/codex/responses",
          Map.merge(
            %{
              "model" => setup.model.exposed_model_id,
              "input" => native_text_input(@prompt_sentinel),
              "stream" => true
            },
            overrides
          )
        )

      assert response.status == 400, param

      assert CodexPooler.JSON.decode(response.resp_body) ==
               {:ok,
                %{
                  "error" => %{
                    "type" => "invalid_request_error",
                    "code" => "invalid_request",
                    "param" => param,
                    "message" => message
                  }
                }},
             param

      refute response.resp_body =~ @prompt_sentinel, param
    end

    # A pre-dispatch rejection never reaches an upstream, so it never produces
    # an attempt and never enters the serving-mode failure projection.
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  # A Full rejection is rebuilt as a JSON body; a streaming request whose
  # upstream 400 carried no content-type must not inherit the stream's
  # `text/event-stream` (findings#219).
  test "explicit Full override relays a content-type-less streaming rejection as JSON",
       %{conn: conn} do
    body =
      CodexPooler.JSON.encode!(%{
        "error" => %{
          "code" => "unsupported_value",
          "message" => @message_with_list,
          "param" => "reasoning.effort",
          "type" => "invalid_request_error"
        }
      })

    upstream =
      start_upstream(
        # provenance: observed codex-pooler-findings#128 live probe shape; the missing content-type header is invented
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            json: [valid: true, required: ["input"]],
            respond: FakeUpstream.raw_response(body, status: 400, headers: [])
          )
        ])
      )

    setup = gateway_setup(upstream)
    put_full_override!(setup)
    response = post_native(conn, setup)

    assert response.status == 400
    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "application/json"

    assert %{"error" => %{"code" => "unsupported_value", "param" => "reasoning.effort"}} =
             CodexPooler.JSON.decode!(response.resp_body)

    refute response.resp_body =~ @provider_sentinel
    refute response.resp_body =~ @prompt_sentinel
    FakeUpstream.verify!(upstream)
  end

  # The backend Chat alias shares the Full caller-facing mapper with the public
  # `/v1/chat/completions` arm (findings#219); only the public arm was pinned.
  test "explicit Full override on the backend Chat alias preserves the Chat parameter name",
       %{conn: conn} do
    upstream =
      start_upstream(
        # provenance: observed codex-pooler-findings#128 live probe (status 400, invalid_request_error, unsupported_value, reasoning.effort); message text synthetic; the Chat alias, the Full override and the two-request sequence are invented
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            json: [valid: true, required: ["input"]],
            respond: validation_rejection(400, "unsupported_value", "reasoning.effort")
          ),
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            json: [valid: true, required: ["input"]],
            respond: validation_rejection(400, "unsupported_value", "reasoning.effort")
          )
        ])
      )

    setup = gateway_setup(upstream)
    put_full_override!(setup)

    for stream? <- [true, false] do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/backend-api/codex/v1/chat/completions", %{
          "model" => setup.model.exposed_model_id,
          "messages" => [%{"role" => "user", "content" => @prompt_sentinel}],
          "reasoning_effort" => "high",
          "stream" => stream?
        })

      assert response.status == 400, "stream #{stream?}"

      assert CodexPooler.JSON.decode(response.resp_body) ==
               {:ok,
                %{
                  "error" => %{
                    "type" => "invalid_request_error",
                    "code" => "unsupported_value",
                    "param" => "reasoning_effort",
                    "message" => "upstream rejected parameter reasoning_effort (unsupported_value); supported values: low, medium, high"
                  }
                }},
             "stream #{stream?}"

      refute response.resp_body =~ "reasoning.effort", "stream #{stream?}"
      refute response.resp_body =~ @provider_sentinel, "stream #{stream?}"
      refute response.resp_body =~ @prompt_sentinel, "stream #{stream?}"
    end

    FakeUpstream.verify!(upstream)
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert length(requests) == 2

    for request <- requests do
      assert request.last_error_code == "upstream_status"
      assert request.response_status_code == 400
      assert request.retry_count == 0
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      # The rendered body is the same under Lite, so the durable routing
      # metadata is the witness that the Full projection was in effect.
      assert_full_override_witness!(attempt)
      # The durable field keeps the provider's parameter path; only the
      # caller-facing rendering is remapped.
      assert attempt.response_metadata["rejection_error_param"] == "reasoning.effort"
      refute inspect({request, attempt}) =~ @prompt_sentinel
      refute inspect({request, attempt}) =~ @provider_sentinel
    end

    assert Repo.aggregate(BridgeDemotion, :count) == 0
    assert Repo.aggregate(RoutingCircuitState, :count) == 0
  end

  # A Full body can be byte-identical to the Lite body, so the durable routing
  # metadata is what proves the explicit override was in effect.
  defp assert_full_override_witness!(attempt) do
    assert attempt.response_metadata["routing"]["model_serving_mode"] == "full"
    assert attempt.response_metadata["routing"]["model_serving_mode_source"] == "override"
  end

  defp put_full_override!(setup) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%ModelServingOverride{
      pool_id: setup.pool.id,
      exposed_model_id: setup.model.exposed_model_id,
      mode: "full",
      created_at: timestamp,
      updated_at: timestamp
    })
  end

  # The provider resolves `previous_response_id` only on the websocket
  # connection that produced the response, and refuses the parameter on HTTP
  # with a detail body. A client that recovers by resending the full input
  # (as OpenAI-compatible agents do on an unsupported or unknown
  # previous_response_id) needs that parameter named in the answer, which the
  # sanitized refusal used to drop (findings#232 row 232-275).
  for stream? <- [true, false] do
    test "native HTTP anchored tool-output continuation relays the provider's unsupported previous_response_id (stream #{stream?})", %{conn: conn} do
      stream? = unquote(stream?)
      anchor_id = "resp_http_anchor_unsupported_sample"
      tool_output = %{"type" => "function_call_output", "call_id" => "call_http_anchor_unsupported", "output" => @prompt_sentinel}

      # FakeUpstream answers an HTTP body carrying `previous_response_id` the
      # way the provider does (observed findings#232 row 232-275 live probe:
      # HTTP 400 with the `{"detail": "Unsupported parameter: ..."}` body)
      # before any scripted response (row 232-276).
      upstream = start_upstream(FakeUpstream.json_response(%{"id" => "resp_http_anchor_never_served"}))

      setup = gateway_setup(upstream)

      response =
        conn
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => anchor_id,
          "input" => [tool_output],
          "stream" => stream?
        })

      assert response.status == 400

      assert CodexPooler.JSON.decode(response.resp_body) ==
               {:ok, %{"error" => refusal_error("unsupported_parameter", "previous_response_id")}}

      refute response.resp_body =~ @prompt_sentinel
      assert [%{method: "POST", path: "/backend-api/codex/responses", json: %{"previous_response_id" => ^anchor_id}}] = FakeUpstream.requests(upstream)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "failed"
      assert request.last_error_code == "upstream_status"
      assert request.response_status_code == 400
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.response_metadata["rejection_detail_class"] == "unsupported_parameter"
      assert attempt.response_metadata["rejection_error_param"] == "previous_response_id"
      refute inspect({request, attempt}) =~ anchor_id
      refute inspect({request, attempt}) =~ @prompt_sentinel
      assert Repo.aggregate(BridgeDemotion, :count) == 0
      assert Repo.aggregate(RoutingCircuitState, :count) == 0
    end
  end

  defp post_native(conn, setup, stream? \\ true) do
    conn
    |> recycle()
    |> auth(setup)
    |> post("/backend-api/codex/responses", %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input(@prompt_sentinel),
      "stream" => stream?
    })
  end

  defp refusal_case("codeless"), do: {codeless_rejection(400, nil), refusal_error("invalid_request", nil)}
  defp refusal_case("codeless_param"), do: {codeless_rejection(400, "tools.tool_search"), refusal_error("invalid_request", "tools.tool_search")}
  # The HTTP answer holds the turn's input index map (the websocket event does
  # not), so an `input[N]` param keeps the client's own index.
  defp refusal_case("codeless_input_param"), do: {codeless_rejection(400, "input[0].content"), refusal_error("invalid_request", "input[0].content")}
  defp refusal_case("unknown_code"), do: {validation_rejection(400, "provider_specific_code", "reasoning.effort"), refusal_error("provider_specific_code", "reasoning.effort")}
  defp refusal_case("server_error_type"), do: {validation_rejection(400, "unsupported_value", "reasoning.effort", "server_error"), refusal_error("unsupported_value", "reasoning.effort")}
  defp refusal_case("missing_type"), do: {validation_rejection(400, "unsupported_value", "reasoning.effort", nil), refusal_error("unsupported_value", "reasoning.effort")}
  defp refusal_case("detail_body"), do: {{:json_error, 400, %{"detail" => "Unsupported value reasoning.effort " <> @provider_sentinel}}, refusal_error("invalid_request", nil)}

  defp final_refusal_error(error, status), do: Map.update!(error, "message", &(&1 <> "; upstream status #{status}"))

  defp refusal_error(code, nil), do: %{"type" => "invalid_request_error", "code" => code, "param" => nil, "message" => "upstream rejected the request (#{code})"}
  defp refusal_error(code, param), do: %{"type" => "invalid_request_error", "code" => code, "param" => param, "message" => "upstream rejected parameter #{param} (#{code})"}

  defp codeless_rejection(status, param) do
    {:json_error, status,
     %{
       "error" => %{
         "message" => "Missing required parameter: 'tools.tool_search'. #{@provider_sentinel}",
         "param" => param,
         "type" => "invalid_request_error"
       }
     }}
  end

  defp validation_rejection(status, code, param, type \\ "invalid_request_error") do
    error =
      %{
        "code" => code,
        "message" => @message_with_list,
        "param" => param,
        "type" => type
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:json_error, status, %{"error" => error}}
  end

  defp message_rejection(status, code, param, message) do
    {:json_error, status,
     %{
       "error" => %{
         "code" => code,
         "message" => message,
         "param" => param,
         "type" => "invalid_request_error"
       }
     }}
  end
end
