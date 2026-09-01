defmodule CodexPooler.Gateway.DenialsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"

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

  test "websocket denial inserts a separate rejected row with current request claim" do
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
    assert rejected.correlation_id == request_claim_key
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
end
