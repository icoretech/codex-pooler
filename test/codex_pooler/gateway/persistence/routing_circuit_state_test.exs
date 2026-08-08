defmodule CodexPooler.Gateway.Persistence.RoutingCircuitStateTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.{CircuitHealth, CircuitState}
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  alias Ecto.Adapters.SQL
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

    assert {:ok, %{admission: :probe, state: %RoutingCircuitState{} = updated}} =
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

    assert {:ok, %{admission: :probe, state: %RoutingCircuitState{} = updated}} =
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
        assert {:ok, %{admission: :none, state: nil}} =
                 CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket", snapshot)
      end)

    assert command_count(commands, "routing_circuit_states", "SELECT") == 0
  end

  test "attempt admission distinguishes probe normal and absent circuit rows" do
    {auth, model, assignment} = routing_fixture()

    assert {:ok, %{admission: :none, state: nil}} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert {:ok, %RoutingCircuitState{} = closed} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :characterization_failure
             )

    closed_snapshot = circuit_snapshot(auth, model, assignment)
    refute closed_snapshot.requires_lock?

    assert {:ok, %{admission: :normal, state: %RoutingCircuitState{id: closed_id}}} =
             CircuitState.begin_attempt(
               auth,
               model,
               assignment,
               "proxy_websocket",
               closed_snapshot
             )

    assert closed_id == closed.id

    opened =
      closed
      |> Ecto.Changeset.change(%{
        status: "open",
        next_probe_at: DateTime.add(now(), -1, :second)
      })
      |> Repo.update!()

    assert {:ok, %{admission: :probe, state: %RoutingCircuitState{id: opened_id} = probe}} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert opened_id == opened.id
    assert probe.metadata["probe_in_flight_count"] == 1
  end

  test "snapshot reuse preserves none and normal admissions without circuit rereads" do
    {auth, model, assignment} = routing_fixture()

    no_row_snapshot = circuit_snapshot(auth, model, assignment)

    {_result, commands} =
      count_repo_commands(fn ->
        assert {:ok, %{admission: :none, state: nil}} =
                 CircuitState.begin_attempt(
                   auth,
                   model,
                   assignment,
                   "proxy_websocket",
                   no_row_snapshot
                 )
      end)

    assert command_count(commands, "routing_circuit_states", "SELECT") == 0

    assert {:ok, %RoutingCircuitState{}} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :characterization_failure
             )

    closed_snapshot = circuit_snapshot(auth, model, assignment)

    {_result, commands} =
      count_repo_commands(fn ->
        assert {:ok, %{admission: :normal, state: %RoutingCircuitState{}}} =
                 CircuitState.begin_attempt(
                   auth,
                   model,
                   assignment,
                   "proxy_websocket",
                   closed_snapshot
                 )
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
    assert first.metadata["saved_reset_recovery"] == recovery_marker(false, nil)

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

  test "closed-to-open recovery marker uses the current last-success stamp" do
    {auth, model, assignment} = routing_fixture()
    update_circuit_settings(%{"circuit_failure_threshold" => 1})

    assert {:ok, %RoutingCircuitState{status: "open"} = initially_opened} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :initial_failure
             )

    assert {:ok, %RoutingCircuitState{status: "closed"} = recovered} =
             CircuitState.record_success(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :normal
             )

    assert recovered.id == initially_opened.id
    refute Map.has_key?(recovered.metadata, "saved_reset_recovery")

    assert {:ok, %RoutingCircuitState{status: "open"} = reopened} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :post_success_failure
             )

    assert reopened.metadata["saved_reset_recovery"] ==
             recovery_marker(false, recovered.last_success_at)

    refute CircuitHealth.saved_reset_recovery_attempted?(reopened)
  end

  test "threshold opening persists a current unattempted saved-reset recovery marker" do
    {auth, model, assignment} = routing_fixture()
    update_circuit_settings(%{"circuit_failure_threshold" => 1})

    assert {:ok, %RoutingCircuitState{status: "open"} = opened} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :threshold_failure
             )

    persisted = Repo.get!(RoutingCircuitState, opened.id)

    assert persisted.metadata["saved_reset_recovery"] == %{
             "version" => 1,
             "attempted" => false,
             "since_success_at" => "never"
           }

    refute CircuitHealth.saved_reset_recovery_attempted?(persisted)

    assert {:ok, %RoutingCircuitState{status: "open"} = after_in_flight_failure} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :additional_in_flight_failure
             )

    assert after_in_flight_failure.failure_count == 2

    assert after_in_flight_failure.metadata["saved_reset_recovery"] ==
             persisted.metadata["saved_reset_recovery"]
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

    assert {:ok, %{admission: :probe, state: %RoutingCircuitState{} = resumed}} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert resumed.id == state.id
    assert resumed.metadata["probe_in_flight_count"] == 1
    assert DateTime.compare(resumed.updated_at, state.updated_at) == :gt
  end

  test "neutral completions release half-open probes without counting success or failure" do
    {auth, model, assignment} = routing_fixture()

    state =
      half_open_circuit!(auth, model, assignment,
        updated_at: now(),
        probe_count: 1,
        recovery_marker: recovery_marker(false, nil)
      )

    assert {:ok, %RoutingCircuitState{} = updated} =
             CircuitState.record_neutral_completion(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :probe
             )

    assert updated.id == state.id
    assert updated.status == "half_open"
    assert updated.reason_code == "test_probe"
    assert updated.failure_count == state.failure_count
    assert updated.success_count == state.success_count
    assert updated.metadata["probe_in_flight_count"] == 0
    assert updated.metadata["saved_reset_recovery"] == recovery_marker(false, nil)
    refute CircuitHealth.saved_reset_recovery_attempted?(updated)
    assert CircuitState.eligible?(auth, model, assignment, "proxy_websocket")
  end

  test "an old normal failure cannot consume another request's half-open probe slot" do
    {auth, model, assignment} = routing_fixture()
    update_circuit_settings(%{"circuit_failure_threshold" => 1})

    assert {:ok, %RoutingCircuitState{status: "open"} = state} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :initial_failure
             )

    state
    |> Ecto.Changeset.change(%{next_probe_at: DateTime.add(now(), -1, :second)})
    |> Repo.update!()

    normal_snapshot = %{
      eligible?: true,
      requires_lock?: false,
      status: "closed",
      state: nil
    }

    assert {:ok, %{admission: normal_admission, state: nil}} =
             CircuitState.begin_attempt(
               auth,
               model,
               assignment,
               "proxy_websocket",
               normal_snapshot
             )

    assert normal_admission == :normal

    assert {:ok,
            %{
              admission: probe_admission,
              state: %RoutingCircuitState{status: "half_open"} = probe
            }} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert probe_admission == :probe

    assert probe.id == state.id
    assert probe.metadata["probe_in_flight_count"] == 1
    assert probe.metadata["saved_reset_recovery"] == recovery_marker(false, nil)
    refute CircuitHealth.saved_reset_recovery_attempted?(probe)

    assert {:ok, %RoutingCircuitState{} = after_old_failure} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :old_normal_request_failed,
               normal_admission
             )

    assert after_old_failure.metadata["probe_in_flight_count"] == 1
    assert after_old_failure.metadata["saved_reset_recovery"] == recovery_marker(false, nil)
    refute CircuitHealth.saved_reset_recovery_attempted?(after_old_failure)
    assert after_old_failure.status == "half_open"
  end

  test "probe admission preserves false and probe failure records the attempt across reopen" do
    {auth, model, assignment} = routing_fixture()
    update_circuit_settings(%{"circuit_failure_threshold" => 1})

    assert {:ok, %RoutingCircuitState{status: "open"} = opened} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :initial_failure
             )

    opened
    |> Ecto.Changeset.change(%{next_probe_at: DateTime.add(now(), -1, :second)})
    |> Repo.update!()

    assert {:ok, %{admission: :probe, state: %RoutingCircuitState{} = probe}} =
             CircuitState.begin_attempt(auth, model, assignment, "proxy_websocket")

    assert probe.metadata["saved_reset_recovery"] == recovery_marker(false, nil)
    refute CircuitHealth.saved_reset_recovery_attempted?(probe)

    assert {:ok, %RoutingCircuitState{status: "open"} = reopened} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :probe_failure,
               :probe
             )

    assert reopened.metadata["probe_in_flight_count"] == 0
    assert reopened.metadata["saved_reset_recovery"] == recovery_marker(true, nil)
    assert CircuitHealth.saved_reset_recovery_attempted?(reopened)

    assert {:ok, %RoutingCircuitState{status: "open"} = still_open} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :additional_failure,
               :normal
             )

    assert still_open.metadata["saved_reset_recovery"] == recovery_marker(true, nil)
    assert CircuitHealth.saved_reset_recovery_attempted?(still_open)
  end

  test "success clears a current recovery marker and invalidates stale replicas" do
    {auth, model, assignment} = routing_fixture()
    update_circuit_settings(%{"circuit_success_threshold" => 1})

    last_success_at = DateTime.add(now(), -300, :second)

    state =
      half_open_circuit!(auth, model, assignment,
        updated_at: now(),
        probe_count: 1,
        last_success_at: last_success_at,
        recovery_marker: recovery_marker(true, last_success_at)
      )

    assert CircuitHealth.saved_reset_recovery_attempted?(state)

    assert {:ok, %RoutingCircuitState{status: "closed"} = recovered} =
             CircuitState.record_success(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :probe
             )

    refute Map.has_key?(recovered.metadata, "saved_reset_recovery")
    refute CircuitHealth.saved_reset_recovery_attempted?(recovered)

    stale_metadata =
      Map.put(
        recovered.metadata,
        "saved_reset_recovery",
        recovery_marker(true, state.last_success_at)
      )

    stale_replica =
      recovered |> Ecto.Changeset.change(%{metadata: stale_metadata}) |> Repo.update!()

    refute CircuitHealth.saved_reset_recovery_attempted?(stale_replica)
  end

  test "non-closing success invalidates a preserved marker with its new success stamp" do
    {auth, model, assignment} = routing_fixture()
    update_circuit_settings(%{"circuit_success_threshold" => 2})

    last_success_at = DateTime.add(now(), -300, :second)

    state =
      half_open_circuit!(auth, model, assignment,
        updated_at: now(),
        probe_count: 1,
        last_success_at: last_success_at,
        recovery_marker: recovery_marker(true, last_success_at)
      )

    assert {:ok, %RoutingCircuitState{status: "half_open"} = partial_success} =
             CircuitState.record_success(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :probe
             )

    assert partial_success.metadata["saved_reset_recovery"] ==
             recovery_marker(true, state.last_success_at)

    refute CircuitHealth.saved_reset_recovery_attempted?(partial_success)
  end

  test "only exact current saved-reset recovery markers read attempted" do
    {auth, model, assignment} = routing_fixture()
    last_success_at = DateTime.add(now(), -60, :second)

    state =
      half_open_circuit!(auth, model, assignment,
        updated_at: now(),
        probe_count: 0,
        last_success_at: last_success_at,
        recovery_marker: recovery_marker(true, last_success_at)
      )

    assert CircuitHealth.saved_reset_recovery(state) == recovery_marker(true, last_success_at)
    assert CircuitHealth.valid_saved_reset_recovery?(state)
    assert CircuitHealth.saved_reset_recovery_attempted?(state)

    invalid_markers = [
      :missing,
      %{"version" => 1, "attempted" => "true", "since_success_at" => "never"},
      %{"version" => 2, "attempted" => true, "since_success_at" => "never"},
      Map.put(recovery_marker(true, last_success_at), "unexpected", true),
      recovery_marker(true, DateTime.add(last_success_at, -1, :second))
    ]

    Enum.each(invalid_markers, fn marker ->
      metadata =
        case marker do
          :missing -> Map.delete(state.metadata, "saved_reset_recovery")
          marker -> Map.put(state.metadata, "saved_reset_recovery", marker)
        end

      persisted = state |> Ecto.Changeset.change(%{metadata: metadata}) |> Repo.update!()

      assert CircuitHealth.saved_reset_recovery(persisted) == nil
      refute CircuitHealth.valid_saved_reset_recovery?(persisted)
      refute CircuitHealth.saved_reset_recovery_attempted?(persisted)
    end)
  end

  test "probe failure releases its admitted slot while normal and none failures preserve it" do
    {auth, model, assignment} = routing_fixture()

    for admission <- [:probe, :normal, :none] do
      Repo.delete_all(RoutingCircuitState)
      half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 1)

      assert {:ok, %RoutingCircuitState{} = updated} =
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_websocket",
                 :attempt_failure,
                 admission
               )

      expected_count = if admission == :probe, do: 0, else: 1
      assert updated.metadata["probe_in_flight_count"] == expected_count
    end
  end

  test "normal failure keeps the existing reopen policy when no probe slot is active" do
    {auth, model, assignment} = routing_fixture()
    half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 0)

    assert {:ok, %RoutingCircuitState{} = updated} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :late_normal_failure,
               :normal
             )

    assert updated.status == "open"
    assert updated.metadata["probe_in_flight_count"] == 0
  end

  test "only probe neutral completion releases an admitted slot" do
    {auth, model, assignment} = routing_fixture()

    for admission <- [:probe, :normal, :none] do
      Repo.delete_all(RoutingCircuitState)
      half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 1)

      assert {:ok, %RoutingCircuitState{} = updated} =
               CircuitState.record_neutral_completion(
                 auth,
                 model,
                 assignment,
                 "proxy_websocket",
                 admission
               )

      expected_count = if admission == :probe, do: 0, else: 1
      assert updated.metadata["probe_in_flight_count"] == expected_count
    end
  end

  test "only probe success releases an admitted slot" do
    {auth, model, assignment} = routing_fixture()
    update_circuit_settings(%{"circuit_success_threshold" => 2})

    for admission <- [:probe, :normal, :none] do
      Repo.delete_all(RoutingCircuitState)
      half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 1)

      assert {:ok, %RoutingCircuitState{} = updated} =
               CircuitState.record_success(
                 auth,
                 model,
                 assignment,
                 "proxy_websocket",
                 admission
               )

      expected_count = if admission == :probe, do: 0, else: 1
      assert updated.metadata["probe_in_flight_count"] == expected_count
    end
  end

  test "normal success follows the close threshold without releasing another probe slot" do
    {auth, model, assignment} = routing_fixture()
    update_circuit_settings(%{"circuit_success_threshold" => 1})
    half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 1)

    assert {:ok, %RoutingCircuitState{} = updated} =
             CircuitState.record_success(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :normal
             )

    assert updated.status == "closed"
    assert updated.metadata["probe_in_flight_count"] == 1
  end

  test "invalid admission is rejected without changing the active probe slot" do
    {auth, model, assignment} = routing_fixture()
    state = half_open_circuit!(auth, model, assignment, updated_at: now(), probe_count: 1)

    assert {:error, :invalid_circuit_admission} =
             CircuitState.record_neutral_completion(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :malformed
             )

    assert Repo.get!(RoutingCircuitState, state.id).metadata["probe_in_flight_count"] == 1
  end

  test "none completion is safe when no circuit row exists" do
    {auth, model, assignment} = routing_fixture()

    assert {:ok, :ok} =
             CircuitState.record_neutral_completion(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :none
             )

    assert {:ok, :ok} =
             CircuitState.record_success(
               auth,
               model,
               assignment,
               "proxy_websocket",
               :none
             )

    assert Repo.aggregate(RoutingCircuitState, :count) == 0
  end

  test "a failure observed from another process opens only its exact assignment model route lane" do
    {auth, model, assignment, sibling_assignment, sibling_model} =
      in_db_observer(fn ->
        {auth, model, assignment} = routing_fixture()
        %{assignment: sibling_assignment} = upstream_assignment_fixture(auth.pool)
        sibling_model = model_fixture(auth.pool, %{exposed_model_id: "gpt-example-sibling"})
        {auth, model, assignment, sibling_assignment, sibling_model}
      end)

    cleanup_unboxed_fixture(auth.pool.id, [
      assignment.upstream_identity_id,
      sibling_assignment.upstream_identity_id
    ])

    update_circuit_settings(%{"circuit_failure_threshold" => 1})

    assert {writer_backend_pid, {:ok, %RoutingCircuitState{status: "open"} = written}} =
             in_db_observer_with_backend_pid(fn ->
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_http",
                 :upstream_model_unavailable
               )
             end)

    assert {reader_backend_pid,
            %{
              exact_lane: false,
              sibling_assignment: true,
              sibling_model: true,
              sibling_route: true,
              retained_state: %RoutingCircuitState{id: retained_id, status: "open"}
            }} =
             in_db_observer_with_backend_pid(fn ->
               %{
                 exact_lane: CircuitState.eligible?(auth, model, assignment, "proxy_http"),
                 sibling_assignment:
                   CircuitState.eligible?(auth, model, sibling_assignment, "proxy_http"),
                 sibling_model:
                   CircuitState.eligible?(auth, sibling_model, assignment, "proxy_http"),
                 sibling_route: CircuitState.eligible?(auth, model, assignment, "proxy_stream"),
                 retained_state: Repo.get!(RoutingCircuitState, written.id)
               }
             end)

    refute writer_backend_pid == reader_backend_pid
    assert retained_id == written.id

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
    cleanup_unboxed_fixture(auth.pool.id, [assignment.upstream_identity_id])

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

    assert {:ok,
            %{admission: :probe, state: %RoutingCircuitState{status: "half_open"} = first_probe}} =
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
               CircuitState.record_success(auth, model, assignment, "proxy_stream", :probe)
             end)

    assert first_success.failure_count == 2
    assert first_success.metadata["probe_in_flight_count"] == 0

    assert {:ok, %{admission: :probe, state: %RoutingCircuitState{status: "half_open"}}} =
             in_db_observer(fn ->
               CircuitState.begin_attempt(auth, model, assignment, "proxy_stream")
             end)

    assert {:ok, %RoutingCircuitState{status: "closed", success_count: 2} = recovered} =
             in_db_observer(fn ->
               CircuitState.record_success(auth, model, assignment, "proxy_stream", :probe)
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
    cleanup_unboxed_fixture(auth.pool.id, [assignment.upstream_identity_id])

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
              SQL.query!(Repo, "SELECT pg_backend_pid()", [])

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

    assert Enum.count(
             results,
             &match?(
               {:ok, %{admission: :probe, state: %RoutingCircuitState{status: "half_open"}}},
               &1
             )
           ) == 1

    assert Enum.count(results, &(&1 == {:error, :routing_circuit_probe_in_flight})) == 1

    assert %RoutingCircuitState{status: "half_open", metadata: metadata} =
             in_db_observer(fn -> Repo.get!(RoutingCircuitState, opened.id) end)

    assert metadata["probe_in_flight_count"] == 1
  end

  @tag :routing_old_normal_failure_during_probe
  test "an old normal failure waits behind an active probe and preserves its slot" do
    {auth, model, assignment} = in_db_observer(&routing_fixture/0)
    cleanup_unboxed_fixture(auth.pool.id, [assignment.upstream_identity_id])

    circuit =
      in_db_observer(fn ->
        half_open_circuit!(auth, model, assignment,
          updated_at: now(),
          probe_count: 1,
          recovery_marker: recovery_marker(false, nil)
        )
      end)

    parent = self()
    barrier = make_ref()

    probe_holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            backend_pid = backend_pid!()

            locked =
              Repo.one!(
                from state in RoutingCircuitState,
                  where: state.id == ^circuit.id,
                  lock: "FOR UPDATE"
              )

            send(
              parent,
              {barrier, :probe_active, backend_pid, locked.metadata["probe_in_flight_count"]}
            )

            receive do
              {^barrier, :release_probe} -> :ok
            after
              10_000 -> raise "timed out waiting to release active probe holder"
            end
          end)
        end)
      end)

    old_failure =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          backend_pid = backend_pid!()
          send(parent, {barrier, :old_failure_started, backend_pid})

          receive do
            {^barrier, :release_old_failure} -> :ok
          after
            5_000 -> raise "timed out waiting to start old normal failure"
          end

          {backend_pid,
           CircuitState.record_failure(
             auth,
             model,
             assignment,
             "proxy_websocket",
             :old_normal_failure,
             :normal
           )}
        end)
      end)

    try do
      assert_receive {^barrier, :probe_active, probe_backend_pid, 1}, 5_000
      assert_receive {^barrier, :old_failure_started, failure_backend_pid}, 5_000
      assert probe_backend_pid != failure_backend_pid
      send(old_failure.pid, {barrier, :release_old_failure})
      observation = observe_blocked_backend!(failure_backend_pid, probe_backend_pid)
      assert observation.wait_event_type == "Lock"
      assert probe_backend_pid in observation.blocking_pids
      send(probe_holder.pid, {barrier, :release_probe})
      assert {:ok, _transaction_result} = Task.await(probe_holder, 10_000)

      assert {^failure_backend_pid, {:ok, %RoutingCircuitState{}}} =
               Task.await(old_failure, 10_000)

      persisted = in_db_observer(fn -> Repo.get!(RoutingCircuitState, circuit.id) end)
      assert persisted.status == "half_open"
      assert persisted.failure_count == 4
      assert persisted.metadata["probe_in_flight_count"] == 1
      assert get_in(persisted.metadata, ["saved_reset_recovery", "attempted"]) == false
    after
      send(probe_holder.pid, {barrier, :release_probe})
      Enum.each([probe_holder, old_failure], &finish_task/1)
    end
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

    metadata =
      %{"probe_in_flight_count" => probe_count}
      |> maybe_put_recovery_marker(Keyword.get(attrs, :recovery_marker))

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
      last_success_at: Keyword.get(attrs, :last_success_at),
      metadata: metadata,
      created_at: DateTime.add(now, -120, :second),
      updated_at: updated_at
    }
    |> Repo.insert!()
  end

  defp recovery_marker(attempted, nil) do
    %{"version" => 1, "attempted" => attempted, "since_success_at" => "never"}
  end

  defp recovery_marker(attempted, %DateTime{} = last_success_at) do
    %{
      "version" => 1,
      "attempted" => attempted,
      "since_success_at" => DateTime.to_iso8601(last_success_at)
    }
  end

  defp maybe_put_recovery_marker(metadata, nil), do: metadata

  defp maybe_put_recovery_marker(metadata, marker),
    do: Map.put(metadata, "saved_reset_recovery", marker)

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

  defp in_db_observer_with_backend_pid(callback) do
    in_db_observer(fn ->
      %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
      {backend_pid, callback.()}
    end)
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp observe_blocked_backend!(waiter_pid, blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + 4_000
    do_observe_blocked_backend!(waiter_pid, blocker_pid, deadline)
  end

  defp do_observe_blocked_backend!(waiter_pid, blocker_pid, deadline) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT pg_blocking_pids($1), wait_event_type FROM pg_stat_activity WHERE pid = $1",
        [waiter_pid]
      )

    case rows do
      [[blocking_pids, "Lock"]] ->
        if blocker_pid in blocking_pids do
          %{blocking_pids: blocking_pids, wait_event_type: "Lock"}
        else
          retry_blocked_backend!(waiter_pid, blocker_pid, deadline)
        end

      _rows ->
        retry_blocked_backend!(waiter_pid, blocker_pid, deadline)
    end
  end

  defp retry_blocked_backend!(waiter_pid, blocker_pid, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      do_observe_blocked_backend!(waiter_pid, blocker_pid, deadline)
    else
      flunk("old normal failure never waited on the active probe PostgreSQL backend")
    end
  end

  defp finish_task(task) do
    case Task.yield(task, 5_000) do
      {:ok, _result} -> :ok
      {:exit, _reason} -> :ok
      nil -> Task.shutdown(task, :brutal_kill)
    end
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
