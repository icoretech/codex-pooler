defmodule CodexPooler.Gateway.DenialsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.AccountingBoundaryTrace
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"

  test "trusted concurrency denials replace domain prose and give each unclaimed retry its own row" do
    fake = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id}

    opts =
      RequestOptions.build(
        %{transport: "websocket", request_id: Ecto.UUID.generate()},
        @endpoint_path,
        payload
      )

    context = %Denials.Context{
      auth: auth,
      model: setup.model,
      payload: payload,
      endpoint: @endpoint_path,
      opts: opts,
      reason: %{code: :api_key_concurrency_limit_exceeded, message: "untrusted domain detail"}
    }

    for _ <- 1..2 do
      assert {:error,
              %{
                status: 429,
                pooler_policy: true,
                code: "api_key_concurrency_limit_exceeded",
                message: "api key active request limit reached; retry shortly"
              }} = Denials.log_gateway(context)
    end

    assert [first, second] = Repo.all(Request)
    refute first.correlation_id == second.correlation_id

    assert Enum.all?(
             [first, second],
             &(&1.status == "rejected" and &1.response_status_code == 429)
           )

    assert Repo.all(Attempt) == []
    assert FakeUpstream.count(fake) == 0
  end

  test "gateway denial persists only allowlisted reasoning policy metadata" do
    fake = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id, "input" => "synthetic"}
    opts = RequestOptions.build(%{}, @endpoint_path, payload)

    reason = %{
      status: 400,
      code: "reasoning_effort_not_allowed",
      message: "reasoning effort is not available for this API key",
      param: "reasoning.effort",
      reasoning_policy: %{
        policy_mode: "allow_up_to",
        configured_effort: "low",
        requested_effort: "high",
        applied_effort: nil,
        unsafe: "discarded"
      }
    }

    assert {:error, ^reason} =
             Denials.log_gateway(%Denials.Context{
               auth: auth,
               model: setup.model,
               reason: reason,
               endpoint: @endpoint_path,
               payload: payload,
               opts: opts
             })

    assert [request] = Repo.all(Request)
    assert Repo.all(Attempt) == []
    assert FakeUpstream.count(fake) == 0

    assert request.request_metadata["gateway_denial"] == %{
             "code" => "reasoning_effort_not_allowed",
             "message" => "reasoning effort is not available for this API key",
             "param" => "reasoning.effort",
             "reasoning_policy" => %{
               "policy_mode" => "allow_up_to",
               "configured_effort" => "low",
               "requested_effort" => "high",
               "applied_effort" => nil
             }
           }
  end

  test "gateway denial omits the raw idempotency key at the accounting boundary" do
    fake = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id, "input" => "synthetic"}
    raw_key = "denial-private-key-#{System.unique_integer([:positive])}"
    opts = RequestOptions.build(%{idempotency_key: raw_key}, @endpoint_path, payload)

    reason = %{
      status: 400,
      code: "reasoning_effort_not_allowed",
      message: "reasoning effort is not available for this API key"
    }

    {result, [_auth, _model, attrs]} =
      AccountingBoundaryTrace.capture_call(
        {CodexPooler.Accounting, :record_denied_request, 3},
        fn ->
          Denials.log_gateway(%Denials.Context{
            auth: auth,
            model: setup.model,
            reason: reason,
            endpoint: @endpoint_path,
            payload: payload,
            opts: opts
          })
        end
      )

    assert {:error, ^reason} = result
    refute Map.has_key?(attrs, :idempotency_key)
    refute inspect(attrs, limit: :infinity, printable_limit: :infinity) =~ raw_key
  end

  test "a policy denial answers a disabled key with the auth boundary's 401" do
    fake = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id, "input" => "synthetic"}
    opts = RequestOptions.build(%{}, @endpoint_path, payload)

    # `GatewayControllerHelpers.authenticate/1` already says 401 for a disabled
    # key; the gateway policy path used to say 403 for the same condition
    # (findings#221). Missing stays 401; a model policy answers 400, which the
    # released Codex client does not resend (findings#206 row 206-438).
    for {reason, status, message} <- [
          {:api_key_disabled, 401, "api key is disabled"},
          {:api_key_missing, 401, "api key is required"},
          {:model_not_allowed, 400, "api key is not allowed to use this model"},
          {:api_key_policy_malformed, 403, "api key policy is invalid"}
        ] do
      code = Atom.to_string(reason)

      assert {:error, %{status: ^status, code: ^code, message: ^message, pooler_policy: true}} =
               Denials.log_policy(%Denials.Context{
                 auth: auth,
                 model: setup.model,
                 reason: reason,
                 endpoint: @endpoint_path,
                 payload: payload,
                 opts: opts
               })

      assert [%Request{status: "rejected", response_status_code: ^status} = request] =
               Repo.all(
                 from r in Request,
                   where: fragment("?->'policy_denial'->>'code' = ?", r.request_metadata, ^code)
               )

      assert request.request_metadata["policy_denial"]["message"] == message
    end

    assert Repo.all(Attempt) == []
    assert FakeUpstream.count(fake) == 0
  end

  test "gateway denial classifies unknown requested reasoning without persisting raw text" do
    fake = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    raw_effort = String.duplicate("x", 4_096)
    payload = %{"model" => setup.model.exposed_model_id, "reasoning" => %{"effort" => raw_effort}}
    opts = RequestOptions.build(%{}, @endpoint_path, payload)

    reason = %{
      status: 400,
      code: "reasoning_effort_not_allowed",
      message: "reasoning effort is not available for this API key",
      param: "reasoning.effort",
      reasoning_policy: %{
        policy_mode: "allow_up_to",
        configured_effort: "low",
        requested_effort: raw_effort,
        applied_effort: nil
      }
    }

    assert {:error, ^reason} =
             Denials.log_gateway(%Denials.Context{
               auth: auth,
               model: setup.model,
               reason: reason,
               endpoint: @endpoint_path,
               payload: payload,
               opts: opts
             })

    assert [request] = Repo.all(Request)

    assert request.request_metadata["gateway_denial"]["reasoning_policy"][
             "requested_effort"
           ] == "unknown"

    refute inspect(request.request_metadata) =~ raw_effort
  end

  # A refusal made before the request's claim never takes that claim: the same
  # request resent once the cause is gone would meet it and get `409
  # duplicate_turn` for good (findings#206 row 206-429). It takes the socket's
  # handshake request id instead.
  test "websocket denial inserts a separate rejected row that never takes the request claim" do
    fake = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id, "input" => "synthetic"}

    anchor_correlation =
      "codex-turn:" <>
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    frame_correlation = "frame-#{System.unique_integer([:positive])}"

    request_claim_key =
      "codex-request:" <>
        (:crypto.hash(:sha256, frame_correlation)
         |> Base.url_encode64(padding: false))

    assert {:ok, %{request: anchor}} =
             CodexPooler.Accounting.record_denied_request(auth, setup.model, %{
               endpoint: @endpoint_path,
               transport: "websocket",
               correlation_id: anchor_correlation,
               requested_model: setup.model.exposed_model_id,
               response_status_code: 400,
               last_error_code: "anchor"
             })

    opts =
      RequestOptions.build(
        %{
          transport: "websocket",
          request_id: frame_correlation,
          request_claim_key: request_claim_key
        },
        @endpoint_path,
        payload
      )
      |> RequestOptions.put_continuity(turn_claim_key: anchor_correlation)

    assert anchor.correlation_id == anchor_correlation
    assert opts.continuity.turn_claim_key == anchor_correlation
    assert opts.continuity.request_claim_key == request_claim_key
    assert opts.request_metadata.request_id == frame_correlation

    reason = %{
      status: 503,
      code: "pinned_continuation_unavailable",
      message: "pinned continuation is unavailable"
    }

    assert {:error, ^reason} =
             Denials.log_gateway(%Denials.Context{
               auth: auth,
               model: setup.model,
               reason: reason,
               endpoint: "/backend-api/codex/responses/compact",
               payload: payload,
               opts: opts
             })

    assert [^anchor, rejected] = Repo.all(from request in Request, order_by: request.admitted_at)
    assert rejected.correlation_id == frame_correlation
    refute Repo.get_by(Request, correlation_id: request_claim_key)
    assert rejected.status == "rejected"

    assert {:error, ^reason} =
             Denials.log_gateway(
               %Denials.Context{
                 auth: auth,
                 model: setup.model,
                 reason: reason,
                 endpoint: @endpoint_path,
                 payload: payload,
                 opts: opts
               },
               anchor
             )

    assert Repo.aggregate(Request, :count) == 2
    assert Repo.get!(Request, anchor.id).status == "rejected"

    ordinary_opts =
      RequestOptions.build(
        %{transport: "websocket", request_id: "ordinary-denial-frame"},
        @endpoint_path,
        payload
      )

    assert {:error, ^reason} =
             Denials.log_gateway(%Denials.Context{
               auth: auth,
               model: setup.model,
               reason: reason,
               endpoint: @endpoint_path,
               payload: payload,
               opts: ordinary_opts
             })

    assert Repo.get_by!(Request, correlation_id: "ordinary-denial-frame").status == "rejected"
  end

  test "the shared policy constructor marks every Pooler-authored denial" do
    # Every producer of a policy denial builds it here, so `/v1` unredacts by
    # construction and a producer cannot forget the marker (findings#221).
    assert %{
             status: 403,
             code: "image_generation_disabled",
             message: "off",
             param: nil,
             pooler_policy: true
           } =
             Denials.policy_error(403, "image_generation_disabled", "off")

    assert %{param: "model", pooler_policy: true} =
             Denials.policy_error(403, "model_not_allowed", "no", "model")
  end

  test "a policy reason has one status and message wherever it is answered" do
    # `PreDispatch` and `log_policy/1` share this mapping, so a disabled or
    # missing key cannot surface as a 403 on one path and a 401 on the other
    # (findings#221).
    assert %{
             status: 401,
             code: "api_key_missing",
             message: "api key is required",
             pooler_policy: true
           } =
             Denials.policy_denial_error(:api_key_missing)

    assert %{status: 401, code: "api_key_disabled", message: "api key is disabled"} =
             Denials.policy_denial_error(:api_key_disabled)

    assert %{
             status: 400,
             code: "model_not_allowed",
             message: "api key is not allowed to use this model",
             param: "model"
           } =
             Denials.policy_denial_error(:model_not_allowed)

    assert %{status: 403, code: "api_key_policy_malformed", message: "api key policy is invalid"} =
             Denials.policy_denial_error(:api_key_policy_malformed)

    # An unforeseen reason keeps its code and the generic policy message.
    assert %{
             status: 403,
             code: "some_future_reason",
             message: "api key policy denied this request",
             pooler_policy: true
           } =
             Denials.policy_denial_error(:some_future_reason)
  end
end
