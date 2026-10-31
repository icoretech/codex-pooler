defmodule CodexPooler.Upstreams.Quota.Windows.ResetRecoverySelection do
  @moduledoc false

  alias CodexPooler.Quotas.{CapacityFacts, Evidence}
  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, CapacityFactsStore, RoutingQuotaSnapshot, WindowSelector}
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle

  @reset_rounding_seconds 5

  # A rolling restart can be accepted without becoming an anchored cycle.
  # Only a confirmed applied reset with current included provider evidence may
  # retire its own measured pre-consume cycle; the raw diagnostic view is intact.
  @spec reject_recovered_prior_cycles([AccountQuotaWindow.t()], RoutingQuotaSnapshot.t()) :: [AccountQuotaWindow.t()]
  def reject_recovered_prior_cycles(windows, snapshot) do
    with {:ok, consumed_at, descriptors} <- confirmed_reset(snapshot),
         true <- included_permission?(snapshot, consumed_at),
         witnesses <- Enum.filter(windows, &recovery_witness?(&1, snapshot, consumed_at)),
         true <- Enum.all?(descriptors, fn descriptor -> Enum.any?(witnesses, &matches_descriptor?(&1, descriptor)) end) do
      Enum.reject(windows, fn window ->
        preconsume_measurement?(window, consumed_at) and
          Enum.any?(descriptors, &recovered_resource?(window, &1, witnesses))
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
         %{"version" => 1, "provider_dispatches" => dispatches} when dispatches in 1..6 <- redemption["provider_replay"],
         {:ok, consumed_at, _offset} <- parse_datetime(redemption["consumed_at"]),
         {:ok, finished_at, _offset} <- parse_datetime(redemption["finished_at"]),
         true <- DateTime.compare(consumed_at, finished_at) != :gt and DateTime.compare(finished_at, as_of) != :gt,
         [_ | _] = descriptors when length(descriptors) <= 2 <- redemption["included_window_descriptors"],
         true <- Enum.all?(descriptors, &valid_descriptor?/1),
         true <- length(Enum.uniq(descriptors)) == length(descriptors) do
      {:ok, consumed_at, descriptors}
    else
      _invalid -> :error
    end
  end

  defp confirmed_reset(_snapshot), do: :error

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
