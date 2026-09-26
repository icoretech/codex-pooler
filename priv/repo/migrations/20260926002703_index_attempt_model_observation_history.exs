defmodule CodexPooler.Repo.Migrations.IndexAttemptModelObservationHistory do
  use Ecto.Migration

  alias CodexPooler.Release.MigrationLockBudget

  @disable_ddl_transaction true

  def up do
    execute(fn ->
      MigrationLockBudget.run(repo(), &ensure_history_index/0)
    end)
  end

  def down do
    execute(fn ->
      MigrationLockBudget.run(repo(), fn ->
        repo().query!("DROP INDEX CONCURRENTLY IF EXISTS public.attempts_model_history_started_idx", [], timeout: :infinity)
      end)
    end)
  end

  defp ensure_history_index do
    # A failed concurrent build leaves an invalid index behind.
    case repo().query!("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass('public.attempts_model_history_started_idx')").rows do
      [[true]] ->
        :ok

      rows when rows in [[], [[false]]] ->
        repo().query!("DROP INDEX CONCURRENTLY IF EXISTS public.attempts_model_history_started_idx", [], timeout: :infinity)
        repo().query!("CREATE INDEX CONCURRENTLY attempts_model_history_started_idx ON public.attempts (started_at, id) WHERE status NOT IN ('queued', 'in_progress')", [], timeout: :infinity)
    end
  end
end
