defmodule CodexPooler.Gateway.Runtime.Dispatch do
  @moduledoc """
  Runtime route dispatch lifecycle after a request has been admitted and reserved.
  """

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Accounting.PreAttemptRelease
  alias CodexPooler.Gateway.Admission
  alias CodexPooler.Gateway.Contracts, as: GatewayContracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.{CandidateEligibility, CircuitRetryAfter, ModelMetadata, RouteFiltering, RouteLifecycle, RoutingSelection}
  alias CodexPooler.Gateway.Routing.CandidateEligibility.Quota
  alias CodexPooler.Gateway.Routing.ProviderCredits
  alias CodexPooler.Gateway.Runtime.Dispatch.ContentFilterBindingRefusal
  alias CodexPooler.Gateway.Runtime.Dispatch.ContentFilterRetryPin
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.PartitionFallback
  alias CodexPooler.Gateway.Runtime.Dispatch.ReplayPreparation
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement
  alias CodexPooler.Gateway.Websocket.DirectCleanup
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility

  @type dispatch_callback ::
          (SelectedCandidateContext.t() ->
             {:ok, GatewayContracts.gateway_result()} | {:error, map()} | {:retry, term()})
  @type dispatch_context :: Context.t() | SelectedCandidateContext.t()
  @type dispatch_result ::
          {:ok, GatewayContracts.gateway_result()} | {:error, map()} | {:retry, term() | nil}

  @spec dispatch(Context.t(), dispatch_callback()) ::
          {:ok, GatewayContracts.gateway_result()} | {:error, map()}
  def dispatch(%Context{} = context, transport_dispatch)
      when is_function(transport_dispatch, 1) do
    context
    |> dispatch_from(0, transport_dispatch)
    |> maybe_dispatch_partition_fallback(context, transport_dispatch)
    |> finalize_dispatch_result()
  end

  # The selected partition's last candidate refused with a provider usage limit
  # before output while a held-back partition can serve the model: the turn
  # moves there once (findings#206 row 206-586). The fallback context's route
  # state has the fallback spent, so its own last candidate finalizes.
  defp maybe_dispatch_partition_fallback({:retry, :partition_fallback}, %Context{} = context, transport_dispatch) do
    case PartitionFallback.context(context) do
      {:ok, fallback_context} -> dispatch_from(fallback_context, 0, transport_dispatch)
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_dispatch_partition_fallback(result, _context, _transport_dispatch), do: result

  @spec dispatch_from(dispatch_context(), non_neg_integer(), dispatch_callback()) ::
          dispatch_result()
  def dispatch_from(context, start_index, transport_dispatch)
      when is_integer(start_index) and start_index >= 0 and is_function(transport_dispatch, 1) do
    resume_dispatch(context, start_index, transport_dispatch)
  end

  defp resume_dispatch(%SelectedCandidateContext{assignment: assignment} = context, start_index, dispatch) when start_index > 0,
    do: dispatch_refiltered(refilter_remaining_cohort(context, assignment.id), dispatch, {:retry, nil}, start_index)

  defp resume_dispatch(context, start_index, dispatch) when start_index > 0 do
    case Enum.at(context.route_plan.candidates, start_index - 1) do
      {attempted, _identity} -> dispatch_refiltered(refilter_remaining_cohort(context, attempted.id), dispatch, {:retry, nil}, start_index)
      nil -> {:retry, nil}
    end
  end

  defp resume_dispatch(context, 0, dispatch), do: dispatch_at(context, 0, dispatch)

  defp dispatch_at(%{route_plan: %{candidates: []}}, _index, _dispatch), do: {:retry, nil}

  defp dispatch_at(context, index, dispatch) do
    {assignment, identity} = hd(context.route_plan.candidates)
    allow_retry? = retry_remaining?(context, assignment.id)
    result = dispatch_candidate(context, assignment, identity, index, allow_retry?, dispatch)
    retry_selected_result(result, context, assignment.id, allow_retry?, dispatch)
  end

  # A guided content-filter retry never moves off its bound account
  # (`ContentFilterRetryPin`): the route filter's deferred-recovery candidates
  # join the remaining cohort outside the pinned plan.
  defp retry_remaining?(context, assignment_id),
    do:
      remaining_cohort(context, assignment_id) != [] and
        not bound_reset_probe?(context.request_options.routing.reset_probe) and
        not RequestOptions.connection_bound_compaction?(context.request_options) and not client_retry_dispatch?(context) and
        not ContentFilterRetryPin.bound?(context.reserved.request)

  defp bound_reset_probe?(%ResetProbe{} = probe), do: ResetProbe.bound?(probe)
  defp bound_reset_probe?(nil), do: false

  defp retry_selected_result({:retry, _reason} = retry, context, assignment_id, true, dispatch),
    do: dispatch_refiltered(refilter_remaining_cohort(context, assignment_id), dispatch, retry, length(Map.get(context.route_state.extensions, :attempted_capacity_assignments, [])) + 1)

  defp retry_selected_result(result, _context, _assignment_id, _allowed?, _dispatch), do: result

  defp dispatch_refiltered({:ok, context}, dispatch, _empty_result, index), do: dispatch_at(context, index, dispatch)
  defp dispatch_refiltered({:error, error}, _dispatch, _empty_result, _index), do: {:error, error}
  defp dispatch_refiltered(:empty, _dispatch, empty_result, _index), do: empty_result

  defp remaining_cohort(context, attempted_id) do
    attempted = MapSet.new([attempted_id | Map.get(context.route_state.extensions, :attempted_capacity_assignments, [])])
    dropped = deferred_recovery_candidates(context)

    (context.route_plan.candidates ++ dropped)
    |> Enum.uniq_by(fn {assignment, _identity} -> assignment.id end)
    |> Enum.reject(fn {assignment, _identity} -> MapSet.member?(attempted, assignment.id) end)
  end

  defp deferred_recovery_candidates(context) do
    Enum.filter(Map.get(context.route_state.extensions, :route_filter_dropped, []), fn {assignment, identity} ->
      snapshot = RouteState.quota_snapshot_for_identity(context.route_state, identity)
      request_context = ProviderCredits.request_context(context.model, context.request_options, assignment.id) |> Map.merge(%{pool_upstream_assignment_id: assignment.id, upstream_identity_id: identity.id})
      decision = Upstreams.provider_credits_decision(snapshot, request_context)
      decision.capacity_basis == :provider_credits or AutoEligibility.gateway_auto_ready?(identity, SavedResets.auto_policy(identity), snapshot.as_of)
    end)
  end

  defp refilter_remaining_cohort(context, attempted_id) do
    remaining = remaining_cohort(context, attempted_id)

    if remaining == [] do
      :empty
    else
      extensions =
        context.route_state.extensions
        |> Map.put(:attempted_capacity_assignments, [attempted_id | Map.get(context.route_state.extensions, :attempted_capacity_assignments, [])])
        |> Map.put(:attempted_capacity_candidates, attempted_advice_candidates(context, attempted_id))
        |> Map.delete(:route_filter_dropped)

      # The retry narrows the candidates and the capacity to what is left, never
      # the saved-reset cohort: a redemption claim locks that cohort and refuses
      # a consume while any account of it carries an applied consume younger
      # than the protection period or one still being verified, including the
      # account just attempted (findings#331).
      route_state =
        %{context.route_state | candidates: remaining, saved_reset_auto_capacity: remaining, extensions: extensions}
        |> RouteState.refresh_quota_snapshots()
        |> RouteState.preload_routing_snapshots(context.auth, context.model, context.request_options)

      input = CandidateEligibility.FilterInput.new(%{auth: context.auth, model: context.model, endpoint: context.endpoint, payload: context.payload, request_options: context.request_options, candidates: remaining})

      filtered_retry_context(RouteFiltering.filter_candidates_with_route_state(input, route_state), context, remaining)
    end
  end

  defp attempted_advice_candidates(context, attempted_id) do
    (Map.get(context.route_state.extensions, :attempted_capacity_candidates, []) ++ context.route_plan.candidates)
    |> Enum.filter(fn {assignment, _identity} -> assignment.id == attempted_id or assignment.id in Map.get(context.route_state.extensions, :attempted_capacity_assignments, []) end)
    |> Enum.uniq_by(fn {assignment, _identity} -> assignment.id end)
  end

  defp filtered_retry_context({:ok, candidates, options, state}, context, remaining) do
    # Keep the original strategy/affinity order inside each basis; retries
    # never broaden a partition, reselect a ring or change an anchor.
    rank = Map.new(Enum.with_index(remaining), fn {{assignment, _identity}, index} -> {assignment.id, index} end)
    capacity = options.routing.quota_decision["candidate_capacity"] || %{}

    candidates =
      Enum.sort_by(candidates, fn {assignment, _identity} ->
        {capacity_retry_tier(capacity[assignment.id]["capacity_basis"]), rank[assignment.id]}
      end)

    plan = Map.merge(context.route_plan, %{candidates: candidates, selected_assignment_id: candidates |> hd() |> elem(0) |> Map.fetch!(:id)})
    {:ok, %{context | route_plan: plan, request_options: options, route_state: state}}
  end

  defp filtered_retry_context({:error, error}, context, _remaining), do: finalize_retry_refusal(context, error)
  defp capacity_retry_tier("provider_credits"), do: 1
  defp capacity_retry_tier("unknown_legacy"), do: 2
  defp capacity_retry_tier(_non_credit), do: 0

  # The refused cohort follows an earlier candidate's attempt of this request,
  # so the release carries that attempt (findings#321).
  defp finalize_retry_refusal(context, %{status: status, code: code} = error) do
    case AttemptSettlement.finalize_routing_refusal(context.reserved.request, %{response_status_code: status, last_error_code: to_string(code)}) do
      {:ok, _finalized} -> {:error, Map.delete(error, :accounting_disposition)}
      {:error, gateway_error} -> {:error, gateway_error}
    end
  end

  @spec candidate_available?(dispatch_context(), non_neg_integer()) :: boolean()
  def candidate_available?(%SelectedCandidateContext{} = context, index) when is_integer(index) and index >= 0,
    do: context.allow_retry? and remaining_cohort(context, context.assignment.id) != []

  def candidate_available?(context, index) when is_integer(index) and index >= 0 do
    index < length(context.route_plan.candidates)
  end

  defp finalize_dispatch_result({:retry, _reason}) do
    {:error,
     error(
       503,
       "no_eligible_backend",
       "no healthy eligible backend is currently available",
       "model"
     )}
  end

  defp finalize_dispatch_result(result) do
    result
  end

  @spec dispatch_candidate(
          dispatch_context(),
          term(),
          term(),
          non_neg_integer(),
          boolean(),
          dispatch_callback()
        ) ::
          {:ok, GatewayContracts.gateway_result()} | {:error, map()} | {:retry, term()}
  defp dispatch_candidate(
         context,
         assignment,
         identity,
         index,
         allow_retry?,
         transport_dispatch
       )
       when is_function(transport_dispatch, 1) do
    selection =
      RoutingSelection.prepare_candidate(%{
        route_plan: context.route_plan,
        assignment: assignment,
        identity: identity,
        index: index,
        route_class: context.route_class
      })

    with :ok <- drain_checkpoint(context),
         {:ok, context} <- apply_route_selection(context, selection, allow_retry?),
         {:ok, context} <- validate_reset_probe_scope(context),
         {:ok, context} <- validate_provider_permission(context),
         {:ok, context} <- persist_route_metadata(context),
         {:ok, context} <- begin_candidate_circuit(context, selection),
         {:ok, context} <- start_dispatch_attempt(context, selection) do
      transport_dispatch.(context)
    end
  end

  # A drain can stop a later candidate after an earlier candidate's attempt;
  # the release then carries that attempt (findings#321 row 321-2).
  defp drain_checkpoint(context) do
    case Admission.checkpoint() do
      :ok ->
        :ok

      {:error, error} ->
        case AttemptSettlement.finalize_before_candidate_attempt(
               context.reserved.request,
               %{response_status_code: 499, last_error_code: "owner_drained"},
               PreAttemptRelease.turn_interrupted()
             ) do
          {:ok, _} -> {:error, Map.delete(error, :accounting_disposition)}
          {:error, _} = failure -> failure
        end
    end
  end

  defp validate_provider_permission(%SelectedCandidateContext{} = context) do
    if Quota.provider_permission_current?(
         context.model,
         {context.assignment, context.identity},
         context.route_state
       ) do
      {:ok, context}
    else
      handle_unavailable_routing_circuit(context, :provider_permission_changed)
    end
  end

  defp begin_candidate_circuit(
         %SelectedCandidateContext{} = context,
         %RoutingSelection{} = selection
       ) do
    case RoutingSelection.begin_circuit(selection, context.auth, context.model) do
      {:ok, %RoutingSelection{} = selection} ->
        {:ok, put_routing_circuit_admission(context, selection)}

      {:error, reason}
      when reason in [:routing_circuit_open, :routing_circuit_probe_in_flight] ->
        handle_unavailable_routing_circuit(context, reason)

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :begin_routing_circuit_attempt,
          context.reserved.request,
          nil,
          reason
        )
    end
  end

  defp apply_route_selection(context, %RoutingSelection{} = selection, allow_retry?) do
    case Accounting.accumulate_request_metadata(
           context.reserved.request,
           selection.selected_metadata
         ) do
      {:ok, request} ->
        request_options =
          RequestOptions.put_routing(
            context.request_options,
            route_selection_updates(context, selection)
          )

        selected_context =
          context
          |> refresh_request_options(request_options)
          |> Map.put(:reserved, %{context.reserved | request: request})
          |> SelectedCandidateContext.from_dispatch_context(selection, allow_retry?)

        {:ok, selected_context}

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :merge_route_selection_metadata,
          context.reserved.request,
          nil,
          reason
        )
    end
  end

  @spec route_selection_updates(dispatch_context(), RoutingSelection.t()) :: keyword()
  defp route_selection_updates(context, %RoutingSelection{} = selection) do
    Keyword.put(payload_selection_updates(context.model, selection.assignment.id, context.request_options), :routing_attempt_metadata, selection.attempt_metadata)
  end

  @doc false
  @spec payload_selection_updates(CodexPooler.Catalog.Model.t(), Ecto.UUID.t(), RequestOptions.t()) :: keyword()
  def payload_selection_updates(model, assignment_id, request_options) do
    metadata = ModelMetadata.selected_assignment_metadata(model, assignment_id)
    updates = [supports_reasoning_summary_parameter?: ModelMetadata.supports_reasoning_summary_parameter?(metadata)]

    case RequestOptions.model_serving_mode_snapshot(request_options) do
      nil -> Keyword.put(updates, :use_responses_lite?, ModelMetadata.bool_metadata(metadata, "use_responses_lite"))
      _resolved_snapshot -> updates
    end
  end

  defp put_routing_circuit_admission(
         %SelectedCandidateContext{} = context,
         %RoutingSelection{circuit_state: %RoutingCircuitState{} = state} = selection
       ) do
    request_options =
      RequestOptions.put_routing(context.request_options, routing_circuit_state: state)

    context
    |> refresh_request_options(request_options)
    |> Map.put(:routing_circuit_state, state)
    |> Map.put(:routing_circuit_admission, selection.circuit_admission)
  end

  defp put_routing_circuit_admission(
         %SelectedCandidateContext{} = context,
         %RoutingSelection{} = selection
       ) do
    Map.put(context, :routing_circuit_admission, selection.circuit_admission)
  end

  defp persist_route_metadata(%SelectedCandidateContext{} = context) do
    case Accounting.persist_request_metadata(context.reserved.request,
           reload?: route_metadata_reload?(context)
         ) do
      {:ok, request} ->
        {:ok, %{context | reserved: %{context.reserved | request: request}}}

      {:error, reason} ->
        FailureResponse.accounting_failure(
          :merge_route_selection_metadata,
          context.reserved.request,
          nil,
          reason
        )
    end
  end

  defp validate_reset_probe_scope(%SelectedCandidateContext{} = context) do
    case context.request_options.routing.reset_probe do
      %ResetProbe{} = probe ->
        validate_bound_reset_probe_scope(context, probe)

      nil ->
        {:ok, context}
    end
  end

  defp validate_bound_reset_probe_scope(context, %ResetProbe{} = probe) do
    cond do
      ResetProbe.unbound?(probe) ->
        {:ok, context}

      ResetProbe.matches?(
        probe,
        context.assignment.id,
        context.identity.id,
        effective_model(context),
        context.route_class
      ) ->
        {:ok, context}

      true ->
        finalize_reset_probe_scope_mismatch(context)
    end
  end

  defp effective_model(%SelectedCandidateContext{} = context),
    do: context.request_options.routing.effective_model || context.model.exposed_model_id

  defp finalize_reset_probe_scope_mismatch(%SelectedCandidateContext{} = context) do
    case AttemptSettlement.finalize_reservation_failure(context.reserved.request, %{
           response_status_code: 503,
           last_error_code: "no_eligible_backend",
           usage_status: "not_applicable",
           pre_attempt_phase: PreAttemptRelease.routing_rejected()
         }) do
      {:ok, _finalized} ->
        {:error,
         error(
           503,
           "no_eligible_backend",
           "no healthy eligible backend is currently available",
           "model"
         )}

      {:error, gateway_error} ->
        {:error, gateway_error}
    end
  end

  defp route_metadata_reload?(%SelectedCandidateContext{index: index}), do: index != 0

  defp start_dispatch_attempt(
         %SelectedCandidateContext{} = context,
         %RoutingSelection{} = selection
       ) do
    attrs = %{
      admitted_attempt_bind:
        DirectCleanup.attempt_callback(
          context.request_options.runtime.direct_cleanup,
          context.reserved.request
        ),
      model: context.model,
      pricing_snapshot: Map.get(context.reserved, :pricing_snapshot),
      upstream_identity: context.identity,
      response_metadata:
        (context.request_options.routing.routing_attempt_metadata || %{})
        |> Map.merge(ReplayPreparation.attempt_metadata(context))
        |> Map.merge(%{
          "pool_upstream_assignment_id" => context.assignment.id,
          "upstream_identity_id" => context.identity.id
        })
    }

    result =
      case context.client_retry_dispatch_authority do
        %ClientRetry.DispatchAuthority{} = authority ->
          Accounting.create_client_retry_dispatch_attempt(
            context.reserved.request,
            context.assignment,
            authority,
            attrs
          )

        nil ->
          Accounting.create_attempt(context.reserved.request, context.assignment, attrs)
      end

    case result do
      {:ok, attempt} ->
        {:ok,
         %{
           context
           | attempt: attempt,
             retry_count: attempt.attempt_number - 1,
             started: System.monotonic_time(:millisecond)
         }}

      {:error, %{code: :request_already_finalized}} ->
        release_unstarted_attempt_circuit(
          context,
          selection,
          "release_finalized_request_circuit_probe"
        )

        {:error,
         error(
           499,
           "request_already_finalized",
           "request lifecycle completed before upstream dispatch",
           "request"
         )}

      {:error, %{code: code}}
      when code in [
             :client_retry_dispatch_claimed,
             :invalid_client_retry_dispatch_authority
           ] ->
        release_unstarted_attempt_circuit(
          context,
          selection,
          "release_rejected_client_retry_dispatch_circuit_probe"
        )

        {:error,
         error(
           409,
           "duplicate_turn",
           "a request with the same turn identity already exists",
           "request"
         )}

      # A content-filter retry binding this candidate cannot honour
      # (`ContentFilterBindingRefusal`, findings#316).
      {:error, %{code: :invalid_content_filter_retry_binding}} ->
        release_unstarted_attempt_circuit(
          context,
          selection,
          "release_refused_content_filter_retry_circuit_probe"
        )

        ContentFilterBindingRefusal.finalize_unstarted(context)

      {:error, reason} ->
        release_unstarted_attempt_circuit(
          context,
          selection,
          "release_failed_attempt_circuit_probe"
        )

        FailureResponse.accounting_failure(
          :create_attempt,
          context.reserved.request,
          nil,
          reason
        )
    end
  end

  defp client_retry_dispatch?(%{
         client_retry_dispatch_authority: %ClientRetry.DispatchAuthority{}
       }),
       do: true

  defp client_retry_dispatch?(_context), do: false

  # No attempt started and no upstream was contacted, so the circuit
  # acquisition (including a claimed half-open probe slot) must complete
  # neutrally: it would otherwise strand probe_in_flight_count until the
  # staleness self-heal.
  defp release_unstarted_attempt_circuit(context, %RoutingSelection{} = selection, operation) do
    selection = %{
      selection
      | circuit_state: context.routing_circuit_state,
        circuit_admission: context.routing_circuit_admission
    }

    RouteLifecycle.log_optional_result(
      operation,
      [request_id: context.reserved.request.id],
      RouteLifecycle.selection_neutral_completion(context.auth, context.model, selection)
    )
  end

  defp refresh_request_options(context, %RequestOptions{} = request_options) do
    %{
      context
      | request_options: request_options,
        route_class: request_options.transport.route_class
    }
  end

  # The refused candidate can follow an earlier candidate's attempt of this
  # request; the release then carries that attempt (findings#321).
  defp handle_unavailable_routing_circuit(%SelectedCandidateContext{} = context, reason) do
    if context.allow_retry? do
      {:retry, reason}
    else
      case AttemptSettlement.finalize_routing_refusal(context.reserved.request, %{
             response_status_code: 503,
             last_error_code: "no_eligible_backend"
           }) do
        # A circuit refused the candidate after route filtering admitted it:
        # the same retry advice as the filter's refusal (findings#206 row
        # 206-548).
        {:ok, _finalized} ->
          {:error, error(503, "no_eligible_backend", "no healthy eligible backend is currently available", "model")}
          |> CircuitRetryAfter.put_current(context.auth, context.model, context.route_plan.candidates, context.route_class)

        {:error, gateway_error} ->
          {:error, gateway_error}
      end
    end
  end

  defp error(status, code, message, param) do
    %{
      status: status,
      code: code,
      message: message,
      param: param
    }
  end
end
