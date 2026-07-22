defmodule CodexPooler.Upstreams.SavedResets.AutoEligibility do
  @moduledoc false

  alias CodexPooler.Quotas.WindowClassifier
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility.Context
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @max_weekly_reset_seconds 7 * 24 * 60 * 60 + 60 * 60
  @assignment_active PoolUpstreamAssignment.active_status()
  @identity_deleted UpstreamIdentity.deleted_status()
  @identity_disabled UpstreamIdentity.disabled_status()

  @type trigger :: Context.trigger()
  @type context :: Context.t()
  @type validation_result :: :ok | {:noop, String.t()} | {:error, :redemption_in_progress}

  @spec normalize_context(term()) :: {:ok, context()} | {:error, :invalid_gateway_auto_context}
  defdelegate normalize_context(context), to: Context, as: :normalize

  @spec validate_locked_gateway_auto(
          UpstreamIdentity.t(),
          PoolUpstreamAssignment.t(),
          context(),
          DateTime.t()
        ) :: validation_result()
  def validate_locked_gateway_auto(
        %UpstreamIdentity{} = identity,
        %PoolUpstreamAssignment{} = assignment,
        %{trigger: trigger} = context,
        %DateTime{} = timestamp
      ) do
    with :ok <- validate_locked_lifecycle(identity, assignment),
         :ok <- validate_context_match(identity, assignment, context) do
      policy = SavedResets.auto_policy(identity)
      snapshot = SavedResets.snapshot(identity, timestamp)

      windows_by_identity_id =
        context.candidate_identity_ids
        |> Windows.list_evidence_by_identity_ids()
        |> compatible_source_windows_by_identity(snapshot, timestamp)

      identity_windows = Map.get(windows_by_identity_id, identity.id, [])

      cond do
        not policy.enabled? ->
          {:noop, "gateway_auto_policy_disabled"}

        not saved_reset_available?(snapshot, policy) ->
          unavailable_snapshot_result(snapshot)

        trigger_current?(
          trigger,
          identity,
          policy,
          windows_by_identity_id,
          identity_windows,
          context,
          timestamp
        ) ->
          :ok

        true ->
          {:noop, "gateway_auto_trigger_not_current"}
      end
    end
  end

  defp compatible_source_windows(windows, %{source: source}) when is_binary(source) do
    Enum.filter(windows, &(&1.source == source))
  end

  defp compatible_source_windows(windows, _snapshot), do: windows

  defp compatible_source_windows_by_identity(windows_by_identity_id, snapshot, timestamp) do
    Map.new(windows_by_identity_id, fn {identity_id, windows} ->
      windows =
        windows
        |> Windows.reject_superseded_primary_windows(timestamp)
        |> compatible_source_windows(snapshot)
        |> WindowSelector.logical_windows(timestamp)

      {identity_id, windows}
    end)
  end

  @spec validate_locked_lifecycle(UpstreamIdentity.t(), PoolUpstreamAssignment.t()) ::
          :ok | {:noop, String.t()}
  defp validate_locked_lifecycle(identity, assignment) do
    cond do
      identity.status in [@identity_deleted, @identity_disabled] ->
        {:noop, "gateway_auto_identity_unavailable"}

      assignment.status != @assignment_active ->
        {:noop, "gateway_auto_assignment_unavailable"}

      assignment.upstream_identity_id != identity.id ->
        {:noop, "gateway_auto_context_mismatch"}

      true ->
        :ok
    end
  end

  @spec validate_context_match(UpstreamIdentity.t(), PoolUpstreamAssignment.t(), context()) ::
          :ok | {:noop, String.t()}
  defp validate_context_match(identity, assignment, context) do
    cond do
      context.pool_upstream_assignment_id != assignment.id or
          context.upstream_identity_id != identity.id ->
        {:noop, "gateway_auto_context_mismatch"}

      assignment.id not in context.candidate_assignment_ids or
          identity.id not in context.candidate_identity_ids ->
        {:noop, "gateway_auto_context_mismatch"}

      true ->
        :ok
    end
  end

  @spec saved_reset_available?(UpstreamIdentity.t(), SavedResets.auto_policy_projection()) ::
          boolean()
  def saved_reset_available?(%UpstreamIdentity{} = identity, policy) do
    identity
    |> SavedResets.snapshot()
    |> saved_reset_available?(policy)
  end

  @spec saved_reset_available?(
          SavedResets.snapshot_projection(),
          SavedResets.auto_policy_projection()
        ) ::
          boolean()
  def saved_reset_available?(snapshot, policy) when is_map(snapshot) and is_map(policy) do
    policy.enabled? and is_integer(snapshot.available_count) and
      snapshot.available_count > policy.keep_credits and not snapshot.in_progress? and
      not snapshot.redemption_stale?
  end

  @spec blocked_weekly_exhaustion?(
          [AccountQuotaWindow.t()],
          SavedResets.auto_policy_projection(),
          DateTime.t()
        ) :: boolean()
  def blocked_weekly_exhaustion?(windows, policy, %DateTime{} = timestamp)
      when is_list(windows) do
    Enum.any?(windows, fn window ->
      weekly_exhausted_window?(window, timestamp) and
        natural_reset_far_enough?(window.reset_at, policy.min_blocked_minutes, timestamp)
    end)
  end

  @spec threshold_pressure?(
          [Ecto.UUID.t()],
          SavedResets.auto_policy_projection(),
          %{optional(Ecto.UUID.t()) => [AccountQuotaWindow.t()]},
          DateTime.t()
        ) :: boolean()
  def threshold_pressure?(
        candidate_identity_ids,
        policy,
        windows_by_identity_id,
        %DateTime{} = timestamp
      )
      when is_list(candidate_identity_ids) and is_map(windows_by_identity_id) do
    candidate_identity_ids != [] and policy.trigger_mode == "threshold" and
      Enum.all?(candidate_identity_ids, fn identity_id ->
        windows_by_identity_id
        |> Map.get(identity_id, [])
        |> Enum.any?(&weekly_pressure_window?(&1, policy, timestamp))
      end)
  end

  @spec expiring_reset?(
          UpstreamIdentity.t(),
          [AccountQuotaWindow.t()],
          SavedResets.auto_policy_projection(),
          DateTime.t()
        ) :: boolean()
  def expiring_reset?(%UpstreamIdentity{} = identity, windows, policy, %DateTime{} = timestamp)
      when is_list(windows) do
    SavedResets.expires_soon?(identity, timestamp) and
      Enum.any?(windows, fn window ->
        weekly_used_window?(window, timestamp) and
          natural_reset_far_enough?(window.reset_at, policy.min_blocked_minutes, timestamp)
      end)
  end

  defp trigger_current?(
         trigger,
         identity,
         policy,
         windows_by_identity_id,
         identity_windows,
         context,
         timestamp
       ) do
    case trigger do
      :blocked_weekly_exhaustion ->
        blocked_weekly_exhaustion?(identity_windows, policy, timestamp)

      :threshold_pressure ->
        threshold_pressure?(
          context.candidate_identity_ids,
          policy,
          windows_by_identity_id,
          timestamp
        )

      :expiring_reset ->
        expiring_reset?(identity, identity_windows, policy, timestamp)
    end
  end

  defp unavailable_snapshot_result(%{in_progress?: true}), do: {:error, :redemption_in_progress}

  defp unavailable_snapshot_result(%{redemption_stale?: true}),
    do: {:error, :redemption_in_progress}

  defp unavailable_snapshot_result(%{available_count: nil}),
    do: {:noop, "gateway_auto_saved_reset_unavailable"}

  defp unavailable_snapshot_result(_snapshot), do: {:noop, "gateway_auto_keep_credits"}

  defp weekly_pressure_window?(window, policy, timestamp) do
    weekly_usable_window?(window, timestamp) and
      used_percent_at_or_above?(window.used_percent, policy.quota_threshold_percent) and
      natural_reset_far_enough?(window.reset_at, policy.min_blocked_minutes, timestamp)
  end

  defp weekly_used_window?(window, timestamp) do
    weekly_usable_window?(window, timestamp) and used_percent_above_zero?(window.used_percent)
  end

  defp weekly_usable_window?(window, timestamp) do
    WindowClassifier.weekly_secondary?(window) and
      window.source_precision in ["observed", "authoritative"] and
      Windows.fresh_window?(window, timestamp) and match?(%DateTime{}, window.reset_at)
  end

  defp weekly_exhausted_window?(window, timestamp) do
    WindowClassifier.weekly_secondary?(window) and match?(%DateTime{}, window.reset_at) and
      used_percent_exhausted?(window.used_percent) and
      "exhausted" in Windows.routing_window_reason_codes(window, timestamp)
  end

  defp used_percent_at_or_above?(%Decimal{} = used_percent, threshold) when is_integer(threshold),
    do: Decimal.compare(used_percent, Decimal.new(threshold)) != :lt

  defp used_percent_at_or_above?(value, threshold)
       when is_number(value) and is_integer(threshold),
       do: value >= threshold

  defp used_percent_at_or_above?(_value, _threshold), do: false

  defp used_percent_above_zero?(%Decimal{} = used_percent),
    do: Decimal.compare(used_percent, Decimal.new(0)) == :gt

  defp used_percent_above_zero?(value) when is_number(value), do: value > 0
  defp used_percent_above_zero?(_value), do: false

  defp used_percent_exhausted?(%Decimal{} = used_percent),
    do: Decimal.compare(used_percent, Decimal.new(100)) != :lt

  defp used_percent_exhausted?(value) when is_number(value), do: value >= 100
  defp used_percent_exhausted?(_value), do: false

  defp natural_reset_far_enough?(%DateTime{} = reset_at, min_blocked_minutes, timestamp) do
    seconds_until_reset = DateTime.diff(reset_at, timestamp, :second)

    seconds_until_reset >= min_blocked_minutes * 60 and
      seconds_until_reset <= @max_weekly_reset_seconds
  end

  defp natural_reset_far_enough?(_reset_at, _min_blocked_minutes, _timestamp), do: false
end
