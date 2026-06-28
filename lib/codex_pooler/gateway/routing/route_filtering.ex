defmodule CodexPooler.Gateway.Routing.RouteFiltering do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.QuotaRefresh.{Executor, Plan}
  alias CodexPooler.Gateway.Routing.SavedResetAutoRedeem
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState

  @type candidate :: CandidateEligibility.FilterInput.candidate()
  @type gateway_error :: Contracts.gateway_error()
  @type quota_mode :: :required | :optional

  @spec filter_candidates(CandidateEligibility.FilterInput.t()) ::
          {:ok, [candidate()], RequestOptions.t()} | {:error, gateway_error()}
  @spec filter_candidates(CandidateEligibility.FilterInput.t(), keyword()) ::
          {:ok, [candidate()], RequestOptions.t()} | {:error, gateway_error()}
  def filter_candidates(filter_input, opts \\ [])

  def filter_candidates(%CandidateEligibility.FilterInput{} = filter_input, opts)
      when is_list(opts) do
    request_options = filter_input.request_options
    quota_mode = Keyword.get(opts, :quota_mode, :required)

    with {:ok, candidates, quota_decision} <-
           filter_quota_eligible_candidates(filter_input, quota_mode),
         request_options = put_quota_decision(request_options, quota_decision),
         filter_input =
           filter_input
           |> CandidateEligibility.FilterInput.put_candidates(candidates)
           |> CandidateEligibility.FilterInput.put_request_options(request_options),
         {:ok, candidates} <-
           CandidateEligibility.filter_circuit_eligible_candidates(filter_input) do
      {:ok, candidates, request_options}
    end
  end

  @spec filter_candidates_with_route_state(
          CandidateEligibility.FilterInput.t(),
          RouteState.t(),
          keyword()
        ) :: {:ok, [candidate()], RequestOptions.t(), RouteState.t()} | {:error, gateway_error()}
  @spec filter_candidates_with_route_state(CandidateEligibility.FilterInput.t(), RouteState.t()) ::
          {:ok, [candidate()], RequestOptions.t(), RouteState.t()} | {:error, gateway_error()}

  def filter_candidates_with_route_state(
        %CandidateEligibility.FilterInput{} = filter_input,
        %RouteState{} = route_state,
        opts \\ []
      )
      when is_list(opts) do
    request_options = filter_input.request_options
    quota_mode = Keyword.get(opts, :quota_mode, :required)

    with {:ok, candidates, quota_decision, route_state} <-
           filter_quota_eligible_candidates(filter_input, route_state, quota_mode),
         request_options = put_quota_decision(request_options, quota_decision),
         filter_input =
           filter_input
           |> CandidateEligibility.FilterInput.put_candidates(candidates)
           |> CandidateEligibility.FilterInput.put_request_options(request_options),
         route_state = RouteState.put_candidates(route_state, candidates),
         {:ok, candidates} <-
           CandidateEligibility.filter_circuit_eligible_candidates(filter_input, route_state) do
      {:ok, candidates, request_options, RouteState.put_candidates(route_state, candidates)}
    end
  end

  defp filter_quota_eligible_candidates(
         %CandidateEligibility.FilterInput{} = filter_input,
         quota_mode
       ) do
    case Plan.filter_eligible_candidates(filter_input) do
      {:refreshable_quota, refresh_plan} ->
        refreshed_result = Executor.refresh_stale_candidates(refresh_plan)

        refreshed_result
        |> SavedResetAutoRedeem.maybe_redeem_before_quota_exhaustion(refresh_plan, quota_mode)
        |> SavedResetAutoRedeem.maybe_redeem_after_quota_exhaustion(refresh_plan, quota_mode)
        |> maybe_allow_missing_quota(filter_input, quota_mode)

      {:ok, _candidates, _decision} = result ->
        result
        |> SavedResetAutoRedeem.maybe_redeem_before_quota_exhaustion(
          %{filter_input: filter_input},
          quota_mode
        )
        |> maybe_allow_missing_quota(filter_input, quota_mode)
    end
  end

  defp filter_quota_eligible_candidates(
         %CandidateEligibility.FilterInput{} = filter_input,
         %RouteState{} = route_state,
         quota_mode
       ) do
    case Plan.filter_eligible_candidates(filter_input, route_state) do
      {:refreshable_quota, refresh_plan} ->
        refreshed_result = Executor.refresh_stale_candidates(refresh_plan)

        refreshed_result
        |> SavedResetAutoRedeem.maybe_redeem_before_quota_exhaustion(refresh_plan, quota_mode)
        |> SavedResetAutoRedeem.maybe_redeem_after_quota_exhaustion(refresh_plan, quota_mode)
        |> maybe_allow_missing_quota(filter_input, quota_mode, route_state)

      {:ok, _candidates, _decision} = result ->
        result
        |> SavedResetAutoRedeem.maybe_redeem_before_quota_exhaustion(
          %{filter_input: filter_input, route_state: route_state},
          quota_mode
        )
        |> maybe_allow_missing_quota(filter_input, quota_mode, route_state)
    end
  end

  defp maybe_allow_missing_quota(
         {:error, %{code: code}},
         %CandidateEligibility.FilterInput{} = filter_input,
         :optional
       )
       when code in ["quota_evidence_unavailable", :quota_evidence_unavailable] do
    {:ok, filter_input.candidates, nil}
  end

  defp maybe_allow_missing_quota(result, _filter_input, _quota_mode), do: result

  defp maybe_allow_missing_quota(
         {:error, %{code: code}},
         %CandidateEligibility.FilterInput{} = filter_input,
         :optional,
         %RouteState{} = route_state
       )
       when code in ["quota_evidence_unavailable", :quota_evidence_unavailable] do
    {:ok, filter_input.candidates, nil, route_state}
  end

  defp maybe_allow_missing_quota(
         {:ok, candidates, quota_decision, %RouteState{} = route_state},
         _filter_input,
         _quota_mode,
         _route_state
       ) do
    {:ok, candidates, quota_decision, route_state}
  end

  defp maybe_allow_missing_quota(
         {:ok, candidates, quota_decision},
         _filter_input,
         _quota_mode,
         %RouteState{} = route_state
       ) do
    {:ok, candidates, quota_decision, route_state}
  end

  defp maybe_allow_missing_quota(result, _filter_input, _quota_mode, _route_state), do: result

  defp put_quota_decision(%RequestOptions{} = request_options, nil), do: request_options

  defp put_quota_decision(%RequestOptions{} = request_options, quota_decision),
    do: RequestOptions.put_routing(request_options, quota_decision: quota_decision)
end
