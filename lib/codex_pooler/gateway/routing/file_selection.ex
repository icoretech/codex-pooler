defmodule CodexPooler.Gateway.Routing.FileSelection do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Routing.{
    CandidateEligibility,
    RouteFiltering,
    RoutePlanInput,
    RoutingSelection
  }

  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.IdentityRouting
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @file_model_identifier "backend-api/files"
  @assignment_active PoolUpstreamAssignment.active_status()
  @assignment_eligible PoolUpstreamAssignment.eligible_status()
  @assignment_health_active PoolUpstreamAssignment.active_health_status()
  @file_routable_identity_statuses IdentityRouting.file_routable_statuses()

  @type candidate :: {PoolUpstreamAssignment.t(), UpstreamIdentity.t()}

  @spec model() :: Model.t()
  def model do
    %Model{exposed_model_id: @file_model_identifier, upstream_model_id: @file_model_identifier}
  end

  @spec select(CodexPooler.Access.auth_context(), map(), RequestOptions.t(), String.t()) ::
          {:ok, RoutingSelection.t()} | {:error, map()}
  def select(auth, payload, %RequestOptions{} = request_options, endpoint) when is_map(payload) do
    candidates =
      auth.pool.id
      |> routable_assignment_query()
      |> Repo.all()

    route_selection(auth, candidates, payload, request_options, endpoint)
  end

  @spec fetch(CodexPooler.Access.auth_context(), String.t(), RequestOptions.t(), String.t()) ::
          {:ok, RoutingSelection.t()} | {:error, map()}
  def fetch(auth, assignment_id, %RequestOptions{} = request_options, endpoint)
      when is_binary(assignment_id) do
    candidates =
      auth.pool.id
      |> routable_assignment_query(assignment_id)
      |> Repo.all()

    route_selection(auth, candidates, %{}, request_options, endpoint)
  end

  defp route_selection(auth, candidates, payload, request_options, endpoint) do
    model = model()

    route_state =
      %{visible_model: model, candidates: candidates}
      |> RouteState.new()
      |> RouteState.preload_routing_snapshots(auth, model, request_options)

    with {:ok, candidates} <- require_file_candidates(candidates, request_options),
         {:ok, candidates, request_options, route_state} <-
           filter_file_candidates(
             auth,
             model,
             candidates,
             payload,
             request_options,
             endpoint,
             route_state
           ),
         {:ok, selection} <-
           RoutingSelection.select_and_begin_circuit(%{
             auth: auth,
             model: model,
             candidates: candidates,
             route_plan_input: RoutePlanInput.from_request_opts(request_options),
             endpoint: endpoint,
             payload: payload,
             request_options: request_options,
             route_state: route_state
           }) do
      {:ok, selection}
    else
      {:error, reason} ->
        {:error, route_selection_error(reason, request_options)}
    end
  end

  defp require_file_candidates([], request_options) do
    {:error,
     %{
       status: 503,
       code: :no_eligible_backend,
       message: "no healthy eligible backend is currently available",
       route_class: RequestOptions.route_class(request_options),
       candidate_exclusions: []
     }}
  end

  defp require_file_candidates(candidates, _request_options), do: {:ok, candidates}

  defp filter_file_candidates(
         auth,
         model,
         candidates,
         payload,
         request_options,
         endpoint,
         route_state
       ) do
    %{
      auth: auth,
      model: model,
      endpoint: endpoint,
      payload: payload,
      request_options: request_options,
      candidates: candidates
    }
    |> CandidateEligibility.FilterInput.new()
    |> RouteFiltering.filter_candidates_with_route_state(route_state, quota_mode: :optional)
  end

  defp route_selection_error(%{status: status, code: code, message: message} = reason, opts) do
    safe_error(status, code, message, route_error_metadata(reason, opts))
  end

  defp route_selection_error(reason, opts) do
    safe_error(
      503,
      :no_eligible_backend,
      "no healthy eligible backend is currently available",
      route_error_metadata(reason, opts)
    )
  end

  defp route_error_metadata(reason, opts) do
    reason
    |> Map.take([:route_class, :candidate_exclusions, :quota_refresh_attempted])
    |> Map.put_new(:route_class, RequestOptions.route_class(opts))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp routable_assignment_query(pool_id, assignment_id \\ nil) do
    PoolUpstreamAssignment
    |> join(:inner, [assignment], identity in UpstreamIdentity,
      on: identity.id == assignment.upstream_identity_id
    )
    |> where(
      [assignment, identity],
      assignment.status == ^@assignment_active and
        assignment.eligibility_status == ^@assignment_eligible and
        assignment.health_status == ^@assignment_health_active and
        identity.status in ^@file_routable_identity_statuses
    )
    |> maybe_pool(pool_id)
    |> maybe_assignment(assignment_id)
    |> order_by([assignment, _identity], asc: assignment.created_at, asc: assignment.id)
    |> select([assignment, identity], {assignment, identity})
  end

  defp maybe_pool(query, pool_id) when is_binary(pool_id),
    do: where(query, [assignment, _identity], assignment.pool_id == ^pool_id)

  defp maybe_pool(query, _pool_id), do: query

  defp maybe_assignment(query, assignment_id) when is_binary(assignment_id),
    do: where(query, [assignment, _identity], assignment.id == ^assignment_id)

  defp maybe_assignment(query, _assignment_id), do: query

  defp safe_error(status, code, message, extra) do
    %{status: status, code: code, message: message, param: nil, upstream: Map.new(extra)}
  end
end
