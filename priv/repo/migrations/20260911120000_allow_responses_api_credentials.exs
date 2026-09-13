defmodule CodexPooler.Repo.Migrations.AllowResponsesApiCredentials do
  use Ecto.Migration

  def up do
    drop constraint(:upstream_identities, :upstream_identities_credential_provenance_check)

    create constraint(:upstream_identities, :upstream_identities_credential_provenance_check,
             check:
               "credential_provenance IS NULL OR credential_provenance IN ('codex_chatgpt_oauth', 'responses_api_key')"
           )
  end

  def down do
    drop constraint(:upstream_identities, :upstream_identities_credential_provenance_check)

    create constraint(:upstream_identities, :upstream_identities_credential_provenance_check,
             check:
               "credential_provenance IS NULL OR credential_provenance = 'codex_chatgpt_oauth'"
           )
  end
end
