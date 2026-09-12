defmodule CodexPooler.Gateway.Routing.RouteLifecycleTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Gateway.Routing.{RouteLifecycle, RoutingSelection}

  setup do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment, identity: identity} = upstream_assignment_fixture(pool)
    model = model_fixture(pool)
    auth = %{pool: pool, api_key: api_key}

    selection = %RoutingSelection{
      assignment: assignment,
      identity: identity,
      route_class: "proxy_websocket",
      route_plan: %{
        planned_at: DateTime.utc_now(),
        affinity: %{
          enabled?: false,
          key_hash: nil,
          pool_id: pool.id,
          api_key_id: api_key.id,
          model_identifier: model.exposed_model_id
        }
      }
    }

    %{auth: auth, model: model, selection: selection}
  end

  test "failure persists both circuit and demotion and success resolves both", context do
    %{auth: auth, model: model, selection: selection} = context

    assert {:ok, "upstream_network_error"} =
             RouteLifecycle.selection_failure(
               auth,
               model,
               selection,
               nil,
               :upstream_network_error
             )

    circuit = Repo.one!(RoutingCircuitState)
    demotion = Repo.one!(BridgeDemotion)
    assert circuit.failure_count == 1
    assert circuit.reason_code == "upstream_network_error"
    assert circuit.pool_upstream_assignment_id == selection.assignment.id
    assert demotion.status == "active"

    # The success that clears a health demotion is a turn that planned its route
    # after the failure wrote it. `BridgeRing.record_success/3` fences on that,
    # so reusing this turn's own selection would leave the row active.
    assert :ok = RouteLifecycle.selection_success(auth, model, next_turn(selection))
    assert %{status: "closed", failure_count: 0, success_count: 1} = Repo.reload!(circuit)
    assert Repo.reload!(demotion).status == "resolved"
  end

  test "neutral probe completion releases slot without changing circuit outcome", context do
    %{auth: auth, model: model, selection: selection} = context

    assert {:ok, _} =
             RouteLifecycle.selection_failure(
               auth,
               model,
               selection,
               nil,
               :upstream_network_error
             )

    circuit = Repo.one!(RoutingCircuitState)

    circuit
    |> Ecto.Changeset.change(status: "half_open", metadata: %{"probe_in_flight_count" => 1})
    |> Repo.update!()

    assert :ok =
             RouteLifecycle.selection_neutral_completion(auth, model, %{
               selection
               | circuit_admission: :probe
             })

    assert %{
             status: "half_open",
             failure_count: 1,
             success_count: 0,
             metadata: %{"probe_in_flight_count" => 0}
           } = Repo.reload!(circuit)

    assert Repo.one!(BridgeDemotion).status == "active"
  end

  test "overload completion demotes for ordering and leaves the circuit alone", context do
    %{auth: auth, model: model, selection: selection} = context

    assert :ok = RouteLifecycle.selection_overload_completion(auth, model, selection, nil)

    demotion = Repo.one!(BridgeDemotion)
    assert demotion.status == "active"
    assert demotion.reason_code == "provider_overloaded"
    assert demotion.metadata == %{"source" => "gateway_overload"}
    assert demotion.pool_upstream_assignment_id == selection.assignment.id

    # An overload says the provider refused the work, not that the account is
    # unhealthy, so the terminal stays health-neutral and writes no circuit row.
    assert Repo.all(RoutingCircuitState) == []

    # The window is the whole penalty. A later turn succeeding on the account is
    # not proof that the capacity which refused the last one came back, so it
    # does not cut a live overload window short; the window expires by itself.
    assert :ok = RouteLifecycle.selection_success(auth, model, next_turn(selection))
    assert Repo.reload!(demotion).status == "active"
  end

  test "neutral completion without a circuit does not create one", context do
    assert :ok =
             RouteLifecycle.selection_neutral_completion(
               context.auth,
               context.model,
               context.selection
             )

    assert Repo.all(RoutingCircuitState) == []
    assert Repo.all(BridgeDemotion) == []
  end

  test "invalid circuit admission is translated to an accounting failure", context do
    %{auth: auth, model: model, selection: selection} = context
    selection = %{selection | route_class: ""}

    for operation <- [
          fn -> RouteLifecycle.selection_success(auth, model, selection) end,
          fn ->
            RouteLifecycle.selection_failure(auth, model, selection, nil, :upstream_network_error)
          end,
          fn -> RouteLifecycle.selection_neutral_completion(auth, model, selection) end
        ] do
      {result, log} = with_log(operation)
      assert {:error, %{status: 500, code: "gateway_accounting_failed"}} = result
      assert log =~ "invalid_route_class"
    end

    assert Repo.all(RoutingCircuitState) == []
  end

  test "optional lifecycle results log only failure codes" do
    assert capture_log(fn ->
             assert :ok = RouteLifecycle.log_optional_result("sample", [], :ok)
             assert :ok = RouteLifecycle.log_optional_result("sample", [], {:ok, :skipped})
           end) == ""

    for reason <- [%{code: "sample_failure"}, %{code: :sample_failure}, {:error, :opaque}] do
      assert capture_log(fn ->
               assert :ok = RouteLifecycle.log_optional_result("sample", [], {:error, reason})
             end) =~ "gateway route lifecycle side effect failed"
    end
  end

  # The turn after this one: a fresh route plan, so its success may reason about
  # the demotion state the previous turn left behind. The planning mark itself is
  # produced by `BridgeRing.plan_route/1` in production and covered against the
  # real planner in `CodexPooler.Gateway.Routing.BridgeRingTest`.
  defp next_turn(%RoutingSelection{route_plan: route_plan} = selection),
    do: %{selection | route_plan: Map.put(route_plan, :planned_at, DateTime.utc_now())}
end
