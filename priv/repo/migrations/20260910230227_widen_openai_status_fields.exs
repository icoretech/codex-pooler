defmodule CodexPooler.Repo.Migrations.WidenOpenAIStatusFields do
  use Ecto.Migration

  def change do
    alter table(:openai_status_feed_states) do
      modify :etag, :string, size: 512
      modify :last_modified, :string, size: 128
      modify :last_error_code, :string, size: 80
      modify :content_hash, :string, size: 128
    end

    alter table(:openai_status_incidents) do
      modify :guid, :string, size: 512
      modify :title, :string, size: 4_000
      modify :status, :string, size: 32
      modify :summary, :string, size: 4_000
      modify :component, :string, size: 512
      modify :link, :string, size: 2_048
      modify :content_hash, :string, size: 128
    end
  end
end
