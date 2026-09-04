defmodule CodexPooler.Repo.Migrations.AddRequestReplayEntitlements do
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION public.request_replay_db_now()
    RETURNS timestamp with time zone
    LANGUAGE sql VOLATILE PARALLEL SAFE
    SET search_path = pg_catalog
    AS $$ SELECT clock_timestamp() $$
    """)

    execute("""
    ALTER TABLE public.codex_turns
      ADD COLUMN semantic_turn_digest bytea,
      ADD CONSTRAINT codex_turns_semantic_turn_digest_shape_check
        CHECK (semantic_turn_digest IS NULL OR octet_length(semantic_turn_digest) = 32)
    """)

    execute(
      "CREATE UNIQUE INDEX codex_turns_id_request_id_uq ON public.codex_turns (id, request_id)"
    )

    execute("""
    CREATE UNIQUE INDEX codex_turns_active_semantic_turn_uq
      ON public.codex_turns (codex_session_id, semantic_turn_digest)
      WHERE semantic_turn_digest IS NOT NULL AND status = 'in_progress'
    """)

    execute("""
    ALTER TABLE public.attempts
      ADD COLUMN replay_generation integer NOT NULL DEFAULT 0,
      ADD CONSTRAINT attempts_replay_generation_check CHECK (replay_generation >= 0)
    """)

    execute("""
    CREATE FUNCTION public.enforce_request_replay_request_storage()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
    AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND ROW(
        NEW.pool_id,
        NEW.api_key_id,
        NEW.model_id,
        NEW.requested_model,
        NEW.reasoning_effort,
        NEW.requested_service_tier,
        NEW.actual_service_tier,
        NEW.service_tier,
        NEW.upstream_account_label,
        NEW.upstream_account_email,
        NEW.upstream_account_plan_label,
        NEW.upstream_account_plan_family
      ) IS DISTINCT FROM ROW(
        OLD.pool_id,
        OLD.api_key_id,
        OLD.model_id,
        OLD.requested_model,
        OLD.reasoning_effort,
        OLD.requested_service_tier,
        OLD.actual_service_tier,
        OLD.service_tier,
        OLD.upstream_account_label,
        OLD.upstream_account_email,
        OLD.upstream_account_plan_label,
        OLD.upstream_account_plan_family
      ) AND EXISTS (
        SELECT 1
        FROM public.request_replay_entitlements entitlement
        WHERE entitlement.request_id = OLD.id
      ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
          CONSTRAINT = 'request_replay_entitlements_request_snapshot_immutable_check';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER request_replay_requests_storage_guard
    BEFORE INSERT OR UPDATE ON public.requests
    FOR EACH ROW EXECUTE FUNCTION public.enforce_request_replay_request_storage()
    """)

    execute("""
    CREATE TABLE public.request_replay_entitlements (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      request_id uuid NOT NULL,
      codex_turn_id uuid NOT NULL,
      eligible_attempt_id uuid NOT NULL,
      replay_attempt_id uuid,
      api_key_id uuid NOT NULL,
      api_key_runtime_epoch bigint NOT NULL,
      pool_id uuid NOT NULL,
      model_id uuid NOT NULL,
      model_identifier text NOT NULL,
      semantic_turn_digest bytea NOT NULL,
      replay_claim_digest bytea NOT NULL,
      provisional_binding_digest bytea,
      replay_generation integer NOT NULL DEFAULT 1,
      owner_lease_digest bytea NOT NULL,
      owner_lease_key_version text NOT NULL,
      predecessor_epoch bigint NOT NULL,
      status text NOT NULL DEFAULT 'armed',
      armed_at timestamp with time zone NOT NULL,
      expires_at timestamp with time zone NOT NULL,
      consumed_at timestamp with time zone,
      started_at timestamp with time zone,
      last_liveness_at timestamp with time zone,
      abandon_at timestamp with time zone,
      terminal_at timestamp with time zone,
      closed_at timestamp with time zone,
      cleanup_checked_at timestamp with time zone,
      CONSTRAINT request_replay_entitlements_status_check
        CHECK (status = ANY (ARRAY['armed'::text, 'consumed'::text, 'expired'::text, 'revoked'::text])),
      CONSTRAINT request_replay_entitlements_model_identifier_present_check
        CHECK (length(btrim(model_identifier, E' \t\n\r')) > 0),
      CONSTRAINT request_replay_entitlements_lease_key_version_present_check
        CHECK (length(btrim(owner_lease_key_version, E' \t\n\r')) > 0),
      CONSTRAINT request_replay_entitlements_semantic_turn_digest_shape_check
        CHECK (octet_length(semantic_turn_digest) = 32),
      CONSTRAINT request_replay_entitlements_replay_claim_digest_shape_check
        CHECK (octet_length(replay_claim_digest) = 32),
      CONSTRAINT request_replay_entitlements_provisional_digest_shape_check
        CHECK (provisional_binding_digest IS NULL OR octet_length(provisional_binding_digest) = 32),
      CONSTRAINT request_replay_entitlements_owner_lease_digest_shape_check
        CHECK (octet_length(owner_lease_digest) = 32),
      CONSTRAINT request_replay_entitlements_api_key_runtime_epoch_check
        CHECK (api_key_runtime_epoch >= 0),
      CONSTRAINT request_replay_entitlements_replay_generation_check
        CHECK (replay_generation = 1),
      CONSTRAINT request_replay_entitlements_predecessor_epoch_check
        CHECK (predecessor_epoch >= 1),
      CONSTRAINT request_replay_entitlements_expiry_check CHECK (expires_at > armed_at),
      CONSTRAINT request_replay_entitlements_lifecycle_tuple_check CHECK (
        status NOT IN ('armed', 'consumed', 'expired', 'revoked') OR
        (status = 'armed' AND replay_attempt_id IS NULL AND provisional_binding_digest IS NULL
          AND consumed_at IS NULL AND started_at IS NULL AND last_liveness_at IS NULL
          AND abandon_at IS NULL AND terminal_at IS NULL AND closed_at IS NULL)
        OR
        (status = 'consumed' AND replay_attempt_id IS NOT NULL
          AND provisional_binding_digest IS NOT NULL AND consumed_at IS NOT NULL
          AND abandon_at IS NOT NULL AND abandon_at > consumed_at AND terminal_at IS NULL
          AND ((started_at IS NULL AND last_liveness_at IS NULL)
            OR (started_at IS NOT NULL AND last_liveness_at IS NOT NULL
              AND consumed_at <= started_at AND started_at <= last_liveness_at
              AND last_liveness_at < abandon_at))
          AND (closed_at IS NULL OR closed_at > COALESCE(last_liveness_at, started_at, consumed_at)))
        OR
        (status IN ('expired', 'revoked') AND replay_attempt_id IS NULL
          AND provisional_binding_digest IS NULL AND consumed_at IS NULL AND started_at IS NULL
          AND last_liveness_at IS NULL AND abandon_at IS NULL AND terminal_at IS NOT NULL
          AND closed_at IS NOT NULL
          AND ((status = 'expired' AND terminal_at >= expires_at)
            OR (status = 'revoked' AND terminal_at >= armed_at))
          AND closed_at > terminal_at)
      ),
      CONSTRAINT request_replay_entitlements_request_id_fkey
        FOREIGN KEY (request_id) REFERENCES public.requests(id) ON DELETE CASCADE,
      CONSTRAINT request_replay_entitlements_codex_turn_request_fkey
        FOREIGN KEY (codex_turn_id, request_id) REFERENCES public.codex_turns(id, request_id),
      CONSTRAINT request_replay_entitlements_eligible_attempt_request_fkey
        FOREIGN KEY (eligible_attempt_id, request_id) REFERENCES public.attempts(id, request_id),
      CONSTRAINT request_replay_entitlements_replay_attempt_request_fkey
        FOREIGN KEY (replay_attempt_id, request_id) REFERENCES public.attempts(id, request_id),
      CONSTRAINT request_replay_entitlements_api_key_id_fkey
        FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE,
      CONSTRAINT request_replay_entitlements_pool_id_fkey
        FOREIGN KEY (pool_id) REFERENCES public.pools(id),
      CONSTRAINT request_replay_entitlements_model_id_fkey
        FOREIGN KEY (model_id) REFERENCES public.models(id)
    )
    """)

    execute(
      "CREATE UNIQUE INDEX request_replay_entitlements_request_id_uq ON public.request_replay_entitlements (request_id)"
    )

    execute("""
    CREATE INDEX request_replay_entitlements_cleanup_due_idx
      ON public.request_replay_entitlements
        (cleanup_checked_at ASC NULLS FIRST, expires_at, abandon_at, id)
      WHERE closed_at IS NULL
    """)

    execute("""
    CREATE FUNCTION public.enforce_request_replay_entitlement_update()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
    AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND ROW(NEW.request_id, NEW.codex_turn_id, NEW.eligible_attempt_id, NEW.api_key_id,
        NEW.api_key_runtime_epoch, NEW.pool_id, NEW.model_id, NEW.model_identifier,
        NEW.semantic_turn_digest, NEW.replay_claim_digest, NEW.replay_generation,
        NEW.owner_lease_digest, NEW.owner_lease_key_version, NEW.predecessor_epoch,
        NEW.armed_at, NEW.expires_at)
      IS DISTINCT FROM
        ROW(OLD.request_id, OLD.codex_turn_id, OLD.eligible_attempt_id, OLD.api_key_id,
        OLD.api_key_runtime_epoch, OLD.pool_id, OLD.model_id, OLD.model_identifier,
        OLD.semantic_turn_digest, OLD.replay_claim_digest, OLD.replay_generation,
        OLD.owner_lease_digest, OLD.owner_lease_key_version, OLD.predecessor_epoch,
        OLD.armed_at, OLD.expires_at) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
          CONSTRAINT = 'request_replay_entitlements_snapshot_immutable_check';
      END IF;

      IF TG_OP = 'UPDATE' AND ((OLD.status = 'consumed' AND NEW.status <> 'consumed')
         OR (OLD.status IN ('expired', 'revoked') AND NEW.status <> OLD.status)) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
          CONSTRAINT = 'request_replay_entitlements_status_transition_check';
      END IF;

      IF TG_OP = 'UPDATE' AND OLD.status = 'consumed' AND
        ROW(NEW.replay_attempt_id, NEW.provisional_binding_digest, NEW.consumed_at)
        IS DISTINCT FROM
        ROW(OLD.replay_attempt_id, OLD.provisional_binding_digest, OLD.consumed_at) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
          CONSTRAINT = 'request_replay_entitlements_consumption_immutable_check';
      END IF;

      PERFORM 1
      FROM public.codex_turns turn_row
      WHERE turn_row.id = NEW.codex_turn_id
        AND turn_row.request_id = NEW.request_id
        AND turn_row.semantic_turn_digest = NEW.semantic_turn_digest
      FOR KEY SHARE;

      IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
          CONSTRAINT = 'request_replay_entitlements_semantic_turn_match_check';
      END IF;

      PERFORM 1
      FROM public.requests request_row
      JOIN public.api_keys api_key ON api_key.id = request_row.api_key_id
      WHERE request_row.id = NEW.request_id
        AND request_row.pool_id = NEW.pool_id
        AND request_row.api_key_id = NEW.api_key_id
        AND request_row.model_id = NEW.model_id
        AND request_row.requested_model = NEW.model_identifier
        AND (api_key.runtime_revocation_epoch = NEW.api_key_runtime_epoch
          OR (TG_OP = 'UPDATE' AND
            (OLD.status = 'consumed' OR NEW.status IN ('expired', 'revoked'))))
      FOR KEY SHARE OF request_row, api_key;

      IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
          CONSTRAINT = 'request_replay_entitlements_request_snapshot_match_check';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE FUNCTION public.enforce_request_replay_turn_snapshot()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog
    AS $$
    BEGIN
      IF ROW(NEW.request_id, NEW.semantic_turn_digest)
         IS DISTINCT FROM ROW(OLD.request_id, OLD.semantic_turn_digest)
         AND EXISTS (
           SELECT 1
           FROM public.request_replay_entitlements entitlement
           WHERE entitlement.codex_turn_id = OLD.id
         ) THEN
        RAISE EXCEPTION USING ERRCODE = '23514',
          CONSTRAINT = 'request_replay_entitlements_semantic_turn_immutable_check';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER request_replay_codex_turns_snapshot_guard
    BEFORE UPDATE ON public.codex_turns
    FOR EACH ROW EXECUTE FUNCTION public.enforce_request_replay_turn_snapshot()
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER request_replay_entitlements_insert_guard
    AFTER INSERT ON public.request_replay_entitlements
    FOR EACH ROW EXECUTE FUNCTION public.enforce_request_replay_entitlement_update()
    """)

    execute("""
    CREATE TRIGGER request_replay_entitlements_update_guard
    BEFORE UPDATE ON public.request_replay_entitlements
    FOR EACH ROW EXECUTE FUNCTION public.enforce_request_replay_entitlement_update()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER IF EXISTS request_replay_codex_turns_snapshot_guard ON public.codex_turns"
    )

    execute(
      "DROP TRIGGER IF EXISTS request_replay_entitlements_update_guard ON public.request_replay_entitlements"
    )

    execute(
      "DROP TRIGGER IF EXISTS request_replay_entitlements_insert_guard ON public.request_replay_entitlements"
    )

    execute("DROP FUNCTION IF EXISTS public.enforce_request_replay_turn_snapshot()")
    execute("DROP FUNCTION IF EXISTS public.enforce_request_replay_entitlement_update()")
    execute("DROP TABLE IF EXISTS public.request_replay_entitlements")

    execute("DROP TRIGGER IF EXISTS request_replay_requests_storage_guard ON public.requests")
    execute("DROP FUNCTION IF EXISTS public.enforce_request_replay_request_storage()")

    execute("""
    ALTER TABLE public.attempts
      DROP CONSTRAINT IF EXISTS attempts_replay_generation_check,
      DROP COLUMN IF EXISTS replay_generation
    """)

    execute("DROP INDEX IF EXISTS public.codex_turns_active_semantic_turn_uq")
    execute("DROP INDEX IF EXISTS public.codex_turns_id_request_id_uq")

    execute("""
    ALTER TABLE public.codex_turns
      DROP CONSTRAINT IF EXISTS codex_turns_semantic_turn_digest_shape_check,
      DROP COLUMN IF EXISTS semantic_turn_digest
    """)

    execute("DROP FUNCTION IF EXISTS public.request_replay_db_now()")
  end
end
