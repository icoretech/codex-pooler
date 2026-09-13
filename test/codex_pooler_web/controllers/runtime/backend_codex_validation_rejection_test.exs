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
                  "message" =>
                    "upstream rejected parameter reasoning.effort (unsupported_value); supported values: low, medium, high"
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
                  "message" =>
                    "upstream rejected the request (invalid_value); supported values: low, medium, high"
                }
              }}

    refute response.resp_body =~ @prompt_sentinel
    FakeUpstream.verify!(upstream)
  end

  test "native HTTP SSE keeps unknown, non-validation, detail, and non-400 rejections empty", %{
    conn: conn
  } do
    cases = [
      {"unknown code", validation_rejection(400, "provider_specific_code", "reasoning.effort")},
      {"server_error type",
       validation_rejection(400, "unsupported_value", "reasoning.effort", "server_error")},
      {"missing type", validation_rejection(400, "unsupported_value", "reasoning.effort", nil)},
      {"detail body",
       {:json_error, 400,
        %{"detail" => "Unsupported value reasoning.effort " <> @provider_sentinel}}},
      {"403", validation_rejection(403, "unsupported_value", "reasoning.effort")},
      {"404", validation_rejection(404, "unsupported_value", "reasoning.effort")},
      {"422", validation_rejection(422, "invalid_value", "reasoning.effort")}
    ]

    for {label, mode} <- cases do
      upstream =
        start_upstream(
          # provenance: synthetic_adversarial
          FakeUpstream.strict_sequence([
            FakeUpstream.expect_request(
              method: "POST",
              path: "/backend-api/codex/responses",
              respond: mode
            )
          ])
        )

      setup = gateway_setup(upstream)
      response = post_native(conn, setup)
      {:json_error, status, _body} = mode

      assert response.status == status, label
      assert response.resp_body == "", label
      FakeUpstream.verify!(upstream)
      assert Repo.aggregate(BridgeDemotion, :count) == 0, label
      assert Repo.aggregate(RoutingCircuitState, :count) == 0, label
    end
  end

  test "native HTTP SSE keeps the canonical 401 and 429 errors for validation-shaped bodies", %{
    conn: conn
  } do
    # A 401 exhausts the auth-refresh path into its fixed 503 error; a 429 keeps
    # the rate-limited status with no relayed body. That 503 is a server-side
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
      {429, 429, {:error, {:unexpected_end, 0}}}
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
                  "message" =>
                    "upstream rejected parameter reasoning.effort (unsupported_value); supported values: low, medium, high"
                }
              }}

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
                  "message" =>
                    "upstream rejected the request (invalid_value); supported values: low, medium, high"
                }
              }}

    refute response.resp_body =~ @prompt_sentinel
    refute response.resp_body =~ @provider_sentinel
    FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
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
      {"none", @message_without_list, nil, "none",
       "upstream rejected parameter reasoning.effort (unsupported_value)"},
      {"unparseable", @message_with_unparseable_list, nil, "unparseable",
       "upstream rejected parameter reasoning.effort (unsupported_value)"},
      {"present", @message_with_list, ~w(low medium high), "present",
       "upstream rejected parameter reasoning.effort (unsupported_value); supported values: low, medium, high"}
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
            respond:
              message_rejection(404, "unsupported_value", "reasoning.effort", @message_with_list)
          )
        ])
      )

    setup = gateway_setup(upstream)
    put_full_override!(setup)
    response = post_native(conn, setup)

    assert response.status == 404
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
              respond:
                {:json_error, 400, %{"error" => Map.put(error, "message", @provider_sentinel)}}
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
    # window matches the persisted rejection-metadata window, not one status)
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

      assert response.status == status, "status #{status}"

      assert CodexPooler.JSON.decode(response.resp_body) ==
               {:ok,
                %{
                  "error" => %{
                    "type" => "invalid_request_error",
                    "code" => code,
                    "param" => param,
                    "message" => "upstream rejected parameter #{param} (#{code})"
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
    # relay and the server-owned body must stay byte-identical.
    for status <- [429, 500] do
      upstream =
        start_upstream(
          FakeUpstream.repeat_last([validation_rejection(status, "invalid_value", "tools")])
        )

      setup = gateway_setup(upstream)
      put_full_override!(setup)
      response = post_native(conn, setup)

      assert response.status == status, "status #{status}"

      assert CodexPooler.JSON.decode(response.resp_body) ==
               {:ok,
                %{
                  "error" => %{
                    "code" => "server_error",
                    "message" => "upstream request failed",
                    "type" => "server_error"
                  }
                }},
             "status #{status}"

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

  defp post_native(conn, setup) do
    conn
    |> recycle()
    |> auth(setup)
    |> post("/backend-api/codex/responses", %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input(@prompt_sentinel),
      "stream" => true
    })
  end

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
