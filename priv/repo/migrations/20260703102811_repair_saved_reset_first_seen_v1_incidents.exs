defmodule CodexPooler.Repo.Migrations.RepairSavedResetFirstSeenV1Incidents do
  use Ecto.Migration

  @rule_kind "upstream_saved_reset_banked_first_seen"
  @baseline_key "saved_reset_first_seen_baseline_at"
  @repair_reason "saved_reset_first_seen_v1_predates_rule_baseline"
  @repair_source "saved_reset_first_seen_v1_migration"

  def up do
    repaired_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    repaired_at
    |> repairable_incident_repairs()
    |> Enum.each(&resolve_repair(&1, repaired_at))
  end

  def down do
    # Data repair is intentionally irreversible: later incident state may be operator-owned.
    :ok
  end

  defp repairable_incident_repairs(%DateTime{} = _repaired_at) do
    """
    SELECT
      incident.id,
      incident.safe_evidence_snapshot,
      target.id,
      target.metadata,
      rule.metadata,
      rule.created_at
    FROM alert_incidents AS incident
    JOIN alert_incident_targets AS target ON target.incident_id = incident.id
    JOIN alert_rules AS rule ON rule.id = target.rule_id
    WHERE incident.rule_kind = $1
      AND incident.state IN ('open', 'acknowledged')
      AND incident.dedupe_key LIKE $2
      AND POSITION(':reset_expires_at:' IN incident.dedupe_key) > 0
      AND target.resolved_at IS NULL
    ORDER BY incident.first_seen_at ASC, incident.id ASC
    """
    |> query!([@rule_kind, "alerts:v1:#{@rule_kind}:%"])
    |> Map.fetch!(:rows)
    |> Enum.group_by(&List.first/1)
    |> Enum.flat_map(&repair_for_incident/1)
  end

  defp repair_for_incident({incident_id, rows}) do
    targets =
      Enum.map(rows, fn [
                          _incident_id,
                          evidence,
                          target_id,
                          target_metadata,
                          rule_metadata,
                          rule_created_at
                        ] ->
        %{
          id: target_id,
          repairable?:
            repairable_target?(evidence, target_metadata, rule_metadata, rule_created_at)
        }
      end)

    stale_target_ids =
      targets
      |> Enum.filter(& &1.repairable?)
      |> Enum.map(& &1.id)

    has_unresolved_valid_target? = Enum.any?(targets, &(not &1.repairable?))

    case stale_target_ids do
      [] ->
        []

      target_ids ->
        [
          %{
            incident_id: incident_id,
            target_ids: target_ids,
            resolve_incident?: not has_unresolved_valid_target?
          }
        ]
    end
  end

  defp repairable_target?(evidence, target_metadata, rule_metadata, rule_created_at) do
    with {:ok, first_seen_at} <- reset_first_seen_at(evidence, target_metadata),
         {:ok, baseline_at} <- rule_baseline_at(rule_metadata, rule_created_at) do
      DateTime.compare(first_seen_at, baseline_at) == :lt
    else
      _skip -> false
    end
  end

  defp reset_first_seen_at(evidence, target_metadata) do
    [target_metadata || %{}, evidence || %{}]
    |> Enum.find_value(&Map.get(&1, "reset_first_seen_at"))
    |> parse_datetime()
  end

  defp rule_baseline_at(rule_metadata, rule_created_at) do
    case parse_datetime((rule_metadata || %{})[@baseline_key]) do
      {:ok, %DateTime{} = baseline_at} -> {:ok, baseline_at}
      {:error, :invalid_datetime} -> parse_datetime(rule_created_at)
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp parse_datetime(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> then(&{:ok, &1})
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_datetime}

  defp resolve_repair(%{incident_id: incident_id, target_ids: target_ids} = repair, repaired_at) do
    metadata = %{
      "repair_reason" => @repair_reason,
      "repair_source" => @repair_source,
      "repaired_at" => DateTime.to_iso8601(repaired_at),
      "repaired_dedupe_version" => "v1"
    }

    query!(
      """
      UPDATE alert_incident_targets
      SET resolved_at = $1, updated_at = $1
      WHERE id = ANY($2::uuid[])
        AND resolved_at IS NULL
      """,
      [repaired_at, target_ids]
    )

    if repair.resolve_incident? do
      query!(
        """
        UPDATE alert_incidents
        SET
          state = 'resolved',
          resolved_at = $1,
          suppression_metadata = suppression_metadata || $2::jsonb,
          updated_at = $1
        WHERE id = $3
          AND state IN ('open', 'acknowledged')
        """,
        [repaired_at, metadata, incident_id]
      )
    end
  end

  defp query!(sql, params) do
    repo().query!(sql, params, log: false)
  end
end
