defmodule CodexPoolerWeb.V1.UpstreamValidationRejectionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @provider_sentinel "private-provider-validation-sentinel"
  @prompt_sentinel "private-validation-prompt-sentinel"

  @expected_error %{
    "message" => "upstream rejected parameter reasoning.effort (unsupported_value); supported values: low, medium, high",
    "type" => "invalid_request_error",
    "code" => "unsupported_value",
    "param" => "reasoning.effort"
  }

  test "POST /v1/responses returns the OpenAI error shape for a streaming and a JSON validation rejection",
       %{conn: conn} do
    upstream =
      start_upstream(
        # provenance: observed codex-pooler-findings#128 live probe (status 400, invalid_request_error, unsupported_value, reasoning.effort); message text synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond: validation_rejection(400, "unsupported_value", "reasoning.effort")
          ),
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond: validation_rejection(400, "unsupported_value", "reasoning.effort")
          )
        ])
      )

    setup = gateway_setup(upstream)

    for stream? <- [true, false] do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => @prompt_sentinel,
          "stream" => stream?
        })

      assert json_response(response, 400) == %{"error" => @expected_error}, "stream #{stream?}"
      refute response.resp_body =~ @provider_sentinel
      refute response.resp_body =~ @prompt_sentinel
    end

    FakeUpstream.verify!(upstream)
    assert_failed_validation_accounting!(setup, 2)
  end

  test "POST /v1/chat/completions maps the relayed param to the Chat field the client sent", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        # provenance: observed codex-pooler-findings#128 live probe (status 400, invalid_request_error, unsupported_value, reasoning.effort); message text synthetic
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond: validation_rejection(400, "unsupported_value", "reasoning.effort")
          )
        ])
      )

    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/chat/completions", %{
        "model" => setup.model.exposed_model_id,
        "messages" => [%{"role" => "user", "content" => @prompt_sentinel}],
        "reasoning_effort" => "high",
        "stream" => true
      })

    assert json_response(response, 400) == %{
             "error" => %{
               "message" => "upstream rejected parameter reasoning_effort (unsupported_value); supported values: low, medium, high",
               "type" => "invalid_request_error",
               "code" => "unsupported_value",
               "param" => "reasoning_effort"
             }
           }

    refute response.resp_body =~ @provider_sentinel
    refute response.resp_body =~ @prompt_sentinel
    FakeUpstream.verify!(upstream)
    assert_failed_validation_accounting!(setup, 1)
  end

  test "POST /v1/chat/completions under Full preserves the Chat parameter name", %{conn: conn} do
    upstream =
      start_upstream(
        # provenance: observed codex-pooler-findings#128 live probe (status 400, invalid_request_error, unsupported_value, reasoning.effort); message text synthetic; the Full override and the two-request sequence are invented
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond: validation_rejection(400, "unsupported_value", "reasoning.effort")
          ),
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
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
        |> post("/v1/chat/completions", %{
          "model" => setup.model.exposed_model_id,
          "messages" => [%{"role" => "user", "content" => @prompt_sentinel}],
          "reasoning_effort" => "high",
          "stream" => stream?
        })

      # The relayed `param` and the Pooler-authored message must name the same
      # Chat field the client sent (codex-pooler-findings#219): a message that
      # still says `reasoning.effort` next to `"param": "reasoning_effort"` is
      # the provider-form leak this test pins.
      assert json_response(response, 400) == %{
               "error" => %{
                 "message" => "upstream rejected parameter reasoning_effort (unsupported_value); supported values: low, medium, high",
                 "type" => "invalid_request_error",
                 "code" => "unsupported_value",
                 "param" => "reasoning_effort"
               }
             },
             "stream #{stream?}"

      refute response.resp_body =~ "reasoning.effort", "stream #{stream?}"
      refute response.resp_body =~ @provider_sentinel
      refute response.resp_body =~ @prompt_sentinel
    end

    FakeUpstream.verify!(upstream)
    assert_failed_validation_accounting!(setup, 2)

    # The rendered body is the same under Lite, so the durable routing metadata
    # is the witness that the Full projection was in effect.
    for attempt <-
          Repo.all(
            from(a in Attempt,
              join: r in Request,
              on: r.id == a.request_id,
              where: r.pool_id == ^setup.pool.id
            )
          ) do
      assert attempt.response_metadata["routing"]["model_serving_mode"] == "full"
      assert attempt.response_metadata["routing"]["model_serving_mode_source"] == "override"
    end
  end

  test "POST /v1/responses keeps non-allowlisted and non-400 rejections redacted", %{conn: conn} do
    cases = [
      {"unknown code", validation_rejection(400, "provider_specific_code", "reasoning.effort"), 400},
      {"api_error type", validation_rejection(400, "unsupported_value", "reasoning.effort", "api_error"), 400},
      {"403", validation_rejection(403, "unsupported_value", "reasoning.effort"), 403}
    ]

    for {label, mode, expected_status} <- cases do
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

      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => @prompt_sentinel,
          "stream" => true
        })

      assert %{"error" => error} = json_response(response, expected_status), label
      # Redacted, but a refused 400 is typed as the client's error: the
      # retryable `server_error` class contradicted it (findings#254 row
      # 254-51). An upstream 403 is the upstream account's standing and keeps
      # `server_error`.
      assert error["type"] == if(expected_status == 400, do: "invalid_request_error", else: "server_error"), label
      assert error["message"] == "upstream request failed", label
      refute error["code"] == "unsupported_value", label
      refute Map.has_key?(error, "param"), label
      refute response.resp_body =~ "reasoning.effort", label
      refute response.resp_body =~ @provider_sentinel, label
      FakeUpstream.verify!(upstream)
    end
  end

  # A refusal outside the relay window keeps the redacted body (fixed message,
  # stream startup code `upstream_status`, no param), typed from the status it
  # is answered with like every other Pooler-authored error: a refused 4xx
  # is `invalid_request_error` and a 429 the throttle class `rate_limit_error`
  # (row 254-72); an upstream 401 or 403, a 5xx and an upstream 404 (answered
  # as 502) stay `server_error` (findings#254 row 254-51).
  test "POST /v1 types a redacted upstream refusal from the status it answers", %{conn: conn} do
    codeless = {:json_error, 400, %{"error" => %{"type" => "invalid_request_error", "message" => "Invalid 'input[1].id': '#{@provider_sentinel}'."}}}

    cases = [
      {"responses stream 400", "/v1/responses", true, codeless, 400, "invalid_request_error"},
      {"responses json 400", "/v1/responses", false, codeless, 400, "invalid_request_error"},
      {"chat stream 400", "/v1/chat/completions", true, codeless, 400, "invalid_request_error"},
      {"chat json 400", "/v1/chat/completions", false, codeless, 400, "invalid_request_error"},
      {"responses 403", "/v1/responses", true, validation_rejection(403, "synthetic_forbidden", nil), 403, "server_error"},
      {"responses 422", "/v1/responses", true, validation_rejection(422, "synthetic_unprocessable", nil), 422, "invalid_request_error"},
      {"responses 429", "/v1/responses", true, validation_rejection(429, "synthetic_throttle", nil), 429, "rate_limit_error"},
      {"responses 500", "/v1/responses", true, validation_rejection(500, "synthetic_failure", nil, "server_error"), 500, "server_error"},
      {"responses 404", "/v1/responses", true, validation_rejection(404, "synthetic_missing", nil), 502, "server_error"}
    ]

    for {label, path, stream?, mode, expected_status, expected_type} <- cases do
      upstream = start_upstream(FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: mode)]))
      setup = gateway_setup(upstream)

      body =
        if path == "/v1/chat/completions",
          do: %{"model" => setup.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => @prompt_sentinel}], "stream" => stream?},
          else: %{"model" => setup.model.exposed_model_id, "input" => @prompt_sentinel, "stream" => stream?}

      response = conn |> recycle() |> auth(setup) |> post(path, body)

      assert %{"error" => error} = json_response(response, expected_status), label
      assert error["type"] == expected_type, label
      assert error["message"] == "upstream request failed", label
      refute response.resp_body =~ @provider_sentinel, label
      FakeUpstream.verify!(upstream)
    end
  end

  test "POST /v1/responses returns one rejection body whichever serving mode resolved", %{
    conn: conn
  } do
    # provenance: observed codex-pooler-findings#173 live probe on icoretech
    # production. One API key, one surface, one provider, one rejection
    # (status 400, invalid_request_error, invalid_value, include[0]); the
    # model's serving mode was the only variable, and the two arms disagreed
    # on both the persisted error code and the client-visible message. The
    # provider message text here is synthetic and carries no supported-values
    # list, matching the observed rejection.
    bodies =
      for mode <- [:lite, :full] do
        upstream =
          start_upstream(
            FakeUpstream.strict_sequence([
              FakeUpstream.expect_request(
                method: "POST",
                path: "/backend-api/codex/responses",
                respond: listless_rejection(400, "invalid_value", "include[0]")
              )
            ])
          )

        setup = gateway_setup(upstream)
        if mode == :full, do: put_full_override!(setup)

        response =
          conn
          |> recycle()
          |> auth(setup)
          |> post("/v1/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => @prompt_sentinel,
            "stream" => true
          })

        assert json_response(response, 400) == %{
                 "error" => %{
                   "type" => "invalid_request_error",
                   "code" => "invalid_value",
                   "param" => "include[0]",
                   "message" => "upstream rejected parameter include[0] (invalid_value)"
                 }
               },
               "mode #{mode}"

        refute response.resp_body =~ @provider_sentinel, "mode #{mode}"
        refute response.resp_body =~ @prompt_sentinel, "mode #{mode}"
        FakeUpstream.verify!(upstream)

        assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
        assert request.response_status_code == 400, "mode #{mode}"
        assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))

        assert attempt.response_metadata["rejection_error_code"] == "invalid_value",
               "mode #{mode}"

        assert attempt.response_metadata["rejection_error_param"] == "include[0]", "mode #{mode}"

        json_response(response, 400)
      end

    assert [lite_body, full_body] = bodies
    assert lite_body == full_body
  end

  test "POST /v1/responses under a Full override names the request when the rejection has no param",
       %{conn: conn} do
    # provenance: synthetic_adversarial, from the codex-pooler-findings#173
    # scope note. `full_failure_body/1` emits an explicit `"param": null` for a
    # rejection carrying a type but no param; the branch had never been driven
    # on the public /v1 surface.
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond:
              {:json_error, 400,
               %{
                 "error" => %{
                   "message" => "Missing required parameter. #{@provider_sentinel}",
                   "type" => "invalid_request_error"
                 }
               }}
          )
        ])
      )

    setup = gateway_setup(upstream)
    put_full_override!(setup)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => @prompt_sentinel,
        "stream" => true
      })

    assert json_response(response, 400) == %{
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_request",
               "param" => nil,
               "message" => "upstream rejected the request (invalid_request)"
             }
           }

    refute response.resp_body =~ @provider_sentinel
    refute response.resp_body =~ @prompt_sentinel
    FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.response_metadata["rejection_error_type"] == "invalid_request_error"
    refute Map.has_key?(attempt.response_metadata, "rejection_error_param")
  end

  test "POST /v1/responses under an explicit Full override relays the rejection type and param",
       %{conn: conn} do
    upstream =
      start_upstream(
        # provenance: observed codex-pooler-findings#161 live probe on an
        # explicit Full override (status 400, invalid_request_error, param
        # tools.defer_loading, no error code); message text synthetic.
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond:
              {:json_error, 400,
               %{
                 "error" => %{
                   "message" => "Missing required parameter. #{@provider_sentinel}",
                   "param" => "tools.defer_loading",
                   "type" => "invalid_request_error"
                 }
               }}
          )
        ])
      )

    setup = gateway_setup(upstream)
    put_full_override!(setup)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => @prompt_sentinel,
        "stream" => true
      })

    # An SDK on the public surface must see a terminal type, not the retryable
    # server_error vocabulary, for a rejection that will fail identically again.
    assert json_response(response, 400) == %{
             "error" => %{
               "type" => "invalid_request_error",
               "code" => "invalid_request",
               "param" => "tools.defer_loading",
               "message" => "upstream rejected parameter tools.defer_loading (invalid_request)"
             }
           }

    refute response.resp_body =~ @provider_sentinel
    refute response.resp_body =~ @prompt_sentinel
    FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.last_error_code == "upstream_status"
    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.response_metadata["rejection_error_type"] == "invalid_request_error"
    assert attempt.response_metadata["rejection_error_param"] == "tools.defer_loading"
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

  defp assert_failed_validation_accounting!(setup, expected_count) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert length(requests) == expected_count

    for request <- requests do
      assert request.status == "failed"
      assert request.last_error_code == "upstream_status"
      assert request.response_status_code == 400
      assert request.retry_count == 0

      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.network_error_code == "upstream_status"
      assert attempt.response_metadata["rejection_error_code"] == "unsupported_value"
      assert attempt.response_metadata["rejection_error_param"] == "reasoning.effort"
      refute inspect({request, attempt}) =~ @provider_sentinel
      refute inspect({request, attempt}) =~ @prompt_sentinel
    end

    assert Repo.aggregate(BridgeDemotion, :count) == 0
    assert Repo.aggregate(RoutingCircuitState, :count) == 0
  end

  # The rejected value is quoted in the prefix *and* repeated in the trailing
  # list. `ValidationRejection` drops it, so the public suffix must offer only
  # the values the provider would actually accept. Every other fixture in this
  # suite rejects a sentinel that never appears in the list, so without this
  # case a regression in the exclusion would reach the wire unnoticed
  # (findings#219).
  test "POST /v1/responses excludes the rejected value from the public supported list", %{
    conn: conn
  } do
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "POST",
            path: "/backend-api/codex/responses",
            respond:
              {:json_error, 400,
               %{
                 "error" => %{
                   "code" => "unsupported_value",
                   "message" =>
                     "Unsupported value: 'medium' is not supported with this model. " <>
                       "Supported values are: 'low', 'medium', and 'high'.",
                   "param" => "reasoning.effort",
                   "type" => "invalid_request_error"
                 }
               }}
          )
        ])
      )

    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => @prompt_sentinel,
        "stream" => false
      })

    assert json_response(response, 400) == %{
             "error" => %{
               "message" =>
                 "upstream rejected parameter reasoning.effort (unsupported_value); " <>
                   "supported values: low, high",
               "type" => "invalid_request_error",
               "code" => "unsupported_value",
               "param" => "reasoning.effort"
             }
           }

    refute response.resp_body =~ @prompt_sentinel

    assert [attempt] = Repo.all(from(attempt in Attempt))
    assert attempt.response_metadata["rejection_supported_values"] == ~w(low high)
    assert attempt.response_metadata["rejection_supported_values_state"] == "present"
  end

  # The provider refuses `previous_response_id` on HTTP with a detail body; it
  # resolves the anchor only on the websocket connection that produced the
  # response. An SDK tool loop sent over HTTP gets the parameter named, so a
  # client can resend the complete input (findings#232 row 232-275).
  test "POST /v1/responses relays the provider's unsupported previous_response_id on an HTTP tool-output continuation", %{conn: conn} do
    anchor_id = "resp_v1_http_anchor_unsupported_sample"

    upstream =
      start_upstream(
        # provenance: observed findings#232 row 232-275 live probe (HTTP 400, `{"detail": ...}` body whose 43-byte text fingerprints to the unsupported previous_response_id message, on /v1/responses stream false and true without owner forwarding)
        FakeUpstream.strict_sequence(
          for _stream <- [true, false] do
            FakeUpstream.expect_request(
              method: "POST",
              path: "/backend-api/codex/responses",
              json: [valid: true, equals: %{"previous_response_id" => anchor_id}],
              respond: {:json_error, 400, %{"detail" => "Unsupported parameter: previous_response_id"}}
            )
          end
        )
      )

    setup = gateway_setup(upstream)

    for stream? <- [true, false] do
      response =
        conn
        |> recycle()
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "previous_response_id" => anchor_id,
          "input" => [%{"type" => "function_call_output", "call_id" => "call_v1_anchor_unsupported", "output" => @prompt_sentinel}],
          "stream" => stream?
        })

      assert json_response(response, 400) == %{
               "error" => %{
                 "message" => "upstream rejected parameter previous_response_id (unsupported_parameter)",
                 "type" => "invalid_request_error",
                 "code" => "unsupported_parameter",
                 "param" => "previous_response_id"
               }
             },
             "stream #{stream?}"

      refute response.resp_body =~ @prompt_sentinel
    end

    FakeUpstream.verify!(upstream)

    for attempt <- Repo.all(from(attempt in Attempt)) do
      assert attempt.response_metadata["rejection_detail_class"] == "unsupported_parameter"
      assert attempt.response_metadata["rejection_error_param"] == "previous_response_id"
      refute inspect(attempt) =~ anchor_id
    end

    assert Repo.aggregate(Attempt, :count) == 2
    assert Repo.aggregate(BridgeDemotion, :count) == 0
    assert Repo.aggregate(RoutingCircuitState, :count) == 0
  end

  # A rejection whose provider message carries no `Supported values are: …`
  # list, so neither path can append a suffix and the two bodies are
  # comparable field for field.
  defp listless_rejection(status, code, param) do
    {:json_error, status,
     %{
       "error" => %{
         "code" => code,
         "message" => "Invalid value: '#{@provider_sentinel}'.",
         "param" => param,
         "type" => "invalid_request_error"
       }
     }}
  end

  defp validation_rejection(status, code, param, type \\ "invalid_request_error") do
    {:json_error, status,
     %{
       "error" => %{
         "code" => code,
         "message" => "Unsupported value: '#{@provider_sentinel}' is not supported with this model. Supported values are: 'low', 'medium', and 'high'.",
         "param" => param,
         "type" => type
       }
     }}
  end
end
