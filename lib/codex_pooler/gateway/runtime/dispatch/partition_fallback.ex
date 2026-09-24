defmodule CodexPooler.Gateway.Runtime.Dispatch.PartitionFallback do
  @moduledoc """
  The one re-selection hop of a native turn whose selected canonical partition
  ran out on a provider usage limit (findings#206 row 206-586).

  Canonical partition selection narrows a native turn to the accounts that
  advertise the model with one source shape. When the selected partition's
  last candidate refuses with a provider usage limit before any output, and a
  held-back candidate can serve the model now, the next request's quota-aware
  partition selection would pick that other partition; this hop gives the same
  turn that answer instead of a terminal usage limit. The held-back candidates
  go through ordinary route filtering (circuits, quota, workspace denials, the
  saved-reset decisions an ordinary request makes) with quota and circuit
  snapshots read now, and the turn is dispatched over the resulting plan with
  the same reservation. The hop happens at most once: the fallback is spent on
  the route state it builds.
  """

  alias CodexPooler.Accounting.PreAttemptRelease
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.CandidateEligibility.PoolReturn
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement

  @doc """
  True when the selected candidate's refusal may take the hop: a held-back
  candidate can serve the model now, the fallback is not spent, and the turn
  is neither a client-retry resend nor connection-bound compaction. The caller
  decides that the refusal is a pre-output provider usage limit.
  """
  @spec available?(SelectedCandidateContext.t()) :: boolean()
  def available?(%SelectedCandidateContext{} = context) do
    fallback = RouteState.partition_fallback(context.route_state)

    fallback != [] and is_nil(context.client_retry_dispatch_authority) and
      not RequestOptions.connection_bound_compaction?(context.request_options) and
      PoolReturn.any_routable?(context.auth, context.model, fallback, context.route_class)
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
          model: context.model,
          reserved: context.reserved,
          candidates: candidates,
          request_options: request_options,
          route_state: route_state
        })

      {:error, %{status: status, code: code} = error} ->
        finalize_refusal(context, error, status, code)
    end
  end

  # The held-back candidates stopped being routable between the refusal's
  # check and this filtering: the request ends on that refusal.
  defp finalize_refusal(context, error, status, code) do
    case AttemptSettlement.finalize_reservation_failure(context.reserved.request, %{
           response_status_code: status,
           last_error_code: to_string(code),
           usage_status: "not_applicable",
           pre_attempt_phase: PreAttemptRelease.routing_rejected()
         }) do
      {:ok, _finalized} -> {:error, Map.delete(error, :accounting_disposition)}
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end
end
