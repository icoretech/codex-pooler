defmodule CodexPooler.Repo.Migrations.BackfillSavedResetFirstSeenMetadata do
  use Ecto.Migration

  def up do
    execute ~S"""
    WITH run_started AS (
      SELECT to_char(transaction_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS first_seen_at
    ),
    candidates AS (
      SELECT
        identity.id,
        identity.metadata,
        identity.metadata #> '{saved_resets,available_expires_at}' AS available_expires_at
      FROM upstream_identities AS identity
      WHERE CASE jsonb_typeof(identity.metadata #> '{saved_resets,available_expires_at}')
        WHEN 'array' THEN jsonb_array_length(identity.metadata #> '{saved_resets,available_expires_at}') > 0
        ELSE false
      END
      AND COALESCE(jsonb_typeof(identity.metadata #> '{saved_resets,available_expirations}'), 'missing') <> 'array'
    ),
    backfilled AS (
      SELECT
        candidate.id,
        COALESCE(
          (
            SELECT jsonb_agg(
              jsonb_build_object(
                'expires_at', valid_expiration.expires_at,
                'first_seen_at', run_started.first_seen_at
              )
              ORDER BY valid_expiration.expires_at
            )
            FROM (
              SELECT DISTINCT expiration.value #>> '{}' AS expires_at
              FROM jsonb_array_elements(candidate.available_expires_at) AS expiration(value)
              CROSS JOIN LATERAL regexp_matches(
                expiration.value #>> '{}',
                '^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|[+-]([0-9]{2}):([0-9]{2}))$'
              ) AS match(parts)
              CROSS JOIN LATERAL (
                SELECT
                  match.parts[1]::integer AS year,
                  match.parts[2]::integer AS month,
                  match.parts[3]::integer AS day,
                  match.parts[4]::integer AS hour,
                  match.parts[5]::integer AS minute,
                  match.parts[6]::integer AS second,
                  COALESCE(match.parts[9]::integer, 0) AS offset_hour,
                  COALESCE(match.parts[10]::integer, 0) AS offset_minute
              ) AS parsed
              WHERE jsonb_typeof(expiration.value) = 'string'
              AND parsed.year BETWEEN 1 AND 9999
              AND parsed.month BETWEEN 1 AND 12
              AND parsed.day BETWEEN 1 AND CASE
                WHEN parsed.month IN (1, 3, 5, 7, 8, 10, 12) THEN 31
                WHEN parsed.month IN (4, 6, 9, 11) THEN 30
                WHEN parsed.month = 2
                  AND (
                    parsed.year % 400 = 0
                    OR (parsed.year % 4 = 0 AND parsed.year % 100 <> 0)
                  ) THEN 29
                WHEN parsed.month = 2 THEN 28
                ELSE 0
              END
              AND parsed.hour BETWEEN 0 AND 23
              AND parsed.minute BETWEEN 0 AND 59
              AND parsed.second BETWEEN 0 AND 59
              AND parsed.offset_hour BETWEEN 0 AND 23
              AND parsed.offset_minute BETWEEN 0 AND 59
            ) AS valid_expiration
          ),
          '[]'::jsonb
        ) AS available_expirations
      FROM candidates AS candidate
      CROSS JOIN run_started
    )
    UPDATE upstream_identities AS identity
    SET metadata = jsonb_set(
      identity.metadata,
      '{saved_resets,available_expirations}',
      backfilled.available_expirations,
      true
    )
    FROM backfilled
    WHERE identity.id = backfilled.id
    """
  end

  def down do
    execute ~S"""
    UPDATE upstream_identities AS identity
    SET metadata = jsonb_set(
      identity.metadata,
      '{saved_resets}',
      (identity.metadata -> 'saved_resets') - 'available_expirations',
      false
    )
    WHERE jsonb_typeof(identity.metadata -> 'saved_resets') = 'object'
      AND (identity.metadata -> 'saved_resets') ? 'available_expirations'
    """
  end
end
