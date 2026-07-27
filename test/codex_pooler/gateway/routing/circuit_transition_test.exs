defmodule CodexPooler.Gateway.Routing.CircuitTransitionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.CircuitState
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @circuit_transition_event [:codex_pooler, :gateway, :routing, :circuit, :transition]

  setup do
    old_config = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      old_config
      |> Keyword.delete(:settings)
      |> Keyword.put(:use_instance_settings?, true)
    )

    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()
    update_circuit_settings(%{"circuit_open_seconds" => 60, "circuit_half_open_probe_limit" => 1})

    on_exit(fn ->
      Application.put_env(:codex_pooler, OperationalSettings, old_config)
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()
    end)
  end

  test "emits exactly one post-commit event for every reachable circuit status transition" do
    {auth, model, assignment} = routing_fixture()
    update_circuit_settings(%{"circuit_failure_threshold" => 1})

    events = capture_transition_events()

    assert {:ok, %RoutingCircuitState{status: "open"} = opened} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :upstream_network_error
             )

    assert_transition(events, "closed_to_open", "closed", "open", "upstream_network_error")

    expire_probe_window!(opened)

    assert {:ok, %RoutingCircuitState{status: "half_open"}} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert_transition(events, "open_to_half_open", "open", "half_open", "none")

    assert {:ok, %RoutingCircuitState{status: "open"} = reopened} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :retryable_upstream_status
             )

    assert_transition(
      events,
      "half_open_to_open",
      "half_open",
      "open",
      "retryable_upstream_status"
    )

    expire_probe_window!(reopened)

    assert {:ok, %RoutingCircuitState{status: "half_open"}} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert_transition(events, "open_to_half_open", "open", "half_open", "none")

    assert {:ok, %RoutingCircuitState{status: "closed"}} =
             CircuitState.record_success(auth, model, assignment, "proxy_websocket")

    assert_transition(events, "half_open_to_closed", "half_open", "closed", "none")

    open_circuit!(auth, model, assignment,
      next_probe_at: DateTime.add(now(), 60, :second),
      route_class: "proxy_stream"
    )

    assert {:ok, %RoutingCircuitState{status: "closed"}} =
             CircuitState.record_success(auth, model, assignment, "proxy_stream")

    assert_transition(events, "open_to_closed", "open", "closed", "none")
    refute_receive {^events, _in_transaction?, _metadata}
  end

  test "emits exactly one probe and reopen pair for each natural blackout cooldown cycle" do
    {auth, model, assignment} = routing_fixture()
    update_circuit_settings(%{"circuit_failure_threshold" => 1})

    events = capture_transition_events()

    assert {:ok, %RoutingCircuitState{status: "open"} = opened} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_stream",
               :upstream_network_error
             )

    assert_transition(events, "closed_to_open", "closed", "open", "upstream_network_error")

    Enum.reduce(1..2, opened, fn _cycle, current ->
      expire_probe_window!(current)

      assert {:ok, %RoutingCircuitState{status: "half_open"}} =
               CircuitState.begin_attempt(auth, model, assignment, "proxy_stream")

      assert_transition(events, "open_to_half_open", "open", "half_open", "none")

      assert {:ok, %RoutingCircuitState{status: "open"} = reopened} =
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_stream",
                 :upstream_network_error
               )

      assert_transition(
        events,
        "half_open_to_open",
        "half_open",
        "open",
        "upstream_network_error"
      )

      reopened
    end)

    refute_receive {^events, _in_transaction?, _metadata}
  end

  test "does not emit for status-preserving writes, write-free paths, or transaction rollbacks" do
    {auth, model, assignment} = routing_fixture()

    update_circuit_settings(%{
      "circuit_failure_threshold" => 3,
      "circuit_half_open_probe_limit" => 2
    })

    events = capture_transition_events()

    assert {:ok, :ok} =
             CircuitState.record_success(auth, model, assignment, "proxy_websocket")

    assert {:ok, :ok} =
             CircuitState.record_neutral_completion(
               auth,
               model,
               assignment,
               "proxy_websocket"
             )

    assert {:ok, %RoutingCircuitState{status: "closed"}} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :first_failure
             )

    assert {:ok, %RoutingCircuitState{status: "closed"}} =
             CircuitState.record_neutral_completion(
               auth,
               model,
               assignment,
               "proxy_websocket"
             )

    assert {:ok, %RoutingCircuitState{status: "closed"}} =
             CircuitState.record_success(auth, model, assignment, "proxy_websocket")

    assert {:ok, nil} =
             CircuitState.begin_attempt(
               auth,
               model,
               assignment,
               "proxy_stream",
               %{eligible?: true, requires_lock?: false, status: nil, state: nil}
             )

    half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 0)

    assert {:ok, %RoutingCircuitState{status: "half_open"}} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert {:ok, %RoutingCircuitState{status: "half_open"}} =
             CircuitState.record_neutral_completion(auth, model, assignment, "proxy_websocket")

    Repo.delete_all(RoutingCircuitState)
    half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 2)

    assert {:error, :routing_circuit_probe_in_flight} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    Repo.delete_all(RoutingCircuitState)
    open_circuit!(auth, model, assignment, next_probe_at: DateTime.add(now(), 60, :second))

    assert {:error, :routing_circuit_open} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    Repo.delete_all(RoutingCircuitState)
    open_circuit!(auth, model, assignment, next_probe_at: nil)

    assert {:error, :routing_circuit_open} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    refute_receive {^events, _in_transaction?, _metadata}
  end

  test "emits exactly one event after a deadlock retry commits" do
    {auth, model, assignment} = in_db_observer(&routing_fixture/0)
    cleanup_unboxed_fixture(auth.pool.id, [assignment.upstream_identity_id])

    assert {:ok, %RoutingCircuitState{status: "closed", failure_count: 1}} =
             in_db_observer(fn ->
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_stream",
                 :upstream_network_error
               )
             end)

    assert {:ok, %RoutingCircuitState{status: "closed", failure_count: 2}} =
             in_db_observer(fn ->
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_stream",
                 :upstream_network_error
               )
             end)

    events = capture_transition_events()

    assert {:ok, %RoutingCircuitState{status: "open", failure_count: 3}} =
             in_db_observer(fn ->
               with_deadlock_trigger(:once, fn ->
                 CircuitState.record_failure(
                   auth,
                   model,
                   assignment,
                   "proxy_stream",
                   :upstream_network_error
                 )
               end)
             end)

    assert_transition(events, "closed_to_open", "closed", "open", "upstream_network_error")
    refute_receive {^events, _in_transaction?, _metadata}
  end

  test "does not emit or persist when deadlock retry is exhausted" do
    {auth, model, assignment} = in_db_observer(&routing_fixture/0)
    cleanup_unboxed_fixture(auth.pool.id, [assignment.upstream_identity_id])

    assert {:ok, %RoutingCircuitState{id: state_id, status: "closed", failure_count: 1}} =
             in_db_observer(fn ->
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_stream",
                 :upstream_network_error
               )
             end)

    events = capture_transition_events()

    log =
      capture_log(fn ->
        assert {:ok, :skipped} =
                 in_db_observer(fn ->
                   with_deadlock_trigger(:always, fn ->
                     CircuitState.record_failure(
                       auth,
                       model,
                       assignment,
                       "proxy_stream",
                       :upstream_network_error
                     )
                   end)
                 end)
      end)

    assert log =~ "code=routing_side_effect_deadlock"

    assert %RoutingCircuitState{id: ^state_id, status: "closed", failure_count: 1} =
             in_db_observer(fn -> Repo.get!(RoutingCircuitState, state_id) end)

    refute_receive {^events, _in_transaction?, _metadata}
  end

  test "does not emit when a missing reference pair degrades the circuit write to skipped" do
    identity_id = Ecto.UUID.generate()

    auth = %{
      pool: %Pool{id: Ecto.UUID.generate()},
      api_key: %APIKey{id: Ecto.UUID.generate()}
    }

    model = %Model{id: Ecto.UUID.generate(), exposed_model_id: "missing-model"}

    assignment = %PoolUpstreamAssignment{
      id: Ecto.UUID.generate(),
      upstream_identity_id: identity_id
    }

    events = capture_transition_events()

    log =
      capture_log(fn ->
        assert {:ok, :skipped} =
                 CircuitState.record_failure(
                   auth,
                   model,
                   assignment,
                   "proxy_stream",
                   :upstream_5xx
                 )
      end)

    assert log =~ "routing side effect skipped"
    assert log =~ "side_effect=circuit_failure"
    assert log =~ "code=upstream_identity_not_found"

    refute_receive {^events, _in_transaction?, _metadata}
  end

  defp open_circuit!(auth, model, assignment, attrs) do
    now = now()
    next_probe_at = Keyword.fetch!(attrs, :next_probe_at)
    route_class = Keyword.get(attrs, :route_class, "proxy_websocket")

    %RoutingCircuitState{
      pool_id: auth.pool.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: model.exposed_model_id,
      route_class: route_class,
      status: "open",
      reason_code: "test_open",
      failure_count: 3,
      success_count: 0,
      opened_at: now,
      next_probe_at: next_probe_at,
      metadata: %{"probe_in_flight_count" => 0},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp expire_probe_window!(state) do
    state
    |> Ecto.Changeset.change(%{next_probe_at: DateTime.add(now(), -1, :second)})
    |> Repo.update!()
  end

  defp capture_transition_events do
    parent = self()
    handler_id = "routing-circuit-transition-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @circuit_transition_event,
        fn _event, _measurements, metadata, _config ->
          send(parent, {handler_id, Repo.in_transaction?(), metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp assert_transition(handler_id, transition, from_status, to_status, reason_class) do
    assert_receive {^handler_id, false, metadata}
    assert metadata.transition == transition
    assert metadata.from_status == from_status
    assert metadata.to_status == to_status
    assert metadata.reason_class == reason_class
    assert metadata.route_class in ["proxy_websocket", "proxy_stream"]
  end

  defp with_deadlock_trigger(mode, callback) when mode in [:once, :always] do
    SQL.query!(
      Repo,
      "DROP TRIGGER IF EXISTS routing_circuit_transition_deadlock ON routing_circuit_states",
      []
    )

    SQL.query!(Repo, "DROP FUNCTION IF EXISTS routing_circuit_transition_deadlock()", [])
    SQL.query!(Repo, "DROP SEQUENCE IF EXISTS routing_circuit_transition_deadlock_seq", [])

    if mode == :once do
      SQL.query!(Repo, "CREATE SEQUENCE routing_circuit_transition_deadlock_seq START 1", [])
    end

    condition =
      case mode do
        :once -> "nextval('routing_circuit_transition_deadlock_seq') = 1"
        :always -> "TRUE"
      end

    SQL.query!(
      Repo,
      """
      CREATE FUNCTION routing_circuit_transition_deadlock()
      RETURNS trigger AS $$
      BEGIN
        IF #{condition} THEN
          RAISE EXCEPTION 'forced routing circuit deadlock' USING ERRCODE = '40P01';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TRIGGER routing_circuit_transition_deadlock
      BEFORE UPDATE ON routing_circuit_states
      FOR EACH ROW EXECUTE FUNCTION routing_circuit_transition_deadlock()
      """,
      []
    )

    try do
      callback.()
    after
      SQL.query!(
        Repo,
        "DROP TRIGGER IF EXISTS routing_circuit_transition_deadlock ON routing_circuit_states",
        []
      )

      SQL.query!(Repo, "DROP FUNCTION IF EXISTS routing_circuit_transition_deadlock()", [])
      SQL.query!(Repo, "DROP SEQUENCE IF EXISTS routing_circuit_transition_deadlock_seq", [])
    end
  end

  defp routing_fixture do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool)

    {%{pool: pool, api_key: api_key}, model, assignment}
  end

  defp half_open_circuit!(auth, model, assignment, attrs) do
    now = now()
    updated_at = Keyword.fetch!(attrs, :updated_at)
    probe_count = Keyword.fetch!(attrs, :probe_count)

    %RoutingCircuitState{
      pool_id: auth.pool.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: model.exposed_model_id,
      route_class: "proxy_websocket",
      status: "half_open",
      reason_code: "test_probe",
      failure_count: 3,
      success_count: 0,
      opened_at: DateTime.add(now, -120, :second),
      half_opened_at: updated_at,
      metadata: %{"probe_in_flight_count" => probe_count},
      created_at: DateTime.add(now, -120, :second),
      updated_at: updated_at
    }
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp update_circuit_settings(attrs) do
    instance_settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(instance_settings, %{"gateway" => attrs})
  end

  defp in_db_observer(callback) do
    task = Task.async(fn -> Sandbox.unboxed_run(Repo, callback) end)

    Task.await(task, 5_000)
  end

  defp cleanup_unboxed_fixture(pool_id, upstream_identity_ids) do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> cleanup_fixture(pool_id, upstream_identity_ids) end)
    end)
  end

  defp cleanup_fixture(pool_id, upstream_identity_ids) do
    pool = Repo.get(Pool, pool_id)
    if pool, do: Repo.delete!(pool)

    Repo.delete_all(
      from identity in UpstreamIdentity,
        where: identity.id in ^upstream_identity_ids
    )
  end
end
