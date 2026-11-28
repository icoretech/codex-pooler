defmodule CodexPooler.Upstreams.Quota.Windows.AppliedResetProgress do
  @moduledoc """
  Corroborates a lower, positive Usage API measurement of the same account reset
  anchor after an applied reset. Provider clocks establish the observation
  span. Runtime evidence can contradict it but never advances it. The marker
  belongs to the current claim and epoch and never authorizes redemption.
  """

  import Ecto.Query

  alias CodexPooler.Quotas.{CapacityFacts, Evidence, WindowClassifier}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.{CycleConfirmation, EvidenceStore, RelativeLiveness, ResetRecoverySelection}

  @key "__quota_applied_reset_progress_v1"
  @type receipt_capacity :: {CapacityFacts.t() | nil, [CapacityFacts.t()]} | nil

  @spec decide(AccountQuotaWindow.t(), Evidence.t(), DateTime.t(), map() | nil) :: :ordinary | {:hold, map()} | {:accept, map()}
  def decide(%AccountQuotaWindow{id: id, used_percent: %Decimal{} = retained} = row, %Evidence{source: "codex_usage_api", used_percent: %Decimal{} = incoming, metadata: %{"credential_epoch" => epoch}} = evidence, now, %{credential_epoch: epoch, redemption: %{"credential_epoch" => epoch, "status" => "succeeded"} = receipt} = context)
      when is_binary(id) and is_integer(epoch) and epoch > 0 do
    with true <- lower_partial_read?(row, evidence, retained, incoming),
         true <- same_time?(evidence.reset_at, row.reset_at) and row.metadata["credential_epoch"] == epoch,
         {:ok, consumed, finished, descriptors} <- ResetRecoverySelection.confirmed_reset(%{redemption: receipt, as_of: evidence.observed_at}),
         true <- descriptor(evidence) in descriptors and DateTime.compare(row.observed_at, evidence.observed_at) == :lt,
         binding <- binding(receipt, evidence),
         true <- current_attempt_interval?(row.metadata[@key], binding, consumed, evidence.observed_at) do
      if permitted_receipt?(context.receipt_capacity, evidence), do: observe(row, evidence, binding, finished, now), else: {:hold, row.metadata |> clear() |> EvidenceStore.clear_candidate()}
    else
      _unbound -> :ordinary
    end
  end

  def decide(_row, _evidence, _now, _context), do: :ordinary

  defp lower_partial_read?(row, evidence, retained, incoming) do
    eligible_window?(evidence) and partial?(retained) and partial?(incoming) and Decimal.lt?(incoming, retained) and
      percentage_only?(row) and percentage_only?(evidence) and row.source_precision in ["observed", "authoritative"]
  end

  # A reconciliation can merge endpoints. Every physical observation must
  # permit included use, and an original receipt must carry this exact row.
  defp permitted_receipt?({%CapacityFacts{} = aggregate, [_ | _] = observations}, evidence) do
    permitted_observations?({aggregate, observations}, evidence.metadata["credential_epoch"], evidence.observed_at) and
      Enum.any?(observations, fn receipt -> Enum.any?(receipt.account_windows, &matches_reading?(&1, evidence)) end)
  end

  defp permitted_receipt?(_capacity, _evidence), do: false

  defp permitted_observations?({aggregate, [_ | _] = observations}, epoch, at), do: Enum.all?([aggregate | observations], &permitted_at?(&1, epoch, at))
  defp permitted_observations?(_capacity, _epoch, _at), do: false
  defp permitted_at?(%CapacityFacts{included_permission: :available, denial_category: :none, credential_epoch: epoch, observed_at: at}, epoch, observed_at), do: same_time?(at, observed_at)
  defp permitted_at?(_facts, _epoch, _observed_at), do: false

  # A denial may arrive without the affected window. It still interrupts
  # proof on that account, inside the same identity-fenced write.
  @spec invalidate_denied_receipt(Ecto.UUID.t(), pos_integer(), receipt_capacity(), DateTime.t()) :: :ok
  def invalidate_denied_receipt(identity_id, epoch, {%CapacityFacts{}, _observations} = capacity, at) do
    unless permitted_observations?(capacity, epoch, at) do
      rows = Repo.all(from row in AccountQuotaWindow, where: row.upstream_identity_id == ^identity_id and fragment("jsonb_exists(?, ?)", row.metadata, ^@key))
      Enum.each(rows, &invalidate_after(&1, at))
    end

    :ok
  end

  def invalidate_denied_receipt(_identity_id, _epoch, _capacity, _at), do: :ok

  defp invalidate_after(row, at) do
    latest =
      case EvidenceStore.parse_candidate(row.metadata) do
        {:ok, candidate} -> candidate.observed_at
        :none -> row.observed_at
      end

    if DateTime.compare(at, latest) != :lt do
      row |> Ecto.Changeset.change(metadata: row.metadata |> clear() |> EvidenceStore.clear_candidate()) |> Repo.update!()
    end
  end

  defp matches_reading?(%{window_kind: kind, window_minutes: minutes, used_percent: used, reset_at: at}, %{window_kind: kind, window_minutes: minutes, used_percent: percent, reset_at: reset}), do: same_time?(at, reset) and Decimal.equal?(used, percent)
  defp matches_reading?(_left, _right), do: false

  defp percentage_only?(window), do: window.active_limit in [nil, 0] and window.credits in [nil, 0]

  defp current_attempt_interval?(%{"binding" => binding, "first_provider_at" => first}, binding, consumed, observed_at) do
    case parse_time(first) do
      {:ok, first_at, 0} -> fresh_since?(consumed, first_at) and fresh_since?(first_at, observed_at)
      _invalid -> false
    end
  end

  defp current_attempt_interval?(_marker, _binding, consumed, observed_at), do: fresh_since?(consumed, observed_at)

  defp observe(row, evidence, binding, finished, now) do
    metadata = row.metadata

    with true <- evidence.source_precision in ["authoritative", "observed"] and safe_provider?(evidence) and Evidence.current_freshness_state(evidence, now) == "fresh",
         {:ok, provider_at} <- RelativeLiveness.provider_observed_at(evidence),
         true <- RelativeLiveness.advances?(evidence, row, now) and fresh_since?(provider_at, evidence.observed_at),
         true <- advances_pending?(metadata, binding, evidence, provider_at),
         true <- DateTime.compare(provider_at, finished) == :gt and DateTime.compare(evidence.observed_at, now) != :gt and DateTime.compare(evidence.reset_at, now) == :gt do
      progress = metadata[@key]
      first_at = first_provider_at(progress, metadata, binding, evidence, provider_at, finished, now)
      marker = %{"binding" => binding, "reset_at" => DateTime.to_iso8601(evidence.reset_at), "first_provider_at" => DateTime.to_iso8601(first_at), "last_provider_at" => DateTime.to_iso8601(provider_at)}

      if DateTime.diff(provider_at, first_at) >= CycleConfirmation.positive_confirmation_seconds() and compatible_runtime?(row, evidence, finished) do
        {:accept, Map.put(marker, "accepted_at", DateTime.to_iso8601(evidence.observed_at))}
      else
        {:hold, metadata |> EvidenceStore.put_candidate(evidence) |> Map.put(@key, marker)}
      end
    else
      _invalid -> {:hold, metadata |> Map.delete(@key) |> EvidenceStore.clear_candidate()}
    end
  end

  defp advances_pending?(%{@key => %{"binding" => binding, "last_provider_at" => last}} = metadata, binding, evidence, provider_at) do
    with {:ok, last_at, 0} <- parse_time(last),
         {:ok, candidate} <- EvidenceStore.parse_candidate(metadata) do
      DateTime.compare(provider_at, last_at) == :gt and DateTime.compare(evidence.observed_at, candidate.observed_at) == :gt
    else
      _invalid -> false
    end
  end

  defp advances_pending?(_metadata, _binding, _evidence, _provider_at), do: true

  defp first_provider_at(%{"binding" => binding, "reset_at" => reset, "first_provider_at" => first, "last_provider_at" => last} = marker, metadata, binding, evidence, provider_at, finished, now) when map_size(marker) == 4 do
    with {:ok, candidate} <- EvidenceStore.parse_candidate(metadata),
         true <- EvidenceStore.candidate_provider_status_safe?(metadata) and EvidenceStore.candidate_valid?(candidate, now),
         true <- reset == DateTime.to_iso8601(evidence.reset_at) and same_time?(candidate.reset_at, evidence.reset_at),
         {:ok, first_at, 0} <- parse_time(first),
         {:ok, last_at, 0} <- parse_time(last),
         true <- valid_chain_clocks?(first_at, last_at, finished, candidate.observed_at, now),
         true <- DateTime.compare(evidence.observed_at, candidate.observed_at) == :gt and not Decimal.lt?(evidence.used_percent, candidate.used_percent) do
      first_at
    else
      _restart -> provider_at
    end
  end

  defp first_provider_at(_marker, _metadata, _binding, _evidence, provider_at, _finished, _now), do: provider_at

  defp valid_chain_clocks?(first_at, last_at, finished, observed_at, now) do
    fresh_since?(first_at, now) and DateTime.compare(first_at, finished) == :gt and
      DateTime.compare(first_at, last_at) != :gt and DateTime.compare(last_at, observed_at) != :gt
  end

  # All writers hold the identity mutex. Inspect persisted pressure even when
  # its source row already existed before the first lower provider reading.
  defp compatible_runtime?(row, evidence, finished) do
    row.upstream_identity_id
    |> EvidenceStore.list_evidence()
    |> Enum.filter(&(same_resource?(&1, evidence) and &1.source != "codex_usage_api" and Evidence.current_freshness_state(&1, evidence.observed_at) == "fresh"))
    |> Enum.all?(fn runtime ->
      non_denying?(runtime) and same_time?(runtime.reset_at, evidence.reset_at) and
        (DateTime.compare(runtime.observed_at, finished) == :lt or
           (DateTime.compare(runtime.observed_at, evidence.observed_at) != :gt and not Decimal.gt?(runtime.used_percent, evidence.used_percent)))
    end)
  end

  @spec put_accepted(map(), map()) :: map()
  def put_accepted(attrs, marker), do: Map.update!(attrs, :metadata, &Map.put(&1, @key, marker))

  @spec check_runtime?(map() | nil, Evidence.t()) :: boolean()
  def check_runtime?(%{credential_epoch: epoch, redemption: %{"credential_epoch" => epoch, "status" => "succeeded"} = receipt}, evidence) when is_integer(epoch) and epoch > 0 do
    with true <- eligible_window?(evidence),
         {:ok, consumed, _finished, descriptors} <- ResetRecoverySelection.confirmed_reset(%{redemption: receipt, as_of: evidence.observed_at}) do
      descriptor(evidence) in descriptors and DateTime.diff(evidence.observed_at, consumed) <= 2 * Evidence.freshness_ttl_seconds()
    else
      _unbound -> false
    end
  end

  def check_runtime?(_context, _evidence), do: false

  @spec runtime_action(map(), Evidence.t()) :: :ordinary | :keep | :clear
  def runtime_action(%{@key => %{"binding" => %{"credential_epoch" => epoch}}} = metadata, evidence) do
    with {:ok, candidate} <- EvidenceStore.parse_candidate(metadata),
         true <- eligible_window?(evidence) and DateTime.compare(evidence.observed_at, candidate.observed_at) != :lt do
      if non_denying?(evidence) and same_time?(evidence.reset_at, candidate.reset_at) and Map.get(evidence.metadata, "credential_epoch", epoch) == epoch and not Decimal.lt?(evidence.used_percent, candidate.used_percent), do: :keep, else: :clear
    else
      _other -> :ordinary
    end
  end

  def runtime_action(_metadata, _evidence), do: :ordinary

  @spec discard_interrupted(AccountQuotaWindow.t(), Evidence.t(), map()) :: AccountQuotaWindow.t()
  def discard_interrupted(%{metadata: %{@key => marker} = metadata} = row, evidence, context) do
    if keep_accepted?(marker, row, evidence) and permitted_receipt?(context.receipt_capacity, evidence) do
      row
    else
      %{row | metadata: metadata |> clear() |> EvidenceStore.clear_candidate()}
    end
  end

  def discard_interrupted(row, _evidence, _context), do: row

  defp keep_accepted?(%{"accepted_at" => _}, row, evidence) do
    partial?(evidence.used_percent) and safe_provider?(evidence) and same_time?(evidence.reset_at, row.reset_at) and not Decimal.lt?(evidence.used_percent, row.used_percent)
  end

  defp keep_accepted?(_marker, _row, _evidence), do: false

  @spec clear(map()) :: map()
  def clear(metadata), do: Map.delete(metadata, @key)

  @spec supersedes?(AccountQuotaWindow.t(), AccountQuotaWindow.t(), map(), DateTime.t()) :: boolean()
  def supersedes?(witness, runtime, snapshot, finished) do
    with true <- same_resource?(witness, runtime) and non_denying?(runtime) and same_time?(witness.reset_at, runtime.reset_at),
         %{"binding" => binding, "reset_at" => reset, "first_provider_at" => first, "last_provider_at" => last, "accepted_at" => accepted} = marker when map_size(marker) == 5 <- witness.metadata[@key],
         true <- current_binding?(binding, snapshot, witness),
         {:ok, reset_at, 0} <- parse_time(reset),
         true <- same_time?(reset_at, witness.reset_at) and safe_provider?(witness),
         {:ok, first_at, 0} <- parse_time(first),
         {:ok, last_at, 0} <- parse_time(last),
         {:ok, accepted_at, 0} <- parse_time(accepted),
         true <- DateTime.compare(first_at, finished) == :gt and DateTime.diff(last_at, first_at) >= CycleConfirmation.positive_confirmation_seconds() and DateTime.compare(last_at, accepted_at) != :gt,
         true <- DateTime.compare(accepted_at, witness.observed_at) != :gt and fresh_since?(accepted_at, snapshot.as_of) do
      covered_runtime?(runtime, witness, finished)
    else
      _unproven -> false
    end
  end

  defp current_binding?(binding, snapshot, witness) do
    descriptor(witness) in snapshot.redemption["included_window_descriptors"] and
      snapshot.redemption["status"] == "succeeded" and binding == binding(snapshot.redemption, witness) and snapshot.credential_epoch == binding["credential_epoch"]
  end

  defp covered_runtime?(runtime, witness, finished) do
    DateTime.compare(runtime.observed_at, finished) == :lt or
      (DateTime.compare(runtime.observed_at, witness.observed_at) == :lt and not Decimal.gt?(runtime.used_percent, witness.used_percent))
  end

  defp non_denying?(window) do
    window.source in ["codex_rate_limit_event", "codex_response_headers"] and
      window.source_precision in ["observed", "authoritative"] and non_exhausted?(window.used_percent) and percentage_only?(window) and
      window.metadata["rate_limit_allowed"] in [nil, true] and window.metadata["rate_limit_reached"] in [nil, false] and
      is_nil(window.metadata["rate_limit_error_code"]) and is_nil(window.metadata["rate_limit_reached_type"])
  end

  defp safe_provider?(evidence), do: evidence.metadata["rate_limit_allowed"] == true and evidence.metadata["rate_limit_reached"] == false and is_nil(evidence.metadata["rate_limit_reached_type"]) and is_nil(evidence.metadata["rate_limit_error_code"])
  defp non_exhausted?(%Decimal{} = used), do: not Decimal.lt?(used, 0) and Decimal.lt?(used, 100)
  defp non_exhausted?(_used), do: false
  defp partial?(%Decimal{} = used), do: Decimal.gt?(used, 0) and Decimal.lt?(used, 100)
  defp partial?(_used), do: false
  defp eligible_window?(%{model: nil, upstream_model: nil} = window), do: WindowClassifier.saved_reset_window?(window)
  defp eligible_window?(_window), do: false
  defp descriptor(window), do: %{"window_kind" => window.window_kind, "window_minutes" => window.window_minutes}
  defp binding(receipt, window), do: receipt |> Map.take(~w(attempt_id generation credential_epoch consumed_at)) |> Map.put("descriptor", descriptor(window))
  defp same_resource?(left, right), do: eligible_window?(left) and eligible_window?(right) and left.window_kind == right.window_kind and left.window_minutes == right.window_minutes

  defp same_time?(%DateTime{} = left, %DateTime{} = right), do: DateTime.compare(left, right) == :eq
  defp same_time?(_left, _right), do: false
  defp fresh_since?(at, now), do: DateTime.compare(at, now) != :gt and DateTime.diff(now, at) <= Evidence.freshness_ttl_seconds()
  defp parse_time(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_time(_value), do: :error
end
