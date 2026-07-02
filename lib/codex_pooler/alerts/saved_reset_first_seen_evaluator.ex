defmodule CodexPooler.Alerts.SavedResetFirstSeenEvaluator do
  @moduledoc """
  Builds metadata-only alert candidates for first-seen banked saved reset evidence.
  """

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

    if snapshot.available? do
      snapshot.available_expirations
      |> Enum.map(&normalize_expiration/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&candidate(rule, assignment, snapshot, timestamp, &1))
    else
      []
    end
  end

  defp candidate(rule, assignment, snapshot, timestamp, expiration) do
    evidence = %{
      "reason_code" => @reason_code,
      "reset_expires_at" => expiration.expires_at,
      "reset_first_seen_at" => expiration.first_seen_at,
      "available_count" => snapshot.available_count,
      "source" => snapshot.source,
      "path_style" => snapshot.path_style,
      "pool_id" => rule.pool_id,
      "upstream_identity_id" => assignment.upstream_identity_id,
      "pool_upstream_assignment_id" => assignment.assignment_id
    }

    match_attrs = %{
      dedupe_key: dedupe_key(assignment.upstream_identity_id, expiration),
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
      dedupe_key: match_attrs.dedupe_key,
      rule_id: rule.id,
      rule_kind: rule.rule_kind,
      match_attrs: match_attrs
    }
  end

  defp target(rule, metadata) do
    %{rule_id: rule.id, pool_id: rule.pool_id, metadata: stringify_metadata(metadata)}
  end

  defp dedupe_key(upstream_identity_id, expiration) do
    Enum.join(
      [
        "alerts",
        "v1",
        @rule_kind,
        "upstream_identity",
        upstream_identity_id || "none",
        "reset_expires_at",
        expiration.expires_at
      ],
      ":"
    )
  end

  defp normalize_expiration(%{expires_at: expires_at, first_seen_at: first_seen_at}) do
    with {:ok, normalized_expires_at} <- normalize_datetime(expires_at),
         {:ok, normalized_first_seen_at} <- normalize_datetime(first_seen_at) do
      %{expires_at: normalized_expires_at, first_seen_at: normalized_first_seen_at}
    else
      {:error, :invalid_datetime} -> nil
    end
  end

  defp normalize_expiration(_expiration), do: nil

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, canonical_datetime(datetime)}

      {:error, _reason} ->
        {:error, :invalid_datetime}
    end
  end

  defp normalize_datetime(_value), do: {:error, :invalid_datetime}

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

  defp stringify_metadata(metadata),
    do: Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
end
