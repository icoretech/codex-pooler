defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetConfirmationProjection do
  @moduledoc false

  alias CodexPooler.Quotas.WindowClassifier

  alias CodexPooler.Upstreams.Quota.{AccountQuotaWindow, Windows, WindowSelector}
  alias CodexPooler.Upstreams.Quota.Windows.{CycleConfirmation, EvidenceStore}

  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle

  @known_sources ~w(
    codex_usage_api
    codex_rate_limit_event
    codex_response_headers
    codex_rate_limit_error
  )
  @known_precisions ~w(authoritative observed inferred)

  @type confirmation_state ::
          :awaiting_confirmation | :confirmed | :not_applied | :confirmation_expired
  @type challenged_evidence_state :: :absent | :exhausted | :candidate_progressing | :usable
  @type t :: %{
          required(:confirmation_state) => confirmation_state(),
          required(:challenged_evidence_state) => challenged_evidence_state()
        }

  @spec project(map(), [AccountQuotaWindow.t()], [AccountQuotaWindow.t()], DateTime.t()) ::
          t() | nil
  def project(redemption, raw_windows, effective_windows, %DateTime{} = snapshot_at)
      when is_map(redemption) and is_list(raw_windows) and is_list(effective_windows) do
    case confirmation_state(redemption["phase"]) do
      {:ok, confirmation_state} ->
        project_confirmation(
          confirmation_state,
          redemption,
          raw_windows,
          effective_windows,
          snapshot_at
        )

      :none ->
        nil
    end
  end

  def project(_redemption, _raw_windows, _effective_windows, _snapshot_at), do: nil

  defp project_confirmation(
         confirmation_state,
         redemption,
         raw_windows,
         effective_windows,
         snapshot_at
       ) do
    consumed_at = nonfuture_datetime(redemption["consumed_at"], snapshot_at)

    effective_windows = recovery_windows(effective_windows, redemption, snapshot_at)

    {candidate_key, candidate_observed_at} =
      challenged_candidate(recovery_windows(raw_windows, redemption, snapshot_at), consumed_at, snapshot_at)

    # A post-consume candidate names the challenged window first, then an accepted confirmation, then the
    # newest reset-bearing account window.
    challenged_key =
      candidate_key || challenge_key(accepted_challenge(effective_windows, consumed_at, snapshot_at)) ||
        challenge_key(fallback_challenge(effective_windows, consumed_at, snapshot_at))

    %{
      confirmation_state: confirmation_state,
      challenged_evidence_state:
        challenged_evidence_state(
          challenged_key,
          candidate_observed_at,
          effective_windows,
          snapshot_at
        )
    }
  end

  defp confirmation_state(phase)
       when phase in ["consuming", "consumed_pending_probe", "reblocked"],
       do: {:ok, :awaiting_confirmation}

  defp confirmation_state(phase) when phase in ["confirmed_by_upstream", "confirmed_by_quota"],
    do: {:ok, :confirmed}

  defp confirmation_state("consume_not_applied"), do: {:ok, :not_applied}
  defp confirmation_state("expired"), do: {:ok, :confirmation_expired}
  defp confirmation_state(_phase), do: :none

  @doc false
  @spec recovery_windows([AccountQuotaWindow.t()], map(), DateTime.t()) :: [AccountQuotaWindow.t()]
  def recovery_windows(windows, %{"included_window_descriptors" => descriptors, "phase" => phase} = redemption, as_of)
      when phase in ["consumed_pending_probe", "reblocked", "confirmed_by_upstream", "confirmed_by_quota"] and is_list(descriptors) and length(descriptors) in 1..2 do
    with %DateTime{} = consumed <- nonfuture_datetime(redemption["consumed_at"], as_of),
         :lt <- DateTime.compare(as_of, RedemptionLifecycle.deadline_at(consumed)),
         false <- RedemptionLifecycle.expired?(redemption, as_of) do
      Enum.filter(windows, fn window ->
        WindowClassifier.saved_reset_window?(window) and
          %{"window_kind" => window.window_kind, "window_minutes" => window.window_minutes} in descriptors and
          matching_epoch?(redemption, window)
      end)
    else
      _outside_interval -> []
    end
  end

  def recovery_windows(_windows, _redemption, _as_of), do: []

  defp matching_epoch?(%{"credential_epoch" => epoch}, %{metadata: metadata}), do: is_integer(epoch) and is_map(metadata) and metadata["credential_epoch"] == epoch
  defp matching_epoch?(_legacy_receipt, _window), do: true

  defp challenged_candidate(raw_windows, consumed_at, snapshot_at) do
    raw_windows
    |> Enum.flat_map(&candidate_challenge(&1, consumed_at, snapshot_at))
    |> Enum.max_by(&challenge_sort_key/1, fn -> nil end)
    |> challenge_pair()
  end

  @spec candidate_observed_at(AccountQuotaWindow.t(), DateTime.t() | nil, DateTime.t()) :: DateTime.t() | nil
  def candidate_observed_at(%AccountQuotaWindow{} = window, consumed_at, %DateTime{} = snapshot_at) do
    metadata = window.metadata || %{}

    with true <- reset_account_window?(window),
         true <- is_map(metadata),
         %DateTime{} <- nonfuture_observed_at(window, snapshot_at),
         {:ok, candidate} <- EvidenceStore.parse_candidate(metadata),
         true <- EvidenceStore.candidate_valid?(candidate, snapshot_at),
         true <- EvidenceStore.candidate_provider_status_safe?(metadata),
         true <- timestamp_between?(candidate.observed_at, consumed_at, snapshot_at) do
      candidate.observed_at
    else
      _invalid -> nil
    end
  end

  def candidate_observed_at(_window, _consumed_at, _snapshot_at), do: nil

  defp candidate_challenge(window, consumed_at, snapshot_at) do
    case candidate_observed_at(window, consumed_at, snapshot_at) do
      %DateTime{} = observed_at -> [{WindowSelector.logical_key(window), observed_at}]
      nil -> []
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

  defp fallback_challenge(effective_windows, consumed_at, snapshot_at) do
    effective_windows
    |> Enum.filter(&(reset_account_window?(&1) and timestamp_between?(&1.observed_at, consumed_at, snapshot_at)))
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

  defp bounded_account_window?(%AccountQuotaWindow{} = window) do
    account_window?(window) and window.source in @known_sources and
      window.source_precision in @known_precisions
  end

  defp account_window?(%AccountQuotaWindow{quota_key: "account", quota_scope: "account"}),
    do: true

  defp account_window?(_window), do: false

  defp reset_account_window?(%AccountQuotaWindow{} = window) do
    bounded_account_window?(window) and WindowClassifier.saved_reset_window?(window)
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

  defp challenge_key({key, _observed_at}), do: key
  defp challenge_key(nil), do: nil

  defp window_sort_key(%AccountQuotaWindow{} = window) do
    {timestamp_rank(window.observed_at), inspect(WindowSelector.logical_key(window))}
  end

  defp timestamp_rank(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)
  defp timestamp_rank(_timestamp), do: -1
end
