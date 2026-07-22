defmodule CodexPooler.Gateway.Routing.CircuitState do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.RequestLifecycle.ReferenceLocks
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @circuit_probe_in_flight_key "probe_in_flight_count"
  @closed_status RoutingCircuitState.closed_status()
  @open_status RoutingCircuitState.open_status()
  @half_open_status RoutingCircuitState.half_open_status()

  @type auth :: CodexPooler.Access.auth_context()
  @type eligibility_snapshot :: %{
          required(:eligible?) => boolean(),
          required(:requires_lock?) => boolean(),
          required(:status) => String.t() | nil,
          required(:state) => RoutingCircuitState.t() | nil
        }

  @spec eligible?(auth(), Model.t(), PoolUpstreamAssignment.t(), String.t()) :: boolean()
  def eligible?(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        %Model{} = model,
        %PoolUpstreamAssignment{} = assignment,
        route_class
      ) do
    now = now()
    settings = OperationalSettings.current()

    case latest(auth, model, assignment, route_class) do
      %RoutingCircuitState{status: @open_status, next_probe_at: %DateTime{} = next_probe_at} ->
        DateTime.compare(next_probe_at, now) != :gt

      %RoutingCircuitState{status: @open_status} ->
        false

      %RoutingCircuitState{status: @half_open_status} = state ->
        probe_available?(state, settings, now)

      _state ->
        true
    end
  end

  @spec eligibility_snapshots(auth(), Model.t(), [term()], String.t()) :: %{
          optional(Ecto.UUID.t()) => eligibility_snapshot()
        }
  def eligibility_snapshots(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        %Model{} = model,
        candidates,
        route_class
      )
      when is_list(candidates) and is_binary(route_class) and route_class != "" do
    assignment_ids =
      candidates
      |> Enum.map(fn {assignment, _identity} -> assignment.id end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    states = latest_by_assignment(auth, model, assignment_ids, route_class)
    settings = OperationalSettings.current()
    now = now()

    Map.new(assignment_ids, fn assignment_id ->
      state = Map.get(states, assignment_id)
      {assignment_id, snapshot_for_state(state, settings, now)}
    end)
  end

  def eligibility_snapshots(
        %{pool: %Pool{}, api_key: %APIKey{}},
        %Model{},
        candidates,
        _route_class
      )
      when is_list(candidates) do
    candidates
    |> Enum.map(fn {assignment, _identity} -> assignment.id end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(&{&1, default_snapshot()})
  end

  @spec begin_attempt(auth(), Model.t(), PoolUpstreamAssignment.t(), String.t()) ::
          {:ok, RoutingCircuitState.t() | nil} | {:error, term()}
  def begin_attempt(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        %Model{} = model,
        %PoolUpstreamAssignment{} = assignment,
        route_class
      )
      when is_binary(route_class) and route_class != "" do
    begin_attempt(auth, model, assignment, route_class, nil)
  end

  def begin_attempt(
        %{pool: %Pool{}, api_key: %APIKey{}},
        %Model{},
        %PoolUpstreamAssignment{},
        _route_class
      ),
      do: {:error, :invalid_route_class}

  @spec begin_attempt(
          auth(),
          Model.t(),
          PoolUpstreamAssignment.t(),
          String.t(),
          eligibility_snapshot() | boolean() | nil
        ) ::
          {:ok, RoutingCircuitState.t() | nil} | {:error, term()}
  def begin_attempt(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        %Model{} = model,
        %PoolUpstreamAssignment{} = assignment,
        route_class,
        snapshot
      )
      when is_binary(route_class) and route_class != "" do
    snapshot = normalize_snapshot(snapshot)

    case snapshot do
      %{eligible?: false, status: @half_open_status} ->
        {:error, :routing_circuit_probe_in_flight}

      %{eligible?: false} ->
        {:error, :routing_circuit_open}

      _snapshot ->
        begin_attempt_with_snapshot(auth, model, assignment, route_class, snapshot)
    end
  end

  def begin_attempt(
        %{pool: %Pool{}, api_key: %APIKey{}},
        %Model{},
        %PoolUpstreamAssignment{},
        _route_class,
        _snapshot
      ),
      do: {:error, :invalid_route_class}

  @spec record_success(auth(), Model.t(), PoolUpstreamAssignment.t(), String.t()) ::
          {:ok, :ok | RoutingCircuitState.t()} | {:error, term()}
  def record_success(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        %Model{} = model,
        %PoolUpstreamAssignment{} = assignment,
        route_class
      )
      when is_binary(route_class) and route_class != "" do
    now = now()
    settings = OperationalSettings.current()

    Repo.transaction(fn ->
      case latest_for_update(auth, model, assignment, route_class) do
        %RoutingCircuitState{} = state ->
          state
          |> RoutingCircuitState.changeset(success_attrs(state, settings, now))
          |> persist_or_rollback(:update)

        nil ->
          :ok
      end
    end)
    |> unwrap_transaction()
  end

  def record_success(
        %{pool: %Pool{}, api_key: %APIKey{}},
        %Model{},
        %PoolUpstreamAssignment{},
        _route_class
      ),
      do: {:error, :invalid_route_class}

  @spec record_failure(auth(), Model.t(), PoolUpstreamAssignment.t(), String.t(), term()) ::
          {:ok, RoutingCircuitState.t() | :skipped} | {:error, term()}
  def record_failure(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        %Model{} = model,
        %PoolUpstreamAssignment{} = assignment,
        route_class,
        reason_code
      )
      when is_binary(route_class) and route_class != "" do
    reason_code = sanitize_reason_code(reason_code)
    now = now()
    settings = OperationalSettings.current()

    run_failure_transaction(
      auth,
      model,
      assignment,
      route_class,
      reason_code,
      settings,
      now,
      _retry_left = 1
    )
  end

  def record_failure(
        %{pool: %Pool{}, api_key: %APIKey{}},
        %Model{},
        %PoolUpstreamAssignment{},
        _route_class,
        _reason_code
      ),
      do: {:error, :invalid_route_class}

  # Same degrade/retry policy as the BridgeRing side-effect writers: a
  # reference-lock rollback (missing or reassigned pair) and a retried
  # residual deadlock must skip the circuit write instead of failing the
  # turn's finalization path; other errors keep their existing plumbing.
  defp run_failure_transaction(
         auth,
         model,
         assignment,
         route_class,
         reason_code,
         settings,
         now,
         retry_left
       ) do
    Repo.transaction(fn ->
      state = latest_for_update(auth, model, assignment, route_class)

      attrs =
        failure_attrs(
          auth,
          model,
          assignment,
          route_class,
          reason_code,
          state,
          settings,
          now
        )

      case state do
        %RoutingCircuitState{} = state ->
          state |> RoutingCircuitState.changeset(attrs) |> persist_or_rollback(:update)

        nil ->
          # The first-failure insert references the assignment and identity
          # rows through FK checks whose implicit lock order inverts the
          # canonical identity-first order used by credential fencing; take
          # the canonical reference locks before inserting.
          ReferenceLocks.lock_and_validate!(assignment.upstream_identity_id, assignment.id)

          %RoutingCircuitState{}
          |> RoutingCircuitState.changeset(Map.put(attrs, :created_at, now))
          |> persist_or_rollback(:insert)
      end
    end)
    |> unwrap_transaction()
    |> degrade_reference_skip(assignment)
  rescue
    error in Postgrex.Error ->
      cond do
        deadlock?(error) and retry_left > 0 ->
          run_failure_transaction(
            auth,
            model,
            assignment,
            route_class,
            reason_code,
            settings,
            now,
            retry_left - 1
          )

        deadlock?(error) ->
          log_skipped_circuit_write(assignment, "routing_side_effect_deadlock")
          {:ok, :skipped}

        true ->
          reraise error, __STACKTRACE__
      end
  end

  defp degrade_reference_skip({:error, %{code: code}}, assignment)
       when code in [
              :upstream_identity_not_found,
              :pool_upstream_assignment_not_found,
              :upstream_reference_mismatch
            ] do
    log_skipped_circuit_write(assignment, Atom.to_string(code))
    {:ok, :skipped}
  end

  defp degrade_reference_skip(result, _assignment), do: result

  defp deadlock?(%Postgrex.Error{postgres: %{code: :deadlock_detected}}), do: true
  defp deadlock?(%Postgrex.Error{}), do: false

  defp log_skipped_circuit_write(assignment, code) do
    Logger.warning(
      "routing side effect skipped side_effect=circuit_failure code=#{code} " <>
        "pool_upstream_assignment_id=#{assignment.id} " <>
        "upstream_identity_id=#{assignment.upstream_identity_id}"
    )
  end

  @spec record_neutral_completion(auth(), Model.t(), PoolUpstreamAssignment.t(), String.t()) ::
          {:ok, :ok | RoutingCircuitState.t()} | {:error, term()}
  def record_neutral_completion(
        %{pool: %Pool{}, api_key: %APIKey{}} = auth,
        %Model{} = model,
        %PoolUpstreamAssignment{} = assignment,
        route_class
      )
      when is_binary(route_class) and route_class != "" do
    now = now()

    Repo.transaction(fn ->
      case latest_for_update(auth, model, assignment, route_class) do
        %RoutingCircuitState{status: @half_open_status} = state ->
          state
          |> RoutingCircuitState.changeset(%{
            metadata: probe_metadata(state, max(probe_in_flight_count(state) - 1, 0)),
            updated_at: now
          })
          |> persist_or_rollback(:update)

        %RoutingCircuitState{} = state ->
          state

        nil ->
          :ok
      end
    end)
    |> unwrap_transaction()
  end

  def record_neutral_completion(
        %{pool: %Pool{}, api_key: %APIKey{}},
        %Model{},
        %PoolUpstreamAssignment{},
        _route_class
      ),
      do: {:error, :invalid_route_class}

  defp begin_attempt_with_snapshot(
         _auth,
         _model,
         _assignment,
         _route_class,
         %{requires_lock?: false} = snapshot
       ),
       do: {:ok, snapshot.state}

  defp begin_attempt_with_snapshot(auth, model, assignment, route_class, _snapshot) do
    now = now()
    settings = OperationalSettings.current()

    Repo.transaction(fn ->
      state = latest_for_update(auth, model, assignment, route_class)
      begin_state(state, settings, now)
    end)
    |> case do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp begin_state(
         %RoutingCircuitState{status: @open_status, next_probe_at: %DateTime{} = next_probe_at} =
           state,
         _settings,
         now
       ) do
    if DateTime.compare(next_probe_at, now) == :gt do
      Repo.rollback(:routing_circuit_open)
    else
      state
      |> RoutingCircuitState.changeset(%{
        status: @half_open_status,
        half_opened_at: now,
        success_count: 0,
        metadata: probe_metadata(state, 1),
        updated_at: now
      })
      |> persist_or_rollback(:update)
    end
  end

  defp begin_state(%RoutingCircuitState{status: @open_status}, _settings, _now),
    do: Repo.rollback(:routing_circuit_open)

  defp begin_state(%RoutingCircuitState{status: @half_open_status} = state, settings, now) do
    stale? = probe_stale?(state, settings, now)
    in_flight = if stale?, do: 0, else: probe_in_flight_count(state)

    if in_flight >= settings.circuit_half_open_probe_limit do
      Repo.rollback(:routing_circuit_probe_in_flight)
    else
      attrs = %{
        metadata: probe_metadata(state, in_flight + 1),
        updated_at: now
      }

      attrs =
        if stale? do
          Map.put(attrs, :half_opened_at, now)
        else
          attrs
        end

      state
      |> RoutingCircuitState.changeset(attrs)
      |> persist_or_rollback(:update)
    end
  end

  defp begin_state(state, _settings, _now), do: state

  defp success_attrs(%RoutingCircuitState{status: @half_open_status} = state, settings, now) do
    success_count = state.success_count + 1
    probe_count = max(probe_in_flight_count(state) - 1, 0)

    attrs = %{
      success_count: success_count,
      last_success_at: now,
      metadata: probe_metadata(state, probe_count),
      updated_at: now
    }

    if success_count >= settings.circuit_success_threshold do
      Map.merge(attrs, %{
        status: @closed_status,
        reason_code: nil,
        failure_count: 0,
        closed_at: now,
        next_probe_at: nil
      })
    else
      attrs
    end
  end

  defp success_attrs(%RoutingCircuitState{} = state, _settings, now) do
    %{
      status: @closed_status,
      reason_code: nil,
      failure_count: 0,
      success_count: state.success_count + 1,
      closed_at: now,
      next_probe_at: nil,
      last_success_at: now,
      metadata: probe_metadata(state, 0),
      updated_at: now
    }
  end

  defp failure_attrs(auth, model, assignment, route_class, reason_code, state, settings, now) do
    failure_count = failure_count(state)
    open? = open_after_failure?(state, failure_count, settings)

    %{
      pool_id: auth.pool.id,
      api_key_id: nil,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: model.exposed_model_id,
      route_class: route_class,
      status: if(open?, do: @open_status, else: @closed_status),
      reason_code: reason_code,
      failure_count: failure_count,
      success_count: 0,
      opened_at: if(open?, do: now),
      half_opened_at: nil,
      closed_at: if(open?, do: nil, else: now),
      next_probe_at: if(open?, do: DateTime.add(now, settings.circuit_open_seconds, :second)),
      last_failure_at: now,
      metadata: probe_metadata(state, probe_count_after_failure(state)),
      updated_at: now
    }
  end

  defp failure_count(nil), do: 1
  defp failure_count(state), do: state.failure_count + 1

  defp probe_count_after_failure(nil), do: 0
  defp probe_count_after_failure(state), do: max(probe_in_flight_count(state) - 1, 0)

  defp probe_available?(state, settings, now) do
    probe_in_flight_count(state) < settings.circuit_half_open_probe_limit or
      probe_stale?(state, settings, now)
  end

  defp probe_stale?(
         %RoutingCircuitState{status: @half_open_status, updated_at: %DateTime{} = updated_at},
         settings,
         now
       ) do
    DateTime.diff(now, updated_at, :second) >= settings.circuit_open_seconds
  end

  defp probe_stale?(_state, _settings, _now), do: false

  defp open_after_failure?(state, failure_count, settings) do
    failure_count >= settings.circuit_failure_threshold or
      match?(%RoutingCircuitState{status: @half_open_status}, state)
  end

  defp latest(auth, model, assignment, route_class) do
    Repo.one(query(auth, model, assignment, route_class))
  end

  defp latest_by_assignment(_auth, _model, [], _route_class), do: %{}

  defp latest_by_assignment(auth, model, assignment_ids, route_class) do
    Repo.all(
      from state in RoutingCircuitState,
        where:
          state.pool_id == ^auth.pool.id and
            is_nil(state.api_key_id) and
            state.pool_upstream_assignment_id in ^assignment_ids and
            state.model_identifier == ^model.exposed_model_id and
            state.route_class == ^route_class,
        distinct: state.pool_upstream_assignment_id,
        order_by: [
          asc: state.pool_upstream_assignment_id,
          desc: state.updated_at,
          desc: state.created_at
        ]
    )
    |> Map.new(&{&1.pool_upstream_assignment_id, &1})
  end

  defp latest_for_update(auth, model, assignment, route_class) do
    auth
    |> query(model, assignment, route_class)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp query(auth, model, assignment, route_class) do
    from state in RoutingCircuitState,
      where:
        state.pool_id == ^auth.pool.id and
          is_nil(state.api_key_id) and
          state.pool_upstream_assignment_id == ^assignment.id and
          state.model_identifier == ^model.exposed_model_id and
          state.route_class == ^route_class,
      order_by: [desc: state.updated_at, desc: state.created_at],
      limit: 1
  end

  defp snapshot_for_state(%RoutingCircuitState{} = state, settings, now) do
    %{
      eligible?: eligible_state?(state, settings, now),
      requires_lock?: active_state?(state),
      status: state.status,
      state: state
    }
  end

  defp snapshot_for_state(_state, _settings, _now), do: default_snapshot()

  defp default_snapshot do
    %{eligible?: true, requires_lock?: false, status: nil, state: nil}
  end

  defp normalize_snapshot(%{eligible?: eligible?} = snapshot) when is_boolean(eligible?) do
    Map.merge(default_snapshot(), snapshot)
  end

  defp normalize_snapshot(value) when is_boolean(value) do
    %{default_snapshot() | eligible?: value, requires_lock?: not value}
  end

  defp normalize_snapshot(_snapshot), do: nil

  defp active_state?(%RoutingCircuitState{status: status}),
    do: status in [@open_status, @half_open_status]

  defp eligible_state?(
         %RoutingCircuitState{status: @open_status, next_probe_at: %DateTime{} = next_probe_at},
         _settings,
         now
       ) do
    DateTime.compare(next_probe_at, now) != :gt
  end

  defp eligible_state?(%RoutingCircuitState{status: @open_status}, _settings, _now), do: false

  defp eligible_state?(%RoutingCircuitState{status: @half_open_status} = state, settings, now),
    do: probe_available?(state, settings, now)

  defp eligible_state?(_state, _settings, _now), do: true

  defp probe_in_flight_count(%RoutingCircuitState{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @circuit_probe_in_flight_key) do
      value when is_integer(value) and value > 0 -> value
      _value -> 0
    end
  end

  defp probe_in_flight_count(_state), do: 0

  defp probe_metadata(%RoutingCircuitState{metadata: metadata}, count) when is_map(metadata) do
    Map.put(metadata, @circuit_probe_in_flight_key, max(count, 0))
  end

  defp probe_metadata(_state, count), do: %{@circuit_probe_in_flight_key => max(count, 0)}

  defp sanitize_reason_code(code) when is_binary(code), do: String.slice(code, 0, 80)
  defp sanitize_reason_code(code), do: code |> to_string() |> String.slice(0, 80)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp persist_or_rollback(changeset, :insert) do
    case Repo.insert(changeset) do
      {:ok, state} -> state
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_or_rollback(changeset, :update) do
    case Repo.update(changeset) do
      {:ok, state} -> state
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
