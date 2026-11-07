defmodule CodexPooler.Upstreams.Quota.Windows.ResetRecoverySelection do
  @moduledoc false

  alias CodexPooler.Quotas.{CapacityFacts, Evidence}
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, CapacityFactsStore, RoutingQuotaSnapshot, WindowSelector}
  alias CodexPooler.Upstreams.Quota.Windows.UsageCoherence
  alias CodexPooler.Upstreams.SavedResets.ManualRedemptionGate
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle

  @reset_rounding_seconds 5

  # A rolling restart can be accepted without becoming an anchored cycle.
  # A confirmed applied reset with current included evidence retires its own
  # prior cycle. A partial non-denying runtime measurement just after consume
  # also yields once the new zero cycle was accepted; later pressure remains.
  @spec reject_recovered_prior_cycles([AccountQuotaWindow.t()], RoutingQuotaSnapshot.t()) :: [AccountQuotaWindow.t()]
  def reject_recovered_prior_cycles(windows, snapshot) do
    with {:ok, consumed_at, finished_at, descriptors} <- confirmed_reset(snapshot),
         true <- included_permission?(snapshot, consumed_at),
         witnesses <- Enum.filter(windows, &recovery_witness?(&1, snapshot, consumed_at)),
         true <- Enum.all?(descriptors, fn descriptor -> Enum.any?(witnesses, &matches_descriptor?(&1, descriptor)) end) do
      Enum.reject(windows, fn window ->
        (preconsume_measurement?(window, consumed_at) and
           Enum.any?(descriptors, &recovered_resource?(window, &1, witnesses))) or
          superseded_partial_measurement?(window, consumed_at, finished_at, descriptors, witnesses, snapshot.as_of)
      end)
    else
      _unproven -> windows
    end
  end

  defp recovered_resource?(window, descriptor, witnesses),
    do: matches_descriptor?(window, descriptor) and Enum.any?(witnesses, &(matches_descriptor?(&1, descriptor) and later_cycle?(&1, window)))

  defp confirmed_reset(%{redemption: redemption, as_of: as_of}) when is_map(redemption) do
    with true <- RedemptionLifecycle.phase(redemption) == RedemptionLifecycle.confirmed_by_quota(),
         true <- RedemptionLifecycle.applied_consume?(redemption),
         %{"code" => code} when code in ["reset", "already_redeemed", "target_redeemed"] <- redemption["result"],
         generation when is_integer(generation) and generation > 0 <- redemption["generation"],
         {:ok, _attempt_id} <- Ecto.UUID.cast(redemption["attempt_id"]),
         %{"version" => version, "provider_dispatches" => dispatches} when dispatches in 1..6 <- redemption["provider_replay"],
         true <- valid_replay_version?(redemption, version, as_of),
         {:ok, consumed_at, _offset} <- parse_datetime(redemption["consumed_at"]),
         {:ok, finished_at, _offset} <- parse_datetime(redemption["finished_at"]),
         true <- DateTime.compare(consumed_at, finished_at) != :gt and DateTime.compare(finished_at, as_of) != :gt,
         [_ | _] = descriptors when length(descriptors) <= 2 <- redemption["included_window_descriptors"],
         true <- Enum.all?(descriptors, &valid_descriptor?/1),
         true <- length(Enum.uniq(descriptors)) == length(descriptors) do
      {:ok, consumed_at, finished_at, descriptors}
    else
      _invalid -> :error
    end
  end

  defp confirmed_reset(_snapshot), do: :error

  defp valid_replay_version?(_redemption, 1, _as_of), do: true

  defp valid_replay_version?(%{"trigger_kind" => "admin_manual", "manual_replacement" => context}, 2, as_of),
    do: ManualRedemptionGate.stored_context_valid?(context, as_of)

  defp valid_replay_version?(_redemption, _version, _as_of), do: false

  defp included_permission?(%{capacity_facts: %CapacityFacts{included_permission: :available, denial_category: :none} = facts} = snapshot, consumed_at) do
    CapacityFactsStore.fresh?(facts, snapshot.credential_epoch, snapshot.as_of) and
      DateTime.compare(facts.observed_at, consumed_at) != :lt
  end

  defp included_permission?(_snapshot, _consumed_at), do: false

  defp recovery_witness?(%AccountQuotaWindow{source: "codex_usage_api", source_precision: precision, used_percent: %Decimal{} = used, observed_at: %DateTime{} = observed_at, reset_at: %DateTime{}, metadata: metadata} = window, snapshot, consumed_at)
       when precision in ["observed", "authoritative"] and is_map(metadata) do
    metadata["credential_epoch"] == snapshot.credential_epoch and
      DateTime.compare(observed_at, consumed_at) != :lt and DateTime.compare(observed_at, snapshot.as_of) != :gt and
      Evidence.current_freshness_state(window, snapshot.as_of) == "fresh" and not Evidence.expired?(window, snapshot.as_of) and
      Decimal.compare(used, Decimal.new(100)) == :lt and
      metadata["rate_limit_allowed"] != false and metadata["rate_limit_reached"] != true
  end

  defp recovery_witness?(_window, _snapshot, _consumed_at), do: false

  defp preconsume_measurement?(%AccountQuotaWindow{used_percent: %Decimal{}, observed_at: %DateTime{} = observed_at, reset_at: %DateTime{}}, consumed_at),
    do: DateTime.compare(observed_at, consumed_at) == :lt

  defp preconsume_measurement?(_window, _consumed_at), do: false

  @spec superseded_partial_measurement?(AccountQuotaWindow.t(), DateTime.t(), DateTime.t(), [map()], [AccountQuotaWindow.t()], DateTime.t()) :: boolean()
  defp superseded_partial_measurement?(%AccountQuotaWindow{source: source, source_precision: precision, used_percent: %Decimal{} = used, observed_at: %DateTime{} = observed_at, reset_at: %DateTime{}, metadata: metadata} = window, consumed_at, finished_at, descriptors, witnesses, as_of)
       when source in ["codex_response_headers", "codex_rate_limit_event"] and precision in ["observed", "authoritative"] and is_map(metadata) do
    DateTime.compare(observed_at, consumed_at) != :lt and
      non_denying_partial_measurement?(metadata, used) and
      Enum.any?(descriptors, fn descriptor ->
        descriptor == %{"window_kind" => "secondary", "window_minutes" => 10_080} and
          matches_descriptor?(window, descriptor) and
          Enum.any?(witnesses, fn witness ->
            matches_descriptor?(witness, descriptor) and later_cycle?(witness, window) and
              before_accepted_zero?(observed_at, witness, consumed_at, finished_at, as_of)
          end)
      end)
  end

  defp superseded_partial_measurement?(_window, _consumed_at, _finished_at, _descriptors, _witnesses, _as_of), do: false

  defp non_denying_partial_measurement?(metadata, used) do
    Decimal.compare(used, Decimal.new(0)) == :gt and Decimal.compare(used, Decimal.new(100)) == :lt and
      is_nil(metadata["rate_limit_reached_type"]) and is_nil(metadata["rate_limit_error_code"]) and
      metadata["rate_limit_allowed"] in [nil, true] and metadata["rate_limit_reached"] in [nil, false]
  end

  defp before_accepted_zero?(observed_at, %AccountQuotaWindow{used_percent: %Decimal{} = used, metadata: metadata} = witness, consumed_at, finished_at, as_of) do
    with true <- Decimal.equal?(used, Decimal.new(0)),
         %{"used_percent" => encoded_used} = encoded <- metadata[UsageCoherence.metadata_key()],
         true <- map_size(encoded) == 8,
         true <- is_binary(encoded_used),
         {%Decimal{} = marker_used, ""} <- Decimal.parse(encoded_used),
         true <- Decimal.equal?(marker_used, used),
         {:ok, marker} <- UsageCoherence.parse_marker(metadata),
         :eq <- DateTime.compare(marker.reset_at, witness.reset_at),
         :eq <- DateTime.compare(marker.last_observed_at, witness.observed_at),
         true <- DateTime.compare(marker.first_observed_at, consumed_at) != :lt,
         true <- DateTime.compare(marker.first_observed_at, marker.last_observed_at) != :gt,
         true <- DateTime.compare(marker.last_observed_at, as_of) != :gt do
      # A coherence chain may restart after a polling gap. The settled receipt
      # caps the cutoff so that later polls never hide newer runtime pressure.
      cutoff = Enum.min([finished_at, marker.first_observed_at], DateTime)
      DateTime.compare(observed_at, cutoff) == :lt
    else
      _unproven -> false
    end
  end

  defp later_cycle?(witness, window),
    do: DateTime.diff(witness.reset_at, window.reset_at, :microsecond) > @reset_rounding_seconds * 1_000_000

  defp matches_descriptor?(%AccountQuotaWindow{} = window, descriptor) do
    window = WindowSelector.normalize_legacy_weekly_primary(window)

    window.quota_key == "account" and window.quota_scope == "account" and window.quota_family == "account" and
      is_nil(window.model) and is_nil(window.upstream_model) and
      window.window_kind == descriptor["window_kind"] and window.window_minutes == descriptor["window_minutes"]
  end

  defp valid_descriptor?(%{"window_kind" => kind, "window_minutes" => minutes} = descriptor),
    do: map_size(descriptor) == 2 and {kind, minutes} in [{"secondary", 10_080}, {"primary", 43_200}]

  defp valid_descriptor?(_descriptor), do: false

  defp parse_datetime(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_datetime(_value), do: :error
end
