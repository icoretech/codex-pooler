defmodule CodexPooler.Gateway.Routing.CandidateEligibility.Quota do
  @moduledoc false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle

  # The routing states `add_classified_quota_candidate/4` keeps as candidates.
  # An eligibility map also carries `routing_state` when it is blocked, so
  # matching the key alone would call every exhausted account routable.
  @routable_routing_states [
    :precise,
    :credit_backed_probe,
    :weekly_only_probe,
    :windowless_provider_available
  ]

  @spec filter_quota_eligible_candidates(FilterInput.t()) ::
          CodexPooler.Gateway.Routing.CandidateEligibility.quota_filter_result()
  def filter_quota_eligible_candidates(%FilterInput{} = input) do
    %{model: model, candidates: candidates} = input

    case classify_quota_candidates(model, candidates) do
      {:ok, candidates, decision} ->
        {:ok, candidates, decision}

      {:error, exclusions, refreshable_candidates} ->
        {:refreshable_quota,
         %{
           filter_input: input,
           candidate_exclusions: exclusions,
           refreshable_candidates: refreshable_candidates
         }}
    end
  end

  @spec filter_quota_eligible_candidates(FilterInput.t(), RouteState.t()) ::
          CodexPooler.Gateway.Routing.CandidateEligibility.quota_filter_result()
  def filter_quota_eligible_candidates(%FilterInput{} = input, %RouteState{} = route_state) do
    %{model: model, candidates: candidates} = input

    case classify_quota_candidates(model, candidates, route_state) do
      {:ok, candidates, decision} ->
        {:ok, candidates, decision}

      {:error, exclusions, refreshable_candidates} ->
        {:refreshable_quota,
         %{
           filter_input: input,
           route_state: route_state,
           candidate_exclusions: exclusions,
           refreshable_candidates: refreshable_candidates
         }}
    end
  end

  @spec quota_unavailable_error([map()], boolean()) ::
          {:error, CodexPooler.Gateway.Routing.CandidateEligibility.gateway_error()}
  def quota_unavailable_error(exclusions, refresh_attempted?) when is_list(exclusions) do
    error_details = quota_unavailable_error_details(exclusions)

    generic_quota_unavailable_error(error_details, exclusions, refresh_attempted?)
  end

  @spec quota_unavailable_error(FilterInput.t(), [map()], boolean()) ::
          {:error, CodexPooler.Gateway.Routing.CandidateEligibility.gateway_error()}
  def quota_unavailable_error(
        %FilterInput{} = filter_input,
        exclusions,
        refresh_attempted?
      )
      when is_list(exclusions) do
    error_details = quota_unavailable_error_details(exclusions)

    case hard_pinned_quota_continuity_metadata(filter_input, exclusions, error_details.code) do
      nil ->
        generic_quota_unavailable_error(error_details, exclusions, refresh_attempted?)

      continuity_metadata ->
        {:error,
         Contracts.pinned_continuation_unavailable_error(continuity_metadata)
         |> Map.put(:candidate_exclusions, exclusions)
         |> Map.put(:quota_refresh_attempted, refresh_attempted?)}
    end
  end

  defp generic_quota_unavailable_error(error_details, exclusions, refresh_attempted?) do
    {:error,
     error(
       503,
       error_details.code,
       error_details.message,
       "model",
       %{
         candidate_exclusions: exclusions,
         quota_refresh_attempted: refresh_attempted?
       }
     )}
  end

  defp hard_pinned_quota_continuity_metadata(
         %FilterInput{request_options: request_options, model: model},
         exclusions,
         internal_reason
       ) do
    with %{} = pin_metadata <- SessionContinuity.hard_pin_metadata(request_options, model),
         %{} = target <- first_quota_exclusion_target(exclusions) do
      Map.merge(pin_metadata, %{
        "denial_family" => "pinned_continuation_unavailable",
        "continuity_family" => "pinned_codex_session",
        "internal_reason" => internal_reason,
        "pool_upstream_assignment_id" => Map.get(target, :pool_upstream_assignment_id),
        "upstream_identity_id" => Map.get(target, :upstream_identity_id)
      })
    else
      _missing -> nil
    end
  end

  defp first_quota_exclusion_target(exclusions) do
    Enum.find(exclusions, fn exclusion ->
      present?(Map.get(exclusion, :pool_upstream_assignment_id)) and
        present?(Map.get(exclusion, :upstream_identity_id))
    end)
  end

  @doc """
  Whether a candidate would survive quota classification right now.

  Canonical partition selection uses this to answer "can this partition still
  serve a turn?" before dispatch narrows the candidate list. It reuses the same
  eligibility and post-reset lifecycle predicates the real filter applies, so a
  partition is never judged unroutable on rules routing would not have enforced.
  Circuit state is deliberately not consulted: it is per route class and
  short-lived, and letting it move the selected partition would make the
  advertised catalog flap.
  """
  @spec quota_routable?(
          Model.t(),
          CodexPooler.Gateway.Routing.CandidateEligibility.candidate(),
          RoutingQuotaSnapshot.t(),
          DateTime.t()
        ) :: boolean()
  def quota_routable?(
        %Model{} = model,
        {_assignment, identity},
        %RoutingQuotaSnapshot{as_of: at} = snapshot,
        %DateTime{} = at
      ) do
    if claimed_pending_reset_probe?(identity) do
      false
    else
      snapshot
      |> QuotaWindows.routing_quota_eligibility_from_snapshot(quota_scope_opts(model))
      |> case do
        %{routing_state: routing_state} when routing_state in @routable_routing_states -> true
        %{exclusions: reasons} when is_list(reasons) -> reset_probe_routeable?(identity, reasons)
      end
    end
  end

  @spec windowless_candidate?(
          Model.t(),
          CodexPooler.Gateway.Routing.CandidateEligibility.candidate(),
          RouteState.t()
        ) :: boolean()
  def windowless_candidate?(
        %Model{} = model,
        {_assignment, identity},
        %RouteState{} = route_state
      ) do
    Map.has_key?(route_state.quota_snapshots, identity.id) and
      not claimed_pending_reset_probe?(identity) and
      match?(
        %{routing_state: :windowless_provider_available},
        routing_quota_eligibility(identity, model, route_state)
      )
  end

  defp classify_quota_candidates(%Model{} = model, candidates) do
    classify_quota_candidates(model, candidates, nil)
  end

  defp classify_quota_candidates(%Model{} = model, candidates, route_state) do
    {precise_candidates, credit_backed_probe_candidates, weekly_probe_candidates,
     reset_probe_candidates, windowless_candidates, exclusions, refreshable_candidates} =
      Enum.reduce(candidates, {[], [], [], [], [], [], []}, fn {assignment, identity} = candidate,
                                                               acc ->
        identity
        |> routing_quota_eligibility(model, route_state)
        |> add_classified_quota_candidate(candidate, assignment, acc)
      end)

    precise_candidates = Enum.reverse(precise_candidates)
    credit_backed_probe_candidates = Enum.reverse(credit_backed_probe_candidates)
    weekly_probe_candidates = Enum.reverse(weekly_probe_candidates)
    reset_probe_candidates = Enum.reverse(reset_probe_candidates)
    windowless_candidates = Enum.reverse(windowless_candidates)

    candidates =
      precise_candidates ++
        credit_backed_probe_candidates ++
        weekly_probe_candidates ++ reset_probe_candidates ++ windowless_candidates

    case candidates do
      [] ->
        {:error, Enum.reverse(exclusions), Enum.reverse(refreshable_candidates)}

      candidates ->
        {:ok, candidates,
         quota_decision(
           candidates,
           precise_candidates,
           credit_backed_probe_candidates,
           weekly_probe_candidates,
           reset_probe_candidates,
           windowless_candidates
         )}
    end
  end

  defp routing_quota_eligibility(
         identity,
         %Model{} = model,
         %RouteState{} = route_state
       ) do
    if claimed_pending_reset_probe?(identity) do
      claimed_pending_reset_probe_exclusion()
    else
      snapshot = RouteState.quota_snapshot_for_identity(route_state, identity)

      QuotaWindows.routing_quota_eligibility_from_snapshot(snapshot, quota_scope_opts(model))
    end
  end

  defp routing_quota_eligibility(identity, %Model{} = model, nil) do
    if claimed_pending_reset_probe?(identity) do
      claimed_pending_reset_probe_exclusion()
    else
      QuotaWindows.routing_quota_eligibility(identity, quota_scope_opts(model))
    end
  end

  defp claimed_pending_reset_probe?(identity) do
    redemption = redemption_metadata(identity)

    RedemptionLifecycle.phase(redemption) == RedemptionLifecycle.consumed_pending_probe() and
      is_binary(RedemptionLifecycle.probe_holder(redemption))
  end

  defp claimed_pending_reset_probe_exclusion do
    %{
      exclusions: [
        %{
          code: "saved_reset_probe_pending",
          message: "saved reset probe confirmation is still pending"
        }
      ]
    }
  end

  defp add_classified_quota_candidate(
         %{routing_state: :precise},
         candidate,
         _assignment,
         {precise, credit_backed, weekly_probes, reset_probes, windowless, excluded, refreshable}
       ) do
    {[candidate | precise], credit_backed, weekly_probes, reset_probes, windowless, excluded,
     refreshable}
  end

  defp add_classified_quota_candidate(
         %{routing_state: :credit_backed_probe},
         candidate,
         _assignment,
         {precise, credit_backed, weekly_probes, reset_probes, windowless, excluded, refreshable}
       ) do
    {precise, [candidate | credit_backed], weekly_probes, reset_probes, windowless, excluded,
     refreshable}
  end

  defp add_classified_quota_candidate(
         %{routing_state: :weekly_only_probe},
         candidate,
         _assignment,
         {precise, credit_backed, weekly_probes, reset_probes, windowless, excluded, refreshable}
       ) do
    {precise, credit_backed, [candidate | weekly_probes], reset_probes, windowless, excluded,
     refreshable}
  end

  defp add_classified_quota_candidate(
         %{routing_state: :windowless_provider_available},
         candidate,
         _assignment,
         {precise, credit_backed, weekly_probes, reset_probes, windowless, excluded, refreshable}
       ) do
    {precise, credit_backed, weekly_probes, reset_probes, [candidate | windowless], excluded,
     refreshable}
  end

  defp add_classified_quota_candidate(
         %{exclusions: reasons},
         {_, identity} = candidate,
         assignment,
         {precise, credit_backed, weekly_probes, reset_probes, windowless, excluded, refreshable}
       ) do
    if reset_probe_routeable?(identity, reasons) do
      # The quota window still reads exhausted, but this identity holds a
      # post-reset lifecycle that a successful probe or fresh quota already
      # confirmed as temporarily routeable. Route it as a guarded reset probe
      # instead of excluding it — this is what sustainably breaks the deadlock.
      {precise, credit_backed, weekly_probes, [candidate | reset_probes], windowless, excluded,
       refreshable}
    else
      exclusion = quota_candidate_exclusion(assignment, identity, reasons)
      refreshable = maybe_add_refreshable_quota_candidate(refreshable, candidate, reasons)

      {precise, credit_backed, weekly_probes, reset_probes, windowless, [exclusion | excluded],
       refreshable}
    end
  end

  # A redeemed identity is routeable-by-lifecycle only when its post-reset phase
  # says so (a confirmed redemption within its bounded window) AND the sole
  # quota block is ACCOUNT weekly exhaustion — the only window a saved reset
  # actually resets. A model-scoped weekly block (e.g. a Spark limit) or any
  # other exclusion (auth, circuit, missing reset) still excludes — fail-closed.
  defp reset_probe_routeable?(identity, reasons) do
    weekly_exhaustion_only?(reasons) and
      RedemptionLifecycle.routeable?(redemption_metadata(identity), now())
  end

  # Reached only from the exclusion clause, where `reasons` is a non-empty list
  # of quota exclusion reasons. All must be account-weekly exhaustion for the
  # reset probe to override — any other block still excludes.
  defp weekly_exhaustion_only?(reasons) do
    Enum.all?(reasons, &account_weekly_exhaustion_reason?/1)
  end

  defp account_weekly_exhaustion_reason?(%{} = reason) do
    reason_field(reason, :quota_key) == "account" and
      reason_field(reason, :quota_scope) == "account" and
      reason_field(reason, :quota_family) == "account" and
      reason_field(reason, :window_kind) == "secondary" and
      quota_exhaustion_reason?(reason)
  end

  defp account_weekly_exhaustion_reason?(_reason), do: false

  defp reason_field(reason, key), do: Map.get(reason, key) || Map.get(reason, Atom.to_string(key))

  defp redemption_metadata(%{metadata: %{} = metadata}), do: metadata["saved_reset_redemption"]
  defp redemption_metadata(_identity), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp maybe_add_refreshable_quota_candidate(refreshable, candidate, reasons) do
    if stale_quota_refreshable?(reasons), do: [candidate | refreshable], else: refreshable
  end

  defp stale_quota_refreshable?(reasons) when is_list(reasons) do
    reasons != [] and Enum.all?(reasons, &stale_quota_refreshable_reason?/1)
  end

  defp stale_quota_refreshable_reason?(%{code: "quota_window_unusable"} = reason),
    do: stale_quota_refreshable_reason_codes?(Map.get(reason, :reason_codes))

  defp stale_quota_refreshable_reason?(%{"code" => "quota_window_unusable"} = reason),
    do: stale_quota_refreshable_reason_codes?(Map.get(reason, "reason_codes"))

  defp stale_quota_refreshable_reason?(_reason), do: false

  defp stale_quota_refreshable_reason_codes?(reason_codes) when is_list(reason_codes) do
    "not_fresh" in reason_codes and
      not Enum.any?(reason_codes, &(&1 in ["reset_missing", "exhausted"]))
  end

  defp stale_quota_refreshable_reason_codes?(_reason_codes), do: false

  defp quota_scope_opts(%Model{} = model) do
    [
      model: model.exposed_model_id,
      requested_model: model.exposed_model_id,
      catalog_model: model.exposed_model_id,
      exposed_model_id: model.exposed_model_id,
      upstream_model: model.upstream_model_id,
      upstream_model_id: model.upstream_model_id
    ]
  end

  defp quota_candidate_exclusion(assignment, identity, reasons) do
    %{
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      reasons: Enum.map(reasons, &sanitize_quota_exclusion/1)
    }
  end

  defp quota_unavailable_error_details(exclusions) do
    reasons = Enum.flat_map(exclusions, &Map.get(&1, :reasons, []))

    if Enum.any?(reasons, &quota_exhaustion_reason?/1) do
      %{
        code: "quota_exhausted",
        message: "upstream quota is exhausted until its reset time"
      }
    else
      %{
        code: "quota_evidence_unavailable",
        message: "no upstream account has fresh reset-bearing quota evidence for this model"
      }
    end
  end

  defp quota_exhaustion_reason?(%{code: code}) when code in ["quota_weekly_exhausted"], do: true

  defp quota_exhaustion_reason?(%{"code" => code}) when code in ["quota_weekly_exhausted"],
    do: true

  defp quota_exhaustion_reason?(%{reason_codes: reason_codes}) when is_list(reason_codes),
    do: "exhausted" in reason_codes

  defp quota_exhaustion_reason?(%{"reason_codes" => reason_codes}) when is_list(reason_codes),
    do: "exhausted" in reason_codes

  defp quota_exhaustion_reason?(_reason), do: false

  defp quota_decision(
         candidates,
         precise_candidates,
         credit_backed_probe_candidates,
         weekly_probe_candidates,
         reset_probe_candidates,
         windowless_candidates
       ) do
    %{
      "allowed" => true,
      "summary" =>
        quota_decision_summary(
          precise_candidates,
          credit_backed_probe_candidates,
          weekly_probe_candidates,
          reset_probe_candidates,
          windowless_candidates
        ),
      "routing_state" =>
        quota_decision_state(
          precise_candidates,
          credit_backed_probe_candidates,
          weekly_probe_candidates,
          reset_probe_candidates,
          windowless_candidates
        ),
      "precise_candidate_count" => length(precise_candidates),
      "credit_backed_probe_candidate_count" => length(credit_backed_probe_candidates),
      "weekly_probe_candidate_count" => length(weekly_probe_candidates),
      "reset_probe_candidate_count" => length(reset_probe_candidates),
      "windowless_provider_available_candidate_count" => length(windowless_candidates),
      "eligible_candidate_count" => length(candidates)
    }
  end

  defp quota_decision_state([_ | _], _credit_backed, _weekly_probes, _reset_probes, _windowless),
    do: "precise"

  defp quota_decision_state([], [_ | _], _weekly_probes, _reset_probes, _windowless),
    do: "credit_backed_probe"

  defp quota_decision_state([], [], [_ | _], _reset_probes, _windowless),
    do: "weekly_only_probe"

  defp quota_decision_state([], [], [], [_ | _], _windowless), do: "reset_probe"
  defp quota_decision_state([], [], [], [], [_ | _]), do: "windowless_provider_available"

  defp quota_decision_summary([], [], [], [_ | _], _windowless),
    do: "allowed by post-reset guarded probe lifecycle"

  defp quota_decision_summary([], [], [], [], [_ | _]),
    do: "allowed by provider availability without reset-bearing quota windows"

  defp quota_decision_summary(precise, credit_backed, weekly_probes, _reset_probes, windowless) do
    base = quota_decision_summary(precise, credit_backed, weekly_probes)

    if windowless == [],
      do: base,
      else: base <> " and provider availability without reset-bearing quota windows"
  end

  defp quota_decision_summary([], [], [_ | _]), do: "allowed by weekly quota evidence"

  defp quota_decision_summary([], [_ | _], []),
    do: "allowed by credit-backed secondary quota evidence"

  defp quota_decision_summary([], [_ | _], [_ | _]),
    do: "allowed by credit-backed secondary and weekly quota evidence"

  defp quota_decision_summary([_ | _], [], []), do: "allowed by fresh quota"

  defp quota_decision_summary([_ | _], [_ | _], []),
    do: "allowed by fresh and credit-backed secondary quota evidence"

  defp quota_decision_summary([_ | _], [], [_ | _]),
    do: "allowed by fresh and weekly quota evidence"

  defp quota_decision_summary([_ | _], [_ | _], [_ | _]),
    do: "allowed by fresh, credit-backed secondary, and weekly quota evidence"

  defp sanitize_quota_exclusion(%{} = exclusion) do
    exclusion
    |> Map.take([
      :code,
      :message,
      :reason_codes,
      :quota_key,
      :window_kind,
      :quota_scope,
      :quota_family,
      :model,
      :upstream_model,
      :source,
      :source_precision,
      :freshness_state,
      :reset_at
    ])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp error(status, code, message, param, metadata),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
