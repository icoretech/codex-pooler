defmodule CodexPooler.Alerts.EvaluationProjection do
  @moduledoc """
  Builds persisted-state alert evaluation projections for Pools and upstream assignments.
  """

  import Ecto.Query

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @active "active"
  @disabled_assignment_states ~w(deleted disabled)
  @auth_target_states ~w(reauth_required refresh_failed)

  @type projection_cache :: %{
          optional({Ecto.UUID.t() | nil, String.t() | nil}) => [map()]
        }

  @spec pool_from_cache(Ecto.UUID.t() | nil, String.t() | nil, DateTime.t(), projection_cache()) ::
          {map(), projection_cache()}
  def pool_from_cache(pool_id, model, timestamp, projection_cache) do
    {assignments, projection_cache} =
      assigned_identities_from_cache(pool_id, model, timestamp, projection_cache)

    {pool_from_assignments(pool_id, model, assignments), projection_cache}
  end

  @spec assigned_identities_from_cache(
          Ecto.UUID.t() | nil,
          String.t() | nil,
          DateTime.t(),
          projection_cache()
        ) :: {[map()], projection_cache()}
  def assigned_identities_from_cache(pool_id, model, timestamp, projection_cache) do
    cache_key = {pool_id, model}

    case Map.fetch(projection_cache, cache_key) do
      {:ok, assignments} ->
        {assignments, projection_cache}

      :error ->
        assignments = assigned_identities(pool_id, model, timestamp)
        {assignments, Map.put(projection_cache, cache_key, assignments)}
    end
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

  defp pool_from_assignments(pool_id, model, assignments) do
    enabled = Enum.filter(assignments, &enabled_assignment?/1)
    usable = Enum.filter(enabled, & &1.usable_assignment?)

    %{
      pool_id: pool_id,
      model: model,
      assignment_count: length(assignments),
      enabled_assignment_count: length(enabled),
      usable_assignment_count: length(usable),
      state_counts: Enum.frequencies_by(enabled, & &1.state),
      assignments: assignments
    }
  end

  defp assigned_identities(pool_id, model, timestamp) do
    assignments = assignment_rows(pool_id)

    windows_by_identity_id =
      windows_by_identity_id(Enum.map(assignments, & &1.upstream_identity_id))

    Enum.map(assignments, fn row ->
      windows = Map.get(windows_by_identity_id, row.upstream_identity_id, [])
      quota_projection = quota_projection(windows, model, timestamp)

      Map.merge(row, %{
        model: model,
        quota_windows: windows,
        quota: quota_projection,
        state: assignment_state(row, quota_projection),
        usable_assignment?: usable_assignment?(row, quota_projection)
      })
    end)
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

  defp windows_by_identity_id([]), do: %{}

  defp windows_by_identity_id(identity_ids) do
    Quota.AccountQuotaWindow
    |> where([window], window.upstream_identity_id in ^identity_ids)
    |> order_by([window],
      asc: window.quota_key,
      asc: window.window_kind,
      asc: window.window_minutes
    )
    |> Repo.all()
    |> Enum.group_by(& &1.upstream_identity_id)
  end

  defp quota_projection(windows, model, timestamp) do
    opts = model_opts(model) ++ [at: timestamp]
    selection = Quota.Windows.quota_window_selection_data_from_windows(windows, opts)
    eligibility = Quota.Windows.routing_quota_eligibility_from_windows(windows, opts)
    state = quota_state(windows, selection, eligibility, timestamp)

    %{
      state: state,
      routing_usable?: eligibility.eligible?,
      window_count: length(windows),
      selector_windows: selection.routing_windows,
      reason_codes: quota_reason_codes(state, selection, eligibility, timestamp)
    }
  end

  defp quota_state([], _selection, _eligibility, _timestamp), do: "missing_evidence"

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
    |> Enum.flat_map(&Quota.Windows.routing_window_reason_codes(&1, timestamp))
    |> Enum.member?("exhausted")
  end

  defp stale_selection?(selection, timestamp) do
    selection.routing_windows
    |> Enum.flat_map(&Quota.Windows.routing_window_reason_codes(&1, timestamp))
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
      |> Enum.flat_map(&Quota.Windows.routing_window_reason_codes(&1, timestamp))
      |> Enum.uniq()

    if reason_codes == [], do: [state], else: [state | reason_codes]
  end

  defp assignment_state(row, _quota) when row.identity_status in @auth_target_states,
    do: row.identity_status

  defp assignment_state(_row, %{state: state}), do: state

  defp usable_assignment?(row, quota) do
    row.assignment_status == @active and row.health_status == @active and
      row.eligibility_status == "eligible" and row.identity_status == @active and
      quota.routing_usable?
  end

  defp model_opts(nil), do: []
  defp model_opts(model), do: [model: model]
end
