defmodule CodexPooler.Upstreams.SavedResets.AutoEligibility do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Quotas.WindowClassifier
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility.Context
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @max_weekly_reset_seconds 7 * 24 * 60 * 60 + 60 * 60
  @last_call_seconds 90 * 60
  @assignment_active PoolUpstreamAssignment.active_status()
  @identity_active UpstreamIdentity.active_status()
  @type trigger :: Context.trigger()
  @type context :: Context.t()
  @type validation_result :: :ok | {:noop, String.t()} | {:error, :redemption_in_progress}
  @type scheduled_burn_context :: %{
          required(:trigger_detail) => String.t(),
          required(:used_percent_at_decision) => Decimal.t(),
          required(:credit_expires_at_at_decision) => DateTime.t(),
          required(:natural_reset_at_decision) => DateTime.t(),
          required(:decided_at) => DateTime.t()
        }
  @type scheduled_burn_reason ::
          :burn_condition_absent | :expiration_stale | :natural_reset_buffer
  @type scheduled_burn_result ::
          {:burn, scheduled_burn_context()} | {:not_ready, scheduled_burn_reason()}
  @type scheduled_validation_result ::
          {:ok, scheduled_burn_context()}
          | {:noop, String.t()}
          | {:error, :redemption_in_progress}

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
      latch = identity_consume_latch(identity, timestamp)

      latched_identity_ids =
        latched_candidate_identity_ids(context.candidate_identity_ids, identity, latch, timestamp)

      windows_by_identity_id =
        context.candidate_identity_ids
        |> Windows.list_evidence_by_identity_ids()
        |> compatible_source_windows_by_identity(snapshot, timestamp)

      identity_windows = Map.get(windows_by_identity_id, identity.id, [])

      cond do
        not policy.enabled? ->
          {:noop, "gateway_auto_policy_disabled"}

        latch == :blocked_awaiting_quota ->
          {:noop, "gateway_auto_awaiting_post_consume_quota"}

        latch == :cooldown ->
          {:noop, "gateway_auto_consume_cooldown"}

        not saved_reset_available?(snapshot, policy) ->
          unavailable_snapshot_result(snapshot)

        trigger_current?(
          trigger,
          identity,
          policy,
          windows_by_identity_id,
          identity_windows,
          latched_identity_ids,
          context,
          timestamp
        ) ->
          :ok

        true ->
          {:noop, "gateway_auto_trigger_not_current"}
      end
    end
  end

  @doc """
  Cheap post-reconciliation gate for traffic-independent expiry rescue.

  It reads only the persisted identity projection and that identity's quota
  evidence. The scheduled redemption transaction repeats every condition after
  locking the identity and assignment.
  """
  @spec scheduled_expiry_candidate?(UpstreamIdentity.t(), DateTime.t()) :: boolean()
  def scheduled_expiry_candidate?(
        %UpstreamIdentity{} = identity,
        %DateTime{} = timestamp
      ) do
    policy = SavedResets.auto_policy(identity)
    snapshot = SavedResets.snapshot(identity, timestamp)

    identity.status == @identity_active and policy.enabled? and
      scheduled_redemption_state(
        identity,
        snapshot,
        timestamp,
        SavedResets.redemption_receive_timeout_ms()
      ) == :clear and
      scheduled_saved_reset_state(snapshot, policy) == :available and
      SavedResets.expires_soon?(identity, timestamp) and
      identity
      |> Windows.list_evidence()
      |> scheduled_burn(snapshot, policy, timestamp)
      |> burn_ready?()
  end

  @spec validate_locked_scheduled_expiry(
          UpstreamIdentity.t(),
          PoolUpstreamAssignment.t(),
          Ecto.UUID.t(),
          DateTime.t(),
          non_neg_integer()
        ) :: scheduled_validation_result()
  def validate_locked_scheduled_expiry(
        %UpstreamIdentity{} = identity,
        %PoolUpstreamAssignment{} = assignment,
        expected_identity_id,
        %DateTime{} = timestamp,
        receive_timeout
      )
      when is_integer(receive_timeout) and receive_timeout >= 0 do
    with :ok <- validate_locked_scheduled_lifecycle(identity, assignment, expected_identity_id) do
      policy = SavedResets.auto_policy(identity)
      snapshot = SavedResets.snapshot(identity, timestamp)

      with :ok <- scheduled_policy_result(policy),
           :ok <-
             identity
             |> scheduled_redemption_state(snapshot, timestamp, receive_timeout)
             |> scheduled_redemption_result(),
           :ok <-
             snapshot |> scheduled_saved_reset_state(policy) |> scheduled_saved_reset_result(),
           :ok <- scheduled_expiry_result(identity, timestamp) do
        identity
        |> Windows.list_evidence()
        |> scheduled_burn(snapshot, policy, timestamp)
        |> scheduled_burn_result()
      end
    end
  end

  defp compatible_source_windows(windows, %{source: source}) when is_binary(source) do
    Enum.filter(windows, &(&1.source == source))
  end

  defp compatible_source_windows(windows, _snapshot), do: windows

  defp compatible_source_windows_by_identity(windows_by_identity_id, snapshot, timestamp) do
    Map.new(windows_by_identity_id, fn {identity_id, windows} ->
      {identity_id, effective_source_windows(windows, snapshot, timestamp)}
    end)
  end

  defp effective_source_windows(windows, snapshot, timestamp) do
    windows
    |> Windows.reject_superseded_primary_windows(timestamp)
    |> compatible_source_windows(snapshot)
    |> WindowSelector.logical_windows(timestamp)
  end

  @spec validate_locked_lifecycle(UpstreamIdentity.t(), PoolUpstreamAssignment.t()) ::
          :ok | {:noop, String.t()}
  defp validate_locked_lifecycle(identity, assignment) do
    cond do
      identity.status in [UpstreamIdentity.deleted_status(), UpstreamIdentity.disabled_status()] ->
        {:noop, "gateway_auto_identity_unavailable"}

      assignment.status != @assignment_active ->
        {:noop, "gateway_auto_assignment_unavailable"}

      assignment.upstream_identity_id != identity.id ->
        {:noop, "gateway_auto_context_mismatch"}

      true ->
        :ok
    end
  end

  defp validate_locked_scheduled_lifecycle(identity, assignment, expected_identity_id) do
    cond do
      identity.status != @identity_active ->
        {:noop, "scheduled_expiry_identity_unavailable"}

      assignment.status != @assignment_active ->
        {:noop, "scheduled_expiry_assignment_unavailable"}

      identity.id != expected_identity_id or
          assignment.upstream_identity_id != expected_identity_id ->
        {:noop, "scheduled_expiry_identity_mismatch"}

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
    # Compatibility projection outside an explicit candidate scan. Scan and
    # redemption validation paths pass their owned timestamp through /3.
    saved_reset_available?(
      identity,
      policy,
      DateTime.utc_now() |> DateTime.truncate(:microsecond)
    )
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

  @spec saved_reset_available?(
          UpstreamIdentity.t(),
          SavedResets.auto_policy_projection(),
          DateTime.t()
        ) :: boolean()
  def saved_reset_available?(
        %UpstreamIdentity{} = identity,
        policy,
        %DateTime{} = timestamp
      ) do
    identity
    |> SavedResets.snapshot(timestamp)
    |> saved_reset_available?(policy)
  end

  @doc """
  Cheap pre-lock gate for automatic redemption candidates: bank availability
  plus the post-consume latch. Keeps latched identities from opening a claim
  transaction (identity and assignment `FOR UPDATE`) on every routed request
  while quota evidence converges; the authoritative check runs again under the
  lock in `validate_locked_gateway_auto/4`.
  """
  @spec gateway_auto_ready?(
          UpstreamIdentity.t(),
          SavedResets.auto_policy_projection(),
          DateTime.t()
        ) :: boolean()
  def gateway_auto_ready?(%UpstreamIdentity{} = identity, policy, %DateTime{} = timestamp) do
    saved_reset_available?(identity, policy, timestamp) and
      identity_consume_latch(identity, timestamp) == :clear
  end

  @doc """
  The automatic-consume latch state for one identity, from its persisted
  redemption record.
  """
  @spec identity_consume_latch(UpstreamIdentity.t(), DateTime.t()) ::
          :blocked_awaiting_quota | :cooldown | :clear
  def identity_consume_latch(%UpstreamIdentity{} = identity, %DateTime{} = timestamp) do
    (identity.metadata || %{})
    |> Map.get("saved_reset_redemption")
    |> RedemptionLifecycle.gateway_auto_latch(timestamp)
  end

  # One bounded metadata read for the other candidates so the under-lock
  # threshold evaluation and the cheap pre-lock evaluation exclude the same
  # latched identities. Runs only on redemption claims, never per request.
  defp latched_candidate_identity_ids(candidate_identity_ids, identity, latch, timestamp) do
    own = if latch == :clear, do: [], else: [identity.id]

    others =
      candidate_identity_ids
      |> Enum.reject(&(&1 == identity.id))
      |> latched_ids_from_metadata(timestamp)

    MapSet.new(own ++ others)
  end

  defp latched_ids_from_metadata([], _timestamp), do: []

  defp latched_ids_from_metadata(identity_ids, timestamp) do
    from(candidate in UpstreamIdentity,
      where: candidate.id in ^identity_ids,
      select: {candidate.id, candidate.metadata}
    )
    |> Repo.all()
    |> Enum.filter(fn {_id, metadata} -> metadata_latched?(metadata, timestamp) end)
    |> Enum.map(fn {id, _metadata} -> id end)
  end

  defp metadata_latched?(metadata, timestamp) do
    record = (metadata || %{})["saved_reset_redemption"]
    RedemptionLifecycle.gateway_auto_latch(record, timestamp) != :clear
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
          MapSet.t(Ecto.UUID.t()),
          DateTime.t()
        ) :: boolean()
  def threshold_pressure?(
        candidate_identity_ids,
        policy,
        windows_by_identity_id,
        latched_identity_ids,
        %DateTime{} = timestamp
      )
      when is_list(candidate_identity_ids) and is_map(windows_by_identity_id) and
             is_struct(latched_identity_ids, MapSet) do
    # A latched identity just spent a credit, so its pre-reset windows are
    # exactly the evidence the latch distrusts: leave it out of the pool-wide
    # computation entirely, so its stale pressure neither arms a consume on a
    # sibling nor vetoes the trigger for healthy siblings. A pool whose every
    # candidate is latched cannot trigger.
    active_candidate_ids =
      Enum.reject(candidate_identity_ids, &(&1 in latched_identity_ids))

    active_candidate_ids != [] and policy.trigger_mode == "threshold" and
      Enum.all?(active_candidate_ids, fn identity_id ->
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
         latched_identity_ids,
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
          latched_identity_ids,
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

  defp scheduled_saved_reset_state(snapshot, policy) do
    cond do
      not is_integer(snapshot.available_count) -> :unavailable
      snapshot.available_count <= policy.keep_credits -> :keep
      true -> :available
    end
  end

  defp scheduled_policy_result(%{enabled?: true}), do: :ok
  defp scheduled_policy_result(_policy), do: {:noop, "scheduled_expiry_policy_disabled"}

  defp scheduled_redemption_result(:clear), do: :ok
  defp scheduled_redemption_result(:in_progress), do: {:error, :redemption_in_progress}
  defp scheduled_redemption_result(:stale), do: {:noop, "scheduled_expiry_redemption_stale"}

  defp scheduled_redemption_result(:invalid),
    do: {:noop, "scheduled_expiry_lifecycle_unavailable"}

  defp scheduled_redemption_result(:latched),
    do: {:noop, "scheduled_expiry_consume_latched"}

  defp scheduled_saved_reset_result(:available), do: :ok

  defp scheduled_saved_reset_result(:unavailable),
    do: {:noop, "scheduled_expiry_saved_reset_unavailable"}

  defp scheduled_saved_reset_result(:keep), do: {:noop, "scheduled_expiry_keep_credits"}

  defp scheduled_expiry_result(identity, timestamp) do
    if SavedResets.expires_soon?(identity, timestamp),
      do: :ok,
      else: {:noop, "scheduled_expiry_not_expiring"}
  end

  defp scheduled_redemption_state(identity, snapshot, timestamp, receive_timeout) do
    redemption = (identity.metadata || %{})["saved_reset_redemption"]

    case scheduled_claim_state(redemption, timestamp, receive_timeout) do
      :clear -> scheduled_non_claim_state(identity, redemption, snapshot, timestamp)
      state -> state
    end
  end

  defp scheduled_claim_state(redemption, timestamp, receive_timeout) do
    cond do
      RedemptionLifecycle.phase(redemption) == :unknown ->
        :invalid

      active_claim?(redemption) and
          fresh_claim?(redemption, timestamp, receive_timeout) ->
        :in_progress

      active_claim?(redemption) ->
        :stale

      true ->
        :clear
    end
  end

  defp scheduled_non_claim_state(identity, redemption, snapshot, timestamp) do
    cond do
      RedemptionLifecycle.blocks_new_redemption?(redemption, timestamp) ->
        :latched

      identity_consume_latch(identity, timestamp) != :clear ->
        :latched

      snapshot.in_progress? ->
        :in_progress

      snapshot.redemption_stale? ->
        :stale

      true ->
        :clear
    end
  end

  defp active_claim?(%{"status" => "redeeming"} = redemption) do
    RedemptionLifecycle.phase(redemption) in [nil, RedemptionLifecycle.consuming()]
  end

  defp active_claim?(_redemption), do: false

  defp fresh_claim?(%{"started_at" => started_at}, timestamp, receive_timeout)
       when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, started_at, _offset} ->
        DateTime.diff(timestamp, started_at, :millisecond) <
          receive_timeout + SavedResets.redemption_stale_grace_ms()

      _invalid ->
        false
    end
  end

  defp fresh_claim?(_redemption, _timestamp, _receive_timeout), do: false

  @doc false
  @spec scheduled_weekly_eligibility(
          [AccountQuotaWindow.t()],
          SavedResets.snapshot_projection(),
          DateTime.t()
        ) :: {:eligible, [AccountQuotaWindow.t()]} | :unavailable
  def scheduled_weekly_eligibility(windows, snapshot, %DateTime{} = timestamp)
      when is_list(windows) do
    usable_windows =
      windows
      |> Windows.reject_superseded_primary_windows(timestamp)
      |> compatible_source_windows(snapshot)
      |> Enum.filter(&scheduled_usable_weekly_window?(&1, timestamp))

    if usable_windows == [], do: :unavailable, else: {:eligible, usable_windows}
  end

  @spec scheduled_burn_condition(
          [AccountQuotaWindow.t()],
          SavedResets.auto_policy_projection(),
          SavedResets.snapshot_projection(),
          DateTime.t()
        ) :: scheduled_burn_result()
  def scheduled_burn_condition(windows, policy, snapshot, %DateTime{} = timestamp)
      when is_list(windows) and is_map(policy) and is_map(snapshot) do
    credit_expires_at = scheduled_credit_expires_at(snapshot.next_expires_at)
    expiration_fresh? = SavedResets.expiration_observation_fresh?(snapshot, timestamp)
    comparison_timestamp = DateTime.truncate(timestamp, :second)
    future_expiration? = future_expiration?(credit_expires_at, comparison_timestamp)

    conditions = %{
      exhausted:
        exhausted_burn_windows(
          windows,
          policy,
          credit_expires_at,
          expiration_fresh?,
          future_expiration?,
          comparison_timestamp
        ),
      threshold:
        threshold_burn_windows(windows, policy, future_expiration?, comparison_timestamp),
      last_call:
        last_call_burn_windows(
          windows,
          credit_expires_at,
          expiration_fresh?,
          comparison_timestamp
        )
    }

    case winning_burn_condition(conditions) do
      {trigger_detail, qualifying_windows} ->
        burn_context(trigger_detail, qualifying_windows, credit_expires_at, timestamp)

      nil ->
        {:not_ready,
         burn_not_ready_reason(
           windows,
           policy,
           credit_expires_at,
           expiration_fresh?,
           future_expiration?,
           comparison_timestamp
         )}
    end
  end

  defp exhausted_burn_windows(
         windows,
         policy,
         credit_expires_at,
         expiration_fresh?,
         true,
         timestamp
       ) do
    Enum.filter(windows, fn window ->
      used_percent_exhausted?(window.used_percent) and
        (natural_reset_far_enough?(window.reset_at, policy.min_blocked_minutes, timestamp) or
           expiration_before_reset?(credit_expires_at, window.reset_at, expiration_fresh?))
    end)
  end

  defp exhausted_burn_windows(
         _windows,
         _policy,
         _credit_expires_at,
         _expiration_fresh?,
         false,
         _timestamp
       ),
       do: []

  defp threshold_burn_windows(
         windows,
         %{trigger_mode: "threshold"} = policy,
         true,
         timestamp
       ) do
    Enum.filter(windows, fn window ->
      used_percent_at_or_above?(window.used_percent, policy.quota_threshold_percent) and
        natural_reset_far_enough?(window.reset_at, policy.min_blocked_minutes, timestamp)
    end)
  end

  defp threshold_burn_windows(_windows, _policy, _future_expiration?, _timestamp), do: []

  defp last_call_burn_windows(windows, credit_expires_at, expiration_fresh?, timestamp) do
    Enum.filter(windows, fn window ->
      used_percent_above_zero?(window.used_percent) and
        last_call_expiration?(credit_expires_at, timestamp) and
        expiration_before_reset?(credit_expires_at, window.reset_at, expiration_fresh?)
    end)
  end

  defp winning_burn_condition(%{exhausted: [_window | _rest] = windows}),
    do: {"exhausted", windows}

  defp winning_burn_condition(%{threshold: [_window | _rest] = windows}),
    do: {"threshold", windows}

  defp winning_burn_condition(%{last_call: [_window | _rest] = windows}),
    do: {"last_call", windows}

  defp winning_burn_condition(_conditions), do: nil

  defp burn_context(trigger_detail, windows, {:ok, credit_expires_at}, timestamp) do
    evidence_window = select_scheduled_evidence_window(windows)

    {:burn,
     %{
       trigger_detail: trigger_detail,
       used_percent_at_decision: evidence_window.used_percent,
       credit_expires_at_at_decision: credit_expires_at,
       natural_reset_at_decision: evidence_window.reset_at,
       decided_at: timestamp
     }}
  end

  defp burn_context(_trigger_detail, _windows, :error, _timestamp),
    do: {:not_ready, :expiration_stale}

  defp burn_not_ready_reason(
         windows,
         policy,
         credit_expires_at,
         expiration_fresh?,
         future_expiration?,
         timestamp
       ) do
    cond do
      future_expiration? and
          expiration_stale_blocker?(
            windows,
            policy,
            credit_expires_at,
            expiration_fresh?,
            timestamp
          ) ->
        :expiration_stale

      future_expiration? and
          natural_reset_blocker?(windows, policy, credit_expires_at, timestamp) ->
        :natural_reset_buffer

      true ->
        :burn_condition_absent
    end
  end

  defp expiration_stale_blocker?(
         windows,
         policy,
         credit_expires_at,
         expiration_fresh?,
         timestamp
       ) do
    not expiration_fresh? and
      (possible_exhausted_bypass?(windows, policy, credit_expires_at, timestamp) or
         possible_last_call_burn?(windows, credit_expires_at, timestamp))
  end

  defp possible_exhausted_bypass?(_windows, _policy, :error, _timestamp), do: false

  defp possible_exhausted_bypass?(windows, policy, {:ok, credit_expires_at}, timestamp) do
    Enum.any?(windows, fn window ->
      used_percent_exhausted?(window.used_percent) and
        not natural_reset_far_enough?(window.reset_at, policy.min_blocked_minutes, timestamp) and
        expiration_before_reset?(credit_expires_at, window.reset_at)
    end)
  end

  defp possible_last_call_burn?(_windows, :error, _timestamp), do: false

  defp possible_last_call_burn?(windows, {:ok, credit_expires_at}, timestamp) do
    last_call_expiration?({:ok, credit_expires_at}, timestamp) and
      Enum.any?(windows, fn window ->
        used_percent_above_zero?(window.used_percent) and
          expiration_before_reset?(credit_expires_at, window.reset_at)
      end)
  end

  defp natural_reset_blocker?(windows, policy, credit_expires_at, timestamp) do
    exhausted_or_threshold_buffer_blocked?(windows, policy, timestamp) or
      last_call_reset_first?(windows, credit_expires_at, timestamp)
  end

  defp exhausted_or_threshold_buffer_blocked?(windows, policy, timestamp) do
    Enum.any?(windows, fn window ->
      (used_percent_exhausted?(window.used_percent) or
         threshold_candidate?(window, policy)) and
        not natural_reset_far_enough?(window.reset_at, policy.min_blocked_minutes, timestamp)
    end)
  end

  defp threshold_candidate?(window, %{trigger_mode: "threshold"} = policy),
    do: used_percent_at_or_above?(window.used_percent, policy.quota_threshold_percent)

  defp threshold_candidate?(_window, _policy), do: false

  defp last_call_reset_first?(windows, {:ok, credit_expires_at}, timestamp) do
    last_call_expiration?({:ok, credit_expires_at}, timestamp) and
      Enum.any?(windows, fn window ->
        used_percent_above_zero?(window.used_percent) and
          not expiration_before_reset?(credit_expires_at, window.reset_at)
      end)
  end

  defp last_call_reset_first?(_windows, _credit_expires_at, _timestamp), do: false

  defp last_call_expiration?({:ok, credit_expires_at}, timestamp) do
    seconds_until_expiration = whole_second_diff(credit_expires_at, timestamp)
    seconds_until_expiration > 0 and seconds_until_expiration <= @last_call_seconds
  end

  defp last_call_expiration?(_credit_expires_at, _timestamp), do: false

  defp future_expiration?({:ok, credit_expires_at}, timestamp),
    do: whole_second_diff(credit_expires_at, timestamp) > 0

  defp future_expiration?(_credit_expires_at, _timestamp), do: false

  defp expiration_before_reset?({:ok, credit_expires_at}, reset_at, true),
    do: expiration_before_reset?(credit_expires_at, reset_at)

  defp expiration_before_reset?(_credit_expires_at, _reset_at, _expiration_fresh?), do: false

  defp expiration_before_reset?(%DateTime{} = credit_expires_at, %DateTime{} = reset_at),
    do:
      DateTime.before?(
        DateTime.truncate(credit_expires_at, :second),
        DateTime.truncate(reset_at, :second)
      )

  defp expiration_before_reset?(_credit_expires_at, _reset_at), do: false

  defp whole_second_diff(left, right) do
    DateTime.diff(DateTime.truncate(left, :second), DateTime.truncate(right, :second), :second)
  end

  @spec scheduled_burn(
          [AccountQuotaWindow.t()],
          SavedResets.snapshot_projection(),
          SavedResets.auto_policy_projection(),
          DateTime.t()
        ) :: scheduled_burn_result()
  defp scheduled_burn(windows, snapshot, policy, timestamp) do
    case scheduled_weekly_eligibility(windows, snapshot, timestamp) do
      {:eligible, eligible_windows} ->
        scheduled_burn_condition(eligible_windows, policy, snapshot, timestamp)

      :unavailable ->
        {:not_ready, :burn_condition_absent}
    end
  end

  defp scheduled_credit_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, credit_expires_at, _offset} -> {:ok, credit_expires_at}
      _invalid -> :error
    end
  end

  defp scheduled_credit_expires_at(_value), do: :error

  defp select_scheduled_evidence_window([window | windows]) do
    Enum.reduce(windows, window, fn candidate, selected ->
      case Decimal.compare(candidate.used_percent, selected.used_percent) do
        :gt -> candidate
        :lt -> selected
        :eq -> select_latest_reset(candidate, selected)
      end
    end)
  end

  defp select_latest_reset(candidate, selected) do
    if DateTime.after?(candidate.reset_at, selected.reset_at), do: candidate, else: selected
  end

  defp scheduled_burn_result({:burn, context}), do: {:ok, context}

  defp scheduled_burn_result({:not_ready, :burn_condition_absent}),
    do: {:noop, "scheduled_expiry_burn_not_ready"}

  defp scheduled_burn_result({:not_ready, :expiration_stale}),
    do: {:noop, "scheduled_expiry_expiration_stale"}

  defp scheduled_burn_result({:not_ready, :natural_reset_buffer}),
    do: {:noop, "scheduled_expiry_natural_reset_buffer"}

  defp burn_ready?({:burn, _context}), do: true
  defp burn_ready?({:not_ready, _reason}), do: false

  defp weekly_usable_window?(window, timestamp) do
    WindowClassifier.weekly_secondary?(window) and
      window.source_precision in ["observed", "authoritative"] and
      Windows.fresh_window?(window, timestamp) and match?(%DateTime{}, window.reset_at)
  end

  defp scheduled_usable_weekly_window?(window, timestamp) do
    weekly_usable_window?(window, timestamp) and used_percent_above_zero?(window.used_percent) and
      future_reset_within_weekly_horizon?(window.reset_at, timestamp)
  end

  defp future_reset_within_weekly_horizon?(%DateTime{} = reset_at, timestamp) do
    seconds_until_reset = DateTime.diff(reset_at, timestamp, :second)
    seconds_until_reset > 0 and seconds_until_reset <= @max_weekly_reset_seconds
  end

  defp future_reset_within_weekly_horizon?(_reset_at, _timestamp), do: false

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
