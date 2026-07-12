defmodule CodexPooler.Repo.Migrations.AddCacheWriteTokensToAccounting do
  use Ecto.Migration

  def change do
    alter table(:ledger_entries) do
      add :cache_write_tokens, :bigint
    end

    create constraint(:ledger_entries, :ledger_entries_cache_write_tokens_nonnegative,
             check: "cache_write_tokens IS NULL OR cache_write_tokens >= 0"
           )

    alter table(:request_log_facts) do
      add :latest_cache_write_tokens, :bigint
    end

    create constraint(:request_log_facts, :request_log_facts_cache_write_tokens_nonnegative,
             check: "latest_cache_write_tokens IS NULL OR latest_cache_write_tokens >= 0"
           )
  end
end
