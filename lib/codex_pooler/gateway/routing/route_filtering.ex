defmodule CodexPooler.Gateway.Routing.RouteFiltering do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.QuotaRefresh.{Executor, Plan}
  alias CodexPooler.Gateway.Routing.SavedResetAutoRedeem
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState

  @type candidate :: CandidateEligibility.FilterInput.candidate()
  @type gateway_error :: Contracts.gateway_error()
  @type quota_mode :: :required | :optional
  @type refilter_clock :: (-> DateTime.t())
  @type filter_option ::
          {:quota_mode, quota_mode()}
          | {:saved_reset_scan_at, DateTime.t()}
          | {:saved_reset_refilter_clock, refilter_clock()}
  @type filter_options :: [filter_option()]

  @spec filter_candidates_with_route_state(
          CandidateEligibility.FilterInput.t(),
          RouteState.t(),
          filter_options()
        ) :: {:ok, [candidate()], RequestOptions.t(), RouteState.t()} | {:error, gateway_error()}
  @spec filter_candidates_with_route_state(CandidateEligibility.FilterInput.t(), RouteState.t()) ::
          {:ok, [candidate()], RequestOptions.t(), RouteState.t()} | {:error, gateway_error()}

  def filter_candidates_with_route_state(
        %CandidateEligibility.FilterInput{} = filter_input,
        %RouteState{} = route_state,
        opts \\ []
      )
      when is_list(opts) do
    saved_reset_scan_at = saved_reset_scan_timestamp(opts)
    saved_reset_opts = saved_reset_options(opts)
    quota_mode = Keyword.get(opts, :quota_mode, :required)

    case filter_partition(
           filter_input,
           route_state,
           quota_mode,
           saved_reset_scan_at,
           saved_reset_opts
         ) do
      {:ok, _candidates, _request_options, _route_state} = result ->
        result

      {:error, _reason} = primary_error ->
        maybe_filter_fallback_partitions(
          primary_error,
          filter_input,
          route_state,
          quota_mode,
          saved_reset_scan_at,
          saved_reset_opts
        )
    end
  end

  defp filter_partition(
         %CandidateEligibility.FilterInput{} = filter_input,
         %RouteState{} = route_state,
         quota_mode,
         saved_reset_scan_at,
         saved_reset_opts
       ) do
    request_options = filter_input.request_options

    with {:ok, candidates} <-
           CandidateEligibility.filter_circuit_eligible_candidates(filter_input, route_state),
         route_state = RouteState.put_candidates(route_state, candidates),
         filter_input = CandidateEligibility.FilterInput.put_candidates(filter_input, candidates),
         {:ok, candidates, quota_decision, route_state} <-
           filter_quota_eligible_candidates(
             filter_input,
             route_state,
             quota_mode,
             saved_reset_scan_at,
             saved_reset_opts
           ),
         request_options =
           request_options
           |> put_reset_probe(route_state.reset_probe)
           |> put_quota_decision(quota_decision),
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

  defp maybe_filter_fallback_partitions(
         {:error, %{code: code}} = primary_error,
         %CandidateEligibility.FilterInput{} = filter_input,
         %RouteState{fallback_candidate_partitions: fallback_partitions} = route_state,
         quota_mode,
         saved_reset_scan_at,
         saved_reset_opts
       )
       when code in [
              "no_eligible_backend",
              :no_eligible_backend,
              "quota_exhausted",
              :quota_exhausted,
              "quota_evidence_unavailable",
              :quota_evidence_unavailable
            ] and fallback_partitions != [] do
    if SessionContinuity.hard_pin_metadata(
         filter_input.request_options,
         filter_input.model
       ) == nil do
      Enum.reduce_while(fallback_partitions, primary_error, fn candidates, _last_error ->
        fallback_filter_input =
          CandidateEligibility.FilterInput.put_candidates(filter_input, candidates)

        fallback_route_state = RouteState.put_candidates(route_state, candidates)

        case filter_partition(
               fallback_filter_input,
               fallback_route_state,
               quota_mode,
               saved_reset_scan_at,
               saved_reset_opts
             ) do
          {:ok, _candidates, _request_options, _route_state} = result -> {:halt, result}
          {:error, _reason} = error -> {:cont, error}
        end
      end)
    else
      primary_error
    end
  end

  defp maybe_filter_fallback_partitions(
         primary_error,
         %CandidateEligibility.FilterInput{},
         %RouteState{},
         _quota_mode,
         _saved_reset_scan_at,
         _saved_reset_opts
       ),
       do: primary_error

  defp filter_quota_eligible_candidates(
         %CandidateEligibility.FilterInput{} = filter_input,
         %RouteState{} = route_state,
         quota_mode,
         saved_reset_scan_at,
         saved_reset_opts
       ) do
    case Plan.filter_eligible_candidates(filter_input, route_state) do
      {:refreshable_quota, refresh_plan} ->
        refreshed_result = Executor.refresh_stale_candidates(refresh_plan)

        refreshed_result
        |> SavedResetAutoRedeem.maybe_redeem_before_quota_exhaustion(
          refresh_plan,
          quota_mode,
          saved_reset_scan_at,
          saved_reset_opts
        )
        |> SavedResetAutoRedeem.maybe_redeem_after_quota_exhaustion(
          refresh_plan,
          quota_mode,
          saved_reset_scan_at,
          saved_reset_opts
        )
        |> maybe_allow_missing_quota(filter_input, quota_mode, route_state)

      {:ok, _candidates, _decision} = result ->
        result
        |> SavedResetAutoRedeem.maybe_redeem_before_quota_exhaustion(
          %{filter_input: filter_input, route_state: route_state},
          quota_mode,
          saved_reset_scan_at,
          saved_reset_opts
        )
        |> maybe_allow_missing_quota(filter_input, quota_mode, route_state)
    end
  end

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

  defp put_reset_probe(%RequestOptions{} = request_options, nil), do: request_options

  defp put_reset_probe(%RequestOptions{} = request_options, reset_probe),
    do: RequestOptions.put_routing(request_options, reset_probe: reset_probe)

  defp saved_reset_scan_timestamp(opts) do
    opts
    |> Keyword.get_lazy(:saved_reset_scan_at, &now/0)
    |> DateTime.truncate(:microsecond)
  end

  defp saved_reset_options(opts) do
    case Keyword.fetch(opts, :saved_reset_refilter_clock) do
      {:ok, clock} -> [refilter_clock: clock]
      :error -> []
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
