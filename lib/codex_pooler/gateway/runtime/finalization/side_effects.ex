defmodule CodexPooler.Gateway.Runtime.Finalization.SideEffects do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Routing.RouteLifecycle, as: RoutingRouteLifecycle
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Gateway.Runtime.Routing.DispatchLifecycle
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.UpstreamEnqueue
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
    if stale_replay_generation?(context) do
      :ok
    else
      callbacks.register_continuity.(
        with_assignment(request_options, context.assignment),
        payload,
        body
      )
    end
  end

  @spec before_finalize_success(SelectedCandidateContext.t(), RequestOptions.t() | map()) :: :ok
  def before_finalize_success(%SelectedCandidateContext{} = context, request_options) do
    maybe_enqueue_gateway_reconciliation(context.reserved.request.pool_id, context.assignment)

    unless replay_dispatch?(context) do
      RoutingRouteLifecycle.log_optional_result(
        "route_lifecycle_success",
        route_lifecycle_metadata(context),
        DispatchLifecycle.success(context)
      )
    end

    maybe_confirm_reset_probe(context, request_options)

    :ok
  end

  @spec observe_http_response(SelectedCandidateContext.t(), Req.Response.t(), binary()) :: :ok
  def observe_http_response(%SelectedCandidateContext{identity: identity}, response, body) do
    RateLimitObserver.record_headers(identity, response)
    RateLimitObserver.record_error(identity, body)
    :ok
  end

  @spec observe_stream_response(
          SelectedCandidateContext.t(),
          Req.Response.t(),
          binary(),
          map() | nil
        ) :: :ok
  def observe_stream_response(
        %SelectedCandidateContext{identity: identity},
        response,
        body,
        state
      ) do
    RateLimitObserver.record_headers(identity, response)

    rate_limit_state =
      if is_map(state) do
        Map.get(state, :rate_limit, state)
      else
        {:ok, collected} = RateLimitObserver.collect_events(body, RateLimitObserver.event_state())
        collected
      end

    RateLimitObserver.commit_events(identity, rate_limit_state)

    :ok
  end

  @spec observe_websocket_response(SelectedCandidateContext.t(), map()) :: :ok
  def observe_websocket_response(%SelectedCandidateContext{identity: identity}, response) do
    RateLimitObserver.record_websocket_upgrade_headers(
      identity,
      websocket_upgrade_headers(response)
    )

    RateLimitObserver.record_websocket_frame_headers(
      identity,
      Map.get(response, :websocket_frame_headers, %{})
    )

    :ok
  end

  defp websocket_upgrade_headers(%{reason: {:websocket_upgrade_failed, status, headers}})
       when is_integer(status) and is_list(headers),
       do: headers

  defp websocket_upgrade_headers(response), do: Map.get(response, :headers, [])

  defp stale_replay_generation?(%SelectedCandidateContext{
         attempt: %{replay_generation: 0},
         request_options: %{runtime: %{replay_generation: generation}}
       })
       when is_integer(generation) and generation > 0,
       do: true

  defp stale_replay_generation?(%SelectedCandidateContext{}), do: false

  defp replay_dispatch?(%SelectedCandidateContext{
         attempt: %{replay_generation: generation},
         request_options: %{runtime: %{replay_generation: generation}}
       })
       when generation > 0,
       do: true

  defp replay_dispatch?(%SelectedCandidateContext{}), do: false

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
    case UpstreamEnqueue.claim_gateway_reconciliation_gate(assignment.upstream_identity_id) do
      :duplicate ->
        :ok

      :ok ->
        enqueue_gateway_reconciliation(pool_id, assignment)
    end
  end

  defp enqueue_gateway_reconciliation(pool_id, assignment) do
    case Jobs.enqueue_gateway_account_reconciliation(pool_id, assignment) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        UpstreamEnqueue.release_gateway_reconciliation_gate(assignment.upstream_identity_id)

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
