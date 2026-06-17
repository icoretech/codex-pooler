defmodule CodexPooler.Gateway.Runtime.Routing.RouteLifecycleTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Routing.RouteLifecycle

  @endpoint_path "/backend-api/codex/responses"

  test "failure returns sanitized gateway error when route metadata cannot be recorded" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_json",
               correlation_id: "route-lifecycle-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    request = invalid_request(reserved.request.id)
    candidates = [{setup.assignment, setup.identity}]

    context = %Context{
      auth: auth,
      endpoint: @endpoint_path,
      payload: payload,
      model: setup.model,
      reserved: %{request: request},
      candidates: candidates,
      request_options: request_options,
      route_plan:
        BridgeRing.plan_route(%{
          auth: auth,
          model: setup.model,
          candidates: candidates,
          route_plan_input: RoutePlanInput.from_reserved(%{request: request}),
          request_options: request_options
        }),
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      route_class: request_options.transport.route_class
    }

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} = RouteLifecycle.failure(context, "upstream_5xx")
      end)

    assert log =~ "operation=merge_route_failure_metadata"
    assert log =~ "request_id=#{request.id}"
  end

  test "failure returns sanitized gateway error when circuit state cannot be recorded" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_json",
               correlation_id: "route-lifecycle-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    candidates = [{setup.assignment, setup.identity}]

    context = %Context{
      auth: auth,
      endpoint: @endpoint_path,
      payload: payload,
      model: setup.model,
      reserved: reserved,
      candidates: candidates,
      request_options: request_options,
      route_plan:
        BridgeRing.plan_route(%{
          auth: auth,
          model: setup.model,
          candidates: candidates,
          route_plan_input: RoutePlanInput.from_reserved(reserved),
          request_options: request_options
        }),
      assignment: setup.assignment,
      identity: setup.identity,
      index: 0,
      route_class: nil
    }

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} = RouteLifecycle.failure(context, "upstream_5xx")
      end)

    assert log =~ "operation=record_route_circuit_failure"
  end

  defp payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => "route lifecycle accounting regression"
    }
  end

  defp request_options(auth, payload, setup) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    %{
      request_id: "route-lifecycle-#{System.unique_integer([:positive])}",
      upstream_endpoint: @endpoint_path
    }
    |> RequestOptions.build(@endpoint_path, payload)
    |> RequestOptions.put_routing(
      requested_model: setup.model.exposed_model_id,
      effective_model: setup.model.exposed_model_id,
      api_key_policy: policy
    )
  end

  defp invalid_request(id) do
    %{
      id: id,
      correlation_id: "route-lifecycle-#{System.unique_integer([:positive])}"
    }
  end
end
