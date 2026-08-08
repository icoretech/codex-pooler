defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetConfirmationProjection do
  @moduledoc false

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.CycleConfirmation
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @known_sources ~w(
    codex_usage_api
    codex_rate_limit_event
    codex_response_headers
    codex_rate_limit_error
  )
  @known_precisions ~w(authoritative observed inferred)
  @blocker_precedence ~w(reset_missing expired not_fresh exhausted unknown_unusable)

  @type confirmation_state ::
          :awaiting_confirmation | :confirmed | :not_applied | :confirmation_expired
  @type challenged_evidence_state :: :absent | :exhausted | :candidate_progressing | :usable
  @type additional_account_blocker_state ::
          :none | :reset_missing | :expired | :not_fresh | :exhausted | :unknown_unusable
  @type t :: %{
          required(:confirmation_state) => confirmation_state(),
          required(:challenged_evidence_state) => challenged_evidence_state(),
          required(:additional_account_blocker_state) => additional_account_blocker_state(),
          required(:observed_at) => DateTime.t() | nil
        }

  @spec project(map(), [AccountQuotaWindow.t()], [AccountQuotaWindow.t()], DateTime.t()) ::
          t() | nil
  def project(redemption, raw_windows, effective_windows, %DateTime{} = snapshot_at)
      when is_map(redemption) and is_list(raw_windows) and is_list(effective_windows) do
    with {:ok, confirmation_state} <- confirmation_state(redemption["phase"]) do
      consumed_at = nonfuture_datetime(redemption["consumed_at"], snapshot_at)

      {challenged_key, candidate_observed_at} =
        challenged_candidate(raw_windows, consumed_at, snapshot_at)

      {challenged_key, accepted_observed_at} =
        preserve_challenge(
          challenged_key,
          accepted_challenge(effective_windows, consumed_at, snapshot_at)
        )

      {challenged_key, fallback_observed_at} =
        preserve_challenge(challenged_key, fallback_challenge(effective_windows, snapshot_at))

      %{
        confirmation_state: confirmation_state,
        challenged_evidence_state:
          challenged_evidence_state(
            challenged_key,
            candidate_observed_at,
            effective_windows,
            snapshot_at
          ),
        additional_account_blocker_state:
          additional_account_blocker_state(
            challenged_key,
            effective_windows,
            snapshot_at
          ),
        observed_at: candidate_observed_at || accepted_observed_at || fallback_observed_at
      }
    else
      :none -> nil
    end
  end

  def project(_redemption, _raw_windows, _effective_windows, _snapshot_at), do: nil

  defp confirmation_state(phase)
       when phase in ["consuming", "consumed_pending_probe", "reblocked"],
       do: {:ok, :awaiting_confirmation}

  defp confirmation_state(phase) when phase in ["confirmed_by_upstream", "confirmed_by_quota"],
    do: {:ok, :confirmed}

  defp confirmation_state("consume_not_applied"), do: {:ok, :not_applied}
  defp confirmation_state("expired"), do: {:ok, :confirmation_expired}
  defp confirmation_state(_phase), do: :none

  defp challenged_candidate(raw_windows, consumed_at, snapshot_at) do
    raw_windows
    |> Enum.flat_map(&candidate_challenge(&1, consumed_at, snapshot_at))
    |> Enum.max_by(&challenge_sort_key/1, fn -> nil end)
    |> challenge_pair()
  end

  defp candidate_challenge(%AccountQuotaWindow{} = window, consumed_at, snapshot_at) do
    metadata = window.metadata || %{}

    with true <- bounded_account_window?(window),
         true <- timestamp_between?(window.observed_at, consumed_at, snapshot_at),
         {:ok, candidate} <- EvidenceStore.parse_candidate(metadata),
         true <- EvidenceStore.candidate_valid?(candidate, snapshot_at),
         true <- EvidenceStore.candidate_provider_status_safe?(metadata),
         true <- timestamp_between?(candidate.observed_at, consumed_at, snapshot_at) do
      [{WindowSelector.logical_key(window), candidate.observed_at}]
    else
      _invalid -> []
    end
  end

  defp accepted_challenge(effective_windows, consumed_at, snapshot_at) do
    effective_windows
    |> Enum.flat_map(&accepted_window_challenge(&1, consumed_at, snapshot_at))
    |> Enum.max_by(&challenge_sort_key/1, fn -> nil end)
    |> challenge_pair()
  end

  defp accepted_window_challenge(
         %AccountQuotaWindow{} = window,
         %DateTime{} = consumed_at,
         snapshot_at
       ) do
    with true <- bounded_account_window?(window),
         true <- CycleConfirmation.selector_valid?(window, snapshot_at),
         {:ok, marker} <- CycleConfirmation.valid_marker(window),
         %DateTime{} = confirmed_at <- nonfuture_datetime(marker["confirmed_at"], snapshot_at),
         true <- DateTime.compare(confirmed_at, consumed_at) != :lt do
      [{WindowSelector.logical_key(window), confirmed_at}]
    else
      _invalid -> []
    end
  end

  defp accepted_window_challenge(_window, _consumed_at, _snapshot_at), do: []

  defp fallback_challenge(effective_windows, snapshot_at) do
    effective_windows
    |> Enum.filter(&weekly_account_window?/1)
    |> Enum.max_by(&window_sort_key/1, fn -> nil end)
    |> case do
      %AccountQuotaWindow{} = window ->
        {WindowSelector.logical_key(window), nonfuture_observed_at(window, snapshot_at)}

      nil ->
        nil
    end
  end

  defp challenged_evidence_state(_challenged_key, %DateTime{}, _effective_windows, _snapshot_at),
    do: :candidate_progressing

  defp challenged_evidence_state(nil, nil, _effective_windows, _snapshot_at), do: :absent

  defp challenged_evidence_state(challenged_key, nil, effective_windows, snapshot_at) do
    case Enum.find(effective_windows, &(logical_key(&1) == challenged_key)) do
      %AccountQuotaWindow{} = window ->
        cond do
          not bounded_account_window?(window) -> :absent
          Windows.usable_window?(window, snapshot_at) -> :usable
          "exhausted" in Windows.routing_window_reason_codes(window, snapshot_at) -> :exhausted
          true -> :absent
        end

      nil ->
        :absent
    end
  end

  defp additional_account_blocker_state(challenged_key, effective_windows, snapshot_at) do
    effective_windows
    |> Enum.filter(&account_window?/1)
    |> Enum.reject(&(logical_key(&1) == challenged_key))
    |> Enum.flat_map(&blocker_reasons(&1, snapshot_at))
    |> Enum.map(&bounded_blocker_reason/1)
    |> Enum.min_by(&blocker_rank/1, fn -> nil end)
    |> case do
      nil -> :none
      "reset_missing" -> :reset_missing
      "expired" -> :expired
      "not_fresh" -> :not_fresh
      "exhausted" -> :exhausted
      "unknown_unusable" -> :unknown_unusable
    end
  end

  defp blocker_reasons(%AccountQuotaWindow{} = window, snapshot_at) do
    cond do
      not bounded_account_window?(window) -> ["unknown_unusable"]
      Windows.usable_window?(window, snapshot_at) -> []
      true -> Windows.routing_window_reason_codes(window, snapshot_at)
    end
  end

  defp blocker_rank(reason), do: Enum.find_index(@blocker_precedence, &(&1 == reason)) || 99

  defp bounded_blocker_reason(reason) when reason in @blocker_precedence, do: reason
  defp bounded_blocker_reason(_reason), do: "unknown_unusable"

  defp bounded_account_window?(%AccountQuotaWindow{} = window) do
    account_window?(window) and window.source in @known_sources and
      window.source_precision in @known_precisions
  end

  defp account_window?(%AccountQuotaWindow{quota_key: "account", quota_scope: "account"}),
    do: true

  defp account_window?(_window), do: false

  defp weekly_account_window?(%AccountQuotaWindow{} = window) do
    bounded_account_window?(window) and window.window_kind == "secondary" and
      window.window_minutes == 10_080
  end

  defp logical_key(%AccountQuotaWindow{} = window), do: WindowSelector.logical_key(window)
  defp logical_key(_window), do: nil

  defp timestamp_between?(%DateTime{} = timestamp, %DateTime{} = lower, %DateTime{} = upper),
    do: DateTime.compare(timestamp, lower) != :lt and DateTime.compare(timestamp, upper) != :gt

  defp timestamp_between?(_timestamp, _lower, _upper), do: false

  defp nonfuture_observed_at(
         %AccountQuotaWindow{observed_at: %DateTime{} = observed_at},
         snapshot_at
       ) do
    if DateTime.compare(observed_at, snapshot_at) == :gt, do: nil, else: observed_at
  end

  defp nonfuture_observed_at(_window, _snapshot_at), do: nil

  defp nonfuture_datetime(value, snapshot_at) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} ->
        if(DateTime.compare(datetime, snapshot_at) == :gt, do: nil, else: datetime)

      _invalid ->
        nil
    end
  end

  defp nonfuture_datetime(_value, _snapshot_at), do: nil

  defp challenge_sort_key({key, observed_at}),
    do: {DateTime.to_unix(observed_at, :microsecond), inspect(key)}

  defp challenge_pair(nil), do: {nil, nil}
  defp challenge_pair({key, observed_at}), do: {key, observed_at}

  defp preserve_challenge(nil, fallback), do: fallback || {nil, nil}
  defp preserve_challenge(challenged_key, _fallback), do: {challenged_key, nil}

  defp window_sort_key(%AccountQuotaWindow{} = window) do
    {timestamp_rank(window.observed_at), inspect(WindowSelector.logical_key(window))}
  end

  defp timestamp_rank(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)
  defp timestamp_rank(_timestamp), do: -1
end
