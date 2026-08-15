defmodule CodexPooler.Repo.Migrations.FencePoolDailyRollupCoverage do
  use Ecto.Migration

  def up do
    alter table(:daily_rollup_coverages) do
      modify :completed_at, :utc_datetime_usec, null: true
      add :mutation_version, :bigint, null: false, default: 0
    end

    create constraint(
             :daily_rollup_coverages,
             :daily_rollup_coverages_mutation_version_check,
             check: "mutation_version >= 0"
           )

    execute("""
    UPDATE public.daily_rollup_coverages
    SET contract_version = 2,
        completed_at = NULL,
        mutation_version = 0,
        updated_at = statement_timestamp()
    """)

    execute("""
    CREATE FUNCTION public.mark_pool_daily_rollup_dates_mutated(p_dates date[])
    RETURNS void
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      affected_date date;
      utc_today date := (clock_timestamp() AT TIME ZONE 'UTC')::date;
    BEGIN
      FOR affected_date IN
        SELECT DISTINCT date_value
        FROM unnest(p_dates) AS values_by_date(date_value)
        WHERE date_value IS NOT NULL
        ORDER BY date_value
      LOOP
        IF affected_date < utc_today THEN
          INSERT INTO public.daily_rollup_coverages (
            rollup_date,
            contract_version,
            completed_at,
            mutation_version,
            created_at,
            updated_at
          )
          VALUES (
            affected_date,
            2,
            NULL,
            1,
            statement_timestamp(),
            statement_timestamp()
          )
          ON CONFLICT (rollup_date) DO UPDATE SET
            contract_version = 2,
            completed_at = NULL,
            mutation_version = public.daily_rollup_coverages.mutation_version + 1,
            updated_at = statement_timestamp();
        END IF;
      END LOOP;
    END;
    $function$
    """)

    execute("""
    CREATE FUNCTION public.track_request_pool_daily_rollup_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        PERFORM public.mark_pool_daily_rollup_dates_mutated(
          ARRAY[(NEW.admitted_at AT TIME ZONE 'UTC')::date]
        );
      ELSIF TG_OP = 'DELETE' THEN
        PERFORM public.mark_pool_daily_rollup_dates_mutated(
          ARRAY[(OLD.admitted_at AT TIME ZONE 'UTC')::date]
        );
      ELSIF OLD.pool_id IS DISTINCT FROM NEW.pool_id
         OR OLD.admitted_at IS DISTINCT FROM NEW.admitted_at THEN
        PERFORM public.mark_pool_daily_rollup_dates_mutated(
          ARRAY[
            (OLD.admitted_at AT TIME ZONE 'UTC')::date,
            (NEW.admitted_at AT TIME ZONE 'UTC')::date
          ]
        );
      END IF;

      RETURN COALESCE(NEW, OLD);
    END;
    $function$
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER requests_track_pool_daily_rollup_mutation
    AFTER INSERT OR UPDATE OR DELETE ON public.requests
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION public.track_request_pool_daily_rollup_mutation()
    """)

    execute("""
    CREATE FUNCTION public.track_ledger_pool_daily_rollup_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      old_relevant boolean := FALSE;
      new_relevant boolean := FALSE;
      projection_changed boolean := FALSE;
    BEGIN
      IF TG_OP <> 'INSERT' THEN
        old_relevant := OLD.entry_kind = 'settlement' AND OLD.amount_status = 'recorded';
      END IF;

      IF TG_OP <> 'DELETE' THEN
        new_relevant := NEW.entry_kind = 'settlement' AND NEW.amount_status = 'recorded';
      END IF;

      IF TG_OP = 'UPDATE' THEN
        projection_changed :=
          OLD.pool_id IS DISTINCT FROM NEW.pool_id
          OR OLD.occurred_at IS DISTINCT FROM NEW.occurred_at
          OR OLD.entry_kind IS DISTINCT FROM NEW.entry_kind
          OR OLD.amount_status IS DISTINCT FROM NEW.amount_status
          OR OLD.usage_status IS DISTINCT FROM NEW.usage_status
          OR OLD.input_tokens IS DISTINCT FROM NEW.input_tokens
          OR OLD.cached_input_tokens IS DISTINCT FROM NEW.cached_input_tokens
          OR OLD.output_tokens IS DISTINCT FROM NEW.output_tokens
          OR OLD.reasoning_tokens IS DISTINCT FROM NEW.reasoning_tokens
          OR OLD.total_tokens IS DISTINCT FROM NEW.total_tokens
          OR OLD.settled_cost_micros IS DISTINCT FROM NEW.settled_cost_micros;
      END IF;

      IF TG_OP = 'INSERT' AND new_relevant THEN
        PERFORM public.mark_pool_daily_rollup_dates_mutated(
          ARRAY[(NEW.occurred_at AT TIME ZONE 'UTC')::date]
        );
      ELSIF TG_OP = 'DELETE' AND old_relevant THEN
        PERFORM public.mark_pool_daily_rollup_dates_mutated(
          ARRAY[(OLD.occurred_at AT TIME ZONE 'UTC')::date]
        );
      ELSIF TG_OP = 'UPDATE' AND projection_changed AND (old_relevant OR new_relevant) THEN
        PERFORM public.mark_pool_daily_rollup_dates_mutated(
          ARRAY[
            CASE WHEN old_relevant THEN (OLD.occurred_at AT TIME ZONE 'UTC')::date END,
            CASE WHEN new_relevant THEN (NEW.occurred_at AT TIME ZONE 'UTC')::date END
          ]
        );
      END IF;

      RETURN COALESCE(NEW, OLD);
    END;
    $function$
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER ledger_entries_track_pool_daily_rollup_mutation
    AFTER INSERT OR UPDATE OR DELETE ON public.ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION public.track_ledger_pool_daily_rollup_mutation()
    """)

    execute("""
    CREATE FUNCTION public.track_daily_rollup_pool_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF current_setting('codex_pooler.pool_daily_rollup_rebuild', true) = 'on' THEN
        RETURN COALESCE(NEW, OLD);
      END IF;

      IF TG_OP = 'INSERT' AND NEW.dimension_kind = 'pool' THEN
        PERFORM public.mark_pool_daily_rollup_dates_mutated(ARRAY[NEW.rollup_date]);
      ELSIF TG_OP = 'DELETE' AND OLD.dimension_kind = 'pool' THEN
        PERFORM public.mark_pool_daily_rollup_dates_mutated(ARRAY[OLD.rollup_date]);
      ELSIF TG_OP = 'UPDATE'
         AND (OLD.dimension_kind = 'pool' OR NEW.dimension_kind = 'pool')
         AND ROW(
           OLD.rollup_date,
           OLD.dimension_kind,
           OLD.pool_id,
           OLD.admitted_request_count,
           OLD.request_count,
           OLD.input_tokens,
           OLD.cached_input_tokens,
           OLD.output_tokens,
           OLD.reasoning_tokens,
           OLD.total_tokens,
           OLD.rounded_settled_cost_micros
         ) IS DISTINCT FROM ROW(
           NEW.rollup_date,
           NEW.dimension_kind,
           NEW.pool_id,
           NEW.admitted_request_count,
           NEW.request_count,
           NEW.input_tokens,
           NEW.cached_input_tokens,
           NEW.output_tokens,
           NEW.reasoning_tokens,
           NEW.total_tokens,
           NEW.rounded_settled_cost_micros
         ) THEN
        PERFORM public.mark_pool_daily_rollup_dates_mutated(
          ARRAY[
            CASE WHEN OLD.dimension_kind = 'pool' THEN OLD.rollup_date END,
            CASE WHEN NEW.dimension_kind = 'pool' THEN NEW.rollup_date END
          ]
        );
      END IF;

      RETURN COALESCE(NEW, OLD);
    END;
    $function$
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER daily_rollups_track_pool_daily_rollup_mutation
    AFTER INSERT OR UPDATE OR DELETE ON public.daily_rollups
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION public.track_daily_rollup_pool_mutation()
    """)

    execute("""
    CREATE FUNCTION public.guard_pool_daily_rollup_coverage_contract()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF NEW.contract_version < 2 THEN
        NEW.contract_version := 2;
        NEW.completed_at := NULL;
      END IF;

      RETURN NEW;
    END;
    $function$
    """)

    execute("""
    CREATE TRIGGER daily_rollup_coverages_guard_contract
    BEFORE INSERT OR UPDATE ON public.daily_rollup_coverages
    FOR EACH ROW
    EXECUTE FUNCTION public.guard_pool_daily_rollup_coverage_contract()
    """)
  end

  def down do
    execute("DELETE FROM public.daily_rollup_coverages")

    execute(
      "DROP TRIGGER IF EXISTS daily_rollup_coverages_guard_contract ON public.daily_rollup_coverages"
    )

    execute("DROP FUNCTION IF EXISTS public.guard_pool_daily_rollup_coverage_contract()")

    execute(
      "DROP TRIGGER IF EXISTS daily_rollups_track_pool_daily_rollup_mutation ON public.daily_rollups"
    )

    execute("DROP FUNCTION IF EXISTS public.track_daily_rollup_pool_mutation()")

    execute(
      "DROP TRIGGER IF EXISTS ledger_entries_track_pool_daily_rollup_mutation ON public.ledger_entries"
    )

    execute("DROP FUNCTION IF EXISTS public.track_ledger_pool_daily_rollup_mutation()")

    execute("DROP TRIGGER IF EXISTS requests_track_pool_daily_rollup_mutation ON public.requests")

    execute("DROP FUNCTION IF EXISTS public.track_request_pool_daily_rollup_mutation()")
    execute("DROP FUNCTION IF EXISTS public.mark_pool_daily_rollup_dates_mutated(date[])")

    drop constraint(
           :daily_rollup_coverages,
           :daily_rollup_coverages_mutation_version_check
         )

    alter table(:daily_rollup_coverages) do
      remove :mutation_version
      modify :completed_at, :utc_datetime_usec, null: false
    end
  end
end
