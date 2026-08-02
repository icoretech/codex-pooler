defmodule CodexPooler.Repo.Migrations.CreateApiKeyUsageBuckets do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '15s'")
    execute("SET LOCAL statement_timeout = '60s'")
    execute("SET LOCAL work_mem = '128MB'")
    execute("SET LOCAL enable_sort = off")

    create table(:api_key_usage_buckets, primary_key: false) do
      add :api_key_id,
          references(:api_keys, type: :binary_id, on_delete: :delete_all),
          primary_key: true,
          null: false

      add :bucket_started_at, :utc_datetime_usec, primary_key: true, null: false
      add :effective_request_count, :bigint, null: false, default: 0
      add :effective_total_tokens, :bigint, null: false, default: 0

      add :effective_cost_micros, :decimal,
        precision: 30,
        scale: 9,
        null: false,
        default: 0

      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create constraint(:api_key_usage_buckets, :api_key_usage_buckets_minute_boundary_check,
             check: "bucket_started_at = date_trunc('minute', bucket_started_at)"
           )

    flush()

    execute(create_apply_delta_function_sql())

    # Keep the backfill and trigger installation in one transaction while
    # preventing concurrent ledger writes. Reads remain available, and writes
    # resume through the trigger after commit without a projection gap.
    execute("LOCK TABLE public.ledger_entries IN SHARE ROW EXCLUSIVE MODE")
    execute(backfill_sql())
    execute(create_sync_trigger_function_sql())

    execute("""
    CREATE TRIGGER ledger_entries_sync_api_key_usage_buckets
    AFTER INSERT OR UPDATE OR DELETE ON public.ledger_entries
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_api_key_usage_bucket_from_ledger_entry()
    """)
  end

  def down do
    execute("""
    DROP TRIGGER IF EXISTS ledger_entries_sync_api_key_usage_buckets
    ON public.ledger_entries
    """)

    execute("DROP FUNCTION IF EXISTS public.sync_api_key_usage_bucket_from_ledger_entry()")

    execute("""
    DROP FUNCTION IF EXISTS public.apply_api_key_usage_bucket_delta(
      uuid,
      timestamp with time zone,
      bigint,
      bigint,
      numeric
    )
    """)

    drop table(:api_key_usage_buckets)
  end

  defp create_apply_delta_function_sql do
    """
    CREATE FUNCTION public.apply_api_key_usage_bucket_delta(
      p_api_key_id uuid,
      p_occurred_at timestamp with time zone,
      p_request_delta bigint,
      p_token_delta bigint,
      p_cost_delta numeric
    )
    RETURNS void
    LANGUAGE sql
    SET search_path = pg_catalog, public
    AS $function$
      INSERT INTO public.api_key_usage_buckets (
        api_key_id,
        bucket_started_at,
        effective_request_count,
        effective_total_tokens,
        effective_cost_micros,
        created_at,
        updated_at
      )
      VALUES (
        p_api_key_id,
        date_trunc('minute', p_occurred_at),
        p_request_delta,
        p_token_delta,
        p_cost_delta,
        statement_timestamp(),
        statement_timestamp()
      )
      ON CONFLICT (api_key_id, bucket_started_at) DO UPDATE SET
        effective_request_count =
          public.api_key_usage_buckets.effective_request_count + EXCLUDED.effective_request_count,
        effective_total_tokens =
          public.api_key_usage_buckets.effective_total_tokens + EXCLUDED.effective_total_tokens,
        effective_cost_micros =
          public.api_key_usage_buckets.effective_cost_micros + EXCLUDED.effective_cost_micros,
        updated_at = statement_timestamp()
    $function$
    """
  end

  defp create_sync_trigger_function_sql do
    """
    CREATE FUNCTION public.sync_api_key_usage_bucket_from_ledger_entry()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = pg_catalog, public
    AS $function$
    BEGIN
      IF TG_OP = 'DELETE'
         AND NOT EXISTS (SELECT 1 FROM public.api_keys WHERE id = OLD.api_key_id) THEN
        RETURN OLD;
      END IF;

      IF TG_OP IN ('UPDATE', 'DELETE') AND OLD.amount_status = 'recorded' THEN
        PERFORM public.apply_api_key_usage_bucket_delta(
          OLD.api_key_id,
          OLD.occurred_at,
          -(
            CASE
              WHEN OLD.entry_kind = 'release' THEN -COALESCE(OLD.request_count, 0)::bigint
              ELSE COALESCE(OLD.request_count, 0)::bigint
            END
          ),
          -(
            CASE
              WHEN OLD.entry_kind = 'release' THEN -COALESCE(OLD.total_tokens, 0)::bigint
              WHEN OLD.entry_kind = 'settlement' AND OLD.usage_status = 'usage_known'
                THEN COALESCE(OLD.total_tokens, 0)::bigint
              WHEN OLD.entry_kind = 'settlement' THEN 0::bigint
              ELSE COALESCE(OLD.total_tokens, 0)::bigint
            END
          ),
          -(
            CASE
              WHEN OLD.entry_kind = 'release' THEN -COALESCE(OLD.estimated_cost_micros, 0::numeric)
              WHEN OLD.entry_kind = 'settlement' AND OLD.usage_status = 'usage_known'
                THEN COALESCE(OLD.settled_cost_micros, 0::numeric)
              WHEN OLD.entry_kind = 'settlement' THEN 0::numeric
              ELSE COALESCE(OLD.estimated_cost_micros, 0::numeric)
            END
          )
        );
      END IF;

      IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.amount_status = 'recorded' THEN
        PERFORM public.apply_api_key_usage_bucket_delta(
          NEW.api_key_id,
          NEW.occurred_at,
          CASE
            WHEN NEW.entry_kind = 'release' THEN -COALESCE(NEW.request_count, 0)::bigint
            ELSE COALESCE(NEW.request_count, 0)::bigint
          END,
          CASE
            WHEN NEW.entry_kind = 'release' THEN -COALESCE(NEW.total_tokens, 0)::bigint
            WHEN NEW.entry_kind = 'settlement' AND NEW.usage_status = 'usage_known'
              THEN COALESCE(NEW.total_tokens, 0)::bigint
            WHEN NEW.entry_kind = 'settlement' THEN 0::bigint
            ELSE COALESCE(NEW.total_tokens, 0)::bigint
          END,
          CASE
            WHEN NEW.entry_kind = 'release' THEN -COALESCE(NEW.estimated_cost_micros, 0::numeric)
            WHEN NEW.entry_kind = 'settlement' AND NEW.usage_status = 'usage_known'
              THEN COALESCE(NEW.settled_cost_micros, 0::numeric)
            WHEN NEW.entry_kind = 'settlement' THEN 0::numeric
            ELSE COALESCE(NEW.estimated_cost_micros, 0::numeric)
          END
        );
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      END IF;

      RETURN NEW;
    EXCEPTION
      WHEN foreign_key_violation THEN
        IF TG_OP = 'DELETE'
           AND NOT EXISTS (SELECT 1 FROM public.api_keys WHERE id = OLD.api_key_id) THEN
          RETURN OLD;
        END IF;

        RAISE;
    END;
    $function$
    """
  end

  defp backfill_sql do
    """
    INSERT INTO public.api_key_usage_buckets (
      api_key_id,
      bucket_started_at,
      effective_request_count,
      effective_total_tokens,
      effective_cost_micros,
      created_at,
      updated_at
    )
    SELECT
      api_key_id,
      date_trunc('minute', occurred_at) AS bucket_started_at,
      SUM(
        CASE
          WHEN entry_kind = 'release' THEN -COALESCE(request_count, 0)
          ELSE COALESCE(request_count, 0)
        END
      )::bigint AS effective_request_count,
      SUM(
        CASE
          WHEN entry_kind = 'release' THEN -COALESCE(total_tokens, 0)
          WHEN entry_kind = 'settlement' AND usage_status = 'usage_known'
            THEN COALESCE(total_tokens, 0)
          WHEN entry_kind = 'settlement' THEN 0
          ELSE COALESCE(total_tokens, 0)
        END
      )::bigint AS effective_total_tokens,
      SUM(
        CASE
          WHEN entry_kind = 'release' THEN -COALESCE(estimated_cost_micros, 0::numeric)
          WHEN entry_kind = 'settlement' AND usage_status = 'usage_known'
            THEN COALESCE(settled_cost_micros, 0::numeric)
          WHEN entry_kind = 'settlement' THEN 0::numeric
          ELSE COALESCE(estimated_cost_micros, 0::numeric)
        END
      ) AS effective_cost_micros,
      statement_timestamp(),
      statement_timestamp()
    FROM public.ledger_entries
    WHERE amount_status = 'recorded'
    GROUP BY api_key_id, date_trunc('minute', occurred_at)
    """
  end
end
