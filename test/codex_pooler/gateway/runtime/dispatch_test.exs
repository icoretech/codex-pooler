defmodule CodexPooler.Gateway.Runtime.DispatchTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Runtime.Dispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState

  @endpoint_path "/backend-api/codex/responses"

  test "dispatch returns sanitized gateway error when route plan metadata cannot be recorded" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)
    parent = self()

    candidates = [{setup.assignment, setup.identity}]

    input = %{
      auth: auth,
      endpoint: @endpoint_path,
      payload: payload,
      model: setup.model,
      reserved: %{request: invalid_request()},
      candidates: candidates,
      request_options: request_options,
      route_state: RouteState.new(%{visible_model: setup.model, candidates: candidates})
    }

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} = Dispatch.dispatch(input, fn _context -> send(parent, :transport_called) end)
      end)

    assert log =~ "gateway accounting finalization failed"
    assert log =~ "operation=merge_route_plan_metadata"
    assert log =~ "request_id=#{input.reserved.request.id}"
    refute_received :transport_called
  end

  test "dispatch_from returns sanitized gateway error when selected route metadata cannot be recorded" do
    setup = gateway_setup(start_upstream(FakeUpstream.json_response(%{"data" => []})))
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = payload(setup)
    request_options = request_options(auth, payload, setup)
    request = invalid_request()
    candidates = [{setup.assignment, setup.identity}]
    parent = self()

    context = %Context{
      auth: auth,
      endpoint: @endpoint_path,
      payload: payload,
      model: setup.model,
      reserved: %{request: request},
      candidates: candidates,
      request_options: request_options,
      route_state: RouteState.new(%{visible_model: setup.model, candidates: candidates}),
      route_plan:
        BridgeRing.plan_route(%{
          auth: auth,
          model: setup.model,
          candidates: candidates,
          route_plan_input: RoutePlanInput.from_reserved(%{request: request}),
          request_options: request_options
        }),
      route_class: request_options.transport.route_class
    }

    log =
      capture_log(fn ->
        assert {:error,
                %{
                  status: 500,
                  code: "gateway_accounting_failed",
                  message: "gateway accounting finalization failed"
                }} =
                 Dispatch.dispatch_from(context, 0, fn _context ->
                   send(parent, :transport_called)
                 end)
      end)

    assert log =~ "gateway accounting finalization failed"
    assert log =~ "operation=merge_route_selection_metadata"
    assert log =~ "request_id=#{request.id}"
    refute_received :transport_called
  end

  defp payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => "runtime dispatch accounting regression"
    }
  end

  defp request_options(auth, payload, setup) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    %{
      request_id: "dispatch-accounting-#{System.unique_integer([:positive])}",
      upstream_endpoint: @endpoint_path
    }
    |> RequestOptions.build(@endpoint_path, payload)
    |> RequestOptions.put_routing(
      requested_model: setup.model.exposed_model_id,
      effective_model: setup.model.exposed_model_id,
      api_key_policy: policy
    )
  end

  defp invalid_request do
    %{
      id: Ecto.UUID.generate(),
      correlation_id: "dispatch-accounting-#{System.unique_integer([:positive])}"
    }
  end
end
