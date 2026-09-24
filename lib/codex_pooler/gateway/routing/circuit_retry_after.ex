defmodule CodexPooler.Gateway.Routing.CircuitRetryAfter do
  @moduledoc """
  Retry advice for the retryable `503` of a Pool with an open-circuit candidate
  (findings#206 row 206-532).

  A candidate the circuit filter took out comes back when its circuit admits a
  probe: an open circuit at its `next_probe_at`, a half-open circuit whose
  probe slots are taken when that probe goes stale (`circuit_open_seconds`
  after its last update) at the latest. The refusal carries the seconds until
  the earliest of those moments, clamped to 1..60, as `Retry-After`, so a
  client backs off for the real bound instead of its own ladder. The state is
  retryable, so no `x-should-retry: false` goes with it, and a refusal marked
  `retryable: false` gets no advice.
  """

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.CircuitState
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState

  @open_status "open"
  @half_open_status "half_open"
  @min_seconds 1
  @max_seconds 60

  @doc """
  Adds `circuit_retry_after_seconds` to a retryable `503` refusal when a
  candidate among `candidates` is circuit-blocked in `route_state` with a
  known unblock time; every other result passes through.
  """
  @spec put(term(), [{map(), map()}], RouteState.t(), DateTime.t()) :: term()
  def put(result, candidates, route_state, now \\ DateTime.utc_now())

  def put({:error, %{status: 503} = error}, candidates, %RouteState{} = route_state, %DateTime{} = now) when is_list(candidates) do
    with true <- Map.get(error, :retryable) != false,
         seconds when is_integer(seconds) <- seconds(candidates, route_state, now) do
      {:error, Map.put(error, :circuit_retry_after_seconds, seconds)}
    else
      _no_advice -> {:error, error}
    end
  end

  def put(result, _candidates, _route_state, _now), do: result

  @doc """
  The same advice for a refusal raised after route filtering, when a circuit
  refused a candidate the filter had admitted (findings#206 row 206-548): the
  circuit states of `candidates` are read now rather than from the filter's
  snapshot.
  """
  @spec put_current(term(), map(), Model.t(), [{map(), map()}], String.t()) :: term()
  def put_current({:error, %{status: 503}} = result, auth, %Model{} = model, candidates, route_class) when is_list(candidates) and is_binary(route_class) do
    snapshots = CircuitState.eligibility_snapshots(auth, model, candidates, route_class)
    route_state = RouteState.put_circuit_snapshots(RouteState.new(%{visible_model: model, candidates: candidates}), snapshots)
    put(result, candidates, route_state)
  end

  def put_current(result, _auth, _model, _candidates, _route_class), do: result

  @doc """
  The seconds until the earliest circuit-blocked candidate among `candidates`
  admits a probe, read now and clamped to 1..60, or `nil` when none is blocked
  with a known time.
  """
  @spec current_seconds(map(), Model.t(), [{map(), map()}], String.t()) :: pos_integer() | nil
  def current_seconds(auth, %Model{} = model, candidates, route_class) when is_list(candidates) and is_binary(route_class) do
    snapshots = CircuitState.eligibility_snapshots(auth, model, candidates, route_class)
    route_state = RouteState.put_circuit_snapshots(RouteState.new(%{visible_model: model, candidates: candidates}), snapshots)
    seconds(candidates, route_state, DateTime.utc_now())
  end

  defp seconds(candidates, route_state, now) do
    settings = OperationalSettings.current()

    candidates
    |> Enum.flat_map(fn {assignment, _identity} -> unblock_at(RouteState.circuit_snapshot(route_state, assignment.id), settings) end)
    |> Enum.min(DateTime, fn -> nil end)
    |> case do
      nil -> nil
      unblock_at -> unblock_at |> DateTime.diff(now, :millisecond) |> ceil_seconds() |> max(@min_seconds) |> min(@max_seconds)
    end
  end

  defp unblock_at(%{eligible?: false, state: %RoutingCircuitState{status: @open_status, next_probe_at: %DateTime{} = next_probe_at}}, _settings),
    do: [next_probe_at]

  defp unblock_at(%{eligible?: false, state: %RoutingCircuitState{status: @half_open_status, updated_at: %DateTime{} = updated_at}}, settings),
    do: [DateTime.add(updated_at, settings.circuit_open_seconds, :second)]

  defp unblock_at(_snapshot, _settings), do: []

  defp ceil_seconds(millis), do: div(millis + 999, 1_000)
end
