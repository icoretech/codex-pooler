defmodule CodexPooler.Gateway.Routing.CircuitHealthEquivalenceTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.{CircuitHealth, CircuitState}

  @route_class "proxy_websocket"

  setup do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      settings: %OperationalSettings{
        circuit_open_seconds: 60,
        circuit_half_open_probe_limit: 1
      }
    )

    on_exit(fn ->
      if previous_settings do
        Application.put_env(:codex_pooler, OperationalSettings, previous_settings)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)
  end

  test "blocked classification matches production routing eligibility across every circuit state" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    model = model_fixture(pool)
    observed_at = now()

    scenarios = [
      {:closed, [status: "closed"]},
      {:open_future, [status: "open", next_probe_at: DateTime.add(observed_at, 3_600, :second)]},
      {:open_past, [status: "open", next_probe_at: DateTime.add(observed_at, -3_600, :second)]},
      {:open_nil_next_probe, [status: "open"]},
      {:half_open_free,
       [status: "half_open", metadata: %{"probe_in_flight_count" => "malformed"}]},
      {:half_open_saturated_fresh,
       [status: "half_open", metadata: %{"probe_in_flight_count" => 1}]},
      {:half_open_saturated_stale,
       [
         status: "half_open",
         metadata: %{"probe_in_flight_count" => 1},
         updated_at: DateTime.add(observed_at, -3_600, :second)
       ]},
      {:absent, nil}
    ]

    scenario_rows =
      Map.new(scenarios, fn {name, attrs} ->
        %{assignment: assignment} = upstream_assignment_fixture(pool)
        state = if attrs, do: circuit_state_fixture(pool, model, assignment, observed_at, attrs)

        {name, {assignment, state}}
      end)

    candidates =
      Enum.map(scenario_rows, fn {_name, {assignment, _state}} -> {assignment, %{}} end)

    snapshots =
      CircuitState.eligibility_snapshots(
        %{pool: pool, api_key: api_key},
        model,
        candidates,
        @route_class
      )

    settings = OperationalSettings.current()

    for {name, {assignment, state}} <- scenario_rows do
      snapshot = Map.fetch!(snapshots, assignment.id)

      assert CircuitHealth.blocked?(state, settings, observed_at) == not snapshot.eligible?,
             "classification diverged for #{name}"
    end
  end

  defp circuit_state_fixture(pool, model, assignment, observed_at, attrs) do
    defaults = [
      status: "closed",
      next_probe_at: nil,
      metadata: %{"probe_in_flight_count" => 0},
      updated_at: observed_at
    ]

    attrs = Keyword.merge(defaults, attrs)

    %RoutingCircuitState{
      pool_id: pool.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: model.exposed_model_id,
      route_class: @route_class,
      status: Keyword.fetch!(attrs, :status),
      reason_code: "synthetic_test_state",
      failure_count: 3,
      success_count: 0,
      next_probe_at: Keyword.fetch!(attrs, :next_probe_at),
      metadata: Keyword.fetch!(attrs, :metadata),
      created_at: observed_at,
      updated_at: Keyword.fetch!(attrs, :updated_at)
    }
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
