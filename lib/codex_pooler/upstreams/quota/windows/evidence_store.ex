defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStore do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @runtime_quota_sources ~w(codex_rate_limit_event codex_response_headers codex_rate_limit_error)
  @usage_reset_forward_tolerance_seconds 5 * 60
  @weekly_restart_anchor_margin_seconds 60 * 60
  @weekly_restart_confirmation_span_seconds 3 * 60
  @weekly_restart_sliding_tolerance_seconds 2 * 60
  @usage_reset_reanchor_min_shift_seconds 60 * 60
  @restart_corroboration_reset_tolerance_seconds 5 * 60
  @relative_reset_refresh_tolerance_seconds 5
  @account_snapshot_reset_tolerance_seconds 5
  @candidate_metadata_key "__quota_confirmed_candidate_v1"
  @candidate_version 1

  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type candidate :: %{
          required(:used_percent) => Decimal.t(),
          required(:reset_at) => DateTime.t(),
          required(:observed_at) => DateTime.t()
        }

  @spec evidence_changeset(identity_ref(), map(), DateTime.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, Evidence.errors() | map()}
  def evidence_changeset(identity_or_id, attrs, observed_at) do
    with {:ok, evidence} <- Evidence.new(attrs, observed_at),
         identity_id when is_binary(identity_id) <- evidence_identity_id(identity_or_id, attrs) do
      %Quota.AccountQuotaWindow{}
      |> Quota.AccountQuotaWindow.changeset(
        evidence
        |> Evidence.to_window_attrs()
        |> Map.put(:upstream_identity_id, identity_id)
        |> put_timestamps()
      )
      |> then(&{:ok, &1})
    else
      {:error, _errors} = error -> error
      _missing_identity -> {:error, %{upstream_identity_id: ["can't be blank"]}}
    end
  end

  @spec record_evidence(identity_ref(), map(), DateTime.t()) ::
          {:ok, Quota.AccountQuotaWindow.t()}
          | {:error, Ecto.Changeset.t() | Evidence.errors() | map()}
  def record_evidence(identity_or_id, attrs, observed_at) do
    record_evidence(identity_or_id, attrs, observed_at, now())
  end

  @spec record_evidence(identity_ref(), map(), DateTime.t(), DateTime.t()) ::
          {:ok, Quota.AccountQuotaWindow.t()}
          | {:error, Ecto.Changeset.t() | Evidence.errors() | map()}
  def record_evidence(identity_or_id, attrs, observed_at, timestamp) do
    if Repo.in_transaction?() do
      record_evidence_in_transaction(identity_or_id, attrs, observed_at, timestamp)
    else
      record_evidence_in_new_transaction(identity_or_id, attrs, observed_at, timestamp)
    end
  end

  defp record_evidence_in_new_transaction(identity_or_id, attrs, observed_at, timestamp) do
    Repo.transaction(fn ->
      identity_or_id
      |> record_evidence_in_transaction(attrs, observed_at, timestamp)
      |> unwrap_record_evidence_transaction()
    end)
  end

  defp unwrap_record_evidence_transaction({:ok, window}), do: window
  defp unwrap_record_evidence_transaction({:error, reason}), do: Repo.rollback(reason)

  defp record_evidence_in_transaction(identity_or_id, attrs, observed_at, timestamp) do
    with {:ok, evidence} <- Evidence.new(attrs, observed_at),
         identity_id when is_binary(identity_id) <- evidence_identity_id(identity_or_id, attrs) do
      advisory_lock_evidence_identity(identity_id)

      attrs =
        evidence
        |> Evidence.to_window_attrs()
        |> Map.put(:upstream_identity_id, identity_id)

      with {:ok, existing} <- get_existing_evidence(identity_id, evidence) do
        timestamped_attrs = merge_attrs(existing, attrs, evidence, timestamp)

        result =
          existing
          |> Quota.AccountQuotaWindow.changeset(timestamped_attrs)
          |> Repo.insert_or_update()

        clear_provider_candidates_after_runtime(result, evidence, existing, identity_id)
      end
    else
      {:error, _errors} = error -> error
      _missing_identity -> {:error, %{upstream_identity_id: ["can't be blank"]}}
    end
  end

  defp advisory_lock_evidence_identity(identity_id) do
    _result =
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [identity_id])

    :ok
  end

  @spec list_evidence(identity_ref()) :: [Quota.AccountQuotaWindow.t()]
  def list_evidence(identity_or_id) do
    case evidence_identity_id(identity_or_id, %{}) do
      identity_id when is_binary(identity_id) ->
        Repo.all(
          from window in Quota.AccountQuotaWindow,
            where: window.upstream_identity_id == ^identity_id,
            order_by: [
              asc: window.quota_scope,
              asc: window.quota_family,
              asc: window.quota_key,
              asc: window.window_kind,
              desc: window.merge_precedence,
              desc: window.observed_at
            ]
        )

      nil ->
        []
    end
  end

  @spec put_candidate(map(), Evidence.t()) :: map()
  def put_candidate(metadata, %Evidence{
        used_percent: %Decimal{} = used_percent,
        reset_at: %DateTime{} = reset_at,
        observed_at: %DateTime{} = observed_at
      })
      when is_map(metadata) do
    Map.put(metadata, @candidate_metadata_key, %{
      "version" => @candidate_version,
      "used_percent" => canonical_decimal_string(used_percent),
      "reset_at" => DateTime.to_iso8601(reset_at),
      "observed_at" => DateTime.to_iso8601(observed_at),
      "count" => 1
    })
  end

  @spec parse_candidate(map()) :: {:ok, candidate()} | :none
  def parse_candidate(metadata) when is_map(metadata) do
    with %{
           "version" => @candidate_version,
           "used_percent" => used_percent,
           "reset_at" => reset_at,
           "observed_at" => observed_at,
           "count" => 1
         } = encoded <- Map.get(metadata, @candidate_metadata_key),
         true <- map_size(encoded) == 5,
         {:ok, decimal} <- parse_decimal(used_percent),
         {:ok, parsed_reset_at} <- parse_datetime(reset_at),
         {:ok, parsed_observed_at} <- parse_datetime(observed_at) do
      {:ok, %{used_percent: decimal, reset_at: parsed_reset_at, observed_at: parsed_observed_at}}
    else
      _invalid -> :none
    end
  end

  @spec candidate_equivalent?(candidate(), Evidence.t()) :: boolean()
  def candidate_equivalent?(
        %{used_percent: candidate_percent, reset_at: candidate_reset},
        %Evidence{
          used_percent: %Decimal{} = incoming_percent,
          reset_at: %DateTime{} = incoming_reset
        }
      ) do
    valid_percent?(candidate_percent) and
      valid_percent?(incoming_percent) and
      Decimal.compare(Decimal.normalize(candidate_percent), Decimal.normalize(incoming_percent)) ==
        :eq and
      reset_times_equivalent?(candidate_reset, incoming_reset)
  end

  def candidate_equivalent?(_candidate, _evidence), do: false

  @spec candidate_valid?(candidate(), DateTime.t()) :: boolean()
  def candidate_valid?(
        %{reset_at: %DateTime{} = reset_at, observed_at: %DateTime{} = observed_at},
        %DateTime{} = timestamp
      ) do
    DateTime.compare(reset_at, timestamp) == :gt and
      DateTime.diff(timestamp, observed_at, :second) <= Evidence.freshness_ttl_seconds() and
      DateTime.diff(observed_at, timestamp, :second) <= Evidence.future_observed_skew_seconds()
  end

  def candidate_valid?(_candidate, _timestamp), do: false

  @spec clear_candidate(map()) :: map()
  def clear_candidate(metadata) when is_map(metadata),
    do: Map.delete(metadata, @candidate_metadata_key)

  defp get_existing_evidence(identity_id, %Evidence{} = evidence) do
    with {:ok, nil} <- exact_existing_evidence(identity_id, evidence),
         {:ok, nil} <- alias_existing_evidence(identity_id, evidence),
         {:ok, nil} <- fallback_existing_evidence(identity_id, evidence) do
      {:ok, %Quota.AccountQuotaWindow{}}
    else
      {:ok, %Quota.AccountQuotaWindow{} = window} -> {:ok, window}
      {:error, _reason} = error -> error
    end
  end

  defp exact_existing_evidence(identity_id, %Evidence{} = evidence) do
    Repo.all(
      from window in Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity_id,
        where: window.quota_scope == ^evidence.quota_scope,
        where: window.quota_family == ^evidence.quota_family,
        where: fragment("COALESCE(lower(?), '')", window.model) == ^lower_string(evidence.model),
        where:
          fragment("COALESCE(lower(?), '')", window.upstream_model) ==
            ^lower_string(evidence.upstream_model),
        where: window.quota_key == ^evidence.quota_key,
        where: window.window_kind == ^evidence.window_kind,
        where: window.window_minutes == ^evidence.window_minutes,
        where: window.source == ^evidence.source,
        where:
          fragment("COALESCE(?, '')", window.raw_limit_id) ==
            ^optional_string(evidence.raw_limit_id),
        where:
          fragment("COALESCE(?, '')", window.raw_limit_name) ==
            ^optional_string(evidence.raw_limit_name),
        where:
          fragment("COALESCE(?, '')", window.raw_metered_feature) ==
            ^optional_string(evidence.raw_metered_feature),
        limit: 2
    )
    |> unambiguous_existing(:ambiguous_quota_window_identity)
  end

  defp alias_existing_evidence(identity_id, %Evidence{quota_key: "codex_spark"} = evidence) do
    Repo.all(
      from window in Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity_id,
        where:
          window.quota_key in [
            "codex_spark",
            "gpt_5_3_codex_spark",
            "codex_bengalfox",
            "codex_other"
          ],
        where: window.quota_scope == ^evidence.quota_scope,
        where: window.quota_family == ^evidence.quota_family,
        where: fragment("COALESCE(lower(?), '')", window.model) == ^lower_string(evidence.model),
        where:
          fragment("COALESCE(lower(?), '')", window.upstream_model) ==
            ^lower_string(evidence.upstream_model),
        where: window.window_kind == ^evidence.window_kind,
        where: window.window_minutes == ^evidence.window_minutes,
        where: window.source == ^evidence.source,
        limit: 2
    )
    |> resolve_alias_existing(evidence)
  end

  defp alias_existing_evidence(_identity_id, _evidence), do: {:ok, nil}

  defp fallback_existing_evidence(_identity_id, _evidence), do: {:ok, nil}

  defp unambiguous_existing([], _code), do: {:ok, nil}
  defp unambiguous_existing([window], _code), do: {:ok, window}

  defp unambiguous_existing([_first, _second], code) do
    {:error, %{code: code, message: "quota window lookup was ambiguous"}}
  end

  defp resolve_alias_existing([], _evidence), do: {:ok, nil}

  defp resolve_alias_existing([window], %Evidence{} = evidence) do
    if alias_raw_identity_matches?(window, evidence), do: {:ok, window}, else: {:ok, nil}
  end

  defp resolve_alias_existing([_first, _second], _evidence) do
    {:error, %{code: :ambiguous_quota_window_alias, message: "quota window lookup was ambiguous"}}
  end

  defp alias_raw_identity_matches?(window, evidence) do
    optional_string(window.raw_limit_id) == optional_string(evidence.raw_limit_id) and
      optional_string(window.raw_limit_name) == optional_string(evidence.raw_limit_name) and
      optional_string(window.raw_metered_feature) == optional_string(evidence.raw_metered_feature)
  end

  defp merge_attrs(%Quota.AccountQuotaWindow{id: nil} = existing, attrs, _evidence, _timestamp),
    do: put_timestamps(attrs, existing)

  defp merge_attrs(
         %Quota.AccountQuotaWindow{} = existing,
         attrs,
         %Evidence{} = evidence,
         timestamp
       ) do
    if uncorroborated_zero_reenable_attempt?(evidence, existing, timestamp) do
      sliding_restart_attrs(existing, attrs, evidence, timestamp)
    else
      merge_attrs_by_decision(existing, attrs, evidence, timestamp)
    end
  end

  # After the provider retired the anchored 5h windows, a restarted weekly
  # account arrives from the usage endpoint as a weak zero whose full-window
  # relative reset is recomputed at response time, so reset_at slides forward in
  # step with each observation. A blocked account receives no traffic, so the
  # runtime corroboration demanded above can never materialize — quarantining
  # genuine restarts (and post-redemption resets) forever. Distinct live
  # responses are still distinguishable from a cached or replayed body: the
  # floating reset advances with observation time, while a cached body keeps a
  # fixed reset. Accept the zero only when a stored candidate and the incoming
  # observation prove that sliding-live shape across the confirmation span;
  # otherwise keep the exhausted row and let the candidate age or restart.
  defp sliding_restart_attrs(existing, attrs, evidence, timestamp) do
    metadata = existing.metadata || %{}

    case parse_candidate(metadata) do
      {:ok, candidate} ->
        cond do
          not newer_observation?(evidence.observed_at, candidate.observed_at) ->
            candidate_snapshot_attrs(existing, metadata, timestamp)

          confirmed_sliding_restart?(candidate, evidence, timestamp) ->
            accepted_snapshot_attrs(existing, attrs, timestamp)

          consistent_sliding_candidate?(candidate, evidence, timestamp) ->
            # Consistent but still inside the confirmation span: keep the
            # original candidate so minute-by-minute observations cannot reset
            # the clock and starve the confirmation forever.
            candidate_snapshot_attrs(existing, metadata, timestamp)

          true ->
            candidate_snapshot_attrs(
              existing,
              put_candidate(clear_candidate(metadata), evidence),
              timestamp
            )
        end

      :none ->
        candidate_snapshot_attrs(
          existing,
          put_candidate(clear_candidate(metadata), evidence),
          timestamp
        )
    end
  end

  defp confirmed_sliding_restart?(candidate, evidence, timestamp) do
    consistent_sliding_candidate?(candidate, evidence, timestamp) and
      DateTime.diff(evidence.observed_at, candidate.observed_at, :second) >=
        @weekly_restart_confirmation_span_seconds
  end

  defp consistent_sliding_candidate?(candidate, evidence, timestamp) do
    candidate_valid?(candidate, timestamp) and
      zero_candidate?(candidate) and
      sliding_live_reset?(candidate, evidence)
  end

  # parse_candidate/1 guarantees a Decimal used_percent on success.
  defp zero_candidate?(%{used_percent: %Decimal{} = percent}), do: zero_percent?(percent)

  defp sliding_live_reset?(
         %{
           reset_at: %DateTime{} = candidate_reset,
           observed_at: %DateTime{} = candidate_observed
         },
         %Evidence{
           reset_at: %DateTime{} = incoming_reset,
           observed_at: %DateTime{} = incoming_observed
         }
       ) do
    delta_observed = DateTime.diff(incoming_observed, candidate_observed, :second)
    delta_reset = DateTime.diff(incoming_reset, candidate_reset, :second)

    abs(delta_reset - delta_observed) <= @weekly_restart_sliding_tolerance_seconds
  end

  defp sliding_live_reset?(_candidate, _evidence), do: false

  # A usage-endpoint zero must never re-enable exhausted weekly quota on its
  # own: without this chokepoint guard, an expired or stale canonical takes
  # the `:incoming` fast paths, and capacity- or credit-bearing shapes exit
  # the weak-capacity quarantine as `:continue` into the generic merge — all
  # single-observation routes around the corroboration requirement. Any
  # account-weekly zero replacing an exhausted canonical needs independent
  # runtime corroboration first, regardless of freshness or capacity shape.
  defp uncorroborated_zero_reenable_attempt?(
         %Evidence{source: "codex_usage_api", used_percent: %Decimal{}} = evidence,
         %Quota.AccountQuotaWindow{used_percent: %Decimal{}} = existing,
         timestamp
       ) do
    account_weekly_evidence?(evidence) and
      zero_percent?(evidence.used_percent) and
      exhausted_by_used_percent?(existing) and
      same_evidence_identity?(evidence, existing) and
      not runtime_weekly_restart_corroborated?(evidence, existing, timestamp)
  end

  defp uncorroborated_zero_reenable_attempt?(_evidence, _existing, _timestamp), do: false

  defp account_weekly_evidence?(evidence) do
    account_quota_identity?(evidence) and Map.get(evidence, :window_kind) == "secondary" and
      Map.get(evidence, :window_minutes) == 10_080
  end

  defp merge_attrs_by_decision(existing, attrs, evidence, timestamp) do
    case confirmed_snapshot_decision(evidence, existing, timestamp) do
      :incoming -> accepted_snapshot_attrs(existing, attrs, timestamp)
      :same_cycle -> same_cycle_snapshot_attrs(existing, attrs, evidence, timestamp)
      {:candidate, metadata} -> candidate_snapshot_attrs(existing, metadata, timestamp)
      :existing -> rejected_snapshot_attrs(existing, evidence, timestamp)
      :continue -> merge_attrs_by_quality(existing, attrs, evidence, timestamp)
    end
  end

  defp merge_attrs_by_quality(existing, attrs, evidence, timestamp) do
    if incoming_explicit_reset_corrects_relative_existing?(evidence, existing, timestamp) do
      merge_explicit_reset_correction_attrs(existing, attrs, evidence, timestamp)
    else
      merge_attrs_by_remaining_quality(existing, attrs, evidence, timestamp)
    end
  end

  defp merge_attrs_by_remaining_quality(existing, attrs, evidence, timestamp) do
    cond do
      usage_reset_reanchor?(evidence, existing, timestamp) ->
        reanchor_attrs_by_shape(existing, attrs, evidence, timestamp)

      incoming_updates_usage_with_existing_reset?(evidence, existing, timestamp) ->
        merge_usage_with_existing_reset_attrs(existing, attrs, evidence, timestamp)

      incoming_updates_usage_with_existing_capacity?(evidence, existing) ->
        merge_usage_with_existing_capacity_attrs(existing, attrs, evidence, timestamp)

      incoming_usage_advances_runtime_reset?(evidence, existing, timestamp) ->
        merge_usage_reset_with_existing_percent_attrs(existing, attrs, timestamp)

      incoming_relative_usage_extends_existing_reset?(evidence, existing, timestamp) ->
        merge_weak_usage_with_existing_reset_attrs(existing, attrs, timestamp)

      incoming_weak_usage_extends_existing_reset?(evidence, existing, timestamp) ->
        merge_weak_usage_with_existing_reset_attrs(existing, attrs, timestamp)

      incoming_refreshes_existing?(evidence, existing, timestamp) ->
        refresh_existing_attrs(existing, attrs, timestamp)

      true ->
        supersede_or_keep_attrs(existing, attrs, evidence, timestamp)
    end
  end

  defp supersede_or_keep_attrs(existing, attrs, evidence, timestamp) do
    if incoming_supersedes?(evidence, existing, timestamp) do
      put_timestamps(attrs, existing)
    else
      existing
      |> window_attrs()
      |> Map.put(:updated_at, timestamp)
    end
  end

  @spec confirmed_snapshot_decision(
          Evidence.t(),
          Quota.AccountQuotaWindow.t(),
          DateTime.t()
        ) :: :incoming | :same_cycle | :existing | :continue | {:candidate, map()}
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp confirmed_snapshot_decision(
         %Evidence{
           source: "codex_usage_api",
           source_precision: incoming_precision,
           reset_at: %DateTime{},
           used_percent: %Decimal{}
         } = evidence,
         %Quota.AccountQuotaWindow{
           source: "codex_usage_api",
           source_precision: existing_precision,
           reset_at: %DateTime{},
           used_percent: %Decimal{}
         } = existing,
         timestamp
       )
       when incoming_precision in ["observed", "authoritative"] and
              existing_precision in ["observed", "authoritative"] do
    cond do
      Evidence.identity_key(evidence) != Evidence.identity_key(existing) ->
        :continue

      not weak_capacity?(evidence) or not weak_capacity?(existing) ->
        :continue

      not newer_observation?(evidence.observed_at, existing.observed_at) ->
        :existing

      Evidence.current_freshness_state(evidence, timestamp) != "fresh" ->
        :existing

      same_cycle_reset?(evidence, existing) and
        relative_reset_metadata?(evidence.metadata) and
        not weak_zero_percent_evidence?(evidence) and
          not stale_same_cycle_exhausted_snapshot?(evidence, existing, timestamp) ->
        :same_cycle

      Evidence.expired?(existing, timestamp) ->
        :incoming

      Evidence.current_freshness_state(existing, timestamp) != "fresh" and
          forward_reset_cycle?(evidence, existing) ->
        :incoming

      weak_zero_percent_evidence?(evidence) ->
        weak_zero_snapshot_decision(evidence, existing, timestamp)

      relative_reset_metadata?(evidence.metadata) and
          relative_reset_metadata?(existing.metadata) ->
        relative_snapshot_decision(evidence, existing)

      relative_reset_metadata?(evidence.metadata) ->
        if higher_used_percent?(evidence.used_percent, existing.used_percent),
          do: :continue,
          else: :existing

      forward_reset_cycle?(evidence, existing) ->
        :incoming

      stale_same_cycle_exhausted_snapshot?(evidence, existing, timestamp) ->
        lower_snapshot_decision(evidence, existing, timestamp)

      true ->
        compare_confirmed_snapshot(evidence, existing, timestamp)
    end
  end

  defp confirmed_snapshot_decision(
         %Evidence{source: "codex_usage_api", used_percent: %Decimal{}} = evidence,
         %Quota.AccountQuotaWindow{source: "codex_usage_api"} = existing,
         timestamp
       ) do
    same_confirmed_identity? = Evidence.identity_key(evidence) == Evidence.identity_key(existing)

    cond do
      not same_confirmed_identity? or not weak_capacity?(evidence) or not weak_capacity?(existing) ->
        :continue

      relative_reset_metadata?(evidence.metadata) and
          Evidence.current_freshness_state(existing, timestamp) != "fresh" ->
        :existing

      relative_reset_metadata?(evidence.metadata) ->
        :continue

      true ->
        :existing
    end
  end

  defp confirmed_snapshot_decision(_evidence, _existing, _timestamp), do: :continue

  @spec compare_confirmed_snapshot(
          Evidence.t(),
          Quota.AccountQuotaWindow.t(),
          DateTime.t()
        ) :: :incoming | {:candidate, map()}
  defp compare_confirmed_snapshot(
         %Evidence{used_percent: incoming_percent} = evidence,
         %Quota.AccountQuotaWindow{
           used_percent: existing_percent
         } = existing,
         timestamp
       ) do
    case compare_percent(incoming_percent, existing_percent) do
      comparison when comparison in [:gt, :eq] -> :incoming
      :lt -> lower_snapshot_decision(evidence, existing, timestamp)
    end
  end

  @spec lower_snapshot_decision(Evidence.t(), Quota.AccountQuotaWindow.t(), DateTime.t()) ::
          :incoming | {:candidate, map()}
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp lower_snapshot_decision(%Evidence{} = evidence, existing, timestamp) do
    case parse_candidate(existing.metadata || %{}) do
      {:ok, candidate} ->
        cond do
          not newer_observation?(evidence.observed_at, candidate.observed_at) ->
            {:candidate, existing.metadata || %{}}

          candidate_valid?(candidate, timestamp) and
            newer_observation?(candidate.observed_at, existing.observed_at) and
              candidate_equivalent?(candidate, evidence) ->
            :incoming

          true ->
            {:candidate, put_candidate(clear_candidate(existing.metadata || %{}), evidence)}
        end

      :none ->
        {:candidate, put_candidate(clear_candidate(existing.metadata || %{}), evidence)}
    end
  end

  defp compare_percent(%Decimal{} = left, %Decimal{} = right),
    do: Decimal.compare(Decimal.normalize(left), Decimal.normalize(right))

  defp newer_observation?(%DateTime{} = incoming, %DateTime{} = existing),
    do: DateTime.compare(incoming, existing) == :gt

  defp forward_reset_cycle?(
         %Evidence{window_kind: "primary", reset_at: %DateTime{} = incoming},
         %Quota.AccountQuotaWindow{reset_at: %DateTime{} = existing}
       ),
       do: DateTime.diff(incoming, existing, :second) > @usage_reset_forward_tolerance_seconds

  defp forward_reset_cycle?(_evidence, _existing), do: false

  # The provider can re-anchor a window's reset earlier than the canonical
  # snapshot mid-cycle (observed with the 2026-07 provider usage reset: the
  # free-plan monthly window jumped from ~19% used / reset in 27 days to 100%
  # used / reset in 11 days). The reset-rollback guard rightly rejects a
  # single such observation — an old cached decaying-window snapshot has the
  # same shape (higher percent, earlier reset) — but each rejected same-cycle
  # refresh keeps the canonical row fresh, so the guard alone deadlocks on
  # the stale values forever. Route the divergent complete usage pair through
  # the two-observation candidate confirmation instead: two consecutive
  # matching snapshots (equal percent, resets within seconds) re-anchor the
  # window; inconsistent or one-off observations keep being rejected. The
  # shift must exceed one hour so ordinary same-cycle countdown drift never
  # qualifies.
  defp usage_reset_reanchor?(
         %Evidence{
           source: "codex_usage_api",
           source_precision: precision,
           reset_at: %DateTime{} = incoming_reset,
           used_percent: %Decimal{}
         } = evidence,
         %Quota.AccountQuotaWindow{
           source: "codex_usage_api",
           reset_at: %DateTime{} = existing_reset,
           used_percent: %Decimal{}
         } = existing,
         timestamp
       )
       when precision in ["observed", "authoritative"] do
    same_evidence_identity?(evidence, existing) and
      newer_observation?(evidence.observed_at, existing.observed_at) and
      Evidence.current_freshness_state(evidence, timestamp) == "fresh" and
      DateTime.diff(existing_reset, incoming_reset, :second) >
        @usage_reset_reanchor_min_shift_seconds
  end

  defp usage_reset_reanchor?(_evidence, _existing, _timestamp), do: false

  # Credit-only incomplete snapshots (exhausted percent beside a positive
  # credit balance with no capacity — the degenerate free-plan shape) keep the
  # capacity-preserving credit flow for their values: the known capacity is
  # preserved and the percent is derived from the incoming credit balance.
  # Complete pairs take the plain candidate re-anchor instead.
  defp reanchor_attrs_by_shape(existing, attrs, evidence, timestamp) do
    if credit_only_incomplete_usage?(evidence) do
      credit_only_reanchor_attrs(existing, attrs, evidence, timestamp)
    else
      reanchor_snapshot_attrs(existing, attrs, evidence, timestamp)
    end
  end

  # The credit flow alone would keep the later stored reset forever
  # (`latest_reset_at`), freezing a reset the provider stopped asserting. Run
  # the capacity-preserving merge on every observation, and track the
  # divergent earlier reset as a candidate: two consecutive observations
  # carrying the same earlier reset (within seconds) adopt it, while the
  # percent stays credit-derived and the capacity stays preserved. The
  # standard candidate confirmation cannot be reused verbatim here because
  # the credit merge advances the canonical observed_at on every tick.
  defp credit_only_reanchor_attrs(existing, attrs, evidence, timestamp) do
    merged = merge_usage_with_existing_capacity_attrs(existing, attrs, evidence, timestamp)
    merged_metadata = Map.get(merged, :metadata) || %{}

    case parse_candidate(existing.metadata || %{}) do
      {:ok, candidate} ->
        if candidate_valid?(candidate, timestamp) and
             newer_observation?(evidence.observed_at, candidate.observed_at) and
             candidate_equivalent?(candidate, evidence) do
          merged
          |> Map.put(:reset_at, evidence.reset_at)
          |> Map.put(:metadata, clear_candidate(merged_metadata))
        else
          Map.put(merged, :metadata, put_candidate(clear_candidate(merged_metadata), evidence))
        end

      :none ->
        Map.put(merged, :metadata, put_candidate(clear_candidate(merged_metadata), evidence))
    end
  end

  defp reanchor_snapshot_attrs(existing, attrs, evidence, timestamp) do
    case lower_snapshot_decision(evidence, existing, timestamp) do
      :incoming ->
        put_timestamps(attrs, existing)

      {:candidate, metadata} ->
        existing
        |> window_attrs()
        |> Map.put(:metadata, metadata)
        |> Map.put(:updated_at, timestamp)
    end
  end

  defp credit_only_incomplete_usage?(evidence) do
    positive_credits?(evidence) and missing_active_limit?(evidence) and
      exhausted_by_used_percent?(evidence)
  end

  # The provider can restart the weekly cycle in place (observed as a
  # zero-usage snapshot whose reset anchors one window ahead of the restart
  # instant, stable across samples and paths). A genuine restart is
  # distinguishable from the idle-rolling usage artifact (zero percent with a
  # reset floating a full window ahead of every observation): the restarted
  # window's reset sits well inside the window duration. The anchor margin is
  # deliberately wide — a rolling value that a provider cache keeps serving
  # for minutes would otherwise drift inside the window and start looking
  # anchored — so only resets at least one hour inside the window qualify.
  # Even then the shape is only admitted into the two-observation candidate
  # confirmation flow (matching percent, resets within seconds); a single
  # observation never demotes the canonical weekly snapshot.
  defp anchored_forward_weekly_cycle?(
         %Evidence{
           window_minutes: 10_080,
           reset_at: %DateTime{} = incoming_reset,
           observed_at: %DateTime{} = observed_at
         },
         %Quota.AccountQuotaWindow{reset_at: %DateTime{} = existing_reset}
       ) do
    window_seconds = 10_080 * 60
    remaining_seconds = DateTime.diff(incoming_reset, observed_at, :second)

    DateTime.diff(incoming_reset, existing_reset, :second) >
      @usage_reset_forward_tolerance_seconds and
      remaining_seconds > 0 and
      remaining_seconds <= window_seconds - @weekly_restart_anchor_margin_seconds
  end

  defp anchored_forward_weekly_cycle?(_evidence, _existing), do: false

  # Two coherent samples of the same cached usage response are not enough to
  # zero out an exhausted weekly: the restart must also be corroborated by an
  # independent provider surface. Runtime evidence (response headers,
  # rate-limit events, rate-limit errors) comes from real dispatched traffic
  # rather than the usage endpoint, so a persisted runtime row proves the
  # provider asserted the new cycle on a second surface — but only when it
  # carries the same logical identity (key, scope, family, model, upstream
  # model, kind, minutes), is fresh and not from the future at the merge
  # timestamp, reports a non-exhausted percent compatible with a restart, and
  # its reset matches the claimed anchor. Stale, contradictory (100 percent),
  # or partial-identity runtime rows corroborate nothing. Without
  # corroboration the zero snapshot stays quarantined — which also fails
  # closed: while quota is genuinely exhausted, requests fail and no fresh
  # runtime weekly with the restarted reset can appear.
  defp runtime_weekly_restart_corroborated?(
         %Evidence{reset_at: %DateTime{} = anchored_reset} = evidence,
         %Quota.AccountQuotaWindow{upstream_identity_id: identity_id},
         %DateTime{} = timestamp
       )
       when is_binary(identity_id) do
    reset_floor = DateTime.add(anchored_reset, -@restart_corroboration_reset_tolerance_seconds)
    reset_ceiling = DateTime.add(anchored_reset, @restart_corroboration_reset_tolerance_seconds)
    observed_floor = DateTime.add(timestamp, -Evidence.freshness_ttl_seconds(), :second)
    # strictly non-future: a corroborating runtime row must have been observed
    # at or before the merge instant
    observed_ceiling = timestamp

    Repo.exists?(
      from window in Quota.AccountQuotaWindow,
        where: window.upstream_identity_id == ^identity_id,
        where: window.source in ^@runtime_quota_sources,
        where: window.quota_key == ^evidence.quota_key,
        where: fragment("COALESCE(?, 'account')", window.quota_scope) == ^evidence.quota_scope,
        where: fragment("COALESCE(?, 'account')", window.quota_family) == ^evidence.quota_family,
        where: fragment("COALESCE(lower(?), '')", window.model) == ^lower_string(evidence.model),
        where:
          fragment("COALESCE(lower(?), '')", window.upstream_model) ==
            ^lower_string(evidence.upstream_model),
        where: window.window_kind == ^evidence.window_kind,
        where: window.window_minutes == ^evidence.window_minutes,
        where: window.used_percent < 100,
        where: window.freshness_state == "fresh",
        where: window.observed_at >= ^observed_floor and window.observed_at <= ^observed_ceiling,
        where: window.reset_at >= ^reset_floor and window.reset_at <= ^reset_ceiling
    )
  end

  defp runtime_weekly_restart_corroborated?(_evidence, _existing, _timestamp), do: false

  defp stale_same_cycle_exhausted_snapshot?(evidence, existing, timestamp) do
    Evidence.current_freshness_state(existing, timestamp) != "fresh" and
      not exhausted_by_used_percent?(existing) and exhausted_by_used_percent?(evidence)
  end

  defp reset_times_equivalent?(%DateTime{} = left, %DateTime{} = right) do
    abs(DateTime.diff(left, right, :second)) <= @account_snapshot_reset_tolerance_seconds
  end

  # A same-cycle reset can drift earlier than the stored reset by countdown
  # rounding, fetch latency, or the provider interleaving two claims of the
  # same window whose resets differ by minutes. Any claim whose reset falls
  # within the window's own duration behind the stored reset still describes
  # the same running window, so its usage must be merged (fail-closed via
  # highest percent) instead of rejected. Anything later than the stored reset
  # beyond a few seconds is a new cycle handled by the forward paths.
  defp same_cycle_reset?(
         %Evidence{reset_at: %DateTime{} = incoming, window_minutes: window_minutes},
         %Quota.AccountQuotaWindow{reset_at: %DateTime{} = existing}
       ) do
    diff = DateTime.diff(incoming, existing, :second)

    diff <= @account_snapshot_reset_tolerance_seconds and
      diff >= -same_cycle_backward_tolerance_seconds(window_minutes)
  end

  defp same_cycle_backward_tolerance_seconds(window_minutes)
       when is_integer(window_minutes) and window_minutes > 0 do
    window_minutes * 60 + @usage_reset_forward_tolerance_seconds
  end

  defp same_cycle_backward_tolerance_seconds(_window_minutes),
    do: @usage_reset_forward_tolerance_seconds

  defp accepted_snapshot_attrs(existing, attrs, timestamp) do
    metadata =
      existing.metadata
      |> Kernel.||(%{})
      |> Map.merge(Map.get(attrs, :metadata, %{}))
      |> clear_inherited_relative_reset_metadata(attrs)
      |> clear_candidate()

    attrs
    |> Map.put(:active_limit, preserved_active_limit(existing, Map.get(attrs, :active_limit)))
    |> Map.put(:credits, preserved_credits(existing, Map.get(attrs, :credits)))
    |> Map.put(:metadata, metadata)
    |> Map.put_new(:created_at, existing.created_at || timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp clear_inherited_relative_reset_metadata(metadata, attrs) do
    incoming_metadata = Map.get(attrs, :metadata, %{})

    if Map.get(attrs, :source_precision) in ["observed", "authoritative"] and
         match?(%DateTime{}, Map.get(attrs, :reset_at)) and
         not relative_reset_metadata?(incoming_metadata) do
      Map.delete(metadata, "reset_after_seconds")
    else
      metadata
    end
  end

  defp same_cycle_snapshot_attrs(existing, attrs, evidence, timestamp) do
    existing
    |> accepted_snapshot_attrs(attrs, timestamp)
    |> Map.put(:reset_at, existing.reset_at)
    |> Map.put(:used_percent, highest_used_percent(existing.used_percent, evidence.used_percent))
    |> preserve_existing_relative_reset_metadata(existing)
  end

  # The canonical reset stays pinned, so the merged metadata must not adopt the
  # incoming claim's relative countdown, which was measured against the
  # incoming (rejected) reset and would misdescribe the pinned one.
  defp preserve_existing_relative_reset_metadata(merged_attrs, existing) do
    existing_metadata = existing.metadata || %{}

    Map.update(merged_attrs, :metadata, existing_metadata, fn metadata ->
      case Map.fetch(existing_metadata, "reset_after_seconds") do
        {:ok, existing_reset_after} ->
          Map.put(metadata, "reset_after_seconds", existing_reset_after)

        :error ->
          Map.delete(metadata, "reset_after_seconds")
      end
    end)
  end

  defp candidate_snapshot_attrs(existing, metadata, timestamp) do
    existing
    |> window_attrs()
    |> Map.put(:metadata, metadata)
    |> Map.put(:updated_at, timestamp)
  end

  defp rejected_snapshot_attrs(existing, evidence, timestamp) do
    existing
    |> window_attrs()
    |> Map.put(:metadata, clear_invalid_candidate(existing.metadata || %{}, timestamp))
    |> Map.put(:updated_at, timestamp)
    |> maybe_refresh_same_cycle_sync(existing, evidence, timestamp)
  end

  # Rejected or candidate same-cycle snapshots must still advance the sync
  # bookkeeping: the provider re-confirmed the current window even when the
  # canonical values win. Without this, rejected refreshes leave the row
  # permanently stale within a cycle, quota admission fails closed, and the
  # whole instance deadlocks into 503s until the next real reset.
  defp maybe_refresh_same_cycle_sync(merged_attrs, existing, evidence, timestamp) do
    if same_cycle_sync_refresh?(evidence, existing, timestamp) do
      merged_attrs
      |> Map.put(:observed_at, evidence.observed_at)
      |> Map.put(:last_sync_at, evidence.observed_at)
      |> Map.put(:freshness_state, "fresh")
    else
      merged_attrs
    end
  end

  defp same_cycle_sync_refresh?(
         %Evidence{
           source_precision: incoming_precision,
           observed_at: %DateTime{},
           reset_at: %DateTime{}
         } = evidence,
         %Quota.AccountQuotaWindow{observed_at: %DateTime{}, reset_at: %DateTime{}} = existing,
         timestamp
       )
       when incoming_precision in ["observed", "authoritative"] do
    newer_observation?(evidence.observed_at, existing.observed_at) and
      Evidence.current_freshness_state(evidence, timestamp) == "fresh" and
      not Evidence.expired?(existing, timestamp) and
      DateTime.diff(evidence.reset_at, existing.reset_at, :second) <=
        @account_snapshot_reset_tolerance_seconds
  end

  defp same_cycle_sync_refresh?(_evidence, _existing, _timestamp), do: false

  defp clear_provider_candidates_after_runtime(
         {:ok, window},
         %Evidence{source: source} = evidence,
         existing,
         identity_id
       )
       when source in @runtime_quota_sources do
    if runtime_pressure_accepted?(window, existing) do
      clear_matching_provider_candidates(evidence, identity_id)
    end

    {:ok, window}
  end

  defp clear_provider_candidates_after_runtime(result, _evidence, _existing, _identity_id),
    do: result

  defp clear_matching_provider_candidates(evidence, identity_id) do
    {scope, family, model, upstream_model, quota_key, kind, minutes} =
      Evidence.logical_window_key(evidence)

    provider_rows =
      Repo.all(
        from provider in Quota.AccountQuotaWindow,
          where: provider.upstream_identity_id == ^identity_id,
          where: provider.source == "codex_usage_api",
          where: provider.quota_scope == ^scope,
          where: provider.quota_family == ^family,
          where: fragment("COALESCE(lower(?), '')", provider.model) == ^lower_string(model),
          where:
            fragment("COALESCE(lower(?), '')", provider.upstream_model) ==
              ^lower_string(upstream_model),
          where: provider.quota_key == ^quota_key,
          where: provider.window_kind == ^kind,
          where: provider.window_minutes == ^minutes
      )

    Enum.each(provider_rows, fn provider ->
      metadata = clear_candidate(provider.metadata || %{})

      if metadata != provider.metadata do
        provider
        |> Ecto.Changeset.change(metadata: metadata, updated_at: now())
        |> Repo.update!()
      end
    end)

    :ok
  end

  defp runtime_pressure_accepted?(window, %Quota.AccountQuotaWindow{id: nil}),
    do: not is_nil(window.id)

  defp runtime_pressure_accepted?(window, existing) do
    higher_used_percent?(window.used_percent, existing.used_percent) or
      later_reset?(window.reset_at, existing.reset_at) or
      window.source != existing.source
  end

  defp later_reset?(%DateTime{} = incoming, %DateTime{} = existing),
    do: DateTime.compare(incoming, existing) == :gt

  defp later_reset?(_incoming, _existing), do: false

  defp clear_invalid_candidate(metadata, timestamp) do
    case parse_candidate(metadata) do
      {:ok, candidate} ->
        if candidate_valid?(candidate, timestamp), do: metadata, else: clear_candidate(metadata)

      :none ->
        clear_candidate(metadata)
    end
  end

  defp incoming_supersedes?(
         %Evidence{} = evidence,
         %Quota.AccountQuotaWindow{} = existing,
         timestamp
       ) do
    cond do
      usage_api_supersedes_runtime_rollback?(evidence, existing, timestamp) ->
        true

      runtime_percent_rollback?(evidence, existing, timestamp) ->
        false

      true ->
        case zero_percent_only_merge_decision(evidence, existing, timestamp) do
          {:ok, decision} ->
            decision

          :continue ->
            quality_supersedes?(evidence, existing, timestamp)
        end
    end
  end

  defp zero_percent_only_merge_decision(%Evidence{} = evidence, existing, timestamp) do
    cond do
      stronger_quota_information?(evidence) and weak_zero_percent_evidence?(existing) and
          not reset_bearing_rollback?(evidence, existing, timestamp) ->
        {:ok, same_evidence_identity?(evidence, existing)}

      weak_zero_percent_evidence?(evidence) and
        stronger_current_quota_information?(existing, timestamp) and
          not newer_usage_reset_supersedes?(evidence, existing) ->
        {:ok, false}

      true ->
        :continue
    end
  end

  defp usage_api_supersedes_runtime_rollback?(
         %Evidence{source: "codex_usage_api", used_percent: %Decimal{} = incoming_percent} =
           evidence,
         %Quota.AccountQuotaWindow{source: source, used_percent: %Decimal{} = existing_percent} =
           existing,
         timestamp
       )
       when source in @runtime_quota_sources do
    rollback_guarded_quota_identity?(evidence) and same_evidence_identity?(evidence, existing) and
      Evidence.current_freshness_state(evidence, timestamp) == "fresh" and
      Decimal.compare(incoming_percent, existing_percent) != :lt
  end

  defp usage_api_supersedes_runtime_rollback?(_evidence, _existing, _timestamp),
    do: false

  defp runtime_percent_rollback?(
         %Evidence{source: source, used_percent: %Decimal{} = incoming_percent} = evidence,
         %Quota.AccountQuotaWindow{
           source: existing_source,
           used_percent: %Decimal{} = existing_percent
         } =
           existing,
         timestamp
       )
       when source in @runtime_quota_sources and
              existing_source in ["codex_usage_api" | @runtime_quota_sources] do
    rollback_guarded_quota_identity?(evidence) and same_evidence_identity?(evidence, existing) and
      weak_capacity?(evidence) and stronger_current_quota_information?(existing, timestamp) and
      Decimal.compare(incoming_percent, existing_percent) != :gt and
      not exhausted_by_used_percent?(evidence)
  end

  defp runtime_percent_rollback?(_evidence, _existing, _timestamp), do: false

  defp incoming_usage_advances_runtime_reset?(
         %Evidence{source: "codex_usage_api"} = evidence,
         %Quota.AccountQuotaWindow{source: source} = existing,
         timestamp
       )
       when source in @runtime_quota_sources do
    same_evidence_identity?(evidence, existing) and weak_zero_percent_evidence?(evidence) and
      stronger_current_quota_information?(existing, timestamp) and
      newer_usage_reset_supersedes?(evidence, existing)
  end

  defp incoming_usage_advances_runtime_reset?(_evidence, _existing, _timestamp), do: false

  defp incoming_weak_usage_extends_existing_reset?(
         %Evidence{source: "codex_usage_api", reset_at: %DateTime{} = incoming_reset} =
           evidence,
         %Quota.AccountQuotaWindow{
           source: "codex_usage_api",
           reset_at: %DateTime{} = existing_reset
         } = existing,
         timestamp
       ) do
    rollback_guarded_quota_identity?(evidence) and same_evidence_identity?(evidence, existing) and
      weak_capacity?(evidence) and stronger_current_quota_information?(existing, timestamp) and
      DateTime.diff(incoming_reset, existing_reset, :second) >
        @usage_reset_forward_tolerance_seconds
  end

  defp incoming_weak_usage_extends_existing_reset?(_evidence, _existing, _timestamp),
    do: false

  defp incoming_relative_usage_extends_existing_reset?(
         %Evidence{source: "codex_usage_api", reset_at: %DateTime{} = incoming_reset} =
           evidence,
         %Quota.AccountQuotaWindow{
           source: "codex_usage_api",
           reset_at: %DateTime{} = existing_reset
         } = existing,
         timestamp
       ) do
    rollback_guarded_quota_identity?(evidence) and same_evidence_identity?(evidence, existing) and
      weak_capacity?(evidence) and relative_reset_metadata?(evidence.metadata) and
      Evidence.current_freshness_state(existing, timestamp) == "fresh" and
      DateTime.diff(incoming_reset, existing_reset, :second) >
        @relative_reset_refresh_tolerance_seconds
  end

  defp incoming_relative_usage_extends_existing_reset?(_evidence, _existing, _timestamp),
    do: false

  defp quality_supersedes?(
         %Evidence{} = evidence,
         %Quota.AccountQuotaWindow{} = existing,
         timestamp
       ) do
    incoming_quality = quality_key(evidence, timestamp)
    existing_quality = quality_key(existing, timestamp)

    higher_precedence_rate_limit_event_supersedes?(evidence, existing) or
      (not reset_bearing_rollback?(evidence, existing, timestamp) and
         (resetless_weekly_rate_limit_supersedes?(evidence, existing) ||
            newer_usage_reset_supersedes?(evidence, existing) ||
            incoming_quality >= existing_quality))
  end

  defp higher_precedence_rate_limit_event_supersedes?(
         %Evidence{source: "codex_rate_limit_event", reset_at: %DateTime{}} = evidence,
         %Quota.AccountQuotaWindow{} = existing
       ) do
    same_evidence_identity?(evidence, existing) and
      merge_precedence(evidence) > merge_precedence(existing)
  end

  defp higher_precedence_rate_limit_event_supersedes?(_evidence, _existing), do: false

  defp reset_bearing_rollback?(
         %Evidence{reset_at: %DateTime{} = reset_at} = evidence,
         %Quota.AccountQuotaWindow{reset_at: %DateTime{} = existing_reset_at} = existing,
         timestamp
       ) do
    same_evidence_identity?(evidence, existing) and
      Evidence.current_freshness_state(existing, timestamp) == "fresh" and
      DateTime.compare(reset_at, existing_reset_at) == :lt and
      not same_source_weak_zero_to_stronger_evidence?(evidence, existing) and
      not explicit_reset_corrects_relative_existing?(evidence, existing)
  end

  defp reset_bearing_rollback?(_evidence, _existing, _timestamp), do: false

  defp explicit_reset_corrects_relative_existing?(
         %Evidence{source_precision: precision},
         %Quota.AccountQuotaWindow{metadata: metadata}
       )
       when precision in ["observed", "authoritative"] do
    relative_reset_metadata?(metadata)
  end

  defp explicit_reset_corrects_relative_existing?(_evidence, _existing), do: false

  defp relative_reset_metadata?(%{} = metadata),
    do:
      not is_nil(
        Map.get(metadata, "reset_after_seconds") || Map.get(metadata, :reset_after_seconds)
      )

  defp relative_reset_metadata?(_metadata), do: false

  defp same_source_weak_zero_to_stronger_evidence?(
         %Evidence{} = evidence,
         %Quota.AccountQuotaWindow{} = existing
       ) do
    evidence.source == existing.source and weak_zero_percent_evidence?(existing) and
      stronger_quota_information?(evidence)
  end

  defp newer_usage_reset_supersedes?(
         %Evidence{
           source: "codex_usage_api",
           source_precision: source_precision,
           reset_at: %DateTime{} = reset_at,
           observed_at: %DateTime{} = observed_at
         } = evidence,
         %Quota.AccountQuotaWindow{
           source: "codex_response_headers",
           reset_at: %DateTime{} = existing_reset_at,
           observed_at: %DateTime{} = existing_observed_at
         } = existing
       )
       when source_precision in ["observed", "authoritative"] do
    same_evidence_identity?(evidence, existing) and
      DateTime.compare(observed_at, existing_observed_at) == :gt and
      DateTime.compare(reset_at, existing_reset_at) == :gt
  end

  defp newer_usage_reset_supersedes?(_evidence, _existing), do: false

  defp resetless_weekly_rate_limit_supersedes?(
         %Evidence{
           source: "codex_rate_limit_event",
           window_minutes: 10_080,
           observed_at: %DateTime{} = observed_at
         } = evidence,
         %Quota.AccountQuotaWindow{
           source: "codex_rate_limit_event",
           window_minutes: 10_080,
           observed_at: %DateTime{} = existing_observed_at
         } = existing
       ) do
    not Evidence.reset_bearing?(evidence) and
      DateTime.compare(observed_at, existing_observed_at) != :lt and
      same_evidence_identity?(evidence, existing)
  end

  defp resetless_weekly_rate_limit_supersedes?(_evidence, _existing), do: false

  defp same_evidence_identity?(%Evidence{} = evidence, %Quota.AccountQuotaWindow{} = existing) do
    Evidence.logical_window_key(evidence) == Evidence.logical_window_key(existing)
  end

  defp canonical_decimal_string(%Decimal{} = value),
    do: value |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} -> if valid_percent?(decimal), do: {:ok, decimal}, else: :error
      _invalid -> :error
    end
  end

  defp parse_decimal(_value), do: :error

  defp valid_percent?(%Decimal{} = value) do
    not Decimal.nan?(value) and not Decimal.inf?(value) and
      Decimal.compare(value, Decimal.new(0)) != :lt and
      Decimal.compare(value, Decimal.new(100)) != :gt
  end

  defp valid_percent?(_value), do: false

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp optional_string(value) when is_binary(value), do: String.trim(value)
  defp optional_string(_value), do: ""

  defp rollback_guarded_quota_identity?(%{quota_key: "account", quota_scope: "account"}),
    do: true

  defp rollback_guarded_quota_identity?(%{quota_scope: scope})
       when scope in ["model", "upstream_model"],
       do: true

  defp rollback_guarded_quota_identity?(_evidence_or_window), do: false

  defp account_quota_identity?(%{quota_key: "account", quota_scope: "account"}), do: true
  defp account_quota_identity?(_evidence_or_window), do: false

  defp weak_zero_snapshot_decision(evidence, existing, timestamp) do
    cond do
      account_quota_identity?(evidence) and anchored_forward_weekly_cycle?(evidence, existing) and
          runtime_weekly_restart_corroborated?(evidence, existing, timestamp) ->
        lower_snapshot_decision(evidence, existing, timestamp)

      account_quota_identity?(evidence) ->
        :existing

      evidence.quota_scope in ["model", "upstream_model"] ->
        :continue

      true ->
        compare_confirmed_snapshot(evidence, existing, timestamp)
    end
  end

  defp relative_snapshot_decision(evidence, existing) do
    if account_quota_identity?(evidence) do
      if later_reset?(evidence.reset_at, existing.reset_at), do: :incoming, else: :existing
    else
      :continue
    end
  end

  defp incoming_refreshes_existing?(
         %Evidence{source: "codex_usage_api"} = evidence,
         %Quota.AccountQuotaWindow{source: "codex_usage_api"} = existing,
         timestamp
       ) do
    same_evidence_identity?(evidence, existing) and weak_zero_percent_evidence?(evidence) and
      stronger_current_quota_information?(existing, timestamp) and
      not exhausted_by_used_percent?(existing)
  end

  defp incoming_refreshes_existing?(
         %Evidence{source: source, used_percent: %Decimal{} = incoming_percent} = evidence,
         %Quota.AccountQuotaWindow{
           source: existing_source,
           used_percent: %Decimal{} = existing_percent
         } = existing,
         timestamp
       )
       when source in @runtime_quota_sources and
              existing_source in ["codex_usage_api" | @runtime_quota_sources] do
    rollback_guarded_quota_identity?(evidence) and same_evidence_identity?(evidence, existing) and
      weak_capacity?(evidence) and stronger_current_quota_information?(existing, timestamp) and
      Decimal.compare(incoming_percent, existing_percent) == :eq and
      not exhausted_by_used_percent?(evidence)
  end

  defp incoming_refreshes_existing?(_evidence, _existing, _timestamp), do: false

  defp incoming_updates_usage_with_existing_capacity?(
         %Evidence{used_percent: %Decimal{} = used_percent} = evidence,
         %Quota.AccountQuotaWindow{} = existing
       ) do
    same_evidence_identity?(evidence, existing) and positive_percent?(used_percent) and
      missing_active_limit?(evidence) and active_limit_bearing?(existing) and
      (weak_capacity?(evidence) or positive_credits?(evidence))
  end

  defp incoming_updates_usage_with_existing_capacity?(_evidence, _existing), do: false

  defp incoming_explicit_reset_corrects_relative_existing?(
         %Evidence{reset_at: %DateTime{}, observed_at: %DateTime{} = observed_at} = evidence,
         %Quota.AccountQuotaWindow{observed_at: %DateTime{} = existing_observed_at} = existing,
         timestamp
       ) do
    same_evidence_identity?(evidence, existing) and
      explicit_reset_corrects_relative_existing?(evidence, existing) and
      not relative_reset_metadata?(evidence.metadata) and
      Evidence.current_freshness_state(evidence, timestamp) == "fresh" and
      DateTime.compare(observed_at, existing_observed_at) == :gt
  end

  defp incoming_explicit_reset_corrects_relative_existing?(
         _evidence,
         _existing,
         _timestamp
       ),
       do: false

  defp incoming_updates_usage_with_existing_reset?(
         %Evidence{
           source_precision: source_precision,
           used_percent: %Decimal{}
         } = evidence,
         %Quota.AccountQuotaWindow{
           reset_at: %DateTime{},
           source_precision: existing_precision,
           used_percent: %Decimal{}
         } = existing,
         timestamp
       )
       when source_precision in ["inferred", "observed", "authoritative"] and
              existing_precision in ["observed", "authoritative"] do
    same_evidence_identity?(evidence, existing) and
      Evidence.current_freshness_state(existing, timestamp) == "fresh" and
      Evidence.current_freshness_state(evidence, timestamp) == "fresh" and
      (source_precision == "inferred" or relative_reset_metadata?(evidence.metadata))
  end

  defp incoming_updates_usage_with_existing_reset?(_evidence, _existing, _timestamp),
    do: false

  defp merge_explicit_reset_correction_attrs(
         %Quota.AccountQuotaWindow{} = existing,
         attrs,
         %Evidence{} = evidence,
         timestamp
       ) do
    active_limit = canonical_active_limit(existing, Map.get(attrs, :active_limit))
    credits = usage_credits(existing, evidence, active_limit, Map.get(attrs, :credits))

    existing
    |> accepted_snapshot_attrs(attrs, timestamp)
    |> Map.put(:active_limit, active_limit)
    |> Map.put(:credits, credits)
    |> maybe_put_used_percent_from_credits(evidence, active_limit, credits)
  end

  defp merge_usage_with_existing_capacity_attrs(
         %Quota.AccountQuotaWindow{} = existing,
         attrs,
         %Evidence{} = evidence,
         timestamp
       ) do
    active_limit = preserved_active_limit(existing, Map.get(attrs, :active_limit))
    credits = usage_credits(existing, evidence, active_limit, Map.get(attrs, :credits))

    attrs
    |> Map.put(:active_limit, active_limit)
    |> Map.put(:credits, credits)
    |> Map.put(:reset_at, latest_reset_at(existing.reset_at, Map.get(attrs, :reset_at)))
    |> maybe_put_used_percent_from_credits(evidence, active_limit, credits)
    |> Map.put_new(:created_at, existing.created_at || timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp merge_usage_with_existing_reset_attrs(
         %Quota.AccountQuotaWindow{} = existing,
         attrs,
         %Evidence{} = evidence,
         timestamp
       ) do
    active_limit = canonical_active_limit(existing, Map.get(attrs, :active_limit))
    credits = usage_credits(existing, evidence, active_limit, Map.get(attrs, :credits))

    existing
    |> window_attrs()
    |> Map.merge(%{
      active_limit: active_limit,
      credits: credits,
      used_percent: highest_used_percent(existing.used_percent, Map.get(attrs, :used_percent)),
      last_sync_at: latest_datetime(existing.last_sync_at, Map.get(attrs, :last_sync_at)),
      observed_at: latest_datetime(existing.observed_at, Map.get(attrs, :observed_at)),
      freshness_state: Map.get(attrs, :freshness_state, existing.freshness_state),
      metadata: Map.merge(existing.metadata || %{}, Map.get(attrs, :metadata, %{})),
      updated_at: timestamp
    })
    |> maybe_put_used_percent_from_credits(evidence, active_limit, credits)
    |> preserve_existing_relative_reset_metadata(existing)
  end

  defp merge_weak_usage_with_existing_reset_attrs(
         %Quota.AccountQuotaWindow{} = existing,
         attrs,
         timestamp
       ) do
    active_limit = preserved_active_limit(existing, Map.get(attrs, :active_limit))
    credits = preserved_credits(existing, Map.get(attrs, :credits))

    existing
    |> window_attrs()
    |> Map.merge(%{
      active_limit: active_limit,
      credits: credits,
      used_percent: highest_used_percent(existing.used_percent, Map.get(attrs, :used_percent)),
      last_sync_at: latest_datetime(existing.last_sync_at, Map.get(attrs, :last_sync_at)),
      observed_at: latest_datetime(existing.observed_at, Map.get(attrs, :observed_at)),
      freshness_state: Map.get(attrs, :freshness_state, existing.freshness_state),
      metadata: Map.merge(existing.metadata || %{}, Map.get(attrs, :metadata, %{})),
      updated_at: timestamp
    })
  end

  defp merge_usage_reset_with_existing_percent_attrs(
         %Quota.AccountQuotaWindow{} = existing,
         attrs,
         timestamp
       ) do
    active_limit = preserved_active_limit(existing, Map.get(attrs, :active_limit))
    credits = preserved_credits(existing, Map.get(attrs, :credits))

    attrs
    |> Map.put(:active_limit, active_limit)
    |> Map.put(:credits, credits)
    |> Map.put(
      :used_percent,
      runtime_usage_percent(existing, Map.get(attrs, :used_percent))
    )
    |> Map.put(:metadata, Map.merge(existing.metadata || %{}, Map.get(attrs, :metadata, %{})))
    |> Map.put_new(:created_at, existing.created_at || timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp refresh_existing_attrs(%Quota.AccountQuotaWindow{} = existing, attrs, timestamp) do
    existing
    |> window_attrs()
    |> Map.merge(%{
      last_sync_at: latest_datetime(existing.last_sync_at, Map.get(attrs, :last_sync_at)),
      observed_at: latest_datetime(existing.observed_at, Map.get(attrs, :observed_at)),
      freshness_state: Map.get(attrs, :freshness_state, existing.freshness_state),
      metadata: Map.merge(existing.metadata || %{}, Map.get(attrs, :metadata, %{})),
      updated_at: timestamp
    })
  end

  defp latest_datetime(%DateTime{} = existing, %DateTime{} = incoming) do
    if DateTime.compare(incoming, existing) == :gt, do: incoming, else: existing
  end

  defp latest_datetime(nil, %DateTime{} = incoming), do: incoming
  defp latest_datetime(existing, _incoming), do: existing

  defp latest_reset_at(%DateTime{} = existing, %DateTime{} = incoming) do
    if DateTime.compare(incoming, existing) == :lt, do: existing, else: incoming
  end

  defp latest_reset_at(nil, %DateTime{} = incoming), do: incoming
  defp latest_reset_at(existing, _incoming), do: existing

  defp weak_zero_percent_evidence?(evidence_or_window) do
    zero_percent?(Map.get(evidence_or_window, :used_percent)) and
      weak_capacity?(evidence_or_window)
  end

  defp stronger_quota_information?(evidence_or_window),
    do: information_quality_rank(evidence_or_window) > 1

  defp stronger_current_quota_information?(evidence_or_window, timestamp) do
    stronger_quota_information?(evidence_or_window) and
      Evidence.current_freshness_state(evidence_or_window, timestamp) == "fresh"
  end

  defp weak_capacity?(evidence_or_window) do
    Map.get(evidence_or_window, :active_limit) in [nil, 0] and
      Map.get(evidence_or_window, :credits) in [nil, 0]
  end

  defp missing_active_limit?(evidence_or_window),
    do: Map.get(evidence_or_window, :active_limit) in [nil, 0]

  defp active_limit_bearing?(evidence_or_window) do
    active_limit = Map.get(evidence_or_window, :active_limit)
    is_integer(active_limit) and active_limit > 0
  end

  defp preserved_active_limit(%Quota.AccountQuotaWindow{active_limit: existing}, incoming)
       when incoming in [nil, 0] and is_integer(existing) and existing > 0,
       do: existing

  defp preserved_active_limit(_existing, incoming), do: incoming

  defp canonical_active_limit(%Quota.AccountQuotaWindow{active_limit: existing}, _incoming)
       when is_integer(existing) and existing > 0,
       do: existing

  defp canonical_active_limit(existing, incoming), do: preserved_active_limit(existing, incoming)

  defp preserved_credits(%Quota.AccountQuotaWindow{credits: existing}, incoming)
       when incoming in [nil, 0] and is_integer(existing) and existing > 0,
       do: existing

  defp preserved_credits(_existing, incoming), do: incoming

  defp usage_credits(
         _existing,
         %Evidence{source: "codex_usage_api"} = evidence,
         active_limit,
         incoming
       )
       when is_integer(active_limit) and active_limit > 0 and is_integer(incoming) and
              incoming >= 0 and incoming <= active_limit do
    if account_quota_identity?(evidence), do: incoming, else: nil
  end

  defp usage_credits(
         %Quota.AccountQuotaWindow{} = existing,
         %Evidence{},
         active_limit,
         _incoming
       )
       when is_integer(active_limit) and active_limit > 0 do
    valid_existing_credits(existing.credits, active_limit)
  end

  defp usage_credits(_existing, _evidence, active_limit, incoming)
       when is_integer(active_limit) and active_limit > 0 and is_integer(incoming) and
              incoming >= 0 and incoming <= active_limit,
       do: incoming

  defp usage_credits(_existing, _evidence, active_limit, incoming)
       when not (is_integer(active_limit) and active_limit > 0) and is_integer(incoming) and
              incoming >= 0,
       do: incoming

  defp usage_credits(_existing, _evidence, _active_limit, _incoming), do: nil

  defp valid_existing_credits(credits, active_limit)
       when is_integer(credits) and credits >= 0 and credits <= active_limit,
       do: credits

  defp valid_existing_credits(_credits, _active_limit), do: nil

  defp maybe_put_used_percent_from_credits(
         attrs,
         %Evidence{source: "codex_usage_api"} = evidence,
         active_limit,
         credits
       )
       when is_integer(active_limit) and active_limit > 0 and is_integer(credits) and credits >= 0 do
    if account_quota_identity?(evidence) do
      Map.put(attrs, :used_percent, used_percent_from_remaining_credits(active_limit, credits))
    else
      attrs
    end
  end

  defp maybe_put_used_percent_from_credits(attrs, _evidence, _active_limit, _credits),
    do: attrs

  defp used_percent_from_remaining_credits(active_limit, credits) do
    active_limit
    |> Decimal.new()
    |> Decimal.sub(Decimal.new(credits))
    |> decimal_non_negative()
    |> Decimal.mult(Decimal.new(100))
    |> Decimal.div(Decimal.new(active_limit))
    |> decimal_clamp_percent()
  end

  defp zero_percent?(%Decimal{} = percent), do: Decimal.compare(percent, Decimal.new(0)) == :eq
  defp zero_percent?(_percent), do: false

  defp positive_percent?(%Decimal{} = percent),
    do: Decimal.compare(percent, Decimal.new(0)) == :gt

  defp higher_used_percent?(%Decimal{} = incoming, %Decimal{} = existing),
    do: Decimal.compare(incoming, existing) == :gt

  defp higher_used_percent?(%Decimal{} = incoming, _existing), do: positive_percent?(incoming)

  defp highest_used_percent(%Decimal{} = existing, %Decimal{} = incoming) do
    if higher_used_percent?(incoming, existing), do: incoming, else: existing
  end

  defp highest_used_percent(nil, %Decimal{} = incoming), do: incoming
  defp highest_used_percent(existing, _incoming), do: existing

  defp runtime_usage_percent(%Quota.AccountQuotaWindow{quota_scope: scope} = existing, incoming)
       when scope in ["model", "upstream_model"],
       do: highest_used_percent(existing.used_percent, incoming)

  defp runtime_usage_percent(_existing, incoming), do: incoming

  defp positive_credits?(%{credits: credits}) when is_integer(credits), do: credits > 0
  defp positive_credits?(_evidence_or_window), do: false

  defp exhausted_by_used_percent?(%{used_percent: %Decimal{} = percent}),
    do: Decimal.compare(percent, Decimal.new(100)) != :lt

  defp exhausted_by_used_percent?(_evidence_or_window), do: false

  defp quality_key(evidence_or_window, timestamp) do
    {
      freshness_rank(Evidence.current_freshness_state(evidence_or_window, timestamp)),
      reset_rank(Evidence.reset_bearing?(evidence_or_window)),
      information_quality_rank(evidence_or_window),
      merge_precedence(evidence_or_window),
      observed_rank(evidence_or_window)
    }
  end

  defp freshness_rank("fresh"), do: 2
  defp freshness_rank("stale"), do: 1
  defp freshness_rank(_state), do: 0

  defp reset_rank(true), do: 1
  defp reset_rank(false), do: 0

  defp merge_precedence(%Evidence{} = evidence), do: evidence.merge_precedence || 0

  defp merge_precedence(%Quota.AccountQuotaWindow{merge_precedence: precedence}),
    do: precedence || 0

  defp observed_rank(%Evidence{observed_at: %DateTime{} = observed_at}),
    do: DateTime.to_unix(observed_at, :microsecond)

  defp observed_rank(%Quota.AccountQuotaWindow{observed_at: %DateTime{} = observed_at}),
    do: DateTime.to_unix(observed_at, :microsecond)

  defp observed_rank(_evidence_or_window), do: 0

  defp information_quality_rank(%{active_limit: active_limit})
       when is_integer(active_limit) and active_limit > 0,
       do: 4

  defp information_quality_rank(%{credits: credits}) when is_integer(credits) and credits > 0,
    do: 3

  defp information_quality_rank(%{used_percent: %Decimal{} = used_percent}) do
    if positive_percent?(used_percent), do: 2, else: 1
  end

  defp information_quality_rank(_evidence_or_window), do: 0

  defp decimal_non_negative(%Decimal{} = value) do
    if Decimal.compare(value, Decimal.new(0)) == :lt, do: Decimal.new(0), else: value
  end

  defp decimal_clamp_percent(%Decimal{} = value) do
    cond do
      Decimal.compare(value, Decimal.new(0)) == :lt -> Decimal.new(0)
      Decimal.compare(value, Decimal.new(100)) == :gt -> Decimal.new(100)
      true -> value
    end
  end

  defp evidence_identity_id(%UpstreamIdentity{id: id}, _attrs), do: id
  defp evidence_identity_id(id, _attrs) when is_binary(id), do: id

  defp evidence_identity_id(_identity_or_id, attrs),
    do: Map.get(attrs, :upstream_identity_id) || Map.get(attrs, "upstream_identity_id")

  defp lower_string(value) when is_binary(value), do: String.downcase(value)
  defp lower_string(_value), do: ""

  defp put_timestamps(attrs, existing \\ %Quota.AccountQuotaWindow{}) do
    timestamp = now()

    attrs
    |> Map.put_new(:created_at, existing.created_at || timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp window_attrs(%Quota.AccountQuotaWindow{} = window) do
    window
    |> Map.from_struct()
    |> Map.take(Quota.AccountQuotaWindow.__schema__(:fields))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
