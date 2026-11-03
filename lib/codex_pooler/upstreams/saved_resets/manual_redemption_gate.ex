defmodule CodexPooler.Upstreams.SavedResets.ManualRedemptionGate do
  @moduledoc false

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.CycleConfirmation
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @receipt_keys ~w(phase status attempt_id generation included_window_descriptors started_at consumed_at deadline_at finished_at)
  @replay_keys ~w(version provider_dispatches endpoint_family scope_fingerprint)

  @spec blocked?(UpstreamIdentity.t(), [AccountQuotaWindow.t()], DateTime.t()) :: boolean()
  def blocked?(%UpstreamIdentity{metadata: metadata} = identity, windows, now) when is_map(metadata) do
    redemption = metadata["saved_reset_redemption"]
    RedemptionLifecycle.blocks_new_redemption?(redemption, now) and replacement_context(identity, windows, now) == :error
  end

  def blocked?(%UpstreamIdentity{metadata: nil}, _windows, _now), do: false
  def blocked?(_identity, _windows, _now), do: true

  # This authorizes a new, explicit spend on the current identity. The old
  # receipt has no credential epoch: neither its verification nor historical
  # credential continuity is inferred from a current provider cycle.
  @spec replacement_context(UpstreamIdentity.t(), [AccountQuotaWindow.t()], DateTime.t()) :: {:ok, map()} | :error
  def replacement_context(%UpstreamIdentity{metadata: %{"saved_reset_redemption" => %{"phase" => "manual_replacement_not_applied", "result" => %{"applied" => false}, "manual_replacement" => %{"version" => 1, "receipt" => %{"phase" => "expired"} = receipt} = context}}} = identity, windows, now) do
    if stored_context_valid?(context, now),
      do: replacement_context(%{identity | metadata: Map.put(identity.metadata, "saved_reset_redemption", receipt)}, windows, now),
      else: :error
  end

  def replacement_context(%UpstreamIdentity{} = identity, windows, %DateTime{} = now) when is_list(windows) do
    with %{} = metadata <- identity.metadata,
         epoch when is_integer(epoch) and epoch > 0 <- metadata["credential_epoch"],
         {:ok, receipt, consumed_at} <- historical_receipt(metadata["saved_reset_redemption"], now),
         [window] <- Enum.filter(windows, &weekly_provider_window?(&1, identity.id, epoch)),
         {:ok, _window_id} <- Ecto.UUID.cast(window.id),
         true <- CycleConfirmation.selector_valid?(window, now),
         {:ok, marker} <- CycleConfirmation.valid_marker(window),
         {:ok, provider_at, 0} <- DateTime.from_iso8601(marker["provider_observed_at"]),
         cycle_started_at <- DateTime.add(window.reset_at, -604_800),
         true <- DateTime.diff(cycle_started_at, consumed_at, :microsecond) > 5_000_000,
         true <- DateTime.compare(cycle_started_at, provider_at) != :gt,
         true <- DateTime.compare(window.reset_at, now) == :gt do
      {:ok, %{"version" => 1, "credential_epoch" => epoch, "window_id" => window.id, "reset_at" => DateTime.to_iso8601(window.reset_at), "receipt" => receipt}}
    else
      _unqualified -> :error
    end
  end

  def replacement_context(_identity, _windows, _now), do: :error

  @spec context_valid?(UpstreamIdentity.t(), [AccountQuotaWindow.t()], term(), DateTime.t()) :: boolean()
  def context_valid?(identity, windows, %{"version" => 1, "receipt" => %{"phase" => "expired"} = receipt} = context, now) when map_size(context) == 5 do
    historical_identity = %{identity | metadata: Map.put(identity.metadata || %{}, "saved_reset_redemption", receipt)}
    replacement_context(historical_identity, windows, now) == {:ok, context}
  end

  def context_valid?(_identity, _windows, _context, _now), do: false

  @spec stored_context_valid?(term(), DateTime.t()) :: boolean()
  def stored_context_valid?(%{"version" => 1, "credential_epoch" => epoch, "window_id" => window_id, "reset_at" => reset_at, "receipt" => receipt} = context, now) when map_size(context) == 5 and is_integer(epoch) and epoch > 0 do
    with {:ok, _id} <- Ecto.UUID.cast(window_id),
         {:ok, reset_at} <- parse(reset_at),
         {:ok, ^receipt, consumed_at} <- historical_receipt(receipt, now) do
      DateTime.diff(DateTime.add(reset_at, -604_800), consumed_at, :microsecond) > 5_000_000
    else
      _invalid -> false
    end
  end

  def stored_context_valid?(_context, _now), do: false

  defp historical_receipt(%{"phase" => "expired", "status" => "failed", "included_window_descriptors" => [], "result" => %{"applied" => true, "code" => code}, "provider_replay" => replay} = receipt, now)
       when code in ~w(reset already_redeemed target_redeemed) and is_map(replay) do
    with {:ok, _uuid} <- Ecto.UUID.cast(receipt["attempt_id"]),
         generation when is_integer(generation) and generation > 0 <- receipt["generation"],
         %{"version" => 1, "provider_dispatches" => count, "endpoint_family" => family, "scope_fingerprint" => fingerprint} <- replay,
         true <- is_integer(count) and count in 1..6,
         true <- family in ["chatgpt_api", "codex_api"],
         true <- is_binary(fingerprint) and Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
         {:ok, started_at} <- parse(receipt["started_at"]),
         {:ok, consumed_at} <- parse(receipt["consumed_at"]),
         {:ok, deadline_at} <- parse(receipt["deadline_at"]),
         {:ok, finished_at} <- parse(receipt["finished_at"]),
         true <- DateTime.compare(started_at, consumed_at) != :gt,
         true <- DateTime.compare(consumed_at, deadline_at) == :lt,
         true <- DateTime.compare(deadline_at, finished_at) != :gt,
         true <- DateTime.compare(finished_at, now) != :gt,
         true <- DateTime.diff(now, consumed_at, :millisecond) >= RedemptionLifecycle.gateway_auto_consume_cooldown_ms() do
      canonical = receipt |> Map.take(@receipt_keys) |> Map.put("result", %{"applied" => true, "code" => code}) |> Map.put("provider_replay", Map.take(replay, @replay_keys))
      {:ok, canonical, consumed_at}
    else
      _invalid -> :error
    end
  end

  defp historical_receipt(_receipt, _now), do: :error

  defp weekly_provider_window?(%AccountQuotaWindow{upstream_identity_id: identity_id, quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: "secondary", window_minutes: 10_080, source: "codex_usage_api", model: nil, upstream_model: nil, metadata: %{"credential_epoch" => epoch}, source_precision: precision}, identity_id, epoch) do
    precision in ["observed", "authoritative"]
  end

  defp weekly_provider_window?(_window, _identity_id, _epoch), do: false

  defp parse(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  defp parse(_value), do: :error
end
