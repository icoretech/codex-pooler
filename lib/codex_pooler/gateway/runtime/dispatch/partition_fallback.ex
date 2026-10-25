defmodule CodexPooler.Gateway.Runtime.Dispatch.PartitionFallback do
  @moduledoc """
  The re-selection hops of a native turn whose selected canonical partition
  cannot serve it while a held-back partition might.

  Canonical partition selection narrows a native turn to the accounts that
  advertise the model with one source shape. Selection classifies every seat
  on the quota snapshot pre-dispatch read, while route filtering, which
  classifies only the selected partition's seats, also refreshes their stale
  reset-bearing evidence and makes the Pool's refusal. Two hops close that gap,
  and each happens at most once per turn: the fallback is spent on the route
  state it builds.

  - Before dispatch (`before_dispatch/3`): route filtering refused every seat
    of the selected partition on quota. The held-back candidates go through
    the same route filtering on a route state built for them; the turn
    proceeds there when it admits one, and otherwise the refusal names both
    partitions' exclusions, so the Pool's advice and its return time cover
    the whole Pool.
  - After a refusal (`available?/1`, `context/1`, findings#206 row 206-586):
    the selected partition's last candidate refused with a provider usage
    limit before any output while a held-back candidate can serve the model
    now. The held-back candidates go through ordinary route filtering (circuits,
    quota, workspace denials, the saved-reset decisions an ordinary request
    makes, none once the request recorded a redemption) with quota and circuit
    snapshots read now, and the turn is dispatched over the resulting plan
    with the same reservation.

  Translated surfaces route over every partition and record no fallback. A
  hard pin and a file affinity leave no held-back candidate, and a
  connection-bound compaction never takes either hop: it can only run on the
  upstream connection that holds its anchor.
  """

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.CandidateEligibility.PoolReturn
  alias CodexPooler.Gateway.Routing.CandidateEligibility.UsageLimit
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Gateway.Runtime.Dispatch.ContentFilterRetryPin
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy

  require Logger

  # The refusals of a selected partition whose every seat route filtering
  # excluded on quota evidence; a circuit, continuity or policy refusal is
  # not the Pool's capacity answer and keeps its own.
  @quota_refusal_codes ["quota_exhausted", "quota_evidence_unavailable"]
  @held_back "held_back"

  @type filter_result ::
          {:ok, [CandidateEligibility.candidate()], RequestOptions.t(), RouteState.t()}
          | {:error, map(), RequestOptions.t()}

  @doc """
  The answer for a native turn whose selected partition route filtering
  refused before reservation: the held-back partition's admitted candidates,
  or the refusal of the whole Pool, each with the request options whose
  `canonical_partition` summary records what happened (the caller records a
  refusal with them). Only a quota refusal takes the fallback; any other
  refusal, a turn with no held-back candidate and a connection-bound
  compaction keep the selected partition's refusal.
  """
  @spec before_dispatch(CandidateEligibility.FilterInput.t(), RouteState.t(), map()) :: filter_result()
  def before_dispatch(%CandidateEligibility.FilterInput{request_options: request_options} = input, %RouteState{} = route_state, %{code: code} = refusal) do
    fallback = RouteState.partition_fallback(route_state)

    cond do
      fallback == [] or RequestOptions.connection_bound_compaction?(request_options) ->
        {:error, refusal, request_options}

      code not in @quota_refusal_codes ->
        {:error, refusal, put_summary(request_options, %{"held_back_skip_reason" => "non_quota_refusal"})}

      true ->
        run_before_dispatch(input, route_state, refusal, fallback)
    end
  end

  def before_dispatch(%CandidateEligibility.FilterInput{request_options: request_options}, _route_state, refusal),
    do: {:error, refusal, request_options}

  defp run_before_dispatch(input, route_state, refusal, fallback) do
    held_back_state = RouteState.take_partition_fallback(route_state, input.auth, input.model, input.request_options)

    held_back_input =
      input
      |> CandidateEligibility.FilterInput.put_candidates(held_back_state.candidates)
      |> CandidateEligibility.FilterInput.put_request_options(record_recovery_outcome(input.request_options, refusal))

    case RouteFiltering.filter_candidates_with_route_state(held_back_input, held_back_state) do
      {:ok, candidates, request_options, state} ->
        log_before_dispatch(input.request_options, refusal, fallback, "admitted", length(candidates), nil)
        {:ok, candidates, put_summary(request_options, %{"held_back_fallback" => "pre_dispatch", "held_back_fallback_outcome" => "admitted"}), state}

      {:error, held_back_refusal} ->
        log_before_dispatch(input.request_options, refusal, fallback, "pool_refusal", 0, held_back_refusal)
        request_options = put_summary(input.request_options, %{"held_back_fallback" => "pre_dispatch", "held_back_fallback_outcome" => "pool_refusal"})
        {:error, pool_refusal(input, refusal, held_back_refusal), request_options}
    end
  end

  # The selected partition can refuse after its filtering redeemed a reset (or
  # met one still converging on its seat). The held-back filtering then starts
  # with that recovery recorded, so it runs no saved-reset scan of its own and
  # the request spends at most one reset (findings#331). The redemption's
  # locked cohort fence refuses that second consume too, since the cohort
  # holds both partitions.
  defp record_recovery_outcome(%RequestOptions{} = request_options, %{non_credit_recovery_outcome: outcome}) when outcome in ["pending", "confirmed"],
    do: RequestOptions.put_routing(request_options, quota_decision: Map.put(request_options.routing.quota_decision || %{}, "non_credit_recovery_outcome", outcome))

  defp record_recovery_outcome(request_options, _refusal), do: request_options

  # One bounded, metadata-only line per pre-dispatch fallback: the phase, the
  # outcome, fixed refusal codes and counts. The request correlator comes from
  # the Logger metadata; no assignment, identity or Pool id is written.
  defp log_before_dispatch(%RequestOptions{} = request_options, refusal, fallback, outcome, admitted_count, held_back_refusal) do
    summary = request_options.routing.canonical_partition || %{}

    Logger.info(fn ->
      "canonical partition fallback phase=pre_dispatch outcome=#{outcome} " <>
        "selected_refusal=#{refusal_code(refusal)} held_back_refusal=#{refusal_code(held_back_refusal)} " <>
        "partition_count=#{count(summary, "partition_count")} selected_count=#{count(summary, "selected_count")} " <>
        "selected_routable_count=#{count(summary, "selected_routable_count")} held_back_count=#{length(fallback)} " <>
        "held_back_routable_count=#{count(summary, "held_back_routable_count")} admitted_count=#{admitted_count}"
    end)
  end

  defp refusal_code(%{code: code}) when is_atom(code) or is_binary(code), do: DiagnosticTaxonomy.identifier(to_string(code)) || "unknown"
  defp refusal_code(_refusal), do: "none"

  defp count(summary, key) do
    case Map.get(summary, key) do
      value when is_integer(value) and value >= 0 -> value
      _absent -> "unknown"
    end
  end

  @doc """
  True when the selected candidate's refusal may take the hop: a held-back
  candidate can serve the model now, the fallback is not spent, and the turn
  is neither a client-retry resend, a guided content-filter retry bound to its
  account (`ContentFilterRetryPin`) nor connection-bound compaction. The
  caller decides that the refusal is a pre-output provider usage limit.
  """
  @spec available?(SelectedCandidateContext.t()) :: boolean()
  def available?(%SelectedCandidateContext{} = context) do
    fallback = RouteState.partition_fallback(context.route_state)

    fallback != [] and is_nil(context.client_retry_dispatch_authority) and
      not ContentFilterRetryPin.bound?(context.reserved.request) and
      not RequestOptions.connection_bound_compaction?(context.request_options) and
      PoolReturn.any_routable?(context.auth, context.model, fallback, context.request_options)
  end

  @doc """
  The dispatch context over the held-back candidates, or the refusal route
  filtering gave them, with the request finalized on it.
  """
  @spec context(Context.t()) :: {:ok, Context.t()} | {:error, map()}
  def context(%Context{} = context) do
    route_state = RouteState.take_partition_fallback(context.route_state, context.auth, context.model, context.request_options)

    filter_input =
      CandidateEligibility.FilterInput.new(%{
        auth: context.auth,
        model: context.model,
        endpoint: context.endpoint,
        payload: context.payload,
        request_options: context.request_options,
        candidates: route_state.candidates
      })

    case RouteFiltering.filter_candidates_with_route_state(filter_input, route_state) do
      {:ok, candidates, request_options, route_state} ->
        Context.new(%{
          auth: context.auth,
          endpoint: context.endpoint,
          payload: context.payload,
          prepared_native_payloads: context.prepared_native_payloads,
          model: context.model,
          reserved: context.reserved,
          candidates: candidates,
          request_options: put_summary(request_options, %{"held_back_fallback" => "after_refusal"}),
          route_state: route_state
        })

      {:error, %{status: status, code: code} = error} ->
        finalize_refusal(context, error, status, code)
    end
  end

  # Both partitions refused. A held-back seat refused on quota adds its
  # exclusions, marked `partition: held_back`, and the Pool's refusal is
  # rebuilt over all of them by the rule the selected partition's refusal
  # applies (`UsageLimit.earliest_reset/2`): the earliest reset of the whole
  # Pool, or the retryable 503 when one seat has no known return. A held-back
  # seat refused for any other reason (an open circuit) has no known return
  # either.
  defp pool_refusal(input, refusal, %{candidate_exclusions: [_ | _] = held_back} = held_back_refusal) do
    exclusions = Map.get(refusal, :candidate_exclusions, []) ++ Enum.map(held_back, &Map.put(&1, :partition, @held_back))
    refresh_attempted? = Map.get(refusal, :quota_refresh_attempted, false) or Map.get(held_back_refusal, :quota_refresh_attempted, false)

    {:error, pool_refusal} = CandidateEligibility.quota_unavailable_error(input, exclusions, refresh_attempted?)
    keep_circuit_retry_after(pool_refusal, held_back_refusal)
  end

  defp pool_refusal(_input, refusal, held_back_refusal), do: refusal |> UsageLimit.retryable() |> keep_circuit_retry_after(held_back_refusal)

  # A retryable Pool refusal whose held-back seat an open circuit took out
  # keeps that circuit's `Retry-After` (findings#206 row 206-532).
  defp keep_circuit_retry_after(%{status: 503} = refusal, %{circuit_retry_after_seconds: seconds}) when is_integer(seconds) and seconds > 0,
    do: Map.put_new(refusal, :circuit_retry_after_seconds, seconds)

  defp keep_circuit_retry_after(refusal, _held_back_refusal), do: refusal

  # Bounded markers on the summary every row of a capped surface records:
  # `held_back_fallback` (`pre_dispatch`, `after_refusal`), its
  # `held_back_fallback_outcome` (`admitted`, `pool_refusal`) and
  # `held_back_skip_reason`. A surface without a summary records none.
  defp put_summary(%RequestOptions{routing: %{canonical_partition: %{} = summary}} = request_options, fields),
    do: RequestOptions.put_routing(request_options, canonical_partition: Map.merge(summary, fields))

  defp put_summary(%RequestOptions{} = request_options, _fields), do: request_options

  # The held-back candidates stopped being routable between the refusal's
  # check and this filtering: the request ends on that refusal, after the
  # selected candidate's attempt, which the release carries (findings#321).
  defp finalize_refusal(context, error, status, code) do
    case AttemptSettlement.finalize_routing_refusal(context.reserved.request, %{
           response_status_code: status,
           last_error_code: to_string(code)
         }) do
      {:ok, _finalized} -> {:error, Map.delete(error, :accounting_disposition)}
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end
end
