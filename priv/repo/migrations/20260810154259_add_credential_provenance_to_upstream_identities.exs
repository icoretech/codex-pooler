defmodule CodexPooler.Repo.Migrations.AddCredentialProvenanceToUpstreamIdentities do
  use Ecto.Migration

  def change do
    alter table(:upstream_identities) do
      add :credential_provenance, :string
    end

    create constraint(
             :upstream_identities,
             :upstream_identities_credential_provenance_check,
             check:
               "credential_provenance IS NULL OR credential_provenance = 'codex_chatgpt_oauth'"
           )
  end
end
