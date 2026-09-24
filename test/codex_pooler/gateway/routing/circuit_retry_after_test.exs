defmodule CodexPooler.Gateway.Routing.CircuitRetryAfterTest do
  # The retry advice of a retryable 503 with a circuit-blocked candidate
  # (findings#206 row 206-532): seconds until the earliest circuit admits a
  # probe, clamped to 1..60.
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.CircuitRetryAfter
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState

  @now ~U[2026-01-01 12:00:00.000000Z]
  @error %{status: 503, code: "quota_exhausted", message: "synthetic", param: "model"}

  test "an open circuit advises the seconds to its next probe, the earliest one when several are open" do
    route_state = route_state(%{"a" => open(25), "b" => open(10), "c" => eligible()})

    assert {:error, %{circuit_retry_after_seconds: 10}} = CircuitRetryAfter.put({:error, @error}, candidates(["a", "b", "c"]), route_state, @now)
  end

  test "the advice is clamped to one minute and to at least one second" do
    assert {:error, %{circuit_retry_after_seconds: 60}} = CircuitRetryAfter.put({:error, @error}, candidates(["a"]), route_state(%{"a" => open(600)}), @now)
    assert {:error, %{circuit_retry_after_seconds: 1}} = CircuitRetryAfter.put({:error, @error}, candidates(["a"]), route_state(%{"a" => open(-5)}), @now)
  end

  test "a half-open circuit whose probe slots are taken advises when that probe goes stale" do
    seconds = OperationalSettings.current().circuit_open_seconds
    half_open = %{eligible?: false, requires_lock?: true, status: "half_open", state: %RoutingCircuitState{status: "half_open", updated_at: DateTime.add(@now, 45 - seconds, :second)}}

    assert {:error, %{circuit_retry_after_seconds: 45}} = CircuitRetryAfter.put({:error, @error}, candidates(["a"]), route_state(%{"a" => half_open}), @now)
  end

  test "no blocked circuit with a known time, a non-retryable 503 and any other result get no advice" do
    no_time = %{eligible?: false, requires_lock?: true, status: "open", state: %RoutingCircuitState{status: "open", next_probe_at: nil}}

    assert {:error, @error} == CircuitRetryAfter.put({:error, @error}, candidates(["a"]), route_state(%{"a" => eligible()}), @now)
    assert {:error, @error} == CircuitRetryAfter.put({:error, @error}, candidates(["a"]), route_state(%{"a" => no_time}), @now)

    pinned = Map.put(@error, :retryable, false)
    assert {:error, pinned} == CircuitRetryAfter.put({:error, pinned}, candidates(["a"]), route_state(%{"a" => open(10)}), @now)

    usage_limit = %{@error | status: 429}
    assert {:error, usage_limit} == CircuitRetryAfter.put({:error, usage_limit}, candidates(["a"]), route_state(%{"a" => open(10)}), @now)
    assert {:ok, [], nil} == CircuitRetryAfter.put({:ok, [], nil}, candidates(["a"]), route_state(%{"a" => open(10)}), @now)
  end

  defp open(seconds), do: %{eligible?: false, requires_lock?: true, status: "open", state: %RoutingCircuitState{status: "open", next_probe_at: DateTime.add(@now, seconds, :second)}}
  defp eligible, do: %{eligible?: true, requires_lock?: false, status: nil, state: nil}
  defp candidates(ids), do: Enum.map(ids, &{%{id: &1}, %{id: "identity-" <> &1}})
  defp route_state(snapshots), do: %RouteState{visible_model: nil, circuit_snapshots: snapshots, circuit_eligibility_snapshots: snapshots}
end
