defmodule CodexPooler.Alerts.SavedResetFirstSeenEvaluator do
  @moduledoc """
  Builds metadata-only alert candidates for first-seen banked saved reset evidence.
  """

  alias CodexPooler.Alerts.EvaluationCandidate
  alias CodexPooler.Alerts.IncidentLifecycle
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Upstreams.SavedResets

  @rule_kind "upstream_saved_reset_banked_first_seen"
  @reason_code "saved_reset_banked_first_seen"

  @type action :: :match | :clear
  @type assignment_projection :: %{
          required(:assignment_id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t() | nil,
          required(:identity_metadata) => map() | nil
        }

  @type candidate :: %{
          required(:action) => action(),
          required(:dedupe_key) => String.t(),
          required(:rule_id) => Ecto.UUID.t(),
          required(:rule_kind) => AlertRule.rule_kind(),
          optional(:match_attrs) => IncidentLifecycle.match_attrs(),
          optional(:clear_attrs) => IncidentLifecycle.clear_attrs()
        }

  @spec candidates(AlertRule.t(), assignment_projection(), DateTime.t()) :: [candidate()]
  def candidates(%AlertRule{} = rule, assignment, %DateTime{} = timestamp) do
    snapshot = SavedResets.snapshot(assignment.identity_metadata || %{}, timestamp)
    dedupe_key = dedupe_key(assignment.upstream_identity_id)
    baseline = rule_baseline(rule, timestamp)

    alertable_expirations =
      snapshot.available_expirations
      |> Enum.map(&normalize_expiration/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&first_seen_on_or_after?(&1, baseline))

    if snapshot.available? and alertable_expirations != [] do
      [candidate(rule, assignment, snapshot, timestamp, dedupe_key, alertable_expirations)]
    else
      [EvaluationCandidate.clear(rule, dedupe_key, timestamp)]
    end
  end

  defp candidate(rule, assignment, snapshot, timestamp, dedupe_key, expirations) do
    evidence = %{
      "reason_code" => @reason_code,
      "available_count" => snapshot.available_count,
      "new_reset_count" => length(expirations),
      "earliest_reset_first_seen_at" => min_datetime_iso(expirations, :first_seen_at),
      "latest_reset_first_seen_at" => max_datetime_iso(expirations, :first_seen_at),
      "next_reset_expires_at" => min_datetime_iso(expirations, :expires_at),
      "latest_reset_expires_at" => max_datetime_iso(expirations, :expires_at),
      "source" => snapshot.source,
      "path_style" => snapshot.path_style,
      "pool_id" => rule.pool_id,
      "upstream_identity_id" => assignment.upstream_identity_id,
      "pool_upstream_assignment_id" => assignment.assignment_id
    }

    match_attrs = %{
      dedupe_key: dedupe_key,
      scope_type: rule.scope_type,
      rule_kind: rule.rule_kind,
      severity: rule.severity,
      pool_id: nil,
      upstream_identity_id: assignment.upstream_identity_id,
      safe_evidence_snapshot: evidence,
      targets: [target(rule, evidence)],
      matched_at: timestamp
    }

    %{
      action: :match,
      dedupe_key: dedupe_key,
      rule_id: rule.id,
      rule_kind: rule.rule_kind,
      match_attrs: match_attrs
    }
  end

  defp target(rule, metadata) do
    %{rule_id: rule.id, pool_id: rule.pool_id, metadata: stringify_metadata(metadata)}
  end

  defp dedupe_key(upstream_identity_id) do
    Enum.join(
      [
        "alerts",
        "v2",
        @rule_kind,
        "upstream_identity",
        upstream_identity_id || "none"
      ],
      ":"
    )
  end

  defp normalize_expiration(%{expires_at: expires_at, first_seen_at: first_seen_at}) do
    with {:ok, expires_at, expires_at_iso} <- normalize_datetime(expires_at),
         {:ok, first_seen_at, first_seen_at_iso} <- normalize_datetime(first_seen_at) do
      %{
        expires_at: expires_at,
        expires_at_iso: expires_at_iso,
        first_seen_at: first_seen_at,
        first_seen_at_iso: first_seen_at_iso
      }
    else
      {:error, :invalid_datetime} -> nil
    end
  end

  defp normalize_expiration(_expiration), do: nil

  defp normalize_datetime(%DateTime{} = value) do
    value = DateTime.shift_zone!(value, "Etc/UTC")
    {:ok, value, canonical_datetime(value)}
  end

  defp normalize_datetime(%NaiveDateTime{} = value) do
    value = DateTime.from_naive!(value, "Etc/UTC")
    {:ok, value, canonical_datetime(value)}
  end

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        normalize_datetime(datetime)

      {:error, _reason} ->
        {:error, :invalid_datetime}
    end
  end

  defp normalize_datetime(_value), do: {:error, :invalid_datetime}

  defp first_seen_on_or_after?(%{first_seen_at: first_seen_at}, %DateTime{} = baseline) do
    DateTime.compare(first_seen_at, baseline) != :lt
  end

  defp rule_baseline(%AlertRule{} = rule, fallback) do
    AlertRule.saved_reset_first_seen_baseline_at(rule) || fallback
  end

  defp canonical_datetime(%DateTime{microsecond: {0, _precision}} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp canonical_datetime(%DateTime{microsecond: {microsecond, _precision}} = datetime) do
    datetime
    |> Map.put(:microsecond, {microsecond, 6})
    |> DateTime.to_iso8601()
    |> String.replace(~r/0+Z$/, "Z")
  end

  defp min_datetime_iso(expirations, key), do: aggregate_datetime_iso(expirations, key, :lt)
  defp max_datetime_iso(expirations, key), do: aggregate_datetime_iso(expirations, key, :gt)

  defp aggregate_datetime_iso([first | rest], key, comparison) do
    Enum.reduce(rest, first, fn expiration, selected ->
      if DateTime.compare(Map.fetch!(expiration, key), Map.fetch!(selected, key)) == comparison do
        expiration
      else
        selected
      end
    end)
    |> Map.fetch!(:"#{key}_iso")
  end

  defp stringify_metadata(metadata),
    do: Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
end
