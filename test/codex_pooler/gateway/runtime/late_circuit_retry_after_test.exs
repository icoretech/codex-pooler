defmodule CodexPooler.Gateway.Runtime.LateCircuitRetryAfterTest do
  # A circuit can refuse a candidate after route filtering admitted it: the
  # circuit opened, or a concurrent request took the half-open probe slot,
  # between the filter's snapshot and the dispatch loop's circuit admission.
  # On the last candidate the loop answers `503 no_eligible_backend`; it carries
  # the same retry advice as route filtering's refusal (findings#206 rows
  # 206-532, 206-548): the seconds until the earliest circuit-blocked candidate
  # of the plan admits a probe, clamped to 1..60.
  #
  # One BEAM node, FakeUpstream never dispatched to; the real dispatch loop
  # over a route plan built before the circuit rows exist (the race window,
  # made deterministic).
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Runtime.Dispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"
  @route_classes ["proxy_http", "proxy_stream"]

  test "an open circuit met at dispatch on the last candidate advises the seconds to its probe" do
    {context, setup, upstream} = dispatch_context!()
    open_circuit!(setup, 40)

    assert {:error, %{status: 503, code: "no_eligible_backend", circuit_retry_after_seconds: seconds}} = Dispatch.dispatch(context, &transport_never_called/1)
    assert seconds in 35..40
    assert FakeUpstream.count(upstream) == 0
  end

  test "a saturated half-open circuit met at dispatch advises when its probe goes stale" do
    {context, setup, _upstream} = dispatch_context!()
    stale_in = OperationalSettings.current().circuit_open_seconds
    half_open_circuit!(setup, 20 - stale_in)

    assert {:error, %{status: 503, code: "no_eligible_backend", circuit_retry_after_seconds: seconds}} = Dispatch.dispatch(context, &transport_never_called/1)
    assert seconds in 15..20
  end

  defp transport_never_called(_context), do: flunk("the refused candidate reached the transport")

  defp dispatch_context! do
    upstream = start_upstream(FakeUpstream.json_response(%{"output" => []}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    payload = %{"model" => setup.model.exposed_model_id, "input" => "synthetic late circuit prompt"}
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    request_options =
      %{request_id: "late-circuit-#{System.unique_integer([:positive])}", upstream_endpoint: @endpoint_path}
      |> RequestOptions.build(@endpoint_path, payload)
      |> RequestOptions.put_routing(requested_model: setup.model.exposed_model_id, effective_model: setup.model.exposed_model_id, api_key_policy: policy)

    assert {:ok, reserved} =
             Accounting.reserve(auth, setup.model, payload, %{
               endpoint: @endpoint_path,
               transport: "http_json",
               correlation_id: "late-circuit-#{System.unique_integer([:positive])}",
               request_metadata: %{}
             })

    candidates = [{setup.assignment, setup.identity}]

    assert {:ok, context} =
             Context.new(%{
               auth: auth,
               endpoint: @endpoint_path,
               payload: payload,
               model: setup.model,
               reserved: reserved,
               candidates: candidates,
               request_options: request_options,
               route_state: RouteState.new(%{visible_model: setup.model, candidates: candidates})
             })

    {context, setup, upstream}
  end

  defp open_circuit!(setup, probe_in_seconds) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    insert_circuits!(setup, %{status: "open", next_probe_at: DateTime.add(now, probe_in_seconds, :second), updated_at: now, metadata: %{"probe_in_flight_count" => 0}})
  end

  defp half_open_circuit!(setup, updated_offset_seconds) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    insert_circuits!(setup, %{status: "half_open", next_probe_at: nil, half_opened_at: now, updated_at: DateTime.add(now, updated_offset_seconds, :second), metadata: %{"probe_in_flight_count" => 1}})
  end

  defp insert_circuits!(setup, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for route_class <- @route_classes do
      %RoutingCircuitState{
        pool_id: setup.pool.id,
        pool_upstream_assignment_id: setup.assignment.id,
        upstream_identity_id: setup.identity.id,
        model_identifier: setup.model.exposed_model_id,
        route_class: route_class,
        reason_code: "upstream_5xx",
        failure_count: 3,
        success_count: 0,
        opened_at: DateTime.add(now, -30, :second),
        last_failure_at: now,
        created_at: DateTime.add(now, -30, :second)
      }
      |> struct(attrs)
      |> Repo.insert!()
    end
  end
end
