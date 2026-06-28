defmodule CodexPooler.Repo.Migrations.CreateAccountingAndObanTables do
  use Ecto.Migration

  # Migration lifecycle note:
  # A generated 20260426220333 monolithic bootstrap migration briefly existed before
  # this schema was split into the 20260426220335-20260426220340 cluster. That
  # monolithic file is intentionally absent from the repository, but early local or
  # pre-release databases may still have its version recorded in schema_migrations.
  # Keep this guard so those databases skip duplicate DDL while fresh installs run
  # the split migrations normally.
  @monolithic_migration_version "20260426220333"

  def up do
    unless monolithic_migration_applied?() do
      execute_statements(~S"""
      CREATE TABLE public.daily_rollups (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      rollup_date date NOT NULL,
      dimension_kind text NOT NULL,
      pool_id uuid,
      api_key_id uuid,
      pool_upstream_assignment_id uuid,
      upstream_identity_id uuid,
      model_id uuid,
      request_count bigint DEFAULT 0 NOT NULL,
      success_count bigint DEFAULT 0 NOT NULL,
      failure_count bigint DEFAULT 0 NOT NULL,
      retry_count bigint DEFAULT 0 NOT NULL,
      input_tokens bigint DEFAULT 0 NOT NULL,
      cached_input_tokens bigint DEFAULT 0 NOT NULL,
      output_tokens bigint DEFAULT 0 NOT NULL,
      reasoning_tokens bigint DEFAULT 0 NOT NULL,
      total_tokens bigint DEFAULT 0 NOT NULL,
      estimated_cost_micros numeric(30,9) DEFAULT 0 NOT NULL,
      settled_cost_micros numeric(30,9) DEFAULT 0 NOT NULL,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      updated_at timestamp with time zone DEFAULT now() NOT NULL,
      CONSTRAINT daily_rollups_cached_input_tokens_check CHECK ((cached_input_tokens >= 0)),
      CONSTRAINT daily_rollups_check CHECK ((((dimension_kind = 'pool'::text) AND (pool_id IS NOT NULL) AND (api_key_id IS NULL) AND (pool_upstream_assignment_id IS NULL) AND (upstream_identity_id IS NULL) AND (model_id IS NULL)) OR ((dimension_kind = 'api_key'::text) AND (pool_id IS NOT NULL) AND (api_key_id IS NOT NULL) AND (pool_upstream_assignment_id IS NULL) AND (upstream_identity_id IS NULL) AND (model_id IS NULL)) OR ((dimension_kind = 'pool_upstream_assignment'::text) AND (pool_id IS NOT NULL) AND (api_key_id IS NULL) AND (pool_upstream_assignment_id IS NOT NULL) AND (upstream_identity_id IS NULL) AND (model_id IS NULL)) OR ((dimension_kind = 'upstream_identity'::text) AND (pool_id IS NOT NULL) AND (api_key_id IS NULL) AND (pool_upstream_assignment_id IS NULL) AND (upstream_identity_id IS NOT NULL) AND (model_id IS NULL)) OR ((dimension_kind = 'model'::text) AND (pool_id IS NOT NULL) AND (api_key_id IS NULL) AND (pool_upstream_assignment_id IS NULL) AND (upstream_identity_id IS NULL) AND (model_id IS NOT NULL)))),
      CONSTRAINT daily_rollups_dimension_kind_check CHECK ((dimension_kind = ANY (ARRAY['pool'::text, 'api_key'::text, 'pool_upstream_assignment'::text, 'upstream_identity'::text, 'model'::text]))),
      CONSTRAINT daily_rollups_estimated_cost_micros_check CHECK ((estimated_cost_micros >= (0)::numeric)),
      CONSTRAINT daily_rollups_failure_count_check CHECK ((failure_count >= 0)),
      CONSTRAINT daily_rollups_input_tokens_check CHECK ((input_tokens >= 0)),
      CONSTRAINT daily_rollups_output_tokens_check CHECK ((output_tokens >= 0)),
      CONSTRAINT daily_rollups_reasoning_tokens_check CHECK ((reasoning_tokens >= 0)),
      CONSTRAINT daily_rollups_request_count_check CHECK ((request_count >= 0)),
      CONSTRAINT daily_rollups_retry_count_check CHECK ((retry_count >= 0)),
      CONSTRAINT daily_rollups_settled_cost_micros_check CHECK ((settled_cost_micros >= (0)::numeric)),
      CONSTRAINT daily_rollups_success_count_check CHECK ((success_count >= 0)),
      CONSTRAINT daily_rollups_total_tokens_check CHECK ((total_tokens >= 0))
      );

      CREATE TABLE public.ledger_entries (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      request_id uuid NOT NULL,
      attempt_id uuid,
      pricing_snapshot_id uuid,
      pool_id uuid NOT NULL,
      api_key_id uuid NOT NULL,
      pool_upstream_assignment_id uuid,
      upstream_identity_id uuid,
      model_id uuid,
      entry_kind text NOT NULL,
      amount_status text DEFAULT 'recorded'::text NOT NULL,
      usage_status text DEFAULT 'usage_pending'::text NOT NULL,
      transport text NOT NULL,
      currency_code text DEFAULT 'USD'::text NOT NULL,
      input_tokens bigint,
      cached_input_tokens bigint,
      output_tokens bigint,
      reasoning_tokens bigint,
      total_tokens bigint,
      request_count integer DEFAULT 0 NOT NULL,
      estimated_cost_micros numeric(30,9) DEFAULT 0 NOT NULL,
      settled_cost_micros numeric(30,9) DEFAULT 0 NOT NULL,
      correction_of_entry_id uuid,
      source_event_id text,
      occurred_at timestamp with time zone DEFAULT now() NOT NULL,
      created_at timestamp with time zone DEFAULT now() NOT NULL,
      details jsonb DEFAULT '{}'::jsonb NOT NULL,
      CONSTRAINT ledger_entries_amount_status_check CHECK ((amount_status = ANY (ARRAY['recorded'::text, 'voided'::text]))),
      CONSTRAINT ledger_entries_cached_input_tokens_check CHECK (((cached_input_tokens IS NULL) OR (cached_input_tokens >= 0))),
      CONSTRAINT ledger_entries_entry_kind_check CHECK ((entry_kind = ANY (ARRAY['reservation'::text, 'release'::text, 'settlement'::text, 'adjustment'::text, 'correction'::text]))),
      CONSTRAINT ledger_entries_estimated_cost_micros_check CHECK ((estimated_cost_micros >= (0)::numeric)),
      CONSTRAINT ledger_entries_input_tokens_check CHECK (((input_tokens IS NULL) OR (input_tokens >= 0))),
      CONSTRAINT ledger_entries_output_tokens_check CHECK (((output_tokens IS NULL) OR (output_tokens >= 0))),
      CONSTRAINT ledger_entries_reasoning_tokens_check CHECK (((reasoning_tokens IS NULL) OR (reasoning_tokens >= 0))),
      CONSTRAINT ledger_entries_request_count_check CHECK ((request_count >= 0)),
      CONSTRAINT ledger_entries_settled_cost_micros_check CHECK ((settled_cost_micros >= (0)::numeric)),
      CONSTRAINT ledger_entries_total_tokens_check CHECK (((total_tokens IS NULL) OR (total_tokens >= 0))),
      CONSTRAINT ledger_entries_transport_check CHECK ((transport = ANY (ARRAY['http_json'::text, 'http_compact_json'::text, 'http_sse'::text, 'websocket'::text, 'http_multipart'::text]))),
      CONSTRAINT ledger_entries_usage_status_check CHECK ((usage_status = ANY (ARRAY['usage_pending'::text, 'usage_known'::text, 'usage_unknown'::text, 'not_applicable'::text])))
      );

      CREATE TABLE public.oban_jobs (
      id bigint NOT NULL,
      state public.oban_job_state DEFAULT 'available'::public.oban_job_state NOT NULL,
      queue text DEFAULT 'default'::text NOT NULL,
      worker text NOT NULL,
      args jsonb DEFAULT '{}'::jsonb NOT NULL,
      errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
      attempt integer DEFAULT 0 NOT NULL,
      max_attempts integer DEFAULT 20 NOT NULL,
      inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
      scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
      attempted_at timestamp without time zone,
      completed_at timestamp without time zone,
      attempted_by text[],
      discarded_at timestamp without time zone,
      priority integer DEFAULT 0 NOT NULL,
      tags text[] DEFAULT ARRAY[]::text[],
      meta jsonb DEFAULT '{}'::jsonb,
      cancelled_at timestamp without time zone,
      CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
      CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
      CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
      CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
      );

      CREATE SEQUENCE public.oban_jobs_id_seq
      START WITH 1
      INCREMENT BY 1
      NO MINVALUE
      NO MAXVALUE
      CACHE 1;

      ALTER SEQUENCE public.oban_jobs_id_seq OWNED BY public.oban_jobs.id;

      CREATE UNLOGGED TABLE public.oban_peers (
      name text NOT NULL,
      node text NOT NULL,
      started_at timestamp without time zone NOT NULL,
      expires_at timestamp without time zone NOT NULL
      );

      CREATE TABLE public.pricing_snapshots (
      id uuid DEFAULT gen_random_uuid() NOT NULL,
      model_identifier text NOT NULL,
      price_version text NOT NULL,
      currency_code text DEFAULT 'USD'::text NOT NULL,
      billing_unit text DEFAULT 'token'::text NOT NULL,
      input_token_micros numeric(30,9),
      cached_input_token_micros numeric(30,9),
      output_token_micros numeric(30,9),
      reasoning_token_micros numeric(30,9),
      request_base_micros numeric(30,9),
      effective_at timestamp with time zone NOT NULL,
      source_url text,
      captured_at timestamp with time zone DEFAULT now() NOT NULL,
      config jsonb DEFAULT '{}'::jsonb NOT NULL,
      CONSTRAINT pricing_snapshots_billing_unit_check CHECK ((billing_unit = ANY (ARRAY['token'::text, 'request'::text, 'minute'::text]))),
      CONSTRAINT pricing_snapshots_cached_input_token_micros_check CHECK (((cached_input_token_micros IS NULL) OR (cached_input_token_micros >= (0)::numeric))),
      CONSTRAINT pricing_snapshots_input_token_micros_check CHECK (((input_token_micros IS NULL) OR (input_token_micros >= (0)::numeric))),
      CONSTRAINT pricing_snapshots_output_token_micros_check CHECK (((output_token_micros IS NULL) OR (output_token_micros >= (0)::numeric))),
      CONSTRAINT pricing_snapshots_reasoning_token_micros_check CHECK (((reasoning_token_micros IS NULL) OR (reasoning_token_micros >= (0)::numeric))),
      CONSTRAINT pricing_snapshots_request_base_micros_check CHECK (((request_base_micros IS NULL) OR (request_base_micros >= (0)::numeric)))
      );

      ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);
      """)
    end
  end

  def down do
    unless monolithic_migration_applied?() do
      execute_statements(~S"""
      DROP TABLE IF EXISTS public.oban_peers CASCADE;
      DROP TABLE IF EXISTS public.oban_jobs CASCADE;
      DROP SEQUENCE IF EXISTS public.oban_jobs_id_seq CASCADE;
      DROP TABLE IF EXISTS public.daily_rollups CASCADE;
      DROP TABLE IF EXISTS public.ledger_entries CASCADE;
      DROP TABLE IF EXISTS public.pricing_snapshots CASCADE;
      """)
    end
  end

  defp monolithic_migration_applied? do
    %{num_rows: rows} =
      repo().query!("SELECT 1 FROM schema_migrations WHERE version::text = $1", [
        @monolithic_migration_version
      ])

    rows > 0
  end

  defp execute_statements(sql) do
    sql
    |> statements()
    |> Enum.each(&execute/1)
  end

  defp statements(sql) do
    sql
    |> String.split(~r/; *\n/,
      trim: true
    )
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
