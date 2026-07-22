defmodule CodexPooler.Gateway.Runtime.Finalization.SideEffects do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Routing.RouteLifecycle, as: RoutingRouteLifecycle
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle
  alias CodexPooler.Jobs
  alias CodexPooler.Upstreams.SavedResets.ProbeLease
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @spec record_success(
          SelectedCandidateContext.t(),
          map(),
          binary(),
          RequestOptions.t() | map(),
          map()
        ) ::
          :ok
  def record_success(
        %SelectedCandidateContext{} = context,
        payload,
        body,
        request_options,
        callbacks
      ) do
    RoutingRouteLifecycle.log_optional_result(
      "route_lifecycle_success",
      route_lifecycle_metadata(context),
      DispatchLifecycle.success(context)
    )

    callbacks.register_continuity.(
      with_assignment(request_options, context.assignment),
      payload,
      body
    )

    maybe_confirm_reset_probe(context, request_options)

    :ok
  end

  defp maybe_confirm_reset_probe(
         %SelectedCandidateContext{} = context,
         %RequestOptions{} = options
       ) do
    case options.routing.reset_probe do
      %ResetProbe{} = probe -> maybe_confirm_bound_reset_probe(context, probe)
      nil -> :ok
    end
  end

  defp maybe_confirm_reset_probe(_context, _request_options), do: :ok

  defp maybe_confirm_bound_reset_probe(%SelectedCandidateContext{} = context, probe) do
    if ResetProbe.bound?(probe) and
         ResetProbe.matches?(
           probe,
           context.assignment.id,
           context.identity.id,
           effective_model(context),
           context.route_class
         ) do
      redemption = (context.identity.metadata || %{})["saved_reset_redemption"] || %{}

      safe_confirm_reset_probe(
        context.identity.id,
        redemption["generation"],
        redemption["attempt_id"],
        probe
      )
    else
      :ok
    end
  end

  defp effective_model(%SelectedCandidateContext{} = context),
    do: context.request_options.routing.effective_model || context.model.exposed_model_id

  defp safe_confirm_reset_probe(identity_id, generation, attempt_id, %ResetProbe{} = probe) do
    ProbeLease.confirm_upstream(identity_id, generation, attempt_id, probe)
    :ok
  rescue
    exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error] ->
      RateLimitObserver.log_failure(
        "reset_probe_confirm",
        [upstream_identity_id: identity_id],
        exception
      )

      :ok
  end

  @spec maybe_enqueue_gateway_reconciliation(Jobs.pool_ref(), PoolUpstreamAssignment.t()) :: :ok
  def maybe_enqueue_gateway_reconciliation(pool_id, assignment) do
    result = Jobs.enqueue_gateway_account_reconciliation(pool_id, assignment)

    case result do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        RateLimitObserver.log_failure(
          "gateway_reconciliation_enqueue",
          [pool_id: pool_id, pool_upstream_assignment_id: assignment.id],
          reason
        )
    end
  end

  defp route_lifecycle_metadata(%SelectedCandidateContext{} = context) do
    [
      pool_upstream_assignment_id: context.assignment.id,
      route_class: context.route_class
    ]
  end

  defp with_assignment(%RequestOptions{} = request_options, %PoolUpstreamAssignment{
         id: assignment_id
       }),
       do:
         RequestOptions.put_file_bridge(request_options,
           pool_upstream_assignment_id: assignment_id
         )

  defp with_assignment(opts, %PoolUpstreamAssignment{id: assignment_id}),
    do: Map.put(opts, :pool_upstream_assignment_id, assignment_id)
end
