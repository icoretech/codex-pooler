defmodule CodexPooler.Gateway.Routing.RouteFiltering do
  @moduledoc false

  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.CandidateEligibility.UsageLimit
  alias CodexPooler.Gateway.Routing.CircuitRetryAfter
  alias CodexPooler.Gateway.Routing.QuotaRefresh.{Executor, Plan}
  alias CodexPooler.Gateway.Routing.SavedResetAutoRedeem
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
    request_options = filter_input.request_options
    quota_mode = Keyword.get(opts, :quota_mode, :required)

    filter_input
    |> filter_candidates(route_state, request_options, quota_mode, saved_reset_scan_at, saved_reset_opts)
    |> CircuitRetryAfter.put(filter_input.candidates, route_state)
  end

  # A retryable `503` of a Pool with an open-circuit candidate carries the
  # seconds until that circuit admits a probe (findings#206 row 206-532).
  defp filter_candidates(filter_input, route_state, request_options, quota_mode, saved_reset_scan_at, saved_reset_opts) do
    classified_candidates = filter_input.candidates

    with {:ok, candidates} <-
           CandidateEligibility.filter_circuit_eligible_candidates(filter_input, route_state),
         circuit_excluded? = length(candidates) < length(filter_input.candidates),
         route_state = RouteState.put_candidates(route_state, candidates),
         filter_input = CandidateEligibility.FilterInput.put_candidates(filter_input, candidates),
         {:ok, candidates, quota_decision, route_state} <-
           filter_input
           |> filter_quota_eligible_candidates(
             route_state,
             quota_mode,
             saved_reset_scan_at,
             saved_reset_opts
           )
           |> retryable_when_circuit_excluded(circuit_excluded?),
         {:ok, candidates} <-
           filter_input
           |> filter_account_denied_candidates(candidates, quota_decision, route_state, quota_mode)
           |> retryable_when_circuit_excluded(circuit_excluded?),
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
           CandidateEligibility.filter_circuit_eligible_candidates(filter_input, route_state),
         {:ok, candidates} <-
           CandidateEligibility.prefer_reasoning_effort_candidates(
             filter_input.model,
             request_options,
             candidates
           ) do
      kept_ids = MapSet.new(candidates, fn {assignment, _identity} -> assignment.id end)
      dropped = Enum.reject(classified_candidates, fn {assignment, _identity} -> MapSet.member?(kept_ids, assignment.id) end)

      route_state =
        route_state
        |> RouteState.put_candidates(candidates)
        |> RouteState.put_route_filter_dropped(dropped)

      {:ok, candidates, request_options, route_state}
    end
  end

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

  # A workspace-level provider denial removes the account for every model and
  # Pool (findings#206 row 206-509). It runs after the saved-reset decisions so
  # it can never change when an automatic redemption fires; routes that do not
  # require quota evidence (file selection) keep today's behaviour.
  defp filter_account_denied_candidates(filter_input, candidates, quota_decision, route_state, :required),
    do: CandidateEligibility.AccountDenial.filter_candidates(filter_input, candidates, quota_decision, route_state)

  defp filter_account_denied_candidates(_filter_input, candidates, _quota_decision, _route_state, _quota_mode),
    do: {:ok, candidates}

  # The terminal quota answer speaks for the whole Pool. A candidate the
  # circuit filter took out first is not quota-exhausted as far as routing
  # knows, and its circuit probes again after `circuit_open_seconds`, so the
  # refusal stays the retryable `503` (findings#206 row 206-508), for example
  # when one account's circuit opened after its quota `429`s while its
  # sibling was exhausted.
  defp retryable_when_circuit_excluded({:error, %{} = error}, true), do: {:error, UsageLimit.retryable(error)}
  defp retryable_when_circuit_excluded(result, _circuit_excluded?), do: result

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
