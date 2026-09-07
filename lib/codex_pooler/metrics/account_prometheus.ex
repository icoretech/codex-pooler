defmodule CodexPooler.Metrics.AccountPrometheus do
  @moduledoc "Pure Prometheus 0.0.4 formatter for fixed account gauge families."

  alias CodexPooler.Metrics.AccountValues, as: V
  alias CodexPooler.Quotas.Evidence

  @families [
    account_metrics_collection_success:
      "One only when the snapshot and every account projection completed.",
    account_metrics_collection_duration_seconds: "Elapsed account collection time in seconds.",
    account_metrics_snapshot_timestamp_seconds:
      "Snapshot evaluation time; not provider freshness.",
    account_metrics_accounts: "Non-deleted enrolled identities in the snapshot.",
    account_metrics_memberships: "Distinct non-deleted account and pool memberships.",
    account_metrics_quota_groups: "Emitted canonical quota groups.",
    account_metrics_observations: "Emitted retained quota observations.",
    account_metrics_evidence_ttl_seconds: "Configured quota evidence freshness TTL in seconds.",
    account_info: "Non-deleted enrolled account inventory.",
    account_state: "Current persisted identity lifecycle state.",
    account_disabled: "Explicit disabled status or disabled timestamp; not availability.",
    account_reauth_required: "Explicit persisted reauthentication requirement.",
    account_projection_complete: "One when this account projection is complete.",
    account_projection_overflow: "One for a measured account cardinality bound violation.",
    account_has_quota_observation: "Presence of time-visible retained quota evidence.",
    account_last_quota_observation_timestamp_seconds:
      "Latest valid non-future quota observation time.",
    account_provider_availability_state: "Current-epoch provider-reported account availability.",
    account_provider_availability_observed_timestamp_seconds:
      "Valid current-epoch provider availability observation time.",
    account_quota_readiness: "Quota readiness; not assignment or model eligibility.",
    account_pool_membership: "Current non-deleted account and pool membership.",
    account_pool_state: "Persisted membership status, health and eligibility.",
    account_pool_reconciliation_state: "Latest valid non-future terminal reconciliation state.",
    account_pool_reconciliation_timestamp_seconds:
      "Latest valid terminal reconciliation finished time.",
    account_pool_last_successful_reconciliation_timestamp_seconds:
      "Last successful whole reconciliation, not quota-only polling.",
    account_quota_info: "Canonical retained quota meter group.",
    account_quota_window_duration_seconds: "Reported positive quota window duration in seconds.",
    account_quota_routing_selection_present:
      "Presence of the routing selector observation in this group.",
    account_quota_observation_info: "Retained time-visible source quota observation.",
    account_quota_observation_used_percent:
      "Valid reported used percentage; missing values are omitted.",
    account_quota_observation_remaining_percent:
      "100 minus valid reported used percentage; not verified capacity.",
    account_quota_observation_reset_timestamp_seconds:
      "Original reported reset time, including elapsed resets.",
    account_quota_observation_timestamp_seconds:
      "Original valid non-future provider observation time.",
    account_quota_observation_freshness:
      "Evidence freshness; missing observation time is unknown.",
    account_quota_observation_elapsed:
      "One when a known reset has elapsed; zero does not establish capacity.",
    account_quota_observation_used_known: "One only for a valid reported used percentage.",
    account_quota_observation_routing_selected: "One for the exact routing selector observation."
  ]

  def families, do: @families

  def render(result, duration) do
    result
    |> samples(duration)
    |> format()
  end

  defp samples({:ok, projection}, duration) do
    [
      {:account_metrics_collection_success, [], V.flag(projection.complete)},
      {:account_metrics_collection_duration_seconds, [], duration},
      {:account_metrics_snapshot_timestamp_seconds, [], V.seconds(projection.as_of)},
      {:account_metrics_accounts, [], projection.accounts},
      {:account_metrics_memberships, [], projection.memberships},
      {:account_metrics_quota_groups, [], projection.groups},
      {:account_metrics_observations, [], projection.observations},
      {:account_metrics_evidence_ttl_seconds, [], Evidence.freshness_ttl_seconds()}
      | projection.samples
    ]
  end

  defp samples({:error, _reason}, duration) do
    [
      {:account_metrics_collection_success, [], 0},
      {:account_metrics_collection_duration_seconds, [], duration},
      {:account_metrics_evidence_ttl_seconds, [], Evidence.freshness_ttl_seconds()}
    ]
  end

  defp format(samples) do
    samples = Enum.reject(samples, fn {_name, _labels, value} -> is_nil(value) end)
    keys = Enum.map(samples, fn {name, labels, _value} -> {name, Enum.sort(labels)} end)

    if length(keys) != MapSet.size(MapSet.new(keys)),
      do: raise("duplicate account metric identity")

    grouped = Enum.group_by(samples, &elem(&1, 0))

    @families
    |> Enum.map(fn {name, help} ->
      metric = "codex_pooler_#{name}"

      [
        "# HELP ",
        metric,
        " ",
        help,
        "\n# TYPE ",
        metric,
        " gauge\n",
        grouped
        |> Map.get(name, [])
        |> Enum.sort()
        |> Enum.map(fn {_name, labels, value} ->
          [metric, labels(labels), " ", number(value), "\n"]
        end)
      ]
    end)
    |> IO.iodata_to_binary()
  end

  defp labels([]), do: ""

  defp labels(labels) do
    [
      "{",
      Enum.map_intersperse(labels, ",", fn {key, value} ->
        [Atom.to_string(key), "=\"", escape(value), "\""]
      end),
      "}"
    ]
  end

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp number(%Decimal{coef: coefficient} = value) when is_integer(coefficient),
    do: Decimal.to_string(value, :normal)

  defp number(value) when is_integer(value), do: Integer.to_string(value)
  defp number(value) when is_float(value), do: Float.to_string(value)
end
