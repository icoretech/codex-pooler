defmodule CodexPooler.Alerts.Evaluation.EvaluationProjection do
  @moduledoc """
  Builds persisted-state alert evaluation projections for Pools and upstream assignments.
  """

  import Ecto.Query

  alias CodexPooler.Alerts.Evaluation.CircuitTerm
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.{RoutingQuotaSnapshot, Windows}
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @active "active"
  @disabled_assignment_states ~w(deleted disabled)
  @auth_target_states ~w(reauth_required refresh_failed)

  @type projection_cache :: %{
          optional(tuple()) => term()
        }

  @spec pool_from_cache(
          Ecto.UUID.t() | nil,
          String.t() | nil,
          map(),
          boolean(),
          projection_cache()
        ) ::
          {map(), projection_cache()}
  def pool_from_cache(pool_id, model, context, circuit_term?, projection_cache) do
    {assignments, projection_cache} =
      assigned_identities_from_cache(pool_id, model, context, circuit_term?, projection_cache)

    evidence =
      Map.get(
        projection_cache,
        CircuitTerm.evidence_cache_key(pool_id, model, context, circuit_term?),
        CircuitTerm.default_evidence()
      )

    {pool_from_assignments(pool_id, model, assignments, evidence), projection_cache}
  end

  @spec assigned_identities_from_cache(
          Ecto.UUID.t() | nil,
          String.t() | nil,
          map(),
          boolean(),
          projection_cache()
        ) :: {[map()], projection_cache()}
  def assigned_identities_from_cache(pool_id, model, context, circuit_term?, projection_cache) do
    cache_key = {pool_id, model, circuit_term?}

    {assignments, projection_cache} =
      case Map.fetch(projection_cache, cache_key) do
        {:ok, assignments} ->
          {assignments, projection_cache}

        :error ->
          {assignments, projection_cache} =
            assigned_identities(pool_id, model, context.at, projection_cache)

          {assignments, Map.put(projection_cache, cache_key, assignments)}
      end

    maybe_apply_circuit_term(
      assignments,
      pool_id,
      model,
      context,
      circuit_term?,
      projection_cache
    )
  end

  @spec enabled_assignment?(map()) :: boolean()
  def enabled_assignment?(assignment) do
    assignment.assignment_status not in @disabled_assignment_states
  end

  @spec all_in_state?(map(), String.t()) :: boolean()
  def all_in_state?(projection, target_state) do
    projection.assignments
    |> Enum.filter(&enabled_assignment?/1)
    |> Enum.all?(&(&1.state == target_state))
  end

  defp pool_from_assignments(pool_id, model, assignments, circuit_evidence) do
    enabled = Enum.filter(assignments, &enabled_assignment?/1)
    usable = Enum.filter(enabled, & &1.usable_assignment?)

    %{
      pool_id: pool_id,
      model: model,
      assignment_count: length(assignments),
      enabled_assignment_count: length(enabled),
      usable_assignment_count: length(usable),
      state_counts: Enum.frequencies_by(enabled, & &1.state),
      circuit_evidence: circuit_evidence,
      assignments: assignments
    }
  end

  defp assigned_identities(pool_id, model, timestamp, projection_cache) do
    assignments = assignment_rows(pool_id)

    snapshots_by_identity_id =
      assignments
      |> Enum.map(& &1.upstream_identity_id)
      |> RoutingQuotaSnapshot.load_by_identity_ids(timestamp)

    {scope, projection_cache} =
      quota_scope_opts_from_cache(pool_id, model, projection_cache)

    assignments =
      Enum.map(assignments, fn row ->
        snapshot = Map.fetch!(snapshots_by_identity_id, row.upstream_identity_id)
        quota_projection = quota_projection(snapshot, scope)

        Map.merge(row, %{
          model: model,
          quota_windows: RoutingQuotaSnapshot.effective_windows(snapshot),
          quota: quota_projection,
          state: assignment_state(row, quota_projection),
          enabled_assignment?: enabled_assignment?(row),
          serves_model?: true,
          circuit_blocked?: false,
          blocked_lanes: [],
          usable_assignment?:
            usable_assignment?(row, quota_projection, %{
              serves_model?: true,
              circuit_blocked?: false
            })
        })
      end)

    {assignments, projection_cache}
  end

  defp maybe_apply_circuit_term(
         assignments,
         pool_id,
         model,
         context,
         false,
         projection_cache
       ) do
    projection_cache =
      Map.put(
        projection_cache,
        CircuitTerm.evidence_cache_key(pool_id, model, context, false),
        CircuitTerm.default_evidence()
      )

    {assignments, projection_cache}
  end

  defp maybe_apply_circuit_term(
         assignments,
         pool_id,
         model,
         context,
         true,
         projection_cache
       ) do
    {assignments, evidence, projection_cache} =
      CircuitTerm.apply(assignments, pool_id, model, context, projection_cache)

    assignments =
      Enum.map(assignments, fn assignment ->
        Map.put(
          assignment,
          :usable_assignment?,
          usable_assignment?(assignment, assignment.quota, %{
            serves_model?: assignment.serves_model?,
            circuit_blocked?: assignment.circuit_blocked?
          })
        )
      end)

    projection_cache =
      Map.put(
        projection_cache,
        CircuitTerm.evidence_cache_key(pool_id, model, context, true),
        evidence
      )

    {assignments, projection_cache}
  end

  defp assignment_rows(pool_id) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        join: identity in UpstreamIdentity,
        on: identity.id == assignment.upstream_identity_id,
        where: assignment.pool_id == ^pool_id,
        order_by: [asc: assignment.created_at, asc: assignment.id],
        select: %{
          pool_id: assignment.pool_id,
          assignment_id: assignment.id,
          upstream_identity_id: identity.id,
          assignment_status: assignment.status,
          health_status: assignment.health_status,
          eligibility_status: assignment.eligibility_status,
          identity_status: identity.status,
          identity_metadata: identity.metadata
        }
    )
  end

  defp quota_projection(snapshot, :invalid_concrete_model) do
    %{
      state: "missing_evidence",
      routing_usable?: false,
      window_count: length(RoutingQuotaSnapshot.effective_windows(snapshot)),
      selector_windows: [],
      reason_codes: ["missing_evidence"]
    }
  end

  defp quota_projection(snapshot, scope_opts) when is_list(scope_opts) do
    windows = RoutingQuotaSnapshot.effective_windows(snapshot)
    opts = scope_opts ++ [at: snapshot.as_of]
    selection = Windows.quota_window_selection_data_from_windows(windows, opts)
    eligibility = Windows.routing_quota_eligibility_from_snapshot(snapshot, scope_opts)
    state = quota_state(windows, selection, eligibility, snapshot.as_of)

    %{
      state: state,
      routing_usable?: eligibility.eligible?,
      window_count: length(windows),
      selector_windows: selection.routing_windows,
      reason_codes: quota_reason_codes(state, selection, eligibility, snapshot.as_of)
    }
  end

  defp quota_state(
         _windows,
         _selection,
         %{eligible?: true, routing_state: :credit_backed_probe},
         _timestamp
       ),
       do: "credit_backed_probe"

  defp quota_state(
         _windows,
         _selection,
         %{eligible?: true, routing_state: :weekly_only_probe},
         _timestamp
       ),
       do: "weekly_only"

  defp quota_state(
         _windows,
         _selection,
         %{eligible?: true, routing_state: :windowless_provider_available},
         _timestamp
       ),
       do: "usable"

  defp quota_state([], _selection, _eligibility, _timestamp), do: "missing_evidence"

  defp quota_state(_windows, _selection, %{eligible?: true}, _timestamp), do: "usable"

  defp quota_state(_windows, selection, _eligibility, timestamp) do
    cond do
      exhausted_selection?(selection, timestamp) -> "exhausted"
      stale_selection?(selection, timestamp) -> "stale"
      true -> "missing_evidence"
    end
  end

  defp exhausted_selection?(selection, timestamp) do
    selection.routing_windows
    |> Enum.flat_map(&Windows.routing_window_reason_codes(&1, timestamp))
    |> Enum.member?("exhausted")
  end

  defp stale_selection?(selection, timestamp) do
    selection.routing_windows
    |> Enum.flat_map(&Windows.routing_window_reason_codes(&1, timestamp))
    |> Enum.any?(&(&1 in ["expired", "not_fresh"]))
  end

  defp quota_reason_codes("usable", _selection, _eligibility, _timestamp), do: ["quota_usable"]

  defp quota_reason_codes("credit_backed_probe", _selection, _eligibility, _timestamp),
    do: ["credit_backed_probe"]

  defp quota_reason_codes("weekly_only", _selection, _eligibility, _timestamp),
    do: ["weekly_only"]

  defp quota_reason_codes("missing_evidence", %{routing_windows: []}, _eligibility, _timestamp),
    do: ["missing_evidence"]

  defp quota_reason_codes(state, selection, _eligibility, timestamp) do
    reason_codes =
      selection.routing_windows
      |> Enum.flat_map(&Windows.routing_window_reason_codes(&1, timestamp))
      |> Enum.uniq()

    if reason_codes == [], do: [state], else: [state | reason_codes]
  end

  defp assignment_state(row, _quota) when row.identity_status in @auth_target_states,
    do: row.identity_status

  defp assignment_state(_row, %{state: state}), do: state

  defp usable_assignment?(row, quota, term) do
    row.assignment_status == @active and row.health_status == @active and
      row.eligibility_status == "eligible" and row.identity_status == @active and
      quota.routing_usable? and term.serves_model? and not term.circuit_blocked?
  end

  defp quota_scope_opts_from_cache(_pool_id, nil, projection_cache),
    do: {[], projection_cache}

  defp quota_scope_opts_from_cache(pool_id, model, projection_cache) do
    cache_key = {:models, pool_id}

    {models, projection_cache} =
      case Map.fetch(projection_cache, cache_key) do
        {:ok, models} ->
          {models, projection_cache}

        :error ->
          models =
            Repo.all(
              from catalog_model in Model,
                where: catalog_model.pool_id == ^pool_id and catalog_model.status == "active",
                order_by: [asc: fragment("lower(?)", catalog_model.exposed_model_id)],
                select: %{
                  exposed_model_id: catalog_model.exposed_model_id,
                  upstream_model_id: catalog_model.upstream_model_id,
                  metadata: catalog_model.metadata
                }
            )

          {models, Map.put(projection_cache, cache_key, models)}
      end

    case normalize_concrete_alias(model) do
      {:ok, normalized_model} ->
        resolve_catalog_aliases(models, normalized_model, projection_cache)

      :error ->
        {:invalid_concrete_model, projection_cache}
    end
  end

  defp resolve_catalog_aliases(models, normalized_model, projection_cache) do
    case Enum.find(models, fn catalog_model ->
           normalize_alias(catalog_model.exposed_model_id) == normalized_model
         end) do
      nil ->
        {[exposed_model_id: normalized_model, upstream_model_id: normalized_model],
         projection_cache}

      %{exposed_model_id: exposed_model_id, upstream_model_id: upstream_model_id} ->
        normalize_catalog_aliases(exposed_model_id, upstream_model_id, projection_cache)
    end
  end

  defp normalize_catalog_aliases(exposed_model_id, upstream_model_id, projection_cache) do
    with {:ok, exposed_model_id} <- normalize_concrete_alias(exposed_model_id),
         {:ok, upstream_model_id} <- normalize_concrete_alias(upstream_model_id) do
      {[exposed_model_id: exposed_model_id, upstream_model_id: upstream_model_id],
       projection_cache}
    else
      _malformed_alias -> {:invalid_concrete_model, projection_cache}
    end
  end

  defp normalize_concrete_alias(alias_value) do
    case normalize_alias(alias_value) do
      nil -> :error
      alias_value -> {:ok, alias_value}
    end
  end

  defp normalize_alias(alias_value) when is_binary(alias_value) do
    alias_value
    |> String.trim()
    |> case do
      "" -> nil
      alias_value -> String.downcase(alias_value)
    end
  end

  defp normalize_alias(_alias_value), do: nil
end
