defmodule CodexPooler.Gateway.Routing.CandidateEligibility.PoolReturn do
  @moduledoc """
  When the rest of a Pool returns, seen from a provider usage-limit refusal on
  its last eligible candidate (findings#206 row 206-545).

  The refused account's own reset is not the Pool's: another candidate that
  routing excluded before dispatch, or that refused earlier in the same
  request, can return sooner. Every other candidate route filtering
  classified is classified again the way routing classifies it, against quota
  evidence read now, so a refusal an earlier attempt recorded counts. The
  answer follows routing's own rule (`UsageLimit.earliest_reset/2`, rows
  206-508 and 206-522): the soonest reset when every other candidate is
  exhausted with a known reset, and `:unknown` as soon as one of them has no
  known return (it is still quota-eligible, its evidence is stale or
  resetless, a saved-reset probe is pending). Nothing here redeems, refreshes
  or writes.
  """

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Routing.CandidateEligibility.{AccountDenial, Quota, UsageLimit}
  alias CodexPooler.Gateway.Routing.CircuitState
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState

  @type candidate :: {map(), map()}

  @doc """
  The earliest return of the candidates other than `refused_assignment_id`:
  `:none` when there are none, `{:ok, usage_limit}` when each of them is
  exhausted with a known reset, `:unknown` otherwise.
  """
  @spec others(Model.t(), [candidate()], Ecto.UUID.t(), DateTime.t()) :: :none | {:ok, UsageLimit.t()} | :unknown
  def others(%Model{} = model, candidates, refused_assignment_id, %DateTime{} = now) when is_list(candidates) do
    case Enum.reject(candidates, fn {assignment, _identity} -> assignment.id == refused_assignment_id end) do
      [] ->
        :none

      others ->
        route_state = %{visible_model: model, candidates: others} |> RouteState.new() |> RouteState.put_quota_snapshots(RouteState.load_quota_snapshots(others))
        exclusions = Enum.map(others, &exclusion(model, &1, route_state))

        if Enum.all?(exclusions, &is_map/1), do: UsageLimit.earliest_reset(exclusions, now), else: :unknown
    end
  end

  @doc """
  True when one of `candidates` can serve `model` now: neither quota nor a
  workspace denial excludes it against quota evidence read now, and its
  circuit for `route_class` admits a request (findings#206 row 206-586).
  """
  @spec any_routable?(map(), Model.t(), [candidate()], String.t()) :: boolean()
  def any_routable?(auth, %Model{} = model, candidates, route_class) when is_list(candidates) and is_binary(route_class) do
    route_state = %{visible_model: model, candidates: candidates} |> RouteState.new() |> RouteState.put_quota_snapshots(RouteState.load_quota_snapshots(candidates))
    circuits = CircuitState.eligibility_snapshots(auth, model, candidates, route_class)

    Enum.any?(candidates, fn {assignment, _identity} = candidate ->
      is_nil(exclusion(model, candidate, route_state)) and circuit_eligible?(Map.get(circuits, assignment.id))
    end)
  end

  def any_routable?(_auth, _model, _candidates, _route_class), do: false

  defp circuit_eligible?(%{eligible?: false}), do: false
  defp circuit_eligible?(_snapshot), do: true

  # Quota first, then the workspace denial, in routing's order; a candidate
  # neither excludes is routable and has no return time to advise.
  defp exclusion(model, candidate, route_state) do
    case Quota.candidate_exclusions(model, [candidate], route_state) do
      [exclusion] -> exclusion
      [] -> AccountDenial.candidate_exclusion(candidate, route_state)
    end
  end
end
