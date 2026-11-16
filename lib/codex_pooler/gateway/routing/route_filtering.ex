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
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot

  @type candidate :: CandidateEligibility.FilterInput.candidate()
  @type gateway_error :: Contracts.gateway_error()
  @type quota_mode :: :required | :optional
  @type refilter_clock :: (-> DateTime.t())
  @type filter_option ::
          {:quota_mode, quota_mode()}
          | {:saved_reset_scan_at, DateTime.t()}
          | {:saved_reset_refilter_clock, refilter_clock()}
  @type filter_options :: [filter_option()]

  # A request spends at most one banked reset (findings#331). Once its routing
  # options record a pending or confirmed recovery (a reset it redeemed, or one
  # still converging on a candidate), every later filtering of the request (the
  # retry over the remaining candidates, either held-back partition hop) runs
  # neither saved-reset scan and keeps that outcome. The redemption's locked
  # cohort fence refuses the same consume while the cohort holds the redeemed
  # account, but the retry narrows the cohort to the candidates it has left.
  @recorded_recovery_outcomes ["pending", "confirmed"]

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
    |> filter_uncapped_candidates(route_state, request_options, quota_mode, saved_reset_scan_at, saved_reset_opts)
    |> SavedResetAutoRedeem.clear_post_apply_failure()
    |> CircuitRetryAfter.put(filter_input.candidates, route_state)
  end

  # An account at its operator usage cap (public issue #637) leaves the
  # request first, before circuits, quota eligibility and both saved-reset
  # scans, like a paused account: it neither counts as a sibling's capacity
  # nor becomes a redemption target. Its exclusion stays recorded, it stays in
  # the dropped set Pool-return advice reads, and its window's reset joins a
  # `quota_exhausted` refusal of the candidates that were left.
  defp filter_uncapped_candidates(filter_input, route_state, request_options, quota_mode, saved_reset_scan_at, saved_reset_opts) do
    case CandidateEligibility.UsageCap.exclude_capped(filter_input, route_state, quota_mode) do
      {:ok, uncapped_input, uncapped_state, capped_exclusions} ->
        uncapped_input
        |> filter_candidates(uncapped_state, request_options, quota_mode, saved_reset_scan_at, saved_reset_opts, filter_input.candidates)
        |> CandidateEligibility.UsageCap.merge_capped_returns(capped_exclusions)

      {:error, _refusal} = refused ->
        refused
    end
  end

  # A retryable `503` of a Pool with an open-circuit candidate carries the
  # seconds until that circuit admits a probe (findings#206 row 206-532).
  defp filter_candidates(filter_input, route_state, request_options, quota_mode, saved_reset_scan_at, saved_reset_opts, classified_candidates) do
    route_state =
      route_state
      |> RouteState.clear_filter_exclusions()
      |> RouteState.record_filter_exclusions(classified_candidates, filter_input.candidates, "usage_capped")

    with {:ok, candidates} <-
           CandidateEligibility.filter_circuit_eligible_candidates(filter_input, route_state),
         circuit_excluded? = length(candidates) < length(filter_input.candidates),
         route_state = RouteState.record_filter_exclusions(route_state, filter_input.candidates, candidates, "circuit_unavailable"),
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
         {quota_exclusions, quota_decision} = pop_quota_exclusions(quota_decision),
         route_state = RouteState.record_filter_exclusions(route_state, filter_input.candidates, candidates, "quota_unavailable", quota_exclusions),
         quota_candidates = candidates,
         {:ok, candidates} <-
           filter_input
           |> filter_account_denied_candidates(candidates, quota_decision, route_state, quota_mode)
           |> retryable_when_circuit_excluded(circuit_excluded?),
         route_state = RouteState.record_filter_exclusions(route_state, quota_candidates, candidates, "account_denied"),
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
         route_state = RouteState.record_filter_exclusions(route_state, filter_input.candidates, candidates, "circuit_unavailable"),
         circuit_candidates = candidates,
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
        |> RouteState.record_filter_exclusions(circuit_candidates, candidates, "reasoning_effort_preferred")
        |> RouteState.put_candidates(candidates)
        |> RouteState.put_route_filter_dropped(dropped)

      {:ok, candidates, request_options, route_state}
    end
  end

  defp pop_quota_exclusions(nil), do: {%{}, nil}
  defp pop_quota_exclusions(decision), do: Map.pop(decision, :route_filter_exclusions, %{})

  defp filter_quota_eligible_candidates(
         %CandidateEligibility.FilterInput{} = filter_input,
         %RouteState{} = route_state,
         quota_mode,
         saved_reset_scan_at,
         saved_reset_opts
       ) do
    {result, route_state, refresh_attempted?} = refresh_non_credit_candidates(filter_input, route_state)
    recovery_plan = %{filter_input: filter_input, route_state: route_state, capacity_band: :non_credit}
    {result, recorded, recovery_plan} = threshold_recovery(result, recovery_plan, quota_mode, saved_reset_scan_at, saved_reset_opts)

    filtered =
      if SavedResetAutoRedeem.post_apply_failure?(result) do
        result
      else
        case result do
          {:error, _error} -> recover_or_defer_capacity(result, recovery_plan, quota_mode, saved_reset_scan_at, saved_reset_opts, refresh_attempted?, recorded)
          admitted -> admit_servable_capacity(admitted, filter_input, quota_mode, route_state, refresh_attempted?)
        end
      end

    keep_recorded_recovery_outcome(filtered, recorded)
  end

  # The threshold scan runs only while the request records no recovery; a
  # redemption it applies is recorded for the rest of the request. A refusal
  # after that redemption is then judged on quota reread now: on the reading
  # from before the redemption, the redeemed account looked routable and was
  # admitted, and the final admission refused its pending reset at send time,
  # leaving an attempt that sent nothing (findings#331).
  defp threshold_recovery(result, %{filter_input: input, route_state: state} = recovery_plan, quota_mode, scan_at, opts) do
    case recorded_recovery_outcome(input.request_options) do
      nil ->
        scanned = SavedResetAutoRedeem.maybe_redeem_before_quota_exhaustion(result, recovery_plan, quota_mode, scan_at, opts)

        case applied_recovery_outcome(scanned) do
          nil -> {scanned, nil, recovery_plan}
          applied -> refresh_after_threshold_recovery(scanned, applied, state, recovery_plan)
        end

      recorded ->
        {result, recorded, recovery_plan}
    end
  end

  defp refresh_after_threshold_recovery(scanned, applied, state, recovery_plan) do
    if SavedResetAutoRedeem.post_apply_failure?(scanned) do
      {scanned, applied, recovery_plan}
    else
      {scanned, applied, %{recovery_plan | route_state: RouteState.refresh_quota_snapshots(state)}}
    end
  rescue
    exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error, RoutingQuotaSnapshot.LoadError] ->
      failure = SavedResetAutoRedeem.post_apply_failure_result(scanned, SavedResetAutoRedeem.recovery_outcome(scanned), exception, __STACKTRACE__)
      {failure, applied, recovery_plan}
  end

  defp admit_servable_capacity(admitted, input, quota_mode, state, refresh_attempted?) do
    {:ok, candidates, decision, selected_state} = maybe_allow_missing_quota(admitted, input, quota_mode, state)

    case filter_account_denied_candidates(input, candidates, decision, selected_state, quota_mode) do
      {:ok, servable} -> {:ok, servable, decision, RouteState.record_filter_exclusions(selected_state, candidates, servable, "account_denied")}
      {:error, _} = denied -> deferred_capacity(denied, input, selected_state, quota_mode, refresh_attempted?)
    end
  end

  defp refresh_non_credit_candidates(filter_input, route_state) do
    case Plan.filter_non_credit_candidates(filter_input, route_state) do
      {:ok, _candidates, _decision} = result ->
        {result, route_state, false}

      {:refreshable_quota, refresh_plan} ->
        if refresh_plan.refreshable_candidates == [] do
          {CandidateEligibility.quota_unavailable_error(filter_input, refresh_plan.candidate_exclusions, false), route_state, false}
        else
          result = Executor.refresh_stale_candidates(refresh_plan)
          {result, RouteState.refresh_quota_snapshots(route_state), true}
        end
    end
  end

  defp recover_or_defer_capacity(result, recovery_plan, quota_mode, scan_at, opts, refresh_attempted?, recorded) do
    %{filter_input: input, route_state: state} = recovery_plan

    case Plan.filter_eligible_candidates(input, state) do
      {:ok, candidates, decision} ->
        {:ok, candidates, decision, state}

      {:refreshable_quota, _plan} ->
        recover_unavailable_capacity(result, recovery_plan, quota_mode, scan_at, opts, refresh_attempted?, recorded)
    end
  end

  defp recover_unavailable_capacity(result, recovery_plan, quota_mode, scan_at, opts, refresh_attempted?, recorded) do
    %{filter_input: input, route_state: state} = recovery_plan
    recovered = blocked_recovery(result, recovery_plan, quota_mode, scan_at, opts, recorded)

    case recovered do
      {:error, _error} -> deferred_capacity(recovered, input, state, quota_mode, refresh_attempted?)
      admitted -> maybe_allow_missing_quota(admitted, input, quota_mode, state)
    end
  end

  # The blocked scan runs only while the request records no recovery, a
  # redemption the threshold scan applied in this filtering included.
  defp blocked_recovery(result, %{filter_input: input, route_state: state} = recovery_plan, quota_mode, scan_at, opts, nil) do
    recovery = %{candidate_exclusions: non_credit_exclusions(input, state), result: result}
    SavedResetAutoRedeem.recover_non_credit_exhaustion(recovery, recovery_plan, quota_mode, scan_at, opts)
  end

  defp blocked_recovery(result, _recovery_plan, _quota_mode, _scan_at, _opts, recorded), do: keep_recorded_recovery_outcome(result, recorded)

  defp non_credit_exclusions(input, state) do
    case Plan.filter_non_credit_candidates(input, state) do
      {:refreshable_quota, plan} -> plan.candidate_exclusions
      {:ok, _candidates, _decision} -> []
    end
  end

  defp deferred_capacity({:error, %{saved_reset_post_apply_failure: true}} = failure, _input, _state, _quota_mode, _refresh_attempted?), do: failure

  defp deferred_capacity(recovered, input, state, quota_mode, refresh_attempted?) do
    outcome = SavedResetAutoRedeem.recovery_outcome(recovered)
    deferred_capacity_with_outcome(recovered, input, state, quota_mode, refresh_attempted?, outcome)
  end

  defp deferred_capacity_with_outcome(recovered, input, state, quota_mode, refresh_attempted?, outcome) do
    refreshed_state = if outcome in [:failed, :not_applied, :pending, :confirmed], do: RouteState.refresh_quota_snapshots(state), else: state

    case Plan.filter_eligible_candidates(input, refreshed_state) do
      {:ok, candidates, decision} ->
        {:ok, candidates, Map.put(decision, "non_credit_recovery_outcome", Atom.to_string(outcome)), refreshed_state}

      {:refreshable_quota, plan} ->
        CandidateEligibility.quota_unavailable_error(input, plan.candidate_exclusions, refresh_attempted?)
        |> put_recovery_outcome(outcome)
        |> maybe_allow_missing_quota(input, quota_mode, refreshed_state)
    end
  rescue
    exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error, RoutingQuotaSnapshot.LoadError] ->
      if outcome in [:pending, :confirmed] do
        SavedResetAutoRedeem.post_apply_failure_result(recovered, outcome, exception, __STACKTRACE__)
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp put_recovery_outcome({:error, error}, outcome), do: {:error, Map.put(error, :non_credit_recovery_outcome, Atom.to_string(outcome))}

  defp recorded_recovery_outcome(%RequestOptions{routing: %{quota_decision: %{"non_credit_recovery_outcome" => outcome}}})
       when outcome in @recorded_recovery_outcomes,
       do: outcome

  defp recorded_recovery_outcome(_request_options), do: nil

  defp applied_recovery_outcome(result) do
    case SavedResetAutoRedeem.recovery_outcome(result) do
      outcome when outcome in [:pending, :confirmed] -> Atom.to_string(outcome)
      _not_applied -> nil
    end
  end

  # The recorded outcome stays on the decision and the refusal of every later
  # filtering of the request, so each one skips the scans too and the request
  # keeps the record of the reset it redeemed. Such a refusal stays the
  # retryable `503`: the redeemed account's return is not known (a pending
  # probe has none), and a retry that left it out of its candidates cannot see
  # it (`UsageLimit`).
  defp keep_recorded_recovery_outcome(result, nil), do: result

  defp keep_recorded_recovery_outcome({:ok, candidates, decision, route_state}, recorded) when is_map(decision),
    do: {:ok, candidates, Map.put(decision, "non_credit_recovery_outcome", recorded), route_state}

  defp keep_recorded_recovery_outcome({:error, %{} = error}, recorded),
    do: {:error, error |> Map.put(:non_credit_recovery_outcome, recorded) |> UsageLimit.retryable()}

  defp keep_recorded_recovery_outcome(result, _recorded), do: result

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
