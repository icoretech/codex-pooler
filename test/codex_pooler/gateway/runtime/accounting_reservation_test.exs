defmodule CodexPooler.Gateway.Runtime.AccountingReservationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"

  test "session-routable execution rejects a claimed turn after a real transaction rollback" do
    upstream = start_upstream(FakeUpstream.json_response(%{"data" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => "pre-attempt rollback regression",
      "stream" => true
    }

    request_options = request_options(auth, payload, setup.model.exposed_model_id)

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint, payload, request_options, setup.model)

    claim_attrs =
      AccountingReservation.attrs(
        auth,
        payload,
        @endpoint,
        prepared.request_options,
        prepared.route_state
      )

    assert {:ok, %{request: turn_claim}} =
             Accounting.claim_websocket_turn(auth, setup.model, claim_attrs)

    reserve_and_start_turn = fn
      received_auth,
      received_model,
      received_payload,
      received_endpoint,
      received_request_options,
      received_route_state,
      received_turn_claim ->
        assert received_auth == auth
        assert received_model.id == setup.model.id
        assert received_payload == payload
        assert received_endpoint == @endpoint
        assert received_request_options.transport.transport == "websocket"
        assert received_route_state == prepared.route_state
        assert received_turn_claim.id == turn_claim.id

        Repo.transaction(fn -> Repo.rollback(:rollback) end)
    end

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 503,
                  code: "gateway_reservation_failed",
                  message: "gateway request reservation failed",
                  retryable: true
                }} =
                 Service.execute_session_routable_model(
                   %{
                     auth: auth,
                     endpoint: @endpoint,
                     payload: payload,
                     request_options: prepared.request_options,
                     model: setup.model,
                     candidates: prepared.candidates,
                     route_state: prepared.route_state,
                     turn_claim: turn_claim
                   },
                   reserve_and_start_turn
                 )
      end)

    assert log =~ "gateway pre-attempt reservation failed"
    assert log =~ "phase=pre_attempt"
    assert log =~ "operation=reserve_and_start_turn"
    assert log =~ "failure_code=gateway_reservation_failed"
    assert log =~ "status=503"
    assert log =~ "request_id=pre-attempt-rollback"
    assert log =~ "failure_reason=rollback"
    assert log =~ "retryable=true"
    refute log =~ "finalization"
    refute log =~ "attempt_id=unknown"

    assert %Request{
             status: "rejected",
             response_status_code: 503,
             last_error_code: "gateway_reservation_failed"
           } = Repo.reload!(turn_claim)

    assert FakeUpstream.count(upstream) == 0
  end

  test "unknown pre-attempt failures stay non-retryable" do
    payload = %{"model" => "gpt-test"}

    request_options =
      RequestOptions.build(%{request_id: "pre-attempt-unknown"}, @endpoint, payload)

    capture_log(fn ->
      assert %{
               status: 500,
               code: "gateway_reservation_failed",
               message: "gateway request reservation failed",
               retryable: false
             } =
               AccountingReservation.pre_attempt_failure(
                 :unexpected_reservation_failure,
                 request_options
               )
    end)
  end

  test "pre-attempt reservation logs sanitize client-controlled request correlators" do
    payload = %{"model" => "gpt-test"}

    request_options =
      RequestOptions.build(%{request_id: "Bearer secret\nforged_field=value"}, @endpoint, payload)

    log =
      capture_log(fn ->
        assert %{code: "gateway_reservation_failed"} =
                 AccountingReservation.pre_attempt_failure(:rollback, request_options)
      end)

    assert log =~ "request_id=redacted"
    refute log =~ "Bearer secret"
    refute log =~ "forged_field=value"
  end

  defp request_options(auth, payload, model) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    %{
      request_id: "pre-attempt-rollback",
      upstream_endpoint: @endpoint,
      transport: "websocket"
    }
    |> RequestOptions.build(@endpoint, payload)
    |> RequestOptions.put_routing(
      requested_model: model,
      effective_model: model,
      api_key_policy: policy
    )
  end
end
