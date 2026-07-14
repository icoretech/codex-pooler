defmodule CodexPooler.Gateway.Routing.SavedResetAutoRedeem do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.QuotaRefresh.{Executor, Plan}
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.ProbeLease
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @spec maybe_redeem_after_quota_exhaustion(term(), map(), :required | :optional) :: term()
  def maybe_redeem_after_quota_exhaustion(result, refresh_plan, quota_mode)

  def maybe_redeem_after_quota_exhaustion(
        {:error, %{code: code} = error} = result,
        refresh_plan,
        :required
      )
      when code in ["quota_exhausted", :quota_exhausted] and is_map(refresh_plan) do
    if all_candidates_excluded_only_by_weekly_exhaustion?(error, refresh_plan) do
      maybe_redeem_candidate(result, refresh_plan, :blocked_weekly_exhaustion)
    else
      result
    end
  end

  def maybe_redeem_after_quota_exhaustion(result, _refresh_plan, _quota_mode), do: result

  @spec maybe_redeem_before_quota_exhaustion(term(), map(), :required | :optional) :: term()
  def maybe_redeem_before_quota_exhaustion(result, refresh_plan, quota_mode)

  def maybe_redeem_before_quota_exhaustion(
        {:ok, _candidates, _decision} = result,
        refresh_plan,
        :required
      )
      when is_map(refresh_plan) do
    maybe_redeem_threshold_candidate(result, refresh_plan)
  end

  def maybe_redeem_before_quota_exhaustion(
        {:ok, _candidates, _decision, %RouteState{}} = result,
        refresh_plan,
        :required
      )
      when is_map(refresh_plan) do
    maybe_redeem_threshold_candidate(result, refresh_plan)
  end

  def maybe_redeem_before_quota_exhaustion(result, _refresh_plan, _quota_mode), do: result

  defp maybe_redeem_candidate(result, refresh_plan, trigger) do
    refresh_plan
    |> candidate_order()
    |> Enum.find(&redeemable_candidate?/1)
    |> case do
      {assignment, identity} ->
        redeem_and_refilter(result, refresh_plan, assignment, identity, trigger)

      nil ->
        result
    end
  end

  defp maybe_redeem_threshold_candidate(result, refresh_plan) do
    candidates = candidate_order(refresh_plan)

    candidates
    |> Enum.find_value(&early_redeemable_candidate(&1, candidates))
    |> case do
      {{assignment, identity}, trigger} ->
        redeem_and_refilter(result, refresh_plan, assignment, identity, trigger)

      nil ->
        result
    end
  end

  defp redeem_and_refilter(result, refresh_plan, assignment, identity, trigger) do
    case SavedResetRedemption.redeem(assignment,
           trigger_kind: "gateway_auto",
           gateway_auto_context:
             gateway_auto_context(refresh_plan, assignment, identity, trigger),
           receive_timeout: 15_000
         ) do
      {:ok, %{applied?: true, code: code} = redeem_result} ->
        log_redemption(assignment, identity, "gateway_auto", code, true)
        route_after_redemption(result, refresh_plan, assignment, redeem_result)

      {:ok, %{applied?: applied?, code: code}} ->
        log_redemption(assignment, identity, "gateway_auto", code, applied?)
        result

      {:error, reason} ->
        log_redemption(assignment, identity, "gateway_auto", safe_reason(reason), false)
        result
    end
  rescue
    exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error] ->
      log_redemption(assignment, identity, "gateway_auto", safe_reason(exception), false)
      result
  end

  # A confirmed redemption (fresh usable quota) can route through the normal
  # refilter. A consumed-but-pending redemption cannot — its quota window still
  # reads exhausted — so the one triggering request claims the irreversible probe
  # and force-routes to the redeemed identity. If the probe was already claimed
  # (another node/request), fall back to the normal refilter.
  defp route_after_redemption(result, refresh_plan, assignment, redeem_result) do
    identity = redeem_result.identity

    if pending_probe?(redeem_result) do
      case claim_probe(identity) do
        {:ok, token} -> force_probe_route(refresh_plan, assignment, identity, token)
        {:error, _reason} -> refilter_after_redemption(result, refresh_plan)
      end
    else
      refilter_after_redemption(result, refresh_plan)
    end
  end

  defp pending_probe?(%{phase: phase}),
    do: phase == RedemptionLifecycle.consumed_pending_probe()

  defp pending_probe?(_redeem_result), do: false

  defp claim_probe(%UpstreamIdentity{} = identity) do
    redemption = (identity.metadata || %{})["saved_reset_redemption"] || %{}
    token = Ecto.UUID.generate()

    case ProbeLease.claim(
           identity,
           redemption["generation"],
           redemption["attempt_id"],
           token
         ) do
      {:ok, :claimed} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp force_probe_route(refresh_plan, assignment, identity, token) do
    candidate = {assignment, identity}
    decision = reset_probe_decision(identity, token)

    case Map.get(refresh_plan, :route_state) do
      %RouteState{} = route_state ->
        {:ok, [candidate], decision, RouteState.put_candidates(route_state, [candidate])}

      _no_route_state ->
        {:ok, [candidate], decision}
    end
  end

  defp reset_probe_decision(%UpstreamIdentity{} = identity, token) do
    %{
      "allowed" => true,
      "routing_state" => "reset_probe",
      "summary" => "guarded probe after saved reset pending confirmation",
      "reset_probe_candidate_count" => 1,
      "reset_probe" => %{
        "token" => token,
        "upstream_identity_id" => identity.id
      }
    }
  end

  defp refilter_after_redemption(
         result,
         %{filter_input: %CandidateEligibility.FilterInput{} = input} = plan
       ) do
    case Map.get(plan, :route_state) do
      %RouteState{} = route_state ->
        refreshed_route_state = RouteState.refresh_quota_window_snapshots(route_state)

        case Plan.filter_eligible_candidates(input, refreshed_route_state) do
          {:refreshable_quota, remaining_plan} ->
            Executor.refresh_stale_candidates(remaining_plan)

          {:ok, candidates, decision} ->
            {:ok, candidates, decision, refreshed_route_state}
        end

      _no_route_state ->
        case Plan.filter_eligible_candidates(input) do
          {:refreshable_quota, remaining_plan} ->
            Executor.refresh_stale_candidates(remaining_plan)

          {:ok, candidates, decision} ->
            {:ok, candidates, decision}
        end
    end
  rescue
    exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error] ->
      Logger.warning("saved reset quota refilter failed reason=#{safe_reason(exception)}")

      result
  end

  defp all_candidates_excluded_only_by_weekly_exhaustion?(error, refresh_plan)
       when is_map(error) do
    exclusions = Map.get(error, :candidate_exclusions) || Map.get(error, "candidate_exclusions")

    candidate_keys =
      refresh_plan
      |> candidate_order()
      |> Enum.map(&candidate_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    exclusion_keys =
      exclusions
      |> List.wrap()
      |> Enum.map(&exclusion_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    MapSet.size(candidate_keys) > 0 and MapSet.equal?(candidate_keys, exclusion_keys) and
      Enum.all?(List.wrap(exclusions), &weekly_account_exhaustion_exclusion?/1)
  end

  defp candidate_order(%{filter_input: %{candidates: candidates}}) when is_list(candidates),
    do: candidates

  defp candidate_order(%{refreshable_candidates: candidates}) when is_list(candidates),
    do: candidates

  defp candidate_order(_refresh_plan), do: []

  defp candidate_key(
         {%PoolUpstreamAssignment{id: assignment_id}, %UpstreamIdentity{id: identity_id}}
       )
       when is_binary(assignment_id) and is_binary(identity_id),
       do: {assignment_id, identity_id}

  defp candidate_key(_candidate), do: nil

  defp gateway_auto_context(refresh_plan, assignment, identity, trigger) do
    candidates = candidate_order(refresh_plan)

    %{
      trigger: trigger,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      candidate_assignment_ids:
        Enum.map(candidates, fn {candidate_assignment, _candidate_identity} ->
          candidate_assignment.id
        end),
      candidate_identity_ids:
        Enum.map(candidates, fn {_candidate_assignment, candidate_identity} ->
          candidate_identity.id
        end),
      route_class: route_class(refresh_plan)
    }
  end

  defp route_class(%{filter_input: %{route_class: route_class}})
       when is_binary(route_class) and route_class != "",
       do: route_class

  defp route_class(%{filter_input: %{request_options: request_options}}),
    do: request_options.transport.route_class

  defp route_class(_refresh_plan), do: "proxy_http"

  defp exclusion_key(exclusion) when is_map(exclusion) do
    assignment_id =
      Map.get(exclusion, :pool_upstream_assignment_id) ||
        Map.get(exclusion, "pool_upstream_assignment_id")

    identity_id =
      Map.get(exclusion, :upstream_identity_id) || Map.get(exclusion, "upstream_identity_id")

    if is_binary(assignment_id) and is_binary(identity_id), do: {assignment_id, identity_id}
  end

  defp exclusion_key(_exclusion), do: nil

  defp weekly_account_exhaustion_exclusion?(exclusion) when is_map(exclusion) do
    reasons = Map.get(exclusion, :reasons) || Map.get(exclusion, "reasons")

    is_list(reasons) and reasons != [] and
      Enum.all?(reasons, &weekly_account_exhaustion_reason?/1)
  end

  defp weekly_account_exhaustion_exclusion?(_exclusion), do: false

  defp weekly_account_exhaustion_reason?(reason) when is_map(reason) do
    reason_code = Map.get(reason, :reason_codes) || Map.get(reason, "reason_codes")

    reason_token(reason, :code) == "quota_weekly_exhausted" and
      reason_token(reason, :quota_key) == "account" and
      reason_token(reason, :window_kind) == "secondary" and
      reason_token(reason, :quota_scope) == "account" and
      reason_token(reason, :quota_family) == "account" and
      exhausted_only_reason_codes?(reason_code)
  end

  defp weekly_account_exhaustion_reason?(_reason), do: false

  defp exhausted_only_reason_codes?(reason_codes) when is_list(reason_codes),
    do: reason_codes != [] and Enum.all?(reason_codes, &(&1 == "exhausted"))

  defp exhausted_only_reason_codes?(_reason_codes), do: false

  defp reason_token(reason, key), do: Map.get(reason, key) || Map.get(reason, Atom.to_string(key))

  defp redeemable_candidate?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity} = candidate
       ) do
    policy = SavedResets.auto_policy(identity)

    saved_reset_available?(identity, policy) and redeemable_weekly_window?(candidate, policy)
  end

  defp redeemable_candidate?(_candidate), do: false

  defp early_redeemable_candidate(candidate, candidates) when is_list(candidates) do
    cond do
      threshold_redeemable_candidate?(candidate, candidates) ->
        {candidate, :threshold_pressure}

      expiring_redeemable_candidate?(candidate) ->
        {candidate, :expiring_reset}

      true ->
        nil
    end
  end

  defp threshold_redeemable_candidate?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity},
         candidates
       )
       when is_list(candidates) do
    policy = SavedResets.auto_policy(identity)

    saved_reset_available?(identity, policy) and policy.trigger_mode == "threshold" and
      all_candidates_at_threshold?(candidates, policy)
  end

  defp threshold_redeemable_candidate?(_candidate, _candidates), do: false

  defp expiring_redeemable_candidate?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity} = candidate
       ) do
    policy = SavedResets.auto_policy(identity)
    timestamp = now()

    saved_reset_available?(identity, policy) and SavedResets.expires_soon?(identity, timestamp) and
      redeemable_expiring_weekly_window?(candidate, policy, timestamp)
  end

  defp expiring_redeemable_candidate?(_candidate), do: false

  defp saved_reset_available?(%UpstreamIdentity{} = identity, policy) do
    AutoEligibility.saved_reset_available?(identity, policy)
  end

  defp redeemable_weekly_window?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity},
         policy
       ) do
    identity
    |> Windows.list_quota_windows()
    |> AutoEligibility.blocked_weekly_exhaustion?(policy, now())
  end

  defp redeemable_expiring_weekly_window?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity},
         policy,
         timestamp
       ) do
    AutoEligibility.expiring_reset?(
      identity,
      Windows.list_quota_windows(identity),
      policy,
      timestamp
    )
  end

  defp all_candidates_at_threshold?([], _policy), do: false

  defp all_candidates_at_threshold?(candidates, policy) when is_list(candidates) do
    candidate_identity_ids =
      candidates
      |> Enum.map(fn {_assignment, identity} -> identity.id end)
      |> Enum.reject(&is_nil/1)

    windows_by_identity_id = Windows.list_quota_windows_by_identity_ids(candidate_identity_ids)

    AutoEligibility.threshold_pressure?(
      candidate_identity_ids,
      policy,
      windows_by_identity_id,
      now()
    )
  end

  defp log_redemption(assignment, identity, trigger_kind, code, applied?) do
    Logger.info(
      "saved reset auto redemption result " <>
        "pool_upstream_assignment_id=#{assignment.id} " <>
        "upstream_identity_id=#{identity.id} " <>
        "trigger_kind=#{trigger_kind} " <>
        "result_code=#{code} " <>
        "applied=#{applied?}"
    )
  end

  defp safe_reason(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp safe_reason(%{code: code}) when is_binary(code), do: sanitize_token(code)
  defp safe_reason(%module{}) when is_atom(module), do: module |> Module.split() |> List.last()
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "unknown"

  defp sanitize_token(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 80)
    |> case do
      "" -> "unknown"
      token -> token
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
