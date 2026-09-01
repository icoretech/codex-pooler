defmodule CodexPooler.Gateway.Routing.QuotaRefresh.Plan do
  @moduledoc """
  Synchronous quota refresh path used when routing finds refreshable stale evidence.
  """

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState

  @max_sync_quota_refresh_candidates 2

  @spec filter_eligible_candidates(CandidateEligibility.FilterInput.t()) ::
          CandidateEligibility.quota_filter_result()
  def filter_eligible_candidates(%CandidateEligibility.FilterInput{} = filter_input) do
    CandidateEligibility.filter_quota_eligible_candidates(filter_input)
  end

  @spec filter_eligible_candidates(CandidateEligibility.FilterInput.t(), RouteState.t()) ::
          CandidateEligibility.quota_filter_result()
  def filter_eligible_candidates(
        %CandidateEligibility.FilterInput{} = filter_input,
        %RouteState{} = route_state
      ) do
    CandidateEligibility.filter_quota_eligible_candidates(filter_input, route_state)
  end

  @type filter_after_refresh_result ::
          {:ok, [CandidateEligibility.candidate()], CandidateEligibility.quota_decision()}
          | {:ok, [CandidateEligibility.candidate()], CandidateEligibility.quota_decision(),
             RouteState.t()}
          | {:error, CandidateEligibility.gateway_error()}

  @spec refresh_candidates(CandidateEligibility.quota_refresh_plan()) ::
          [CandidateEligibility.candidate()]
  def refresh_candidates(%{
        filter_input: %CandidateEligibility.FilterInput{} = filter_input,
        refreshable_candidates: refreshable_candidates
      }) do
    refreshable_candidates
    |> prioritize_candidates(filter_input.request_options)
    |> Enum.take(@max_sync_quota_refresh_candidates)
  end

  @spec filter_after_refresh(CandidateEligibility.quota_refresh_plan()) ::
          filter_after_refresh_result()
  def filter_after_refresh(%{
        filter_input: %CandidateEligibility.FilterInput{} = filter_input,
        route_state: %RouteState{} = route_state,
        candidate_exclusions: exclusions,
        refreshable_candidates: refreshable_candidates
      }) do
    route_state = RouteState.refresh_quota_snapshots(route_state)

    case CandidateEligibility.filter_quota_eligible_candidates(filter_input, route_state) do
      {:ok, refreshed_candidates, decision} ->
        {:ok, refreshed_candidates, Map.put(decision, "refreshed_stale_quota", true), route_state}

      {:refreshable_quota, remaining_plan} ->
        CandidateEligibility.quota_unavailable_error(
          filter_input,
          terminal_exclusions(exclusions, remaining_plan, refreshable_candidates),
          refreshable_candidates != []
        )
    end
  end

  def filter_after_refresh(%{
        filter_input: %CandidateEligibility.FilterInput{} = filter_input,
        candidate_exclusions: exclusions,
        refreshable_candidates: refreshable_candidates
      }) do
    case CandidateEligibility.filter_quota_eligible_candidates(filter_input) do
      {:ok, refreshed_candidates, decision} ->
        {:ok, refreshed_candidates, Map.put(decision, "refreshed_stale_quota", true)}

      {:refreshable_quota, remaining_plan} ->
        CandidateEligibility.quota_unavailable_error(
          filter_input,
          terminal_exclusions(exclusions, remaining_plan, refreshable_candidates),
          refreshable_candidates != []
        )
    end
  end

  defp prioritize_candidates(
         candidates,
         %RequestOptions{continuity: %{codex_session: %CodexSession{} = session}}
       ) do
    Enum.sort_by(candidates, fn {assignment, _identity} ->
      if assignment.id == session.pool_upstream_assignment_id, do: 0, else: 1
    end)
  end

  defp prioritize_candidates(candidates, _request_options), do: candidates

  defp terminal_exclusions(_original, remaining_plan, [_candidate | _candidates]),
    do: remaining_plan.candidate_exclusions

  defp terminal_exclusions(original, _remaining_plan, []), do: original
end
