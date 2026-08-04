defmodule CodexPooler.Gateway.Routing.SavedResetAutoRedeem do
  @moduledoc false

  require Logger

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.QuotaRefresh.{Executor, Plan}
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.ProbeLease
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @type refilter_clock :: (-> DateTime.t())
  @type refilter_option :: {:refilter_clock, refilter_clock()}
  @type refilter_options :: [refilter_option()]

  @spec maybe_redeem_after_quota_exhaustion(term(), map(), :required | :optional) :: term()
  def maybe_redeem_after_quota_exhaustion(result, refresh_plan, quota_mode) do
    # Compatibility entry point for callers outside RouteFiltering's explicit
    # candidate scan. The routed cycle always calls /4 with its owned timestamp.
    maybe_redeem_after_quota_exhaustion(result, refresh_plan, quota_mode, now())
  end

  @spec maybe_redeem_after_quota_exhaustion(
          term(),
          map(),
          :required | :optional,
          DateTime.t()
        ) :: term()
  def maybe_redeem_after_quota_exhaustion(
        result,
        refresh_plan,
        quota_mode,
        %DateTime{} = timestamp
      ) do
    maybe_redeem_after_quota_exhaustion(result, refresh_plan, quota_mode, timestamp, [])
  end

  @doc false
  @spec maybe_redeem_after_quota_exhaustion(
          term(),
          map(),
          :required | :optional,
          DateTime.t(),
          refilter_options()
        ) :: term()
  def maybe_redeem_after_quota_exhaustion(
        {:error, %{code: code} = error} = result,
        refresh_plan,
        :required,
        %DateTime{} = timestamp,
        opts
      )
      when code in ["quota_exhausted", :quota_exhausted] and is_map(refresh_plan) and
             is_list(opts) do
    if all_candidates_excluded_only_by_weekly_exhaustion?(error, refresh_plan) do
      maybe_redeem_candidate(result, refresh_plan, :blocked_weekly_exhaustion, timestamp, opts)
    else
      result
    end
  end

  def maybe_redeem_after_quota_exhaustion(
        result,
        _refresh_plan,
        _quota_mode,
        %DateTime{},
        opts
      )
      when is_list(opts),
      do: result

  @spec maybe_redeem_before_quota_exhaustion(term(), map(), :required | :optional) :: term()
  def maybe_redeem_before_quota_exhaustion(result, refresh_plan, quota_mode) do
    # Compatibility entry point for callers outside RouteFiltering's explicit
    # candidate scan. The routed cycle always calls /4 with its owned timestamp.
    maybe_redeem_before_quota_exhaustion(result, refresh_plan, quota_mode, now())
  end

  @spec maybe_redeem_before_quota_exhaustion(
          term(),
          map(),
          :required | :optional,
          DateTime.t()
        ) :: term()
  def maybe_redeem_before_quota_exhaustion(
        result,
        refresh_plan,
        quota_mode,
        %DateTime{} = timestamp
      ) do
    maybe_redeem_before_quota_exhaustion(result, refresh_plan, quota_mode, timestamp, [])
  end

  @doc false
  @spec maybe_redeem_before_quota_exhaustion(
          term(),
          map(),
          :required | :optional,
          DateTime.t(),
          refilter_options()
        ) :: term()
  def maybe_redeem_before_quota_exhaustion(
        {:ok, _candidates, _decision} = result,
        refresh_plan,
        :required,
        %DateTime{} = timestamp,
        opts
      )
      when is_map(refresh_plan) and is_list(opts) do
    maybe_redeem_threshold_candidate(result, refresh_plan, timestamp, opts)
  end

  def maybe_redeem_before_quota_exhaustion(
        {:ok, _candidates, _decision, %RouteState{}} = result,
        refresh_plan,
        :required,
        %DateTime{} = timestamp,
        opts
      )
      when is_map(refresh_plan) and is_list(opts) do
    maybe_redeem_threshold_candidate(result, refresh_plan, timestamp, opts)
  end

  def maybe_redeem_before_quota_exhaustion(
        result,
        _refresh_plan,
        _quota_mode,
        %DateTime{},
        opts
      )
      when is_list(opts),
      do: result

  defp maybe_redeem_candidate(result, refresh_plan, trigger, timestamp, opts) do
    refresh_plan
    |> candidate_order()
    |> Enum.find(&redeemable_candidate?(&1, timestamp))
    |> case do
      {assignment, identity} ->
        redeem_and_refilter(result, refresh_plan, assignment, identity, trigger, timestamp, opts)

      nil ->
        result
    end
  end

  defp maybe_redeem_threshold_candidate(result, refresh_plan, timestamp, opts) do
    candidates = candidate_order(refresh_plan)

    candidates
    |> Enum.find_value(&early_redeemable_candidate(&1, candidates, timestamp))
    |> case do
      {{assignment, identity}, trigger} ->
        redeem_and_refilter(result, refresh_plan, assignment, identity, trigger, timestamp, opts)

      nil ->
        result
    end
  end

  defp redeem_and_refilter(
         result,
         refresh_plan,
         assignment,
         identity,
         trigger,
         scan_timestamp,
         opts
       ) do
    trigger_detail = trigger_detail(trigger)

    case SavedResetRedemption.redeem(assignment,
           trigger_kind: "gateway_auto",
           started_at: scan_timestamp,
           gateway_auto_context:
             gateway_auto_context(refresh_plan, assignment, identity, trigger),
           receive_timeout: 15_000
         ) do
      {:ok, %{applied?: true, code: code} = redeem_result} ->
        log_redemption(assignment, identity, "gateway_auto", trigger_detail, code, true)

        route_after_redemption(
          result,
          refresh_plan,
          assignment,
          redeem_result,
          scan_timestamp,
          opts
        )

      {:ok, %{applied?: applied?, code: code}} ->
        log_redemption(assignment, identity, "gateway_auto", trigger_detail, code, applied?)
        result

      {:error, reason} ->
        log_redemption(
          assignment,
          identity,
          "gateway_auto",
          trigger_detail,
          safe_reason(reason),
          false
        )

        result
    end
  rescue
    exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error] ->
      log_redemption(
        assignment,
        identity,
        "gateway_auto",
        trigger_detail(trigger),
        safe_reason(exception),
        false
      )

      result
  end

  # A confirmed redemption (fresh usable quota) can route through the normal
  # refilter. A consumed-but-pending redemption cannot — its quota window still
  # reads exhausted — so the one triggering request claims the irreversible probe
  # and force-routes to the redeemed identity. If the probe was already claimed
  # (another node/request), fall back to the normal refilter.
  defp route_after_redemption(
         result,
         refresh_plan,
         assignment,
         redeem_result,
         scan_timestamp,
         opts
       ) do
    identity = redeem_result.identity

    if pending_probe?(redeem_result) do
      case claim_probe(refresh_plan, assignment, identity) do
        {:ok, probe} ->
          force_probe_route(refresh_plan, assignment, identity, probe)

        {:error, _reason} ->
          refilter_after_redemption(result, refresh_plan, scan_timestamp, opts)
      end
    else
      refilter_after_redemption(result, refresh_plan, scan_timestamp, opts)
    end
  end

  defp pending_probe?(%{phase: phase}),
    do: phase == RedemptionLifecycle.consumed_pending_probe()

  defp pending_probe?(_redeem_result), do: false

  defp claim_probe(refresh_plan, assignment, %UpstreamIdentity{} = identity) do
    redemption = (identity.metadata || %{})["saved_reset_redemption"] || %{}

    with %ResetProbe{} = probe <- reset_probe(refresh_plan),
         {:ok, bound_probe} <-
           ResetProbe.bind(
             probe,
             assignment.id,
             identity.id,
             effective_model(refresh_plan),
             route_class(refresh_plan)
           ),
         {:ok, :claimed} <-
           ProbeLease.claim(
             identity,
             redemption["generation"],
             redemption["attempt_id"],
             bound_probe
           ) do
      {:ok, bound_probe}
    else
      {:error, reason} -> {:error, reason}
      _missing_probe -> {:error, :invalid_scope}
    end
  end

  defp force_probe_route(refresh_plan, assignment, identity, %ResetProbe{} = probe) do
    candidate = {assignment, identity}
    decision = reset_probe_decision()

    case Map.get(refresh_plan, :route_state) do
      %RouteState{} = route_state ->
        route_state =
          route_state
          |> RouteState.put_candidates([candidate])
          |> RouteState.put_reset_probe(probe)

        {:ok, [candidate], decision, route_state}

      _no_route_state ->
        {:ok, [candidate], decision, probe}
    end
  end

  defp reset_probe_decision do
    %{
      "allowed" => true,
      "routing_state" => "reset_probe",
      "summary" => "guarded probe after saved reset pending confirmation",
      "reset_probe_candidate_count" => 1,
      "eligible_candidate_count" => 1
    }
  end

  defp reset_probe(%{filter_input: %{request_options: request_options}}),
    do: request_options.routing.reset_probe

  defp reset_probe(_refresh_plan), do: nil

  defp effective_model(%{filter_input: %{request_options: request_options, model: model}}),
    do: request_options.routing.effective_model || model.exposed_model_id

  defp refilter_after_redemption(
         result,
         %{filter_input: %CandidateEligibility.FilterInput{} = input} = plan,
         scan_timestamp,
         opts
       ) do
    refilter_timestamp = refilter_timestamp(scan_timestamp, opts)

    case Map.get(plan, :route_state) do
      %RouteState{} = route_state ->
        refreshed_route_state =
          refresh_route_state_quota(route_state, refilter_timestamp)

        case Plan.filter_eligible_candidates(input, refreshed_route_state) do
          {:refreshable_quota, remaining_plan} ->
            Executor.refresh_stale_candidates(remaining_plan)

          {:ok, candidates, decision} ->
            {:ok, candidates, decision, refreshed_route_state}
        end

      _no_route_state ->
        refreshed_route_state =
          RouteState.new(%{
            visible_model: input.model,
            candidates: input.candidates
          })
          |> refresh_route_state_quota(refilter_timestamp)

        case Plan.filter_eligible_candidates(input, refreshed_route_state) do
          {:refreshable_quota, remaining_plan} ->
            remaining_plan
            |> Executor.refresh_stale_candidates()
            |> without_refreshed_route_state()

          {:ok, candidates, decision} ->
            {:ok, candidates, decision}
        end
    end
  rescue
    exception in [DBConnection.ConnectionError, Ecto.QueryError, Postgrex.Error] ->
      Logger.warning("saved reset quota refilter failed reason=#{safe_reason(exception)}")

      result
  end

  defp without_refreshed_route_state({:ok, candidates, decision, %RouteState{}}),
    do: {:ok, candidates, decision}

  defp without_refreshed_route_state(other), do: other

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
    cohort = cohort_order(refresh_plan)

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
      cohort_identity_ids:
        Enum.map(cohort, fn {_candidate_assignment, candidate_identity} ->
          candidate_identity.id
        end),
      routable_identity_ids:
        Enum.map(routable_order(refresh_plan), fn {_candidate_assignment, candidate_identity} ->
          candidate_identity.id
        end),
      route_class: route_class(refresh_plan),
      quota_scope: quota_scope(refresh_plan),
      hard_pinned_continuity?: hard_pinned_continuity?(refresh_plan)
    }
  end

  defp quota_scope(%{filter_input: %{model: model}}) do
    %{
      requested_model: model.exposed_model_id,
      catalog_model: model.exposed_model_id,
      exposed_model_id: model.exposed_model_id,
      upstream_model: model.upstream_model_id,
      upstream_model_id: model.upstream_model_id
    }
  end

  defp quota_scope(_refresh_plan), do: nil

  # Only a hard-pinned continuation with a genuinely resolved target may
  # bypass the threshold sibling usable-capacity protection. Classification is
  # owned by the routing continuity authority: a newly created Codex session,
  # session header, accepted turn state, or an unresolved previous-response
  # anchor is soft preference, not a pin, so a first turn never bypasses.
  defp hard_pinned_continuity?(%{
         filter_input: %{
           auth: auth,
           request_options: request_options,
           model: %Model{} = model
         }
       }) do
    SessionContinuity.hard_pinned_continuity?(auth, request_options, model)
  end

  defp hard_pinned_continuity?(_refresh_plan), do: false

  defp cohort_order(%{route_state: %RouteState{saved_reset_auto_cohort: cohort}})
       when is_list(cohort),
       do: cohort

  defp cohort_order(refresh_plan), do: candidate_order(refresh_plan)

  defp routable_order(%{filter_input: %{candidates: candidates}}) when is_list(candidates),
    do: candidates

  defp routable_order(refresh_plan), do: candidate_order(refresh_plan)

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
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity} = candidate,
         timestamp
       ) do
    policy = SavedResets.auto_policy(identity)

    saved_reset_available?(identity, policy, timestamp) and
      redeemable_weekly_window?(candidate, policy, timestamp)
  end

  defp redeemable_candidate?(_candidate, _timestamp), do: false

  defp early_redeemable_candidate(candidate, candidates, timestamp) when is_list(candidates) do
    if threshold_redeemable_candidate?(candidate, candidates, timestamp),
      do: {candidate, :threshold_pressure}
  end

  defp threshold_redeemable_candidate?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity},
         candidates,
         timestamp
       )
       when is_list(candidates) do
    policy = SavedResets.auto_policy(identity)

    saved_reset_available?(identity, policy, timestamp) and policy.trigger_mode == "threshold" and
      all_candidates_at_threshold?(candidates, timestamp)
  end

  defp threshold_redeemable_candidate?(_candidate, _candidates, _timestamp), do: false

  defp saved_reset_available?(%UpstreamIdentity{} = identity, policy, timestamp) do
    AutoEligibility.gateway_auto_ready?(identity, policy, timestamp)
  end

  defp redeemable_weekly_window?(
         {%PoolUpstreamAssignment{}, %UpstreamIdentity{} = identity},
         policy,
         timestamp
       ) do
    identity
    |> Windows.list_quota_windows(timestamp)
    |> AutoEligibility.blocked_weekly_exhaustion?(policy, timestamp)
  end

  defp all_candidates_at_threshold?([], _timestamp), do: false

  defp all_candidates_at_threshold?(candidates, timestamp) when is_list(candidates) do
    latched_identity_ids =
      candidates
      |> Enum.filter(fn {_assignment, identity} ->
        match?(%UpstreamIdentity{}, identity) and
          AutoEligibility.identity_consume_latch(identity, timestamp) != :clear
      end)
      |> MapSet.new(fn {_assignment, identity} -> identity.id end)

    active_candidates =
      Enum.reject(candidates, fn {_assignment, identity} ->
        identity.id in latched_identity_ids
      end)

    windows_by_identity_id =
      active_candidates
      |> Enum.map(fn {_assignment, identity} -> identity.id end)
      |> Windows.list_quota_windows_by_identity_ids(timestamp)

    active_candidates != [] and
      Enum.all?(active_candidates, fn {_assignment, identity} ->
        AutoEligibility.threshold_pressure?(
          [identity.id],
          SavedResets.auto_policy(identity),
          windows_by_identity_id,
          MapSet.new(),
          timestamp
        )
      end)
  end

  defp refresh_route_state_quota(%RouteState{} = route_state, timestamp) do
    snapshots =
      route_state.candidates
      |> Enum.map(fn {_assignment, identity} -> identity.id end)
      |> Enum.uniq()
      |> Windows.list_quota_windows_by_identity_ids(timestamp)

    RouteState.put_quota_window_snapshot(route_state, snapshots, timestamp)
  end

  defp newer_timestamp(%DateTime{} = previous_timestamp) do
    ensure_newer_timestamp(now(), previous_timestamp)
  end

  defp newer_timestamp(%DateTime{} = previous_timestamp, refilter_clock)
       when is_function(refilter_clock, 0) do
    refilter_clock
    |> refilter_clock_timestamp!()
    |> ensure_newer_timestamp(previous_timestamp)
  end

  defp refilter_timestamp(previous_timestamp, []) do
    newer_timestamp(previous_timestamp)
  end

  defp refilter_timestamp(previous_timestamp, opts) when is_list(opts) do
    newer_timestamp(previous_timestamp, refilter_clock!(opts))
  end

  defp refilter_clock!(opts) do
    case Keyword.get(opts, :refilter_clock, &now/0) do
      clock when is_function(clock, 0) ->
        clock

      _invalid_clock ->
        raise ArgumentError, "refilter_clock must be a zero-arity function"
    end
  end

  defp refilter_clock_timestamp!(refilter_clock) do
    case refilter_clock.() do
      %DateTime{} = timestamp ->
        DateTime.truncate(timestamp, :microsecond)

      _invalid_timestamp ->
        raise ArgumentError, "refilter_clock must return a DateTime"
    end
  end

  defp ensure_newer_timestamp(timestamp, previous_timestamp) do
    case DateTime.compare(timestamp, previous_timestamp) do
      :gt -> timestamp
      _not_newer -> DateTime.add(previous_timestamp, 1, :microsecond)
    end
  end

  defp log_redemption(assignment, identity, trigger_kind, trigger_detail, code, applied?) do
    Logger.info(
      "saved reset auto redemption result " <>
        "pool_upstream_assignment_id=#{assignment.id} " <>
        "upstream_identity_id=#{identity.id} " <>
        "trigger_kind=#{trigger_kind} " <>
        "trigger_detail=#{trigger_detail} " <>
        "result_code=#{code} " <>
        "applied=#{applied?}"
    )
  end

  defp trigger_detail(:blocked_weekly_exhaustion), do: "exhausted"
  defp trigger_detail(:threshold_pressure), do: "threshold"

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
