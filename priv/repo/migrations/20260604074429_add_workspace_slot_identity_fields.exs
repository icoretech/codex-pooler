defmodule CodexPooler.Repo.Migrations.AddWorkspaceSlotIdentityFields do
  use Ecto.Migration

  def up do
    alter table(:upstream_identities) do
      add :workspace_id, :text
      add :workspace_label, :text
      add :seat_type, :text
    end

    execute("""
    UPDATE public.upstream_identities
    SET workspace_id = NULLIF(BTRIM(workspace_id), ''),
        workspace_label = NULLIF(BTRIM(workspace_label), ''),
        seat_type = NULLIF(BTRIM(seat_type), '')
    """)

    execute("""
    CREATE TEMP TABLE identity_merge_map ON COMMIT DROP AS
    WITH duplicate_groups AS (
      SELECT chatgpt_account_id, workspace_id
      FROM public.upstream_identities
      WHERE chatgpt_account_id IS NOT NULL
      GROUP BY chatgpt_account_id, workspace_id
      HAVING COUNT(*) > 1
    ), locked_groups AS (
      SELECT pg_advisory_xact_lock(hashtextextended(chatgpt_account_id, 0)),
             chatgpt_account_id,
             workspace_id
      FROM duplicate_groups
    ), candidate_rows AS (
      SELECT identity.*,
             EXISTS (
               SELECT 1
               FROM public.encrypted_secrets secret
               WHERE secret.upstream_identity_id = identity.id
             ) AS has_secret_material
      FROM public.upstream_identities identity
      JOIN locked_groups group_key
        ON identity.chatgpt_account_id = group_key.chatgpt_account_id
       AND identity.workspace_id IS NOT DISTINCT FROM group_key.workspace_id
      FOR UPDATE OF identity
    ), ranked AS (
      SELECT id AS duplicate_id,
             FIRST_VALUE(id) OVER (
               PARTITION BY chatgpt_account_id, workspace_id
               ORDER BY
                 CASE WHEN has_secret_material THEN 0 ELSE 1 END,
                 created_at ASC,
                 auth_verified_at DESC NULLS LAST,
                 id ASC
             ) AS canonical_id
      FROM candidate_rows
    )
    SELECT duplicate_id, canonical_id
    FROM ranked
    WHERE duplicate_id <> canonical_id
    """)

    execute("""
    CREATE TEMP TABLE affected_identity_map ON COMMIT DROP AS
    SELECT duplicate_id AS identity_id, canonical_id AS target_identity_id
    FROM identity_merge_map
    UNION
    SELECT canonical_id AS identity_id, canonical_id AS target_identity_id
    FROM identity_merge_map
    """)

    execute("""
    SELECT assignment.id
    FROM public.pool_upstream_assignments assignment
    JOIN affected_identity_map affected ON affected.identity_id = assignment.upstream_identity_id
    FOR UPDATE OF assignment
    """)

    execute("""
    CREATE TEMP TABLE assignment_merge_map ON COMMIT DROP AS
    WITH affected_assignments AS (
      SELECT assignment.id,
             assignment.pool_id,
             assignment.upstream_identity_id,
             affected.target_identity_id,
             FIRST_VALUE(assignment.id) OVER (
               PARTITION BY assignment.pool_id, affected.target_identity_id
               ORDER BY
                 CASE WHEN assignment.upstream_identity_id = affected.target_identity_id THEN 0 ELSE 1 END,
                 CASE assignment.status
                   WHEN 'active' THEN 0
                   WHEN 'pending' THEN 1
                   WHEN 'refresh_due' THEN 2
                   WHEN 'refreshing' THEN 3
                   WHEN 'paused' THEN 4
                   WHEN 'refresh_failed' THEN 5
                   WHEN 'reauth_required' THEN 6
                   WHEN 'disabled' THEN 7
                   WHEN 'errored' THEN 8
                   WHEN 'deleted' THEN 9
                   ELSE 10
                 END,
                 assignment.created_at ASC,
                 assignment.id ASC
             ) AS canonical_assignment_id
      FROM public.pool_upstream_assignments assignment
      JOIN affected_identity_map affected ON affected.identity_id = assignment.upstream_identity_id
    )
    SELECT id AS duplicate_assignment_id,
           canonical_assignment_id,
           target_identity_id
    FROM affected_assignments
    WHERE id <> canonical_assignment_id
    """)

    execute("""
    CREATE TEMP TABLE assignment_keep_map ON COMMIT DROP AS
    WITH affected_assignments AS (
      SELECT assignment.id,
             affected.target_identity_id,
             FIRST_VALUE(assignment.id) OVER (
               PARTITION BY assignment.pool_id, affected.target_identity_id
               ORDER BY
                 CASE WHEN assignment.upstream_identity_id = affected.target_identity_id THEN 0 ELSE 1 END,
                 CASE assignment.status
                   WHEN 'active' THEN 0
                   WHEN 'pending' THEN 1
                   WHEN 'refresh_due' THEN 2
                   WHEN 'refreshing' THEN 3
                   WHEN 'paused' THEN 4
                   WHEN 'refresh_failed' THEN 5
                   WHEN 'reauth_required' THEN 6
                   WHEN 'disabled' THEN 7
                   WHEN 'errored' THEN 8
                   WHEN 'deleted' THEN 9
                   ELSE 10
                 END,
                 assignment.created_at ASC,
                 assignment.id ASC
             ) AS canonical_assignment_id
      FROM public.pool_upstream_assignments assignment
      JOIN affected_identity_map affected ON affected.identity_id = assignment.upstream_identity_id
    )
    SELECT id AS assignment_id, target_identity_id
    FROM affected_assignments
    WHERE id = canonical_assignment_id
    """)

    merge_assignment_rollups()
    resolve_assignment_unique_conflicts()
    move_assignment_dependents()
    move_identity_dependents()

    execute("""
    UPDATE public.pool_upstream_assignments assignment
    SET upstream_identity_id = keep_map.target_identity_id,
        updated_at = now()
    FROM assignment_keep_map keep_map
    WHERE assignment.id = keep_map.assignment_id
      AND assignment.upstream_identity_id <> keep_map.target_identity_id
    """)

    execute("""
    DELETE FROM public.pool_upstream_assignments assignment
    USING assignment_merge_map merge_map
    WHERE assignment.id = merge_map.duplicate_assignment_id
    """)

    execute("""
    DELETE FROM public.upstream_identities identity
    USING identity_merge_map merge_map
    WHERE identity.id = merge_map.duplicate_id
      AND NOT EXISTS (
        SELECT 1 FROM public.pool_upstream_assignments assignment
        WHERE assignment.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.encrypted_secrets secret
        WHERE secret.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.account_quota_windows quota
        WHERE quota.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.attempts attempt
        WHERE attempt.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.ledger_entries ledger
        WHERE ledger.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.daily_rollups rollup
        WHERE rollup.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.bridge_affinities affinity
        WHERE affinity.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.bridge_demotions demotion
        WHERE demotion.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.routing_circuit_states circuit
        WHERE circuit.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.invite_acceptances acceptance
        WHERE acceptance.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.codex_files file_record
        WHERE file_record.upstream_identity_id = identity.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.alert_incidents incident
        WHERE incident.upstream_identity_id = identity.id
      )
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM public.upstream_identities identity JOIN identity_merge_map merge_map ON merge_map.duplicate_id = identity.id) THEN
        RAISE EXCEPTION 'workspace slot identity reconciliation left referenced duplicate identities';
      END IF;
    END $$
    """)

    execute("DROP INDEX IF EXISTS public.upstream_identities_chatgpt_identity_uq")

    create unique_index(:upstream_identities, [:chatgpt_account_id],
             name: :upstream_identities_chatgpt_legacy_workspace_uq,
             where: "chatgpt_account_id IS NOT NULL AND workspace_id IS NULL"
           )

    create unique_index(:upstream_identities, [:chatgpt_account_id, :workspace_id],
             name: :upstream_identities_chatgpt_workspace_slot_uq,
             where: "chatgpt_account_id IS NOT NULL AND workspace_id IS NOT NULL"
           )
  end

  def down do
    raise Ecto.MigrationError,
          "workspace slot identity fields cannot be safely removed without losing slot data"
  end

  defp merge_assignment_rollups do
    execute("""
    INSERT INTO public.daily_rollups (
      id,
      rollup_date,
      dimension_kind,
      pool_id,
      api_key_id,
      pool_upstream_assignment_id,
      upstream_identity_id,
      model_id,
      request_count,
      success_count,
      failure_count,
      retry_count,
      input_tokens,
      cached_input_tokens,
      output_tokens,
      reasoning_tokens,
      total_tokens,
      estimated_cost_micros,
      settled_cost_micros,
      created_at,
      updated_at
    )
    SELECT gen_random_uuid(),
           rollup.rollup_date,
           'pool_upstream_assignment',
           rollup.pool_id,
           NULL,
           merge_map.canonical_assignment_id,
           NULL,
           NULL,
           SUM(rollup.request_count),
           SUM(rollup.success_count),
           SUM(rollup.failure_count),
           SUM(rollup.retry_count),
           SUM(rollup.input_tokens),
           SUM(rollup.cached_input_tokens),
           SUM(rollup.output_tokens),
           SUM(rollup.reasoning_tokens),
           SUM(rollup.total_tokens),
           SUM(rollup.estimated_cost_micros),
           SUM(rollup.settled_cost_micros),
           MIN(rollup.created_at),
           now()
    FROM public.daily_rollups rollup
      JOIN assignment_merge_map merge_map
        ON merge_map.duplicate_assignment_id = rollup.pool_upstream_assignment_id
      WHERE rollup.dimension_kind = 'pool_upstream_assignment'
      GROUP BY rollup.rollup_date, rollup.pool_id, merge_map.canonical_assignment_id
    ON CONFLICT (rollup_date, pool_upstream_assignment_id)
    WHERE dimension_kind = 'pool_upstream_assignment'
    DO UPDATE SET
      request_count = daily_rollups.request_count + EXCLUDED.request_count,
      success_count = daily_rollups.success_count + EXCLUDED.success_count,
      failure_count = daily_rollups.failure_count + EXCLUDED.failure_count,
      retry_count = daily_rollups.retry_count + EXCLUDED.retry_count,
      input_tokens = daily_rollups.input_tokens + EXCLUDED.input_tokens,
      cached_input_tokens = daily_rollups.cached_input_tokens + EXCLUDED.cached_input_tokens,
      output_tokens = daily_rollups.output_tokens + EXCLUDED.output_tokens,
      reasoning_tokens = daily_rollups.reasoning_tokens + EXCLUDED.reasoning_tokens,
      total_tokens = daily_rollups.total_tokens + EXCLUDED.total_tokens,
      estimated_cost_micros = daily_rollups.estimated_cost_micros + EXCLUDED.estimated_cost_micros,
      settled_cost_micros = daily_rollups.settled_cost_micros + EXCLUDED.settled_cost_micros,
      updated_at = now()
    """)

    execute("""
    DELETE FROM public.daily_rollups rollup
    USING assignment_merge_map merge_map
    WHERE rollup.pool_upstream_assignment_id = merge_map.duplicate_assignment_id
      AND rollup.dimension_kind = 'pool_upstream_assignment'
    """)
  end

  defp resolve_assignment_unique_conflicts do
    execute("""
    UPDATE public.bridge_demotions demotion
    SET status = 'resolved',
        updated_at = now()
    FROM assignment_merge_map merge_map
    WHERE demotion.pool_upstream_assignment_id = merge_map.duplicate_assignment_id
      AND demotion.status = 'active'
      AND EXISTS (
        SELECT 1
        FROM public.bridge_demotions existing
        WHERE existing.pool_id = demotion.pool_id
          AND existing.api_key_id = demotion.api_key_id
          AND existing.model_identifier = demotion.model_identifier
          AND existing.pool_upstream_assignment_id = merge_map.canonical_assignment_id
          AND existing.status = 'active'
      )
    """)

    execute("""
    UPDATE public.routing_circuit_states circuit
    SET status = 'closed',
        updated_at = now()
    FROM assignment_merge_map merge_map
    WHERE circuit.pool_upstream_assignment_id = merge_map.duplicate_assignment_id
      AND circuit.status IN ('open', 'half_open')
      AND EXISTS (
        SELECT 1
        FROM public.routing_circuit_states existing
        WHERE existing.pool_id = circuit.pool_id
          AND existing.pool_upstream_assignment_id = merge_map.canonical_assignment_id
          AND existing.model_identifier = circuit.model_identifier
          AND existing.route_class = circuit.route_class
          AND existing.status IN ('open', 'half_open')
      )
    """)
  end

  defp move_assignment_dependents do
    Enum.each(
      ~w(attempts bridge_affinities bridge_demotions bridge_owner_leases codex_sessions codex_files invite_acceptances ledger_entries routing_circuit_states),
      fn table ->
        execute("""
        UPDATE public.#{table} dependent
        SET pool_upstream_assignment_id = merge_map.canonical_assignment_id
        FROM assignment_merge_map merge_map
        WHERE dependent.pool_upstream_assignment_id = merge_map.duplicate_assignment_id
        """)
      end
    )
  end

  defp move_identity_dependents do
    move_encrypted_secrets()
    move_quota_windows()
    merge_identity_rollups()

    Enum.each(
      ~w(attempts ledger_entries bridge_affinities bridge_demotions routing_circuit_states invite_acceptances codex_files alert_incidents),
      fn table ->
        execute("""
        UPDATE public.#{table} dependent
        SET upstream_identity_id = merge_map.canonical_id
        FROM identity_merge_map merge_map
        WHERE dependent.upstream_identity_id = merge_map.duplicate_id
        """)
      end
    )
  end

  defp move_encrypted_secrets do
    execute("""
    WITH ranked_active AS (
      SELECT secret.id,
             ROW_NUMBER() OVER (
               PARTITION BY merge_map.canonical_id, secret.secret_kind
               ORDER BY
                 CASE WHEN secret.upstream_identity_id = merge_map.canonical_id THEN 0 ELSE 1 END,
                 secret.created_at DESC,
                 secret.id ASC
             ) AS row_number
      FROM public.encrypted_secrets secret
      JOIN (
        SELECT duplicate_id AS identity_id, canonical_id FROM identity_merge_map
        UNION
        SELECT canonical_id AS identity_id, canonical_id FROM identity_merge_map
      ) merge_map ON merge_map.identity_id = secret.upstream_identity_id
      WHERE secret.status = 'active'
    )
    UPDATE public.encrypted_secrets secret
    SET status = 'superseded',
        superseded_at = COALESCE(secret.superseded_at, now())
    FROM ranked_active ranked
    WHERE secret.id = ranked.id
      AND ranked.row_number > 1
    """)

    execute("""
    UPDATE public.encrypted_secrets secret
    SET upstream_identity_id = merge_map.canonical_id
    FROM identity_merge_map merge_map
    WHERE secret.upstream_identity_id = merge_map.duplicate_id
    """)
  end

  defp move_quota_windows do
    execute("""
    WITH affected_windows AS (
      SELECT quota_window.id,
             COALESCE(merge_map.canonical_id, quota_window.upstream_identity_id) AS target_identity_id,
             ROW_NUMBER() OVER (
               PARTITION BY
                 COALESCE(merge_map.canonical_id, quota_window.upstream_identity_id),
                 quota_window.quota_scope,
                 quota_window.quota_family,
                 COALESCE(lower(quota_window.model), ''),
                 COALESCE(lower(quota_window.upstream_model), ''),
                 quota_window.quota_key,
                 quota_window.window_kind,
                 quota_window.window_minutes,
                 quota_window.source,
                 COALESCE(quota_window.raw_limit_id, ''),
                 COALESCE(quota_window.raw_limit_name, ''),
                 COALESCE(quota_window.raw_metered_feature, '')
               ORDER BY
                 CASE WHEN quota_window.upstream_identity_id = COALESCE(merge_map.canonical_id, quota_window.upstream_identity_id) THEN 0 ELSE 1 END,
                 CASE quota_window.freshness_state WHEN 'fresh' THEN 0 WHEN 'stale' THEN 1 ELSE 2 END,
                 quota_window.last_sync_at DESC,
                 quota_window.observed_at DESC,
                 quota_window.id ASC
             ) AS row_number
      FROM public.account_quota_windows quota_window
      LEFT JOIN identity_merge_map merge_map
        ON merge_map.duplicate_id = quota_window.upstream_identity_id
      WHERE quota_window.upstream_identity_id IN (
        SELECT duplicate_id FROM identity_merge_map
        UNION
        SELECT canonical_id FROM identity_merge_map
      )
    )
    DELETE FROM public.account_quota_windows quota_window
    USING affected_windows ranked
    WHERE quota_window.id = ranked.id
      AND ranked.row_number > 1
    """)

    execute("""
    UPDATE public.account_quota_windows quota_window
    SET upstream_identity_id = merge_map.canonical_id,
        updated_at = now()
    FROM identity_merge_map merge_map
    WHERE quota_window.upstream_identity_id = merge_map.duplicate_id
    """)
  end

  defp merge_identity_rollups do
    execute("""
    INSERT INTO public.daily_rollups (
      id,
      rollup_date,
      dimension_kind,
      pool_id,
      api_key_id,
      pool_upstream_assignment_id,
      upstream_identity_id,
      model_id,
      request_count,
      success_count,
      failure_count,
      retry_count,
      input_tokens,
      cached_input_tokens,
      output_tokens,
      reasoning_tokens,
      total_tokens,
      estimated_cost_micros,
      settled_cost_micros,
      created_at,
      updated_at
    )
    SELECT gen_random_uuid(),
           rollup.rollup_date,
           'upstream_identity',
           rollup.pool_id,
           NULL,
           NULL,
           merge_map.canonical_id,
           NULL,
           SUM(rollup.request_count),
           SUM(rollup.success_count),
           SUM(rollup.failure_count),
           SUM(rollup.retry_count),
           SUM(rollup.input_tokens),
           SUM(rollup.cached_input_tokens),
           SUM(rollup.output_tokens),
           SUM(rollup.reasoning_tokens),
           SUM(rollup.total_tokens),
           SUM(rollup.estimated_cost_micros),
           SUM(rollup.settled_cost_micros),
           MIN(rollup.created_at),
           now()
    FROM public.daily_rollups rollup
    JOIN identity_merge_map merge_map ON merge_map.duplicate_id = rollup.upstream_identity_id
      WHERE rollup.dimension_kind = 'upstream_identity'
      GROUP BY rollup.rollup_date, rollup.pool_id, merge_map.canonical_id
    ON CONFLICT (rollup_date, upstream_identity_id)
    WHERE dimension_kind = 'upstream_identity'
    DO UPDATE SET
      request_count = daily_rollups.request_count + EXCLUDED.request_count,
      success_count = daily_rollups.success_count + EXCLUDED.success_count,
      failure_count = daily_rollups.failure_count + EXCLUDED.failure_count,
      retry_count = daily_rollups.retry_count + EXCLUDED.retry_count,
      input_tokens = daily_rollups.input_tokens + EXCLUDED.input_tokens,
      cached_input_tokens = daily_rollups.cached_input_tokens + EXCLUDED.cached_input_tokens,
      output_tokens = daily_rollups.output_tokens + EXCLUDED.output_tokens,
      reasoning_tokens = daily_rollups.reasoning_tokens + EXCLUDED.reasoning_tokens,
      total_tokens = daily_rollups.total_tokens + EXCLUDED.total_tokens,
      estimated_cost_micros = daily_rollups.estimated_cost_micros + EXCLUDED.estimated_cost_micros,
      settled_cost_micros = daily_rollups.settled_cost_micros + EXCLUDED.settled_cost_micros,
      updated_at = now()
    """)

    execute("""
    DELETE FROM public.daily_rollups rollup
    USING identity_merge_map merge_map
    WHERE rollup.upstream_identity_id = merge_map.duplicate_id
      AND rollup.dimension_kind = 'upstream_identity'
    """)
  end
end
