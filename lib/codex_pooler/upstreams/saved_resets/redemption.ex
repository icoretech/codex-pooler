defmodule CodexPooler.Upstreams.SavedResetRedemption do
  @moduledoc """
  Redeems Codex saved reset credits with metadata-only persistence.
  """

  import Ecto.Query

  alias CodexPooler.Events
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.CreditLocator
  alias CodexPooler.Upstreams.SavedResets.ObservationOrdering
  alias CodexPooler.Upstreams.SavedResets.PostResetEvidence
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets
  alias CodexPooler.Upstreams.StatusVocabulary.Assignment, as: AssignmentStatus
  alias CodexPooler.Upstreams.StatusVocabulary.Identity, as: IdentityStatus

  @assignment_active AssignmentStatus.active_status()
  @identity_active IdentityStatus.active_status()
  @identity_deleted IdentityStatus.deleted_status()
  @identity_disabled IdentityStatus.disabled_status()
  @scheduled_expiry_trigger "scheduled_expiry_rescue"
  @known_noop_codes ~w(no_credit nothing_to_reset)
  @known_applied_codes ~w(reset already_redeemed)
  @known_provider_result_codes @known_applied_codes ++ @known_noop_codes
  @redemption_target_key "saved_reset_redemption_target"
  @legacy_recovery_marker %{"version" => 1, "state" => "unresolved"}
  @maximum_provider_dispatches 6
  @replay_cutoff_seconds 6 * 60 * 60
  @observe_only_interval_seconds 6 * 60 * 60
  @provider_staleness_floor_seconds 30 * 60
  @replay_delays_seconds %{1 => 60, 2 => 5 * 60, 3 => 15 * 60, 4 => 60 * 60, 5 => 3 * 60 * 60}

  @type trigger_kind :: String.t()

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @type redeem_result :: %{
          required(:status) => :succeeded | :failed | :noop,
          required(:identity) => UpstreamIdentity.t(),
          required(:assignment) => PoolUpstreamAssignment.t(),
          required(:applied?) => boolean(),
          required(:code) => String.t(),
          optional(:phase) => String.t(),
          optional(:consumed_at) => DateTime.t(),
          optional(:available_count_before) => non_neg_integer(),
          optional(:available_count_after) => non_neg_integer(),
          optional(:http_status) => non_neg_integer(),
          optional(:reason) => String.t()
        }

  @type scheduled_noop_result :: %{
          required(:status) => :noop,
          required(:applied?) => false,
          required(:code) => String.t(),
          optional(:identity) => UpstreamIdentity.t()
        }

  @type scheduled_redeem_result ::
          {:ok, redeem_result() | scheduled_noop_result()}
          | {:error,
             lifecycle_error()
             | :redemption_in_progress
             | :saved_reset_consume_outcome_ambiguous}

  @type scheduled_decision_evidence :: %{
          required(:trigger_detail) => String.t(),
          required(:used_percent_at_decision) => String.t(),
          required(:credit_expires_at_at_decision) => String.t(),
          required(:natural_reset_at_decision) => String.t(),
          required(:decided_at) => String.t()
        }

  @type stale_consuming_recovery_candidate :: %{
          required(:attempt_id) => Ecto.UUID.t(),
          required(:generation) => non_neg_integer()
        }

  @spec stale_consuming_recovery_candidate(UpstreamIdentity.t(), keyword()) ::
          stale_consuming_recovery_candidate() | nil
  def stale_consuming_recovery_candidate(identity, opts \\ [])

  def stale_consuming_recovery_candidate(%UpstreamIdentity{} = identity, opts) do
    now = Keyword.get_lazy(opts, :now, &now/0)

    receive_timeout =
      Keyword.get(opts, :receive_timeout, SavedResets.redemption_receive_timeout_ms())

    redemption = get_in(identity.metadata || %{}, ["saved_reset_redemption"])

    with %{
           "status" => "redeeming",
           "phase" => "consuming",
           "attempt_id" => attempt_id,
           "generation" => generation,
           "started_at" => started_at
         } <- redemption,
         {:ok, attempt_id} <- Ecto.UUID.cast(attempt_id),
         true <- is_integer(generation) and generation >= 0,
         %DateTime{} = started_at <- parse_datetime(started_at),
         true <-
           DateTime.diff(now, started_at, :millisecond) >=
             receive_timeout + SavedResets.redemption_stale_grace_ms(),
         true <- recovery_due?(redemption, now) do
      %{attempt_id: attempt_id, generation: generation}
    else
      _invalid_or_not_due -> nil
    end
  end

  def stale_consuming_recovery_candidate(_identity, _opts), do: nil

  @type stale_consuming_result ::
          {:ok, redeem_result() | scheduled_noop_result()}
          | {:snooze, pos_integer()}
          | {:error, term()}

  @spec resume_stale_consuming(
          PoolUpstreamAssignment.t() | Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          non_neg_integer(),
          keyword()
        ) :: stale_consuming_result()
  def resume_stale_consuming(
        assignment_or_id,
        expected_identity_id,
        expected_attempt_id,
        expected_generation,
        opts \\ []
      ) do
    now = Keyword.get_lazy(opts, :now, &now/0)

    receive_timeout =
      Keyword.get(opts, :receive_timeout, SavedResets.redemption_receive_timeout_ms())

    expected = %{
      assignment_id: assignment_id(assignment_or_id),
      identity_id: expected_identity_id,
      attempt_id: expected_attempt_id,
      generation: expected_generation
    }

    case prepare_stale_consuming(expected, now, receive_timeout) do
      {:ok, %{endpoint_kind: :chatgpt} = recovery} ->
        resume_chatgpt_recovery(recovery, now)

      {:ok, %{endpoint_kind: :codex} = recovery} ->
        resume_codex_recovery(recovery, now)

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:noop, code, identity, assignment} ->
        {:ok, noop_result(identity, assignment, code)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_stale_consuming(expected, now, receive_timeout) do
    with {:ok, expected} <- normalize_recovery_expected(expected) do
      Repo.transaction(fn -> prepare_stale_consuming_locked(expected, now, receive_timeout) end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    _error -> {:error, :saved_reset_persistence_failed}
  end

  defp prepare_stale_consuming_locked(expected, now, receive_timeout) do
    identity = lock_identity!(expected.identity_id)
    assignments = lock_canonical_assignments(identity.id)
    canonical = List.first(assignments)
    redemption = get_in(identity.metadata || %{}, ["saved_reset_redemption"])

    cond do
      identity.status != @identity_active or
          not match?(%PoolUpstreamAssignment{id: id} when id == expected.assignment_id, canonical) ->
        {:noop, "recovery_superseded", identity, canonical || recovery_assignment(expected)}

      not valid_recovery_attempt?(redemption, expected, now, receive_timeout) ->
        {:noop, "recovery_target_invalid", identity, canonical}

      legacy_recovery?(redemption) ->
        normalize_legacy_recovery!(identity, redemption, now)

      true ->
        prepare_versioned_recovery(
          identity,
          canonical,
          redemption,
          expected,
          now,
          receive_timeout
        )
    end
  end

  defp normalize_recovery_expected(expected) do
    with {:ok, assignment_id} <- Ecto.UUID.cast(expected.assignment_id),
         {:ok, identity_id} <- Ecto.UUID.cast(expected.identity_id),
         {:ok, attempt_id} <- Ecto.UUID.cast(expected.attempt_id),
         true <- is_integer(expected.generation) and expected.generation >= 0 do
      {:ok,
       %{
         expected
         | assignment_id: assignment_id,
           identity_id: identity_id,
           attempt_id: attempt_id
       }}
    else
      _invalid -> {:error, :stale_consuming_recovery_target_invalid}
    end
  end

  defp lock_canonical_assignments(identity_id) do
    active_pool_ids =
      Repo.all(from pool in Pool, where: pool.status == "active", select: pool.id)

    Repo.all(
      from assignment in PoolUpstreamAssignment,
        where:
          assignment.upstream_identity_id == ^identity_id and
            assignment.status == ^@assignment_active and assignment.pool_id in ^active_pool_ids,
        order_by: [asc: assignment.created_at, asc: assignment.id],
        lock: "FOR UPDATE"
    )
  end

  defp recovery_assignment(%{assignment_id: assignment_id}),
    do: %PoolUpstreamAssignment{id: assignment_id}

  defp valid_recovery_attempt?(redemption, expected, now, receive_timeout) do
    with %{
           "status" => "redeeming",
           "phase" => "consuming",
           "attempt_id" => attempt_id,
           "generation" => generation,
           "started_at" => started_at
         } <- redemption,
         {:ok, ^attempt_id} <- Ecto.UUID.cast(expected.attempt_id),
         ^attempt_id <- attempt_id,
         ^generation <- expected.generation,
         %DateTime{} = started_at <- parse_datetime(started_at) do
      DateTime.diff(now, started_at, :millisecond) >=
        receive_timeout + SavedResets.redemption_stale_grace_ms()
    else
      _invalid -> false
    end
  end

  defp legacy_recovery?(redemption) do
    not Map.has_key?(redemption, "provider_replay") and
      (is_nil(redemption["legacy_recovery"]) or
         redemption["legacy_recovery"] == @legacy_recovery_marker)
  end

  defp normalize_legacy_recovery!(identity, redemption, now) do
    next_action_at = DateTime.add(now, @observe_only_interval_seconds, :second)

    normalized =
      redemption
      |> Map.put("legacy_recovery", @legacy_recovery_marker)
      |> Map.put("legacy_recovery_last_code", "legacy_unresolved")
      |> Map.put("legacy_recovery_last_observed_at", DateTime.to_iso8601(now))
      |> Map.put("legacy_recovery_next_action_at", DateTime.to_iso8601(next_action_at))

    if normalized == redemption do
      identity
    else
      identity
      |> UpstreamIdentity.changeset(%{
        metadata: Map.put(identity.metadata || %{}, "saved_reset_redemption", normalized),
        updated_at: now
      })
      |> Repo.update!()
    end

    {:snooze, @observe_only_interval_seconds}
  end

  defp prepare_versioned_recovery(
         identity,
         assignment,
         redemption,
         expected,
         now,
         receive_timeout
       ) do
    replay = redemption["provider_replay"]
    started_at = parse_datetime(redemption["started_at"])

    with %{
           "version" => 1,
           "endpoint_family" => endpoint_family,
           "scope_fingerprint" => scope_fingerprint,
           "provider_dispatches" => provider_dispatches
         } <- replay,
         true <-
           is_integer(provider_dispatches) and
             provider_dispatches in 0..@maximum_provider_dispatches do
      context = %{
        endpoint_family: endpoint_family,
        expected: expected,
        provider_dispatches: provider_dispatches,
        receive_timeout: receive_timeout,
        scope_fingerprint: scope_fingerprint,
        started_at: started_at
      }

      prepare_versioned_recovery_mode(identity, assignment, redemption, replay, context, now)
    else
      {:error, %{code: :saved_reset_credit_locator_invalid}} ->
        {:noop, "recovery_target_invalid", identity, assignment}

      {:error, _reason} ->
        {:noop, "missing_access_token", identity, assignment}

      _invalid ->
        {:noop, "scope_changed", identity, assignment}
    end
  end

  defp prepare_versioned_recovery_mode(
         identity,
         assignment,
         redemption,
         replay,
         context,
         now
       ) do
    exhausted? =
      context.provider_dispatches >= @maximum_provider_dispatches or
        DateTime.compare(now, DateTime.add(context.started_at, @replay_cutoff_seconds, :second)) !=
          :lt

    cond do
      replay["mode"] == "observe_only" or exhausted? ->
        prepare_observe_only_recovery(
          identity,
          assignment,
          redemption,
          replay,
          context,
          now,
          exhausted?
        )

      replay["mode"] in [nil, "replay"] ->
        prepare_provider_recovery(
          identity,
          assignment,
          redemption,
          replay,
          context,
          now,
          :replay
        )

      true ->
        {:noop, "scope_changed", identity, assignment}
    end
  end

  defp prepare_observe_only_recovery(
         identity,
         assignment,
         redemption,
         replay,
         context,
         now,
         entering?
       ) do
    normalize_entry? =
      entering? and
        (replay["mode"] != "observe_only" or is_nil(replay["replay_exhausted_at"]) or
           is_nil(replay["unresolved_since"]) or is_nil(replay["next_action_at"]))

    {identity, redemption, replay} =
      if normalize_entry? do
        enter_observe_only!(identity, redemption, replay, now)
      else
        {identity, redemption, replay}
      end

    with {:ok, due_at} <- observe_only_due_at(replay, now),
         false <- DateTime.compare(now, due_at) == :lt do
      if context.provider_dispatches == 0 do
        settle_consume_not_applied!(identity, assignment, redemption, context.expected, now)
      else
        prepare_provider_recovery(
          identity,
          assignment,
          redemption,
          replay,
          context,
          now,
          :observe_only
        )
      end
    else
      true -> {:snooze, remaining_seconds(observe_only_due_at!(replay, now), now)}
      :error -> persist_observe_only_locked!(identity, redemption, "scope_changed", now)
    end
  end

  defp enter_observe_only!(identity, redemption, replay, now) do
    exhausted_at = replay["replay_exhausted_at"] || DateTime.to_iso8601(now)
    unresolved_since = replay["unresolved_since"] || exhausted_at
    floor_at = provider_staleness_floor_at(replay, now)

    next_action_at =
      if DateTime.compare(now, floor_at) == :lt,
        do: floor_at,
        else: now

    updated_replay =
      replay
      |> Map.put("mode", "observe_only")
      |> Map.put("replay_exhausted_at", exhausted_at)
      |> Map.put("unresolved_since", unresolved_since)
      |> Map.put("last_code", "write_budget_exhausted")
      |> Map.put("next_action_at", DateTime.to_iso8601(next_action_at))

    updated_redemption = Map.put(redemption, "provider_replay", updated_replay)
    updated_identity = persist_recovery_redemption!(identity, updated_redemption, now)
    {updated_identity, updated_redemption, updated_replay}
  end

  defp observe_only_due_at(replay, now) do
    case parse_datetime(replay["next_action_at"]) do
      %DateTime{} = next_action_at ->
        {:ok, later_datetime(next_action_at, provider_staleness_floor_at(replay, now))}

      nil ->
        :error
    end
  end

  defp observe_only_due_at!(replay, now) do
    {:ok, due_at} = observe_only_due_at(replay, now)
    due_at
  end

  defp provider_staleness_floor_at(replay, now) do
    case parse_datetime(replay["last_provider_dispatched_at"]) do
      %DateTime{} = last_dispatched_at ->
        DateTime.add(last_dispatched_at, @provider_staleness_floor_seconds, :second)

      nil ->
        now
    end
  end

  defp settle_consume_not_applied!(identity, assignment, redemption, expected, now) do
    phase = RedemptionLifecycle.consume_not_applied()

    if RedemptionLifecycle.can_transition?(
         redemption,
         phase,
         expected.generation,
         expected.attempt_id
       ) do
      updated =
        redemption
        |> Map.put("status", RedemptionLifecycle.legacy_status_for(phase))
        |> Map.put("phase", phase)
        |> Map.put("finished_at", DateTime.to_iso8601(now))
        |> Map.put("result", %{
          "code" => phase,
          "applied" => false,
          "available_count_before" => nil,
          "available_count_after" => nil,
          "http_status" => nil
        })

      updated_identity =
        identity
        |> UpstreamIdentity.changeset(%{
          metadata:
            identity.metadata
            |> Kernel.||(%{})
            |> Map.put("saved_reset_redemption", updated)
            |> Map.delete(@redemption_target_key),
          updated_at: now
        })
        |> Repo.update!()

      {:noop, phase, updated_identity, assignment}
    else
      {:noop, "recovery_target_invalid", identity, assignment}
    end
  end

  defp prepare_provider_recovery(
         identity,
         assignment,
         redemption,
         replay,
         context,
         now,
         mode
       ) do
    snapshot = SavedResets.snapshot(identity, now)

    with {:ok, endpoint_family, consume_url, scope_fingerprint} <-
           provider_scope(identity, assignment, snapshot),
         true <- endpoint_family == context.endpoint_family,
         true <- scope_fingerprint == context.scope_fingerprint,
         {:ok, access_token} <- Secrets.decrypt_active_secret(identity, "access_token"),
         {:ok, target} <-
           recovery_target(
             identity,
             redemption,
             context.expected,
             endpoint_family,
             scope_fingerprint
           ) do
      recovery = %{
        identity: identity,
        assignment: assignment,
        attempt_id: context.expected.attempt_id,
        generation: context.expected.generation,
        trigger_kind: redemption["trigger_kind"],
        trigger_detail: redemption["trigger_detail"],
        started_at: context.started_at,
        receive_timeout: context.receive_timeout,
        endpoint_kind: endpoint_kind(endpoint_family),
        endpoint_family: endpoint_family,
        scope_fingerprint: scope_fingerprint,
        consume_url: consume_url,
        list_url: recovery_list_url(identity, assignment, endpoint_family, snapshot),
        access_token: access_token,
        target: target,
        provider_dispatches: context.provider_dispatches,
        last_provider_dispatched_at: parse_datetime(replay["last_provider_dispatched_at"]),
        recovery_mode: mode
      }

      if mode == :observe_only,
        do: {:ok, recovery},
        else: prepare_due_versioned_recovery(recovery, replay, now)
    else
      {:error, %{code: :saved_reset_credit_locator_invalid}} when mode == :observe_only ->
        persist_observe_only_locked!(identity, redemption, "target_invalid", now)

      {:error, _reason} when mode == :observe_only ->
        persist_observe_only_locked!(identity, redemption, "missing_access_token", now)

      _invalid when mode == :observe_only ->
        persist_observe_only_locked!(identity, redemption, "scope_changed", now)

      {:error, %{code: :saved_reset_credit_locator_invalid}} ->
        {:noop, "recovery_target_invalid", identity, assignment}

      {:error, _reason} ->
        {:noop, "missing_access_token", identity, assignment}

      _invalid ->
        {:noop, "scope_changed", identity, assignment}
    end
  end

  defp prepare_due_versioned_recovery(recovery, replay, now) do
    case recovery_replay_due_at(replay) do
      {:ok, due_at} ->
        if DateTime.compare(now, due_at) == :lt do
          {:snooze, remaining_seconds(due_at, now)}
        else
          {:ok, recovery}
        end

      :error ->
        {:noop, "scope_changed", recovery.identity, recovery.assignment}
    end
  end

  defp recovery_target(identity, redemption, expected, "chatgpt_api", scope_fingerprint) do
    locator = (identity.metadata || %{})[@redemption_target_key]
    dispatches = get_in(redemption, ["provider_replay", "provider_dispatches"])

    cond do
      is_binary(locator) ->
        CreditLocator.open(locator, %{
          identity_id: identity.id,
          attempt_id: expected.attempt_id,
          generation: expected.generation,
          endpoint_family: "chatgpt_api",
          scope_fingerprint: scope_fingerprint
        })

      dispatches == 0 ->
        {:ok, nil}

      true ->
        {:error, %{code: :saved_reset_credit_locator_invalid}}
    end
  end

  defp recovery_target(_identity, _redemption, _expected, "codex_api", _scope), do: {:ok, nil}
  defp recovery_target(_identity, _redemption, _expected, _family, _scope), do: :error

  defp recovery_list_url(identity, assignment, "chatgpt_api", snapshot) do
    case chatgpt_reset_urls(identity, assignment, snapshot) do
      {:ok, list_url, _consume_url} -> list_url
      _unsupported -> nil
    end
  end

  defp recovery_list_url(_identity, _assignment, _endpoint_family, _snapshot), do: nil
  defp endpoint_kind("chatgpt_api"), do: :chatgpt
  defp endpoint_kind("codex_api"), do: :codex

  defp remaining_seconds(%DateTime{} = due_at, now),
    do: max(DateTime.diff(due_at, now, :second), 1)

  defp recovery_replay_due_at(%{"provider_dispatches" => 0} = replay) do
    case replay["next_action_at"] do
      nil -> {:ok, ~U[1970-01-01 00:00:00Z]}
      value -> parse_recovery_due_at(value)
    end
  end

  defp recovery_replay_due_at(
         %{
           "provider_dispatches" => dispatches,
           "last_provider_dispatched_at" => last_dispatched_at
         } = replay
       )
       when dispatches in 1..5 do
    with %DateTime{} = last_dispatched_at <- parse_datetime(last_dispatched_at),
         delay when is_integer(delay) <- Map.get(@replay_delays_seconds, dispatches),
         {:ok, persisted_due_at} <- optional_recovery_due_at(replay["next_action_at"]) do
      dispatch_floor = DateTime.add(last_dispatched_at, delay, :second)
      {:ok, later_datetime(dispatch_floor, persisted_due_at)}
    else
      _invalid -> :error
    end
  end

  defp recovery_replay_due_at(_replay), do: :error

  defp optional_recovery_due_at(nil), do: {:ok, ~U[1970-01-01 00:00:00Z]}
  defp optional_recovery_due_at(value), do: parse_recovery_due_at(value)

  defp parse_recovery_due_at(value) do
    case parse_datetime(value) do
      %DateTime{} = due_at -> {:ok, due_at}
      nil -> :error
    end
  end

  defp later_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp resume_chatgpt_recovery(recovery, now) do
    case list_recovery_chatgpt_credits(recovery) do
      {:ok, credits} ->
        resume_from_chatgpt_credits(recovery, credits, now)

      {:error, _reason} ->
        persist_recovery_observation(recovery, "list_failed", now, observation_interval(recovery))
    end
  end

  defp list_recovery_chatgpt_credits(recovery) do
    case Req.get(recovery.list_url,
           headers:
             CloudflareCookies.request_headers(
               recovery.list_url,
               request_headers(
                 recovery.access_token,
                 recovery.identity.chatgpt_account_id,
                 :get
               )
             ),
           retry: false,
           receive_timeout: recovery.receive_timeout
         )
         |> store_cloudflare_cookies(recovery.list_url) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        parse_recovery_chatgpt_credits(body)

      _failed ->
        {:error, :list_failed}
    end
  rescue
    _error -> {:error, :list_failed}
  end

  defp parse_recovery_chatgpt_credits(%{"credits" => credits}) when is_list(credits) do
    parsed =
      Enum.reduce_while(credits, [], fn
        %{"id" => id} = credit, acc when is_binary(id) and byte_size(id) in 1..1_024 ->
          status = Map.get(credit, "status")
          redeemed_at = Map.get(credit, "redeemed_at")

          if status in ["available", "redeeming", "redeemed"] and
               (is_nil(redeemed_at) or is_binary(redeemed_at)) do
            {:cont, [%{id: id, status: status, redeemed_at: redeemed_at} | acc]}
          else
            {:halt, :invalid}
          end

        _invalid, _acc ->
          {:halt, :invalid}
      end)

    case parsed do
      :invalid -> {:error, :list_failed}
      rows -> {:ok, Enum.reverse(rows)}
    end
  end

  defp parse_recovery_chatgpt_credits(_body), do: {:error, :list_failed}

  defp resume_from_chatgpt_credits(
         %{target: nil, provider_dispatches: 0} = recovery,
         credits,
         now
       ) do
    case Enum.find(credits, &(&1.status == "available")) do
      %{id: credit_id} -> reserve_and_dispatch_recovery(recovery, credit_id, now)
      nil -> persist_recovery_observation(recovery, "target_available", now, 60)
    end
  end

  defp resume_from_chatgpt_credits(%{target: target} = recovery, credits, now)
       when is_binary(target) do
    case Enum.find(credits, &(&1.id == target)) do
      %{status: "redeemed", redeemed_at: redeemed_at} ->
        settle_recovered_applied(recovery, "target_redeemed", redeemed_at, now)

      %{status: "redeeming"} ->
        persist_recovery_observation(
          recovery,
          "target_redeeming",
          now,
          observation_interval(recovery)
        )

      _available_missing_or_empty when recovery.recovery_mode == :observe_only ->
        persist_recovery_observation(
          recovery,
          "target_available",
          now,
          @observe_only_interval_seconds
        )

      _available_missing_or_empty ->
        reserve_and_dispatch_recovery(recovery, target, now)
    end
  end

  defp resume_codex_recovery(%{recovery_mode: :observe_only} = recovery, now) do
    if fresh_usable_quota_after_dispatch?(recovery, now) do
      settle_recovered_applied(recovery, "reset", nil, now)
    else
      persist_recovery_observation(
        recovery,
        "quota_unresolved",
        now,
        @observe_only_interval_seconds
      )
    end
  end

  defp resume_codex_recovery(recovery, now) do
    if fresh_usable_quota_after_dispatch?(recovery, now) do
      settle_recovered_applied(recovery, "reset", nil, now)
    else
      reserve_and_dispatch_recovery(recovery, nil, now)
    end
  end

  defp fresh_usable_quota_after_dispatch?(
         %{last_provider_dispatched_at: %DateTime{} = dispatched_at, identity: identity},
         now
       ) do
    identity
    |> Windows.list_evidence()
    |> PostResetEvidence.classify(dispatched_at, now)
    |> Kernel.==(:confirmed)
  end

  defp fresh_usable_quota_after_dispatch?(_recovery, _now), do: false

  defp reserve_and_dispatch_recovery(recovery, selected_credit_id, now) do
    case reserve_recovery_dispatch(recovery, selected_credit_id, now) do
      {:ok, reserved_recovery, reserved_credit_id} ->
        dispatch_recovery(reserved_recovery, reserved_credit_id, now)

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:noop, code, identity, assignment} ->
        {:ok, noop_result(identity, assignment, code)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reserve_recovery_dispatch(recovery, selected_credit_id, now) do
    Repo.transaction(fn ->
      reserve_recovery_dispatch_locked(recovery, selected_credit_id, now)
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :saved_reset_persistence_failed}
  end

  defp reserve_recovery_dispatch_locked(recovery, selected_credit_id, now) do
    identity = lock_identity!(recovery.identity.id)
    assignments = lock_canonical_assignments(identity.id)
    canonical = List.first(assignments)
    metadata = identity.metadata || %{}
    redemption = metadata["saved_reset_redemption"] || %{}
    replay = redemption["provider_replay"] || %{}

    with %PoolUpstreamAssignment{id: assignment_id} = assignment <- canonical,
         true <- assignment_id == recovery.assignment.id,
         true <- identity.status == @identity_active,
         true <- exact_recovery_attempt?(redemption, recovery),
         true <- replay["provider_dispatches"] == recovery.provider_dispatches,
         true <- replay["provider_dispatches"] < @maximum_provider_dispatches,
         true <- before_replay_cutoff?(redemption, now),
         {:ok, due_at} <- recovery_replay_due_at(replay),
         true <- DateTime.compare(now, due_at) != :lt,
         {:ok, endpoint_family, consume_url, scope_fingerprint} <-
           provider_scope(identity, assignment, SavedResets.snapshot(identity, now)),
         true <- endpoint_family == recovery.endpoint_family,
         true <- consume_url == recovery.consume_url,
         true <- scope_fingerprint == recovery.scope_fingerprint,
         {:ok, locator, credit_id} <-
           reserve_recovery_target(
             metadata[@redemption_target_key],
             selected_credit_id,
             recovery,
             identity,
             replay
           ) do
      dispatches = replay["provider_dispatches"] + 1
      next_action_at = next_replay_action_at(dispatches, now)

      updated_replay =
        replay
        |> Map.put("provider_dispatches", dispatches)
        |> Map.put("last_provider_dispatched_at", DateTime.to_iso8601(now))
        |> Map.put("next_action_at", DateTime.to_iso8601(next_action_at))
        |> Map.put("mode", "replay")
        |> Map.put("last_code", "dispatch_reserved")

      updated_redemption = Map.put(redemption, "provider_replay", updated_replay)

      updated_metadata =
        metadata
        |> Map.put("saved_reset_redemption", updated_redemption)
        |> put_reserved_locator(locator)

      updated_identity =
        identity
        |> UpstreamIdentity.changeset(%{metadata: updated_metadata, updated_at: now})
        |> Repo.update!()

      updated = %{
        recovery
        | identity: updated_identity,
          assignment: assignment,
          provider_dispatches: dispatches,
          last_provider_dispatched_at: now
      }

      {:ok, updated, credit_id}
    else
      false -> recovery_reservation_conflict(identity, canonical, redemption, recovery, now)
      nil -> {:noop, "recovery_superseded", identity, recovery.assignment}
      _invalid -> {:noop, "scope_changed", identity, canonical || recovery.assignment}
    end
  end

  defp exact_recovery_attempt?(redemption, recovery) do
    redemption["status"] == "redeeming" and redemption["phase"] == "consuming" and
      redemption["attempt_id"] == recovery.attempt_id and
      redemption["generation"] == recovery.generation
  end

  defp before_replay_cutoff?(redemption, now) do
    case parse_datetime(redemption["started_at"]) do
      %DateTime{} = started_at ->
        DateTime.compare(now, DateTime.add(started_at, @replay_cutoff_seconds, :second)) == :lt

      nil ->
        false
    end
  end

  defp reserve_recovery_target(locator, selected_credit_id, recovery, identity, replay) do
    reserve_target(
      locator,
      selected_credit_id,
      recovery.endpoint_kind,
      locator_binding(
        identity.id,
        recovery,
        recovery.endpoint_family,
        recovery.scope_fingerprint
      ),
      replay
    )
  end

  defp recovery_reservation_conflict(identity, canonical, redemption, recovery, now) do
    replay = redemption["provider_replay"] || %{}

    cond do
      not match?(%PoolUpstreamAssignment{id: id} when id == recovery.assignment.id, canonical) ->
        {:noop, "recovery_superseded", identity, canonical || recovery.assignment}

      not exact_recovery_attempt?(redemption, recovery) ->
        {:noop, "recovery_target_invalid", identity, canonical}

      is_integer(replay["provider_dispatches"]) and
          replay["provider_dispatches"] >= @maximum_provider_dispatches ->
        {:noop, "write_budget_exhausted", identity, canonical}

      not before_replay_cutoff?(redemption, now) ->
        {:noop, "write_budget_exhausted", identity, canonical}

      true ->
        recovery_reservation_due_conflict(identity, canonical, replay, now)
    end
  end

  defp recovery_reservation_due_conflict(identity, canonical, replay, now) do
    case recovery_replay_due_at(replay) do
      {:ok, due_at} -> {:snooze, remaining_seconds(due_at, now)}
      :error -> {:noop, "recovery_target_invalid", identity, canonical}
    end
  end

  defp next_replay_action_at(dispatches, now) do
    case Map.get(@replay_delays_seconds, dispatches) do
      nil -> now
      delay -> DateTime.add(now, delay, :second)
    end
  end

  defp dispatch_recovery(%{endpoint_kind: endpoint_kind} = recovery, credit_id, now) do
    body =
      %{"redeem_request_id" => idempotency_key(recovery)}
      |> maybe_put_recovery_credit_id(endpoint_kind, credit_id)

    case Req.post(recovery.consume_url,
           headers:
             CloudflareCookies.request_headers(
               recovery.consume_url,
               request_headers(
                 recovery.access_token,
                 recovery.identity.chatgpt_account_id,
                 :post
               )
             ),
           json: body,
           retry: false,
           receive_timeout: recovery.receive_timeout
         )
         |> store_cloudflare_cookies(recovery.consume_url) do
      {:ok, %{status: status, body: response_body}} ->
        code = response_code(response_body, status, endpoint_kind)
        finalize_recovery_response(recovery, code, status, now)

      {:error, _reason} ->
        preserve_and_snooze_recovery(recovery, "transport_error", now)
    end
  rescue
    _error -> preserve_and_snooze_recovery(recovery, "persistence_failed", now)
  end

  defp maybe_put_recovery_credit_id(body, :chatgpt, credit_id),
    do: Map.put(body, "credit_id", credit_id)

  defp maybe_put_recovery_credit_id(body, :codex, _credit_id), do: body

  defp finalize_recovery_response(recovery, code, status, now)
       when code in @known_applied_codes do
    result =
      result_from_response(
        code,
        status,
        SavedResets.snapshot(recovery.identity).available_count,
        recovery.identity,
        recovery.assignment,
        Map.put(recovery, :finished_at, now)
      )

    finalize_reserved_attempt(result, Map.put(recovery, :finished_at, now))
  end

  defp finalize_recovery_response(recovery, code, _status, now),
    do: preserve_and_snooze_recovery(recovery, code, now)

  defp preserve_and_snooze_recovery(recovery, code, now) do
    if recovery.provider_dispatches >= @maximum_provider_dispatches do
      persist_observe_only_handoff(recovery, now)
    else
      _result =
        recovery
        |> Map.put(:finished_at, now)
        |> preserve_ambiguous_attempt(bounded_recovery_code(code))

      {:snooze, recovery_next_snooze(recovery, now)}
    end
  end

  defp persist_observe_only_handoff(recovery, now) do
    Repo.transaction(fn ->
      identity = lock_identity!(recovery.identity.id)
      metadata = identity.metadata || %{}
      redemption = metadata["saved_reset_redemption"] || %{}

      if exact_recovery_attempt?(redemption, recovery) do
        replay = redemption["provider_replay"]

        {updated_identity, _redemption, updated_replay} =
          enter_observe_only!(identity, redemption, replay, now)

        due_at = observe_only_due_at!(updated_replay, now)
        {:snooze, remaining_seconds(due_at, now), updated_identity}
      else
        {:noop, "recovery_target_invalid", identity, recovery.assignment}
      end
    end)
    |> case do
      {:ok, {:snooze, seconds, _identity}} -> {:snooze, seconds}
      {:ok, {:noop, code, identity, assignment}} -> {:ok, noop_result(identity, assignment, code)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :saved_reset_persistence_failed}
  end

  defp recovery_next_snooze(recovery, now) do
    due_at =
      next_replay_action_at(recovery.provider_dispatches, recovery.last_provider_dispatched_at)

    max(DateTime.diff(due_at, now, :second), 1)
  end

  defp settle_recovered_applied(recovery, code, redeemed_at, now) do
    consumed_at =
      parse_datetime(redeemed_at) || recovery.last_provider_dispatched_at || recovery.started_at

    recovery = Map.put(recovery, :finished_at, now)
    result = recovered_applied_result(recovery, code, consumed_at, now)
    finalize_reserved_attempt(result, recovery)
  end

  defp recovered_applied_result(recovery, code, consumed_at, now) do
    %{
      status: :succeeded,
      applied?: true,
      code: code,
      phase: post_reset_phase(recovery.identity, consumed_at, now),
      consumed_at: consumed_at,
      available_count_before: SavedResets.snapshot(recovery.identity).available_count
    }
  end

  defp persist_recovery_observation(recovery, code, now, snooze_seconds) do
    result =
      Repo.transaction(fn ->
        identity = lock_identity!(recovery.identity.id)
        metadata = identity.metadata || %{}
        redemption = metadata["saved_reset_redemption"] || %{}

        if exact_recovery_attempt?(redemption, recovery) do
          next_action_at =
            recovery
            |> recovery_observation_due_at(now, snooze_seconds)
            |> DateTime.to_iso8601()

          replay =
            redemption["provider_replay"]
            |> Map.put("last_code", bounded_observation_code(code))
            |> Map.put("last_observed_at", DateTime.to_iso8601(now))
            |> Map.put("next_action_at", next_action_at)

          identity
          |> UpstreamIdentity.changeset(%{
            metadata:
              Map.put(
                metadata,
                "saved_reset_redemption",
                Map.put(redemption, "provider_replay", replay)
              ),
            updated_at: now
          })
          |> Repo.update!()

          {:snooze, snooze_seconds}
        else
          {:noop, "recovery_target_invalid", identity, recovery.assignment}
        end
      end)

    case result do
      {:ok, {:snooze, seconds}} ->
        {:snooze, seconds}

      {:ok, {:noop, noop_code, identity, assignment}} ->
        {:ok, noop_result(identity, assignment, noop_code)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _error -> {:error, :saved_reset_persistence_failed}
  end

  defp recovery_observation_due_at(recovery, now, snooze_seconds) do
    requested_due_at = DateTime.add(now, snooze_seconds, :second)

    if recovery.recovery_mode == :observe_only do
      requested_due_at
    else
      case recovery_replay_due_at(%{
             "provider_dispatches" => recovery.provider_dispatches,
             "last_provider_dispatched_at" =>
               encode_optional_datetime(recovery.last_provider_dispatched_at),
             "next_action_at" => nil
           }) do
        {:ok, replay_due_at} -> later_datetime(requested_due_at, replay_due_at)
        :error -> requested_due_at
      end
    end
  end

  defp observation_interval(%{recovery_mode: :observe_only}),
    do: @observe_only_interval_seconds

  defp observation_interval(_recovery), do: 60

  defp bounded_observation_code(code)
       when code in [
              "list_failed",
              "target_redeeming",
              "target_available",
              "quota_unresolved",
              "scope_changed",
              "target_invalid",
              "missing_access_token",
              "legacy_unresolved"
            ],
       do: code

  defp bounded_observation_code(code), do: bounded_recovery_code(code)

  defp persist_observe_only_locked!(identity, redemption, code, now) do
    next_action_at = DateTime.add(now, @observe_only_interval_seconds, :second)

    replay =
      redemption["provider_replay"]
      |> Map.put("mode", "observe_only")
      |> Map.put("last_code", bounded_observation_code(code))
      |> Map.put("last_observed_at", DateTime.to_iso8601(now))
      |> Map.put("next_action_at", DateTime.to_iso8601(next_action_at))

    _identity =
      persist_recovery_redemption!(identity, Map.put(redemption, "provider_replay", replay), now)

    {:snooze, @observe_only_interval_seconds}
  end

  defp persist_recovery_redemption!(identity, redemption, timestamp) do
    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(identity.metadata || %{}, "saved_reset_redemption", redemption),
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp encode_optional_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_optional_datetime(_datetime), do: nil

  @type saved_reset_observation_intent :: %{
          required(:available_count) => non_neg_integer(),
          required(:authoritative_zero?) => boolean(),
          required(:observed_at) => DateTime.t(),
          required(:path_style) => String.t() | nil,
          required(:status) => String.t(),
          required(:usage_path) => String.t() | nil
        }

  @spec ensure_manual_available(PoolUpstreamAssignment.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, PoolUpstreamAssignment.t(), UpstreamIdentity.t()}
          | {:error, lifecycle_error() | :redemption_in_progress}
  def ensure_manual_available(assignment_or_id, opts \\ []) do
    receive_timeout =
      Keyword.get(opts, :receive_timeout, SavedResets.redemption_receive_timeout_ms())

    timestamp = Keyword.get_lazy(opts, :started_at, &now/0)

    with {:ok, assignment, identity} <- load_assignment_identity(assignment_or_id),
         :ok <- ensure_identity_usable(identity),
         :ok <- ensure_credentials_usable(identity),
         :ok <- ensure_saved_reset_available(identity, timestamp, receive_timeout) do
      {:ok, assignment, identity}
    end
  end

  @type claim :: %{
          required(:identity) => UpstreamIdentity.t(),
          required(:assignment) => PoolUpstreamAssignment.t(),
          required(:attempt_id) => Ecto.UUID.t(),
          required(:generation) => non_neg_integer(),
          required(:trigger_kind) => trigger_kind(),
          required(:started_at) => DateTime.t(),
          required(:receive_timeout) => non_neg_integer(),
          optional(:trigger_detail) => String.t(),
          optional(:scheduled_decision_evidence) => scheduled_decision_evidence()
        }

  @spec redeem(PoolUpstreamAssignment.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, redeem_result()}
          | {:error,
             lifecycle_error()
             | :redemption_in_progress
             | :saved_reset_consume_outcome_ambiguous}
  def redeem(assignment_or_id, opts \\ []) do
    trigger_kind = Keyword.get(opts, :trigger_kind, "admin_manual")

    receive_timeout =
      Keyword.get(opts, :receive_timeout, SavedResets.redemption_receive_timeout_ms())

    started_at = Keyword.get_lazy(opts, :started_at, &now/0)

    opts =
      opts
      |> Keyword.put(:trigger_kind, trigger_kind)
      |> Keyword.put(:receive_timeout, receive_timeout)

    with {:ok, assignment, identity} <- load_assignment_identity(assignment_or_id) do
      case normalize_gateway_auto_context(trigger_kind, Keyword.get(opts, :gateway_auto_context)) do
        {:ok, gateway_auto_context} ->
          assignment
          |> claim_attempt(
            identity,
            trigger_kind,
            receive_timeout,
            started_at,
            gateway_auto_context
          )
          |> redeem_claim(opts)

        {:noop, code} ->
          {:ok, noop_result(identity, assignment, code)}
      end
    end
  end

  @spec redeem_scheduled_expiry(
          PoolUpstreamAssignment.t() | Ecto.UUID.t(),
          Ecto.UUID.t(),
          keyword()
        ) :: scheduled_redeem_result()
  def redeem_scheduled_expiry(assignment_or_id, expected_identity_id, opts \\ []) do
    receive_timeout =
      Keyword.get(opts, :receive_timeout, SavedResets.redemption_receive_timeout_ms())

    started_at_override = Keyword.get(opts, :started_at)

    opts =
      opts
      |> Keyword.put(:trigger_kind, @scheduled_expiry_trigger)
      |> Keyword.put(:receive_timeout, receive_timeout)

    assignment_or_id
    |> assignment_id()
    |> claim_scheduled_attempt(
      expected_identity_id,
      receive_timeout,
      started_at_override
    )
    |> redeem_claim(opts)
  end

  @spec redeem_claim(
          {:ok, claim() | {:noop, redeem_result() | scheduled_noop_result()}}
          | {:error, lifecycle_error() | :redemption_in_progress},
          keyword()
        ) ::
          {:ok, redeem_result() | scheduled_noop_result()}
          | {:error,
             lifecycle_error()
             | :redemption_in_progress
             | :saved_reset_consume_outcome_ambiguous}
  defp redeem_claim({:ok, {:noop, result}}, _opts), do: {:ok, result}
  defp redeem_claim({:ok, claim}, opts), do: do_redeem(claim, opts)
  defp redeem_claim({:error, reason}, _opts), do: {:error, reason}

  defp load_assignment_identity(assignment_or_id) do
    assignment_or_id
    |> assignment_id()
    |> load_active_assignment()
  end

  defp load_active_assignment(assignment_id) when is_binary(assignment_id) do
    case Repo.get(PoolUpstreamAssignment, assignment_id) do
      %PoolUpstreamAssignment{status: @assignment_active} = assignment ->
        load_active_identity(assignment)

      _missing_or_inactive ->
        {:error, lifecycle_error(:pool_assignment_not_found, "pool assignment was not found")}
    end
  end

  defp load_active_assignment(_assignment_id),
    do: {:error, lifecycle_error(:pool_assignment_not_found, "pool assignment was not found")}

  defp load_active_identity(%PoolUpstreamAssignment{} = assignment) do
    case Repo.get(UpstreamIdentity, assignment.upstream_identity_id) do
      %UpstreamIdentity{status: @identity_deleted} ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

      %UpstreamIdentity{status: @identity_disabled} ->
        {:error,
         lifecycle_error(:upstream_identity_unavailable, "upstream identity is not available")}

      %UpstreamIdentity{status: status} = identity
      when status not in [@identity_deleted, @identity_disabled] ->
        {:ok, assignment, identity}

      _missing_or_inactive ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  defp ensure_identity_usable(%UpstreamIdentity{status: @identity_deleted}),
    do: {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

  defp ensure_identity_usable(%UpstreamIdentity{status: @identity_disabled}),
    do:
      {:error,
       lifecycle_error(:upstream_identity_unavailable, "upstream identity is not available")}

  defp ensure_identity_usable(%UpstreamIdentity{}), do: :ok

  defp ensure_credentials_usable(%UpstreamIdentity{} = identity) do
    case Secrets.secret_status(identity) do
      :present ->
        :ok

      _status ->
        {:error,
         lifecycle_error(
           :upstream_secret_not_routable,
           "saved reset redemption requires usable credentials"
         )}
    end
  end

  defp ensure_saved_reset_available(%UpstreamIdentity{} = identity, timestamp, receive_timeout) do
    snapshot = SavedResets.snapshot(identity, timestamp)
    redemption = (identity.metadata || %{})["saved_reset_redemption"]

    cond do
      RedemptionLifecycle.blocks_new_redemption?(redemption, timestamp) ->
        {:error,
         lifecycle_error(
           :saved_reset_redemption_in_progress,
           "saved reset redemption is already in progress"
         )}

      fresh_redemption?(redemption, timestamp, receive_timeout) ->
        {:error, :redemption_in_progress}

      snapshot.in_progress? ->
        {:error,
         lifecycle_error(
           :saved_reset_redemption_in_progress,
           "saved reset redemption is already in progress"
         )}

      snapshot.reported? != true or snapshot.available? != true ->
        {:error, lifecycle_error(:saved_reset_unavailable, "no saved resets are available")}

      true ->
        :ok
    end
  end

  defp normalize_gateway_auto_context("gateway_auto", context) do
    case AutoEligibility.normalize_context(context) do
      {:ok, context} -> {:ok, context}
      {:error, :invalid_gateway_auto_context} -> {:noop, "gateway_auto_context_invalid"}
    end
  end

  defp normalize_gateway_auto_context(_trigger_kind, _context), do: {:ok, nil}

  defp gateway_auto_trigger_detail(%{trigger: :blocked_weekly_exhaustion}), do: "exhausted"
  defp gateway_auto_trigger_detail(%{trigger: :threshold_pressure}), do: "threshold"
  defp gateway_auto_trigger_detail(_context), do: nil

  defp claim_attempt(
         assignment,
         identity,
         trigger_kind,
         receive_timeout,
         started_at,
         gateway_auto_context
       ) do
    Repo.transaction(fn ->
      case lock_claim_identity(identity.id, gateway_auto_context) do
        {:ok, locked_identity, locked_cohort} ->
          claim_locked_identity!(
            locked_identity,
            locked_cohort,
            assignment,
            trigger_kind,
            receive_timeout,
            started_at,
            gateway_auto_context
          )

        {:noop, code} ->
          {:noop, noop_result(identity, assignment, code)}
      end
    end)
    |> case do
      {:ok, claim} -> {:ok, claim}
      {:error, :redemption_in_progress} -> {:error, :redemption_in_progress}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_scheduled_attempt(
         assignment_id,
         expected_identity_id,
         receive_timeout,
         started_at_override
       ) do
    Repo.transaction(fn ->
      case lock_scheduled_identity(expected_identity_id) do
        %UpstreamIdentity{} = locked_identity ->
          claim_locked_scheduled_identity!(
            locked_identity,
            assignment_id,
            expected_identity_id,
            receive_timeout,
            started_at_override
          )

        nil ->
          {:noop, scheduled_noop_result("scheduled_expiry_identity_unavailable")}
      end
    end)
    |> case do
      {:ok, claim} -> {:ok, claim}
      {:error, :redemption_in_progress} -> {:error, :redemption_in_progress}
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_locked_scheduled_identity!(
         locked_identity,
         assignment_id,
         expected_identity_id,
         receive_timeout,
         started_at_override
       ) do
    case lock_scheduled_assignment(assignment_id) do
      %PoolUpstreamAssignment{} = locked_assignment ->
        decision_at = started_at_override || now()

        case AutoEligibility.validate_locked_scheduled_expiry(
               locked_identity,
               locked_assignment,
               expected_identity_id,
               decision_at,
               receive_timeout
             ) do
          {:ok, scheduled_burn_context} ->
            build_redemption_claim!(
              locked_identity.metadata || %{},
              locked_identity,
              locked_assignment,
              @scheduled_expiry_trigger,
              receive_timeout,
              decision_at,
              scheduled_burn_context,
              nil
            )

          {:noop, code} ->
            {:noop, noop_result(locked_identity, locked_assignment, code)}

          {:error, reason} ->
            Repo.rollback(reason)
        end

      nil ->
        {:noop,
         scheduled_noop_result(
           "scheduled_expiry_assignment_unavailable",
           locked_identity
         )}
    end
  end

  defp claim_locked_identity!(
         locked_identity,
         locked_cohort,
         assignment,
         trigger_kind,
         receive_timeout,
         started_at,
         gateway_auto_context
       ) do
    metadata = locked_identity.metadata || %{}
    redemption = metadata["saved_reset_redemption"]

    cond do
      # A lifecycle that already consumed a credit (pending, in-flight, expired,
      # or unrecognized) can never be overridden into a second consumption, not
      # even by the stale-admin recovery path. Recovery is evidence-only.
      RedemptionLifecycle.blocks_new_redemption?(redemption, started_at) ->
        Repo.rollback(:redemption_in_progress)

      redemption_in_progress_for_trigger?(redemption, started_at, receive_timeout, trigger_kind) ->
        Repo.rollback(:redemption_in_progress)

      true ->
        claim_validated_identity!(
          locked_identity,
          locked_cohort,
          assignment,
          trigger_kind,
          receive_timeout,
          started_at,
          gateway_auto_context
        )
    end
  end

  defp claim_validated_identity!(
         locked_identity,
         locked_cohort,
         assignment,
         trigger_kind,
         receive_timeout,
         started_at,
         gateway_auto_context
       ) do
    metadata = locked_identity.metadata || %{}
    redemption = metadata["saved_reset_redemption"]

    case validate_locked_gateway_auto(
           locked_identity,
           assignment,
           gateway_auto_context,
           started_at
         ) do
      {:ok, current_assignment} ->
        case gateway_auto_sibling_fence(
               locked_identity,
               locked_cohort,
               gateway_auto_context,
               started_at
             ) do
          :ok ->
            locked_identity
            |> maybe_mark_stale_admin_redemption!(
              metadata,
              redemption,
              trigger_kind,
              started_at
            )
            |> build_redemption_claim!(
              locked_identity,
              current_assignment,
              trigger_kind,
              receive_timeout,
              started_at,
              nil,
              gateway_auto_trigger_detail(gateway_auto_context)
            )

          {:noop, code} ->
            {:noop, noop_result(locked_identity, current_assignment, code)}
        end

      {:noop, code} ->
        {:noop, noop_result(locked_identity, assignment, code)}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp gateway_auto_sibling_fence(locked_identity, locked_cohort, gateway_auto_context, timestamp) do
    case sibling_consume_fence(locked_identity, locked_cohort, gateway_auto_context, timestamp) do
      :ok ->
        sibling_usable_capacity_fence(
          locked_identity,
          locked_cohort,
          gateway_auto_context,
          timestamp
        )

      {:noop, _code} = result ->
        result
    end
  end

  defp validate_locked_gateway_auto(_locked_identity, assignment, nil, _started_at),
    do: {:ok, assignment}

  defp validate_locked_gateway_auto(
         %UpstreamIdentity{} = locked_identity,
         %PoolUpstreamAssignment{} = assignment,
         gateway_auto_context,
         %DateTime{} = started_at
       ) do
    with {:ok, locked_assignment} <- lock_gateway_auto_assignment(assignment),
         :ok <-
           AutoEligibility.validate_locked_gateway_auto(
             locked_identity,
             locked_assignment,
             gateway_auto_context,
             started_at
           ) do
      {:ok, locked_assignment}
    end
  end

  defp lock_gateway_auto_assignment(%PoolUpstreamAssignment{id: assignment_id}) do
    case Repo.one(
           from assignment in PoolUpstreamAssignment,
             where: assignment.id == ^assignment_id,
             lock: "FOR UPDATE"
         ) do
      %PoolUpstreamAssignment{} = assignment -> {:ok, assignment}
      nil -> {:noop, "gateway_auto_assignment_unavailable"}
    end
  end

  defp sibling_consume_fence(_locked_identity, _locked_cohort, nil, _timestamp), do: :ok

  defp sibling_consume_fence(locked_identity, locked_cohort, _gateway_auto_context, timestamp) do
    if Enum.any?(locked_cohort, fn {identity_id, sibling} ->
         identity_id != locked_identity.id and
           RedemptionLifecycle.gateway_auto_sibling_fence(
             (sibling.metadata || %{})["saved_reset_redemption"],
             timestamp
           ) != :clear
       end) do
      {:noop, "gateway_auto_sibling_consume_barrier"}
    else
      :ok
    end
  end

  defp sibling_usable_capacity_fence(_locked_identity, _locked_cohort, nil, _timestamp), do: :ok

  defp sibling_usable_capacity_fence(
         locked_identity,
         locked_cohort,
         %{trigger: :threshold_pressure, session_continuity?: false} = gateway_auto_context,
         timestamp
       ) do
    routable_identity_ids =
      Map.get(
        gateway_auto_context,
        :routable_identity_ids,
        gateway_auto_context.candidate_identity_ids
      )

    if Enum.any?(locked_cohort, fn {identity_id, sibling} ->
         identity_id != locked_identity.id and identity_id in routable_identity_ids and
           AutoEligibility.locked_sibling_usable_capacity?(
             sibling,
             gateway_auto_context,
             timestamp
           )
       end) do
      {:noop, "gateway_auto_sibling_usable_capacity"}
    else
      :ok
    end
  end

  defp sibling_usable_capacity_fence(_locked_identity, _locked_cohort, _context, _timestamp),
    do: :ok

  defp lock_scheduled_identity(identity_id) do
    case Ecto.UUID.cast(identity_id) do
      {:ok, identity_id} ->
        Repo.one(
          from identity in UpstreamIdentity,
            where: identity.id == ^identity_id,
            lock: "FOR UPDATE"
        )

      :error ->
        nil
    end
  end

  defp lock_scheduled_assignment(assignment_id) do
    case Ecto.UUID.cast(assignment_id) do
      {:ok, assignment_id} ->
        Repo.one(
          from assignment in PoolUpstreamAssignment,
            where: assignment.id == ^assignment_id,
            lock: "FOR UPDATE"
        )

      :error ->
        nil
    end
  end

  defp redemption_in_progress_for_trigger?(redemption, started_at, receive_timeout, trigger_kind) do
    fresh_redemption?(redemption, started_at, receive_timeout) or
      (stale_redemption?(redemption) and trigger_kind == "gateway_auto")
  end

  defp maybe_mark_stale_admin_redemption!(
         locked_identity,
         metadata,
         redemption,
         "admin_manual",
         started_at
       ) do
    # A stale record still in the `consuming` phase crashed inside the consume
    # POST window: the provider may already have applied it, so it must not be
    # marked failed and re-keyed — the claim below resumes the same attempt and
    # generation, reproducing the same provider idempotency key.
    if stale_redemption?(redemption) and resumable_consume_crash?(redemption) == false do
      mark_stale_redemption_failed!(locked_identity, redemption, started_at).metadata || %{}
    else
      metadata
    end
  end

  defp maybe_mark_stale_admin_redemption!(
         _locked_identity,
         metadata,
         _redemption,
         _trigger_kind,
         _started_at
       ),
       do: metadata

  defp build_redemption_claim!(
         metadata,
         locked_identity,
         assignment,
         trigger_kind,
         receive_timeout,
         started_at,
         scheduled_burn_context,
         trigger_detail
       ) do
    case encode_claim_scheduled_decision_evidence(scheduled_burn_context) do
      {:ok, scheduled_decision_evidence} ->
        {attempt_id, generation} = claim_attempt_identity(metadata)

        claim =
          %{
            "status" => "redeeming",
            "phase" => RedemptionLifecycle.consuming(),
            "attempt_id" => attempt_id,
            "generation" => generation,
            "trigger_kind" => trigger_kind,
            "started_at" => DateTime.to_iso8601(started_at),
            "finished_at" => nil,
            "result" => nil
          }
          |> put_trigger_detail(trigger_detail)
          |> put_scheduled_decision_evidence(scheduled_decision_evidence)
          |> put_carried_applied_consume(metadata["saved_reset_redemption"] || %{})

        {metadata, claim} =
          put_provider_replay_contract(metadata, claim, locked_identity, assignment, started_at)

        claimed_identity = update_redemption_metadata!(locked_identity, metadata, claim)

        %{
          identity: claimed_identity,
          assignment: assignment,
          attempt_id: attempt_id,
          generation: generation,
          trigger_kind: trigger_kind,
          started_at: started_at,
          receive_timeout: receive_timeout
        }
        |> maybe_put_claim_trigger_detail(trigger_detail)
        |> maybe_put_claim_scheduled_decision_evidence(scheduled_decision_evidence)

      {:error, :invalid_decision_evidence} ->
        {:noop,
         noop_result(
           locked_identity,
           assignment,
           "scheduled_expiry_decision_evidence_invalid"
         )}
    end
  end

  defp do_redeem(%{identity: identity, assignment: assignment} = claim, opts) do
    case Secrets.decrypt_active_secret(identity, "access_token") do
      {:ok, access_token} ->
        result =
          identity
          |> SavedResets.snapshot()
          |> endpoint_family_result(identity, assignment, access_token, claim, opts)

        case result do
          {:error, reason} ->
            {:error, reason}

          {:ambiguous, code} ->
            preserve_ambiguous_attempt(claim, code)

          {:finalize, result, reserved_claim} ->
            finalize_reserved_attempt(result, reserved_claim)

          result when is_map(result) ->
            finalize_attempt(result, claim)
        end

      {:error, _reason} ->
        finalize_attempt(
          %{
            status: :failed,
            applied?: false,
            code: "missing_access_token",
            reason: "active access token was not available"
          },
          claim
        )
    end
  end

  defp finalize_reserved_attempt(result, claim) do
    case finalize_attempt(result, claim) do
      {:ok, _result} = success ->
        success

      {:error, _reason} ->
        preserve_ambiguous_attempt(claim, "persistence_failed")
    end
  rescue
    _exception -> preserve_ambiguous_attempt(claim, "persistence_failed")
  end

  defp endpoint_family_result(
         %{path_style: "chatgpt_api"} = snapshot,
         identity,
         assignment,
         access_token,
         claim,
         _opts
       ) do
    with {:ok, list_url, consume_url} <- chatgpt_reset_urls(identity, assignment, snapshot),
         {:ok, list_result} <-
           list_chatgpt_credits(list_url, identity, access_token, claim.receive_timeout) do
      case list_result do
        %{credit_id: nil, available_count: available_count, http_status: http_status} ->
          %{
            status: :noop,
            applied?: false,
            code: "no_credit",
            available_count_before: available_count,
            available_count_after: 0,
            http_status: http_status,
            saved_reset_observation:
              no_credit_observation_intent(snapshot, available_count, claim.started_at)
          }

        %{credit_id: credit_id, available_count: available_count} ->
          consume_credit(
            consume_url,
            identity,
            access_token,
            %{"credit_id" => credit_id, "redeem_request_id" => idempotency_key(claim)},
            available_count,
            claim,
            :chatgpt
          )
      end
    else
      {:error, result} -> result
    end
  end

  defp endpoint_family_result(
         %{path_style: "codex_api"} = snapshot,
         identity,
         assignment,
         access_token,
         claim,
         _opts
       ) do
    case codex_reset_url(identity, assignment, snapshot) do
      {:ok, consume_url} ->
        consume_credit(
          consume_url,
          identity,
          access_token,
          %{"redeem_request_id" => idempotency_key(claim)},
          snapshot.available_count,
          claim,
          :codex
        )

      {:error, result} ->
        result
    end
  end

  defp endpoint_family_result(_snapshot, _identity, _assignment, _access_token, _claim, _opts) do
    %{
      status: :noop,
      applied?: false,
      code: "saved_reset_endpoint_unknown"
    }
  end

  defp list_chatgpt_credits(url, identity, access_token, receive_timeout) do
    case Req.get(url,
           headers:
             CloudflareCookies.request_headers(
               url,
               request_headers(access_token, identity.chatgpt_account_id, :get)
             ),
           retry: false,
           receive_timeout: receive_timeout
         )
         |> store_cloudflare_cookies(url) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, parse_chatgpt_credit_list(body, status)}

      {:ok, %{status: status}} ->
        {:error, failed_result(http_code(status), status)}

      {:error, _reason} ->
        {:error, transport_failed_result()}
    end
  end

  defp parse_chatgpt_credit_list(body, http_status) do
    credits = Map.get(body, "credits")
    usable_credit = first_usable_credit(credits)

    available_count =
      case non_negative_truncated_integer(Map.get(body, "available_count")) do
        {:ok, count} -> count
        :error -> Enum.count(List.wrap(credits), &usable_credit?/1)
      end

    %{
      credit_id: usable_credit && usable_credit["id"],
      available_count: available_count,
      http_status: http_status
    }
  end

  defp first_usable_credit(credits) when is_list(credits),
    do: Enum.find(credits, &usable_credit?/1)

  defp first_usable_credit(_credits), do: nil

  defp usable_credit?(%{"id" => id} = credit) when is_binary(id) do
    not Map.has_key?(credit, "status") or credit["status"] == "available"
  end

  defp usable_credit?(_credit), do: false

  defp consume_credit(
         url,
         _identity,
         access_token,
         body,
         available_count_before,
         claim,
         endpoint_kind
       ) do
    credit_id = if endpoint_kind == :chatgpt, do: body["credit_id"]

    with {:ok, reserved_claim, reserved_credit_id} <-
           reserve_provider_dispatch(claim, url, endpoint_kind, credit_id) do
      consume_reserved_credit(
        url,
        access_token,
        body,
        available_count_before,
        reserved_claim,
        reserved_credit_id,
        endpoint_kind
      )
    end
  end

  defp consume_reserved_credit(
         url,
         access_token,
         body,
         available_count_before,
         reserved_claim,
         reserved_credit_id,
         endpoint_kind
       ) do
    body =
      if endpoint_kind == :chatgpt,
        do: Map.put(body, "credit_id", reserved_credit_id),
        else: body

    case Req.post(url,
           headers:
             CloudflareCookies.request_headers(
               url,
               request_headers(
                 access_token,
                 reserved_claim.identity.chatgpt_account_id,
                 :post
               )
             ),
           json: body,
           retry: false,
           receive_timeout: reserved_claim.receive_timeout
         )
         |> store_cloudflare_cookies(url) do
      {:ok, %{status: status, body: response_body}} ->
        handle_consume_response(
          response_code(response_body, status, endpoint_kind),
          status,
          available_count_before,
          reserved_claim
        )

      {:error, _reason} ->
        {:ambiguous, "transport_error"}
    end
  rescue
    _exception -> preserve_ambiguous_attempt(reserved_claim, "persistence_failed")
  end

  defp handle_consume_response(code, status, available_count_before, claim)
       when code in @known_provider_result_codes do
    {:finalize,
     result_from_response(
       code,
       status,
       available_count_before,
       claim.identity,
       claim.assignment,
       claim
     ), claim}
  end

  defp handle_consume_response(code, _status, _available_count_before, _claim),
    do: {:ambiguous, code}

  defp store_cloudflare_cookies(result, url) do
    CloudflareCookies.store_from_result(url, result)
    result
  end

  defp result_from_response(code, status, available_count_before, identity, assignment, claim) do
    cond do
      code in ["reset", "already_redeemed"] ->
        # The provider consumed a credit as of now; capture that before the
        # refresh so evidence is only accepted when observed at/after it.
        consumed_at = claim[:finished_at] || now()

        case PoolReconciliation.refresh_quota_from_usage(identity, assignment,
               receive_timeout: claim.receive_timeout
             ) do
          {:ok, refreshed_identity} ->
            available_count_after = SavedResets.snapshot(refreshed_identity).available_count

            %{
              status: :succeeded,
              applied?: true,
              code: code,
              phase: post_reset_phase(refreshed_identity, consumed_at, consumed_at),
              consumed_at: consumed_at,
              available_count_before: available_count_before,
              available_count_after: available_count_after,
              http_status: status
            }

          {:error, _reason} ->
            # The provider returned `reset`: a credit was consumed. A failed or
            # partial usage refresh must not reverse that external side effect,
            # and must not report `applied=false` (which would let a later
            # request consume a second credit). Record the consumed credit as a
            # pending confirmation, fail-closed, so it converges only from fresh
            # provider evidence.
            %{
              status: :succeeded,
              applied?: true,
              code: code,
              phase: RedemptionLifecycle.consumed_pending_probe(),
              consumed_at: consumed_at,
              available_count_before: available_count_before,
              http_status: status,
              reason: "quota refresh after saved reset is pending confirmation"
            }
        end

      code in ["no_credit", "nothing_to_reset"] ->
        %{
          status: :noop,
          applied?: false,
          code: code,
          available_count_before: available_count_before,
          http_status: status
        }

      true ->
        %{
          status: :failed,
          applied?: false,
          code: code,
          available_count_before: available_count_before,
          http_status: status,
          reason: "saved reset redemption failed"
        }
    end
  end

  defp response_code(body, status, _endpoint_kind) do
    with true <- status in 200..299,
         true <- is_map(body),
         code when code in @known_provider_result_codes <- body["code"],
         true <- valid_windows_reset?(body) do
      code
    else
      _invalid when status in 500..599 -> "provider_failed"
      _invalid -> "malformed_response"
    end
  end

  defp valid_windows_reset?(body) do
    not Map.has_key?(body, "windows_reset") or is_integer(body["windows_reset"])
  end

  defp chatgpt_reset_urls(identity, assignment, snapshot) do
    base = reset_base_url(identity, assignment)

    case snapshot.usage_path do
      "/wham/usage" ->
        {:ok, base <> "/wham/rate-limit-reset-credits",
         base <> "/wham/rate-limit-reset-credits/consume"}

      "/backend-api/wham/usage" ->
        {:ok, base <> "/backend-api/wham/rate-limit-reset-credits",
         base <> "/backend-api/wham/rate-limit-reset-credits/consume"}

      nil ->
        {:ok, base <> "/backend-api/wham/rate-limit-reset-credits",
         base <> "/backend-api/wham/rate-limit-reset-credits/consume"}

      _usage_path ->
        {:error, %{status: :noop, applied?: false, code: "saved_reset_endpoint_unknown"}}
    end
  end

  defp codex_reset_url(identity, assignment, snapshot) do
    base = reset_base_url(identity, assignment)

    case snapshot.usage_path do
      "/api/codex/usage" ->
        {:ok, base <> "/api/codex/rate-limit-reset-credits/consume"}

      "/backend-api/codex/usage" ->
        {:ok, base <> "/backend-api/codex/rate-limit-reset-credits/consume"}

      nil ->
        {:ok, base <> "/api/codex/rate-limit-reset-credits/consume"}

      _usage_path ->
        {:error, %{status: :noop, applied?: false, code: "saved_reset_endpoint_unknown"}}
    end
  end

  defp reset_base_url(identity, assignment) do
    identity
    |> EndpointMetadata.usage_base_url(assignment)
    |> EndpointMetadata.normalize_base_url()
  end

  defp request_headers(access_token, chatgpt_account_id, request_kind) do
    headers = [
      {"authorization", "Bearer " <> String.trim(access_token)},
      {"accept", "application/json"}
    ]

    headers =
      if request_kind == :post do
        headers ++ [{"content-type", "application/json"}]
      else
        headers
      end

    if account_scope = emitted_chatgpt_account_scope(chatgpt_account_id) do
      headers ++ [{"chatgpt-account-id", account_scope}]
    else
      headers
    end
  end

  defp send_chatgpt_account_header?(chatgpt_account_id) when is_binary(chatgpt_account_id) do
    chatgpt_account_id = String.trim(chatgpt_account_id)

    chatgpt_account_id != "" and not String.starts_with?(chatgpt_account_id, "email_") and
      not String.starts_with?(chatgpt_account_id, "local_")
  end

  defp send_chatgpt_account_header?(_chatgpt_account_id), do: false

  defp emitted_chatgpt_account_scope(chatgpt_account_id) do
    if send_chatgpt_account_header?(chatgpt_account_id),
      do: String.trim(chatgpt_account_id),
      else: nil
  end

  defp put_provider_replay_contract(metadata, claim, identity, assignment, started_at) do
    snapshot = SavedResets.snapshot(identity, started_at)

    case provider_scope(identity, assignment, snapshot) do
      {:ok, endpoint_family, _consume_url, scope_fingerprint} ->
        metadata = Map.delete(metadata, @redemption_target_key)

        replay = %{
          "version" => 1,
          "endpoint_family" => endpoint_family,
          "scope_fingerprint" => scope_fingerprint,
          "provider_dispatches" => 0,
          "mode" => "replay",
          "next_action_at" => DateTime.to_iso8601(started_at)
        }

        {metadata, Map.put(claim, "provider_replay", replay)}

      :unsupported ->
        {metadata, claim}
    end
  end

  defp provider_scope(identity, assignment, %{path_style: "chatgpt_api"} = snapshot) do
    case chatgpt_reset_urls(identity, assignment, snapshot) do
      {:ok, _list_url, consume_url} ->
        endpoint_family = "chatgpt_api"
        account_scope = emitted_chatgpt_account_scope(identity.chatgpt_account_id) || ""

        {:ok, endpoint_family, consume_url,
         CreditLocator.scope_fingerprint(endpoint_family, consume_url, account_scope)}

      {:error, _result} ->
        :unsupported
    end
  end

  defp provider_scope(identity, assignment, %{path_style: "codex_api"} = snapshot) do
    case codex_reset_url(identity, assignment, snapshot) do
      {:ok, consume_url} ->
        endpoint_family = "codex_api"

        {:ok, endpoint_family, consume_url,
         CreditLocator.scope_fingerprint(endpoint_family, consume_url, "")}

      {:error, _result} ->
        :unsupported
    end
  end

  defp provider_scope(_identity, _assignment, _snapshot), do: :unsupported

  defp reserve_provider_dispatch(claim, consume_url, endpoint_kind, selected_credit_id) do
    Repo.transaction(fn ->
      identity = lock_identity!(claim.identity.id)
      metadata = identity.metadata || %{}
      redemption = metadata["saved_reset_redemption"] || %{}

      with :ok <- validate_reservation_identity(redemption, claim),
           :ok <- validate_reservation_dispatch(redemption, claim),
           {:ok, locked_assignment} <-
             lock_reservation_assignment(claim.assignment.id, identity.id),
           {:ok, endpoint_family, ^consume_url, scope_fingerprint} <-
             provider_scope(identity, locked_assignment, SavedResets.snapshot(identity)),
           :ok <-
             validate_replay_contract(
               redemption["provider_replay"],
               endpoint_family,
               scope_fingerprint
             ),
           {:ok, locator, credit_id} <-
             reserve_target(
               metadata[@redemption_target_key],
               selected_credit_id,
               endpoint_kind,
               locator_binding(identity.id, claim, endpoint_family, scope_fingerprint),
               redemption["provider_replay"]
             ) do
        dispatched_at = now()

        replay =
          redemption["provider_replay"]
          |> Map.update!("provider_dispatches", &(&1 + 1))
          |> Map.put("last_provider_dispatched_at", DateTime.to_iso8601(dispatched_at))
          |> Map.put(
            "next_action_at",
            DateTime.to_iso8601(next_replay_action_at(1, dispatched_at))
          )
          |> Map.put("last_code", "dispatch_reserved")

        redemption = Map.put(redemption, "provider_replay", replay)

        metadata =
          metadata
          |> Map.put("saved_reset_redemption", redemption)
          |> put_reserved_locator(locator)

        updated_identity =
          identity
          |> UpstreamIdentity.changeset(%{metadata: metadata, updated_at: dispatched_at})
          |> Repo.update!()

        {claim |> Map.put(:identity, updated_identity) |> Map.put(:assignment, locked_assignment),
         credit_id}
      else
        _invalid -> Repo.rollback(:saved_reset_dispatch_reservation_invalid)
      end
    end)
    |> case do
      {:ok, {reserved_claim, credit_id}} -> {:ok, reserved_claim, credit_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_reservation_identity(redemption, claim) do
    if redemption["status"] == "redeeming" and
         redemption["phase"] == RedemptionLifecycle.consuming() and
         redemption["attempt_id"] == claim.attempt_id and
         redemption["generation"] == claim.generation,
       do: :ok,
       else: :error
  end

  defp validate_reservation_dispatch(redemption, claim) do
    persisted_dispatches = get_in(redemption, ["provider_replay", "provider_dispatches"])

    loaded_dispatches =
      get_in(claim.identity.metadata || %{}, [
        "saved_reset_redemption",
        "provider_replay",
        "provider_dispatches"
      ])

    if is_integer(persisted_dispatches) and persisted_dispatches == loaded_dispatches,
      do: :ok,
      else: :error
  end

  defp lock_reservation_assignment(assignment_id, identity_id) do
    case Repo.one(
           from assignment in PoolUpstreamAssignment,
             where:
               assignment.id == ^assignment_id and
                 assignment.upstream_identity_id == ^identity_id and
                 assignment.status == ^@assignment_active,
             lock: "FOR UPDATE"
         ) do
      %PoolUpstreamAssignment{} = assignment -> {:ok, assignment}
      nil -> :error
    end
  end

  defp validate_replay_contract(
         %{
           "version" => 1,
           "endpoint_family" => endpoint_family,
           "scope_fingerprint" => scope_fingerprint,
           "provider_dispatches" => provider_dispatches
         },
         endpoint_family,
         scope_fingerprint
       )
       when is_integer(provider_dispatches) and provider_dispatches == 0,
       do: :ok

  defp validate_replay_contract(_replay, _endpoint_family, _scope_fingerprint), do: :error

  defp reserve_target(locator, selected_credit_id, :chatgpt, binding, %{
         "provider_dispatches" => provider_dispatches
       }) do
    cond do
      is_binary(locator) ->
        with {:ok, credit_id} <- CreditLocator.open(locator, binding) do
          {:ok, locator, credit_id}
        end

      provider_dispatches == 0 and is_binary(selected_credit_id) ->
        with {:ok, locator} <- CreditLocator.seal(selected_credit_id, binding) do
          {:ok, locator, selected_credit_id}
        end

      true ->
        {:error, :saved_reset_credit_locator_invalid}
    end
  end

  defp reserve_target(_locator, _selected_credit_id, :codex, _binding, _replay),
    do: {:ok, nil, nil}

  defp locator_binding(identity_id, claim, endpoint_family, scope_fingerprint) do
    %{
      identity_id: identity_id,
      attempt_id: claim.attempt_id,
      generation: claim.generation,
      endpoint_family: endpoint_family,
      scope_fingerprint: scope_fingerprint
    }
  end

  defp put_reserved_locator(metadata, locator) when is_binary(locator),
    do: Map.put(metadata, @redemption_target_key, locator)

  defp put_reserved_locator(metadata, nil), do: Map.delete(metadata, @redemption_target_key)

  defp preserve_ambiguous_attempt(claim, code) do
    _result =
      Repo.transaction(fn ->
        identity = lock_identity!(claim.identity.id)
        metadata = identity.metadata || %{}
        redemption = metadata["saved_reset_redemption"] || %{}

        if redemption["attempt_id"] == claim.attempt_id and
             redemption["generation"] == claim.generation and
             redemption["phase"] == RedemptionLifecycle.consuming() and
             get_in(redemption, ["provider_replay", "provider_dispatches"]) in 1..6 do
          replay =
            redemption["provider_replay"]
            |> Map.put("last_code", bounded_recovery_code(code))

          identity
          |> UpstreamIdentity.changeset(%{
            metadata:
              Map.put(
                metadata,
                "saved_reset_redemption",
                Map.put(redemption, "provider_replay", replay)
              ),
            updated_at: claim[:finished_at] || now()
          })
          |> Repo.update!()
        end
      end)

    {:error, :saved_reset_consume_outcome_ambiguous}
  rescue
    _error -> {:error, :saved_reset_consume_outcome_ambiguous}
  end

  defp bounded_recovery_code(code)
       when code in [
              "transport_error",
              "provider_failed",
              "persistence_failed",
              "no_credit",
              "nothing_to_reset"
            ],
       do: code

  defp bounded_recovery_code("malformed_response"), do: "provider_failed"
  defp bounded_recovery_code("http_" <> _status), do: "provider_failed"

  defp bounded_recovery_code(_code), do: "provider_failed"

  defp finalize_attempt(result, claim) do
    Repo.transaction(fn ->
      identity = lock_identity!(claim.identity.id)
      metadata = identity.metadata || %{}
      redemption = metadata["saved_reset_redemption"] || %{}

      if finalization_matches_claim?(redemption, claim) do
        finished_at = claim[:finished_at] || now()

        base = %{
          "attempt_id" => claim.attempt_id,
          "generation" => claim.generation,
          "trigger_kind" => claim.trigger_kind,
          "started_at" => DateTime.to_iso8601(claim.started_at),
          "finished_at" => DateTime.to_iso8601(finished_at),
          "result" => metadata_result(result)
        }

        base =
          base
          |> put_trigger_detail(claim[:trigger_detail])
          |> put_scheduled_decision_evidence(claim[:scheduled_decision_evidence])
          |> put_carried_applied_consume(redemption)
          |> put_provider_replay_history(redemption)

        redemption = Map.merge(base, redemption_lifecycle_fields(result))

        metadata = Map.delete(metadata, @redemption_target_key)

        {metadata, ledger} =
          apply_saved_reset_observation(
            identity,
            metadata,
            result[:saved_reset_observation]
          )

        updated_identity =
          persist_finalized_attempt!(identity, metadata, ledger, redemption, finished_at)

        updated_identity
      else
        resolve_finalizer_cas_loss(identity, claim)
      end
    end)
    |> case do
      {:ok, updated_identity} ->
        broadcast_redemption(updated_identity)

        {:ok,
         result
         |> Map.delete(:saved_reset_observation)
         |> Map.put(:identity, updated_identity)
         |> Map.put(:assignment, claim.assignment)}

      {:error, reason} ->
        if claim_has_reserved_dispatch?(claim) do
          {:error, :saved_reset_consume_outcome_ambiguous}
        else
          {:error, reason}
        end
    end
  end

  defp resolve_finalizer_cas_loss(identity, claim) do
    if claim_has_reserved_dispatch?(claim),
      do: Repo.rollback(:saved_reset_finalizer_cas_lost),
      else: identity
  end

  defp finalization_matches_claim?(redemption, %{endpoint_kind: _endpoint_kind} = recovery) do
    exact_recovery_attempt?(redemption, recovery)
  end

  defp finalization_matches_claim?(redemption, claim) do
    redemption["attempt_id"] == claim.attempt_id and
      redemption["generation"] == claim.generation
  end

  defp metadata_result(result) do
    %{
      "code" => result.code,
      "applied" => result.applied?,
      "available_count_before" => Map.get(result, :available_count_before),
      "available_count_after" => Map.get(result, :available_count_after),
      "http_status" => Map.get(result, :http_status)
    }
  end

  # A result carrying a lifecycle `:phase` records the phase-driven legacy status
  # plus the consume timestamp and bounded-window deadline. Every other result
  # keeps the legacy top-level status derived from the redemption outcome.
  defp redemption_lifecycle_fields(%{phase: phase, consumed_at: %DateTime{} = consumed_at})
       when is_binary(phase) do
    %{
      "status" => RedemptionLifecycle.legacy_status_for(phase),
      "phase" => phase,
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "deadline_at" => DateTime.to_iso8601(RedemptionLifecycle.deadline_at(consumed_at))
    }
  end

  defp redemption_lifecycle_fields(result), do: %{"status" => Atom.to_string(result.status)}

  # After a consumed reset, only fresh usable account evidence observed at/after
  # the consume time confirms the identity. Anything else (the provider omitted
  # the account window, or it is still exhausted) stays pending and converges
  # later from real evidence — never a fabricated success.
  defp post_reset_phase(refreshed_identity, consumed_at, timestamp) do
    case PostResetEvidence.classify(
           Windows.list_evidence(refreshed_identity),
           consumed_at,
           timestamp
         ) do
      :confirmed -> RedemptionLifecycle.confirmed_by_quota()
      _pending_or_reblocked -> RedemptionLifecycle.consumed_pending_probe()
    end
  end

  # The provider idempotency key is derived deterministically from the persisted
  # attempt id and generation, so a retry of the same claim reproduces the same
  # key without persisting a raw secret. Different attempts derive distinct keys.
  defp idempotency_key(%{attempt_id: attempt_id, generation: generation}) do
    {:ok, uuid} =
      :sha256
      |> :crypto.hash("saved_reset_redeem:#{attempt_id}:#{generation}")
      |> binary_part(0, 16)
      |> Ecto.UUID.load()

    uuid
  end

  defp noop_result(identity, assignment, code) when is_binary(code) do
    %{
      status: :noop,
      applied?: false,
      code: code,
      identity: identity,
      assignment: assignment
    }
  end

  defp scheduled_noop_result(code, identity \\ nil) when is_binary(code) do
    %{status: :noop, applied?: false, code: code}
    |> maybe_put_result_identity(identity)
  end

  defp maybe_put_result_identity(result, %UpstreamIdentity{} = identity),
    do: Map.put(result, :identity, identity)

  defp maybe_put_result_identity(result, _identity), do: result

  @doc false
  @spec encode_scheduled_decision_evidence(term()) ::
          {:ok, scheduled_decision_evidence()} | {:error, :invalid_decision_evidence}
  def encode_scheduled_decision_evidence(
        %{
          trigger_detail: trigger_detail,
          used_percent_at_decision: used_percent,
          credit_expires_at_at_decision: credit_expires_at,
          natural_reset_at_decision: natural_reset_at,
          decided_at: decided_at
        } = context
      )
      when map_size(context) == 5 do
    with {:ok, trigger_detail} <- encode_trigger_detail(trigger_detail),
         {:ok, used_percent} <- encode_used_percent(used_percent),
         {:ok, credit_expires_at} <- encode_evidence_timestamp(credit_expires_at),
         {:ok, natural_reset_at} <- encode_evidence_timestamp(natural_reset_at),
         {:ok, decided_at} <- encode_evidence_timestamp(decided_at) do
      {:ok,
       %{
         trigger_detail: trigger_detail,
         used_percent_at_decision: used_percent,
         credit_expires_at_at_decision: credit_expires_at,
         natural_reset_at_decision: natural_reset_at,
         decided_at: decided_at
       }}
    else
      _invalid -> {:error, :invalid_decision_evidence}
    end
  end

  def encode_scheduled_decision_evidence(_context),
    do: {:error, :invalid_decision_evidence}

  defp encode_claim_scheduled_decision_evidence(nil), do: {:ok, nil}

  defp encode_claim_scheduled_decision_evidence(context),
    do: encode_scheduled_decision_evidence(context)

  defp put_trigger_detail(record, detail) when detail in ["exhausted", "threshold"],
    do: Map.put(record, "trigger_detail", detail)

  defp put_trigger_detail(record, _detail), do: record

  defp maybe_put_claim_trigger_detail(claim, detail) when detail in ["exhausted", "threshold"],
    do: Map.put(claim, :trigger_detail, detail)

  defp maybe_put_claim_trigger_detail(claim, _detail), do: claim

  defp encode_trigger_detail(value)
       when value in ["immediate_expiry", "exhausted", "threshold", "last_call"],
       do: {:ok, value}

  defp encode_trigger_detail(_value), do: :error

  defp encode_used_percent(%Decimal{coef: coefficient, exp: exponent} = value)
       when is_integer(coefficient) and is_integer(exponent) do
    cond do
      Decimal.compare(value, Decimal.new(0)) == :lt ->
        :error

      Decimal.compare(value, Decimal.new(100)) == :gt ->
        :error

      fractional_digits(value) > 3 ->
        :error

      true ->
        encoded = value |> Decimal.normalize() |> Decimal.to_string(:normal)
        if byte_size(encoded) in 1..6, do: {:ok, encoded}, else: :error
    end
  rescue
    ArgumentError -> :error
  end

  defp encode_used_percent(_value), do: :error

  defp fractional_digits(%Decimal{} = value) do
    value = Decimal.normalize(value)
    max(-value.exp, 0)
  end

  defp encode_evidence_timestamp(%DateTime{} = value) do
    with {:ok, value} <- DateTime.shift_zone(value, "Etc/UTC") do
      encoded = value |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

      if byte_size(encoded) in 20..27 and String.ends_with?(encoded, "Z"),
        do: {:ok, encoded},
        else: :error
    end
  end

  defp encode_evidence_timestamp(_value), do: :error

  defp put_scheduled_decision_evidence(record, nil), do: record

  defp put_scheduled_decision_evidence(record, evidence) do
    record
    |> Map.put("trigger_detail", evidence.trigger_detail)
    |> Map.put("used_percent_at_decision", evidence.used_percent_at_decision)
    |> Map.put("credit_expires_at_at_decision", evidence.credit_expires_at_at_decision)
    |> Map.put("natural_reset_at_decision", evidence.natural_reset_at_decision)
    |> Map.put("decided_at", evidence.decided_at)
  end

  defp maybe_put_claim_scheduled_decision_evidence(claim, nil), do: claim

  defp maybe_put_claim_scheduled_decision_evidence(claim, evidence),
    do: Map.put(claim, :scheduled_decision_evidence, evidence)

  @spec no_credit_observation_intent(
          SavedResets.snapshot_projection(),
          non_neg_integer(),
          DateTime.t()
        ) :: saved_reset_observation_intent()
  defp no_credit_observation_intent(snapshot, available_count, observed_at) do
    %{
      available_count: available_count,
      authoritative_zero?: available_count == 0,
      observed_at: observed_at,
      path_style: snapshot.path_style,
      status: "reported",
      usage_path: snapshot.usage_path
    }
  end

  defp apply_saved_reset_observation(identity, metadata, nil) do
    {metadata, identity.saved_reset_first_seen_ledger}
  end

  defp apply_saved_reset_observation(identity, metadata, intent) do
    persisted_observed_at = get_in(metadata, ["saved_resets", "observed_at"])

    case ObservationOrdering.authorize(intent.observed_at, persisted_observed_at) do
      {:apply, observed_at} ->
        snapshot = SavedResets.snapshot(identity)

        saved_reset_metadata =
          %{
            "status" => intent.status,
            "available_count" => intent.available_count,
            "source" => "codex_reset_credits_api",
            "path_style" => intent.path_style,
            "observed_at" => observed_at,
            "usage_path" => intent.usage_path,
            "reason" => nil
          }
          |> Map.merge(expiration_metadata(snapshot, intent.authoritative_zero?, observed_at))

        {Map.put(metadata, "saved_resets", saved_reset_metadata),
         identity.saved_reset_first_seen_ledger}

      :skip ->
        {metadata, identity.saved_reset_first_seen_ledger}
    end
  end

  defp expiration_metadata(_snapshot, true, observed_at) do
    %{
      "available_expires_at" => [],
      "available_expirations" => [],
      "next_expires_at" => nil,
      "expires_observed_at" => observed_at,
      "expires_refresh_attempted_at" => observed_at
    }
  end

  defp expiration_metadata(snapshot, false, _observed_at) do
    expiration_metadata_from_snapshot(snapshot)
  end

  defp persist_finalized_attempt!(identity, metadata, ledger, redemption, finished_at) do
    identity
    |> Ecto.Changeset.change(%{
      metadata: Map.put(metadata, "saved_reset_redemption", redemption),
      saved_reset_first_seen_ledger: ledger,
      updated_at: finished_at
    })
    |> Repo.update!()
  end

  @spec expiration_metadata_from_snapshot(SavedResets.snapshot_projection()) :: map()
  defp expiration_metadata_from_snapshot(snapshot) do
    %{
      "available_expires_at" => snapshot.available_expires_at,
      "available_expirations" => stored_available_expiration_rows(snapshot.available_expirations),
      "next_expires_at" => snapshot.next_expires_at,
      "expires_observed_at" => snapshot.expires_observed_at,
      "expires_refresh_attempted_at" => snapshot.expires_refresh_attempted_at
    }
  end

  @spec stored_available_expiration_rows([SavedResets.available_expiration_row()]) :: [map()]
  defp stored_available_expiration_rows(rows) when is_list(rows) do
    rows
    |> Enum.map(fn
      %{expires_at: expires_at, first_seen_at: first_seen_at} = row
      when is_binary(expires_at) and is_binary(first_seen_at) ->
        %{"expires_at" => expires_at, "first_seen_at" => first_seen_at}
        |> maybe_put_granted_at(row)

      _row ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_put_granted_at(stored_row, source_row) do
    if Map.has_key?(source_row, :granted_at) do
      Map.put(stored_row, "granted_at", Map.get(source_row, :granted_at))
    else
      stored_row
    end
  end

  defp mark_stale_redemption_failed!(identity, redemption, finished_at) do
    metadata = identity.metadata || %{}
    generation = next_generation(metadata)

    update_redemption_metadata!(
      identity,
      metadata,
      %{
        "status" => "failed",
        "attempt_id" => redemption["attempt_id"] || Ecto.UUID.generate(),
        "generation" => generation,
        "trigger_kind" => redemption["trigger_kind"] || "admin_manual",
        "started_at" => redemption["started_at"],
        "finished_at" => DateTime.to_iso8601(finished_at),
        "result" => %{
          "code" => "stale_redemption_unknown",
          "applied" => false,
          "available_count_before" => nil,
          "available_count_after" => nil,
          "http_status" => nil
        }
      }
      |> put_carried_applied_consume(redemption)
    )
  end

  defp put_carried_applied_consume(base, redemption) do
    case RedemptionLifecycle.carried_applied_consume_at(redemption) do
      nil -> base
      carried_at -> Map.put(base, "last_applied_consume_at", carried_at)
    end
  end

  defp put_provider_replay_history(base, %{"provider_replay" => replay}) when is_map(replay),
    do: Map.put(base, "provider_replay", replay)

  defp put_provider_replay_history(base, _redemption), do: base

  defp claim_has_reserved_dispatch?(%{identity: %UpstreamIdentity{metadata: metadata}}) do
    case get_in(metadata || %{}, [
           "saved_reset_redemption",
           "provider_replay",
           "provider_dispatches"
         ]) do
      count when is_integer(count) and count > 0 -> true
      _count -> false
    end
  end

  defp claim_has_reserved_dispatch?(_claim), do: false

  defp update_redemption_metadata!(identity, metadata, redemption) do
    timestamp = now()

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(metadata || %{}, "saved_reset_redemption", redemption),
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp lock_claim_identity(identity_id, nil) do
    locked_identity = lock_identity!(identity_id)
    {:ok, locked_identity, %{identity_id => locked_identity}}
  end

  defp lock_claim_identity(identity_id, %{cohort_identity_ids: cohort_identity_ids}) do
    normalized_ids =
      cohort_identity_ids
      |> Enum.map(&Ecto.UUID.cast!/1)
      |> Enum.uniq()
      |> Enum.sort()

    locked_identities =
      Repo.all(
        from identity in UpstreamIdentity,
          where:
            fragment(
              "? = ANY(?::uuid[])",
              identity.id,
              ^Enum.map(normalized_ids, &Ecto.UUID.dump!/1)
            ),
          order_by: [asc: identity.id],
          lock: "FOR UPDATE"
      )

    locked_ids = Enum.map(locked_identities, & &1.id)

    if locked_ids == normalized_ids do
      case Enum.find(locked_identities, &(&1.id == identity_id)) do
        %UpstreamIdentity{} = locked_identity ->
          {:ok, locked_identity, Map.new(locked_identities, &{&1.id, &1})}

        nil ->
          {:noop, "gateway_auto_context_mismatch"}
      end
    else
      {:noop, "gateway_auto_context_mismatch"}
    end
  end

  defp broadcast_redemption(identity) do
    identity.id
    |> PoolAssignments.list_pool_assignments_for_identity()
    |> Enum.each(fn assignment ->
      Events.broadcast_upstreams(assignment.pool_id, "upstream_account_saved_reset_redeemed", %{
        assignment_id: assignment.id,
        upstream_identity_id: identity.id
      })
    end)
  end

  defp lock_identity!(identity_id) do
    Repo.one!(
      from identity in UpstreamIdentity,
        where: identity.id == ^identity_id,
        lock: "FOR UPDATE"
    )
  end

  defp fresh_redemption?(
         %{"status" => "redeeming", "started_at" => started_at},
         now,
         receive_timeout
       ) do
    case parse_datetime(started_at) do
      %DateTime{} = started_at ->
        DateTime.diff(now, started_at, :millisecond) <
          receive_timeout + SavedResets.redemption_stale_grace_ms()

      nil ->
        false
    end
  end

  defp fresh_redemption?(_redemption, _now, _receive_timeout), do: false

  defp stale_redemption?(%{"status" => "redeeming"}), do: true
  defp stale_redemption?(_redemption), do: false

  defp recovery_due?(redemption, now) do
    next_action_at =
      get_in(redemption, ["provider_replay", "next_action_at"]) ||
        redemption["legacy_recovery_next_action_at"]

    case next_action_at do
      nil -> true
      next_action_at -> due_at?(parse_datetime(next_action_at), now)
    end
  end

  defp due_at?(%DateTime{} = due_at, now), do: DateTime.compare(due_at, now) != :gt
  defp due_at?(_invalid, _now), do: false

  defp next_generation(metadata) do
    case get_in(metadata || %{}, ["saved_reset_redemption", "generation"]) do
      generation when is_integer(generation) and generation >= 0 -> generation + 1
      _generation -> 1
    end
  end

  # A crash inside the consume POST window leaves a `consuming` record whose
  # provider call may or may not have landed. Resuming that attempt reuses its
  # persisted attempt id and generation, so the derived redeem_request_id is
  # byte-identical and the provider can deduplicate instead of consuming a
  # second credit. Every other shape claims a fresh attempt.
  defp claim_attempt_identity(metadata) do
    redemption = get_in(metadata || %{}, ["saved_reset_redemption"])

    if resumable_consume_crash?(redemption) do
      {redemption["attempt_id"], redemption["generation"]}
    else
      {Ecto.UUID.generate(), next_generation(metadata)}
    end
  end

  defp resumable_consume_crash?(%{} = redemption) do
    RedemptionLifecycle.phase(redemption) == RedemptionLifecycle.consuming() and
      is_binary(redemption["attempt_id"]) and is_integer(redemption["generation"])
  end

  defp resumable_consume_crash?(_redemption), do: false

  defp non_negative_truncated_integer(value) when is_integer(value), do: {:ok, max(value, 0)}

  defp non_negative_truncated_integer(value) when is_float(value) do
    {:ok, value |> trunc() |> max(0)}
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(%Decimal{} = value) do
    {:ok, value |> Decimal.round(0, :down) |> Decimal.to_integer() |> max(0)}
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> non_negative_truncated_integer(decimal)
      _invalid -> :error
    end
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(_value), do: :error

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp failed_result(code, http_status) do
    %{
      status: :failed,
      applied?: false,
      code: code,
      http_status: http_status,
      reason: "saved reset redemption failed"
    }
  end

  defp transport_failed_result do
    %{
      status: :failed,
      applied?: false,
      code: "transport_error",
      reason: "saved reset redemption request failed"
    }
  end

  defp http_code(status) when is_integer(status), do: "http_#{status}"

  defp assignment_id(%PoolUpstreamAssignment{id: id}), do: id
  defp assignment_id(id) when is_binary(id), do: id
  defp assignment_id(_assignment_or_id), do: nil

  defp lifecycle_error(code, message), do: %{code: code, message: message}
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
