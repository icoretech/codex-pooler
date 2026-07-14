defmodule CodexPooler.Gateway.Persistence.RoutingCircuitStateTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.CircuitState
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings

  alias Ecto.Adapters.SQL.Sandbox

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

  test "half-open circuits reject new probes while a fresh probe is in flight" do
    {auth, model, assignment} = routing_fixture()
    half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 1)

    refute CircuitState.eligible?(auth, model, assignment, "proxy_websocket")

    assert {:error, :routing_circuit_probe_in_flight} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")
  end

  test "half-open circuits recover stale in-flight probes" do
    {auth, model, assignment} = routing_fixture()
    stale_updated_at = DateTime.add(now(), -61, :second)

    state =
      half_open_circuit!(auth, model, assignment, updated_at: stale_updated_at, probe_count: 1)

    assert CircuitState.eligible?(auth, model, assignment, "proxy_websocket")

    assert {:ok, %RoutingCircuitState{} = updated} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert updated.id == state.id
    assert updated.metadata["probe_in_flight_count"] == 1
    assert DateTime.compare(updated.updated_at, state.updated_at) == :gt
  end

  test "open circuits reject selected attempts from request-local snapshots" do
    {auth, model, assignment} = routing_fixture()
    open_circuit!(auth, model, assignment, next_probe_at: DateTime.add(now(), 60, :second))

    snapshot = circuit_snapshot(auth, model, assignment)

    refute snapshot.eligible?

    assert {:error, :routing_circuit_open} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket", snapshot)
  end

  test "half-open selected attempts keep probe limits capped from locked snapshots" do
    {auth, model, assignment} = routing_fixture()
    half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 1)

    snapshot = circuit_snapshot(auth, model, assignment)

    refute snapshot.eligible?

    assert {:error, :routing_circuit_probe_in_flight} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket", snapshot)
  end

  test "stale half-open selected attempts recover through lock-time probe accounting" do
    {auth, model, assignment} = routing_fixture()
    stale_updated_at = DateTime.add(now(), -61, :second)

    state =
      half_open_circuit!(auth, model, assignment, updated_at: stale_updated_at, probe_count: 1)

    snapshot = circuit_snapshot(auth, model, assignment)

    assert snapshot.eligible?
    assert snapshot.requires_lock?

    assert {:ok, %RoutingCircuitState{} = updated} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket", snapshot)

    assert updated.id == state.id
    assert updated.metadata["probe_in_flight_count"] == 1
    assert DateTime.compare(updated.updated_at, state.updated_at) == :gt
  end

  test "closed selected attempts use request-local snapshots without circuit rereads" do
    {auth, model, assignment} = routing_fixture()

    snapshot = circuit_snapshot(auth, model, assignment)

    assert snapshot.eligible?
    refute snapshot.requires_lock?

    {_result, commands} =
      count_repo_commands(fn ->
        assert {:ok, nil} =
                 CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket", snapshot)
      end)

    assert command_count(commands, "routing_circuit_states", "SELECT") == 0
  end

  test "failure threshold updates affect the next failure without resetting persisted counts" do
    {auth, model, assignment} = routing_fixture()

    assert {:ok, %RoutingCircuitState{} = first} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :first_failure
             )

    assert first.status == "closed"
    assert first.failure_count == 1

    update_circuit_settings(%{"circuit_failure_threshold" => 2})

    assert {:ok, %RoutingCircuitState{} = opened} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :second_failure
             )

    assert opened.id == first.id
    assert opened.status == "open"
    assert opened.failure_count == 2
    assert %DateTime{} = opened.next_probe_at
  end

  test "open-window updates change half-open probe decisions without resetting circuit rows" do
    {auth, model, assignment} = routing_fixture()
    prior_updated_at = DateTime.add(now(), -30, :second)

    state =
      half_open_circuit!(auth, model, assignment, updated_at: prior_updated_at, probe_count: 1)

    refute CircuitState.eligible?(auth, model, assignment, "proxy_websocket")

    assert {:error, :routing_circuit_probe_in_flight} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    update_circuit_settings(%{"circuit_open_seconds" => 10})

    assert CircuitState.eligible?(auth, model, assignment, "proxy_websocket")

    assert {:ok, %RoutingCircuitState{} = resumed} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert resumed.id == state.id
    assert resumed.metadata["probe_in_flight_count"] == 1
    assert DateTime.compare(resumed.updated_at, state.updated_at) == :gt
  end

  test "neutral completions release half-open probes without counting success or failure" do
    {auth, model, assignment} = routing_fixture()
    state = half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 1)

    assert {:ok, %RoutingCircuitState{} = updated} =
             CircuitState.record_neutral_completion(auth, model, assignment, "proxy_websocket")

    assert updated.id == state.id
    assert updated.status == "half_open"
    assert updated.reason_code == "test_probe"
    assert updated.failure_count == state.failure_count
    assert updated.success_count == state.success_count
    assert updated.metadata["probe_in_flight_count"] == 0
    assert CircuitState.eligible?(auth, model, assignment, "proxy_websocket")
  end

  test "a failure observed from another process opens only its exact assignment model route lane" do
    {auth, model, assignment, sibling_assignment, sibling_model} =
      in_db_observer(fn ->
        {auth, model, assignment} = routing_fixture()
        %{assignment: sibling_assignment} = upstream_assignment_fixture(auth.pool)
        sibling_model = model_fixture(auth.pool, %{exposed_model_id: "gpt-example-sibling"})
        {auth, model, assignment, sibling_assignment, sibling_model}
      end)

    cleanup_unboxed_pool(auth.pool.id)

    update_circuit_settings(%{"circuit_failure_threshold" => 1})

    assert {:ok, %RoutingCircuitState{status: "open"}} =
             in_db_observer(fn ->
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_http",
                 :upstream_model_unavailable
               )
             end)

    assert %{
             exact_lane: false,
             sibling_assignment: true,
             sibling_model: true,
             sibling_route: true
           } =
             in_db_observer(fn ->
               %{
                 exact_lane: CircuitState.eligible?(auth, model, assignment, "proxy_http"),
                 sibling_assignment:
                   CircuitState.eligible?(auth, model, sibling_assignment, "proxy_http"),
                 sibling_model:
                   CircuitState.eligible?(auth, sibling_model, assignment, "proxy_http"),
                 sibling_route: CircuitState.eligible?(auth, model, assignment, "proxy_stream")
               }
             end)

    assert %RoutingCircuitState{
             pool_id: pool_id,
             api_key_id: nil,
             pool_upstream_assignment_id: assignment_id,
             model_identifier: model_identifier,
             route_class: "proxy_http",
             reason_code: "upstream_model_unavailable"
           } = in_db_observer(fn -> Repo.one!(RoutingCircuitState) end)

    assert pool_id == auth.pool.id
    assert assignment_id == assignment.id
    assert model_identifier == model.exposed_model_id
  end

  test "threshold and bounded half-open recovery persist across process observers" do
    {auth, model, assignment} = in_db_observer(&routing_fixture/0)
    cleanup_unboxed_pool(auth.pool.id)

    update_circuit_settings(%{
      "circuit_failure_threshold" => 2,
      "circuit_success_threshold" => 2,
      "circuit_half_open_probe_limit" => 1
    })

    assert {:ok, %RoutingCircuitState{status: "closed", failure_count: 1}} =
             in_db_observer(fn ->
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_stream",
                 :first_failure
               )
             end)

    assert {:ok, %RoutingCircuitState{status: "open", failure_count: 2} = opened} =
             in_db_observer(fn ->
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_stream",
                 :second_failure
               )
             end)

    in_db_observer(fn ->
      opened
      |> Ecto.Changeset.change(%{next_probe_at: DateTime.add(now(), -1, :second)})
      |> Repo.update!()
    end)

    assert {:ok, %RoutingCircuitState{status: "half_open"} = first_probe} =
             in_db_observer(fn ->
               CircuitState.begin_attempt(auth, model, assignment, "proxy_stream")
             end)

    assert first_probe.metadata["probe_in_flight_count"] == 1

    assert {:error, :routing_circuit_probe_in_flight} =
             in_db_observer(fn ->
               CircuitState.begin_attempt(auth, model, assignment, "proxy_stream")
             end)

    assert {:ok, %RoutingCircuitState{status: "half_open", success_count: 1} = first_success} =
             in_db_observer(fn ->
               CircuitState.record_success(auth, model, assignment, "proxy_stream")
             end)

    assert first_success.failure_count == 2
    assert first_success.metadata["probe_in_flight_count"] == 0

    assert {:ok, %RoutingCircuitState{status: "half_open"}} =
             in_db_observer(fn ->
               CircuitState.begin_attempt(auth, model, assignment, "proxy_stream")
             end)

    assert {:ok, %RoutingCircuitState{status: "closed", success_count: 2} = recovered} =
             in_db_observer(fn ->
               CircuitState.record_success(auth, model, assignment, "proxy_stream")
             end)

    assert recovered.failure_count == 0
    assert recovered.reason_code == nil
    assert recovered.next_probe_at == nil
    assert recovered.metadata["probe_in_flight_count"] == 0

    assert in_db_observer(fn ->
             CircuitState.eligible?(auth, model, assignment, "proxy_stream")
           end)
  end

  test "concurrent half-open attempts admit exactly one probe across independent checkouts" do
    {auth, model, assignment} = in_db_observer(&routing_fixture/0)
    cleanup_unboxed_pool(auth.pool.id)

    update_circuit_settings(%{
      "circuit_failure_threshold" => 1,
      "circuit_half_open_probe_limit" => 1
    })

    assert {:ok, %RoutingCircuitState{status: "open"} = opened} =
             in_db_observer(fn ->
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_stream",
                 :probe_race
               )
             end)

    in_db_observer(fn ->
      opened
      |> Ecto.Changeset.change(%{next_probe_at: DateTime.add(now(), -1, :second)})
      |> Repo.update!()
    end)

    parent = self()
    barrier = make_ref()

    attempts =
      Enum.map(1..2, fn _index ->
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[attempt_backend_pid]]} =
              Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])

            send(parent, {:probe_attempt_started, barrier, self(), attempt_backend_pid})

            receive do
              {:release_probe_attempt, ^barrier} -> :ok
            after
              5_000 -> raise "timed out waiting to start half-open probe race"
            end

            CircuitState.begin_attempt(auth, model, assignment, "proxy_stream")
          end)
        end)
      end)

    attempt_processes =
      Enum.map(attempts, fn _task ->
        assert_receive {:probe_attempt_started, ^barrier, pid, backend_pid}, 5_000
        {pid, backend_pid}
      end)

    assert attempt_processes |> Enum.map(&elem(&1, 0)) |> Enum.uniq() ==
             Enum.map(attempt_processes, &elem(&1, 0))

    attempt_backend_pids = Enum.map(attempt_processes, &elem(&1, 1))
    assert Enum.uniq(attempt_backend_pids) == attempt_backend_pids

    Enum.each(attempts, fn task ->
      send(task.pid, {:release_probe_attempt, barrier})
    end)

    results = Enum.map(attempts, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, %RoutingCircuitState{status: "half_open"}}, &1)) == 1

    assert Enum.count(results, &(&1 == {:error, :routing_circuit_probe_in_flight})) == 1

    assert %RoutingCircuitState{status: "half_open", metadata: metadata} =
             in_db_observer(fn -> Repo.get!(RoutingCircuitState, opened.id) end)

    assert metadata["probe_in_flight_count"] == 1
  end

  defp open_circuit!(auth, model, assignment, attrs) do
    now = now()
    next_probe_at = Keyword.fetch!(attrs, :next_probe_at)

    %RoutingCircuitState{
      pool_id: auth.pool.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: model.exposed_model_id,
      route_class: "proxy_websocket",
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

  defp circuit_snapshot(auth, model, assignment) do
    auth
    |> CircuitState.eligibility_snapshots(model, [{assignment, %{}}], "proxy_websocket")
    |> Map.fetch!(assignment.id)
  end

  defp count_repo_commands(fun) do
    parent = self()
    handler_id = "routing-circuit-state-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(parent, {handler_id, metadata[:source], command_name(metadata[:query])})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_commands(handler_id, %{})}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_commands(handler_id, commands) do
    receive do
      {^handler_id, source, command} ->
        key = {source, command}
        drain_repo_commands(handler_id, Map.update(commands, key, 1, &(&1 + 1)))
    after
      0 -> commands
    end
  end

  defp command_count(commands, source, command), do: Map.get(commands, {source, command}, 0)

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp command_name(_query), do: nil

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

  defp cleanup_unboxed_pool(pool_id) do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        pool = Repo.get(CodexPooler.Pools.Pool, pool_id)
        if pool, do: Repo.delete!(pool)
      end)
    end)
  end
end
