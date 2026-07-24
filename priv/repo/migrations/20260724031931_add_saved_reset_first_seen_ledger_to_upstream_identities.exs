defmodule CodexPooler.Repo.Migrations.AddSavedResetFirstSeenLedgerToUpstreamIdentities do
  use Ecto.Migration

  def up do
    alter table(:upstream_identities) do
      add :saved_reset_first_seen_ledger, :map,
        null: false,
        default: %{"version" => 1, "entries" => []}
    end

    execute("""
    WITH raw_entries AS (
      SELECT
        identity.id,
        entry.value AS entry
      FROM upstream_identities AS identity
      CROSS JOIN LATERAL jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(
            identity.metadata -> 'saved_resets' -> 'available_expirations'
          ) = 'array'
          AND pg_column_size(
            identity.metadata -> 'saved_resets' -> 'available_expirations'
          ) <= 1048576
          THEN identity.metadata -> 'saved_resets' -> 'available_expirations'
          ELSE '[]'::jsonb
        END
      ) AS entry(value)
    ),
    valid_entries AS (
      SELECT
        id,
        (entry ->> 'expires_at')::timestamptz AS expires_at,
        (entry ->> 'first_seen_at')::timestamptz AS first_seen_at
      FROM raw_entries
      WHERE jsonb_typeof(entry) = 'object'
        AND jsonb_typeof(entry -> 'expires_at') = 'string'
        AND jsonb_typeof(entry -> 'first_seen_at') = 'string'
        AND entry ->> 'expires_at' ~
          '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
        AND entry ->> 'first_seen_at' ~
          '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
        AND pg_input_is_valid(entry ->> 'expires_at', 'timestamp with time zone')
        AND pg_input_is_valid(entry ->> 'first_seen_at', 'timestamp with time zone')
    ),
    earliest_entries AS (
      SELECT
        id,
        expires_at,
        min(first_seen_at) AS first_seen_at
      FROM valid_entries
      GROUP BY id, expires_at
    ),
    seeded_ledgers AS (
      SELECT
        id,
        jsonb_build_object(
          'version',
          1,
          'entries',
          jsonb_agg(
            jsonb_build_object(
              'expires_at',
              to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS') ||
                CASE
                  WHEN extract(microseconds FROM expires_at)::bigint % 1000000 = 0
                  THEN 'Z'
                  ELSE '.' ||
                    to_char(expires_at AT TIME ZONE 'UTC', 'US') ||
                    'Z'
                END,
              'first_seen_at',
              to_char(first_seen_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS') ||
                CASE
                  WHEN extract(microseconds FROM first_seen_at)::bigint % 1000000 = 0
                  THEN 'Z'
                  ELSE '.' ||
                    to_char(first_seen_at AT TIME ZONE 'UTC', 'US') ||
                    'Z'
                END
            )
            ORDER BY expires_at
          )
        ) AS ledger
      FROM earliest_entries
      GROUP BY id
    )
    UPDATE upstream_identities AS identity
    SET saved_reset_first_seen_ledger = seeded_ledgers.ledger
    FROM seeded_ledgers
    WHERE identity.id = seeded_ledgers.id
    """)
  end

  def down do
    alter table(:upstream_identities) do
      remove :saved_reset_first_seen_ledger
    end
  end
end
