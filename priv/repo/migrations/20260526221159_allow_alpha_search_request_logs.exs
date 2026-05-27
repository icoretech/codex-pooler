defmodule CodexPooler.Repo.Migrations.AllowAlphaSearchRequestLogs do
  use Ecto.Migration

  def change do
    execute(
      """
      ALTER TABLE requests
      DROP CONSTRAINT requests_endpoint_check,
      ADD CONSTRAINT requests_endpoint_check CHECK ((endpoint = ANY (ARRAY[
        '/backend-api/codex/models'::text,
        '/backend-api/codex/responses'::text,
        '/backend-api/codex/responses/compact'::text,
        '/backend-api/codex/images/generations'::text,
        '/backend-api/codex/images/edits'::text,
        '/backend-api/codex/thread/goal/get'::text,
        '/backend-api/codex/thread/goal/set'::text,
        '/backend-api/codex/thread/goal/clear'::text,
        '/backend-api/codex/analytics-events/events'::text,
        '/backend-api/codex/memories/trace_summarize'::text,
        '/backend-api/codex/alpha/search'::text,
        '/backend-api/codex/realtime/calls'::text,
        '/backend-api/codex/safety/arc'::text,
        '/backend-api/codex/agent-identities/jwks'::text,
        '/backend-api/wham/agent-identities/jwks'::text,
        '/backend-api/transcribe'::text,
        '/backend-api/files'::text,
        '/backend-api/files/uploaded'::text,
        '/api/codex/usage'::text,
        '/wham/usage'::text,
        '/backend-api/wham/usage'::text,
        '/v1/models'::text,
        '/v1/usage'::text,
        '/v1/files'::text,
        '/v1/files/content'::text,
        '/v1/files/delete'::text
      ])))
      """,
      """
      ALTER TABLE requests
      DROP CONSTRAINT requests_endpoint_check,
      ADD CONSTRAINT requests_endpoint_check CHECK ((endpoint = ANY (ARRAY[
        '/backend-api/codex/models'::text,
        '/backend-api/codex/responses'::text,
        '/backend-api/codex/responses/compact'::text,
        '/backend-api/codex/images/generations'::text,
        '/backend-api/codex/images/edits'::text,
        '/backend-api/codex/thread/goal/get'::text,
        '/backend-api/codex/thread/goal/set'::text,
        '/backend-api/codex/thread/goal/clear'::text,
        '/backend-api/codex/analytics-events/events'::text,
        '/backend-api/codex/memories/trace_summarize'::text,
        '/backend-api/codex/realtime/calls'::text,
        '/backend-api/codex/safety/arc'::text,
        '/backend-api/codex/agent-identities/jwks'::text,
        '/backend-api/wham/agent-identities/jwks'::text,
        '/backend-api/transcribe'::text,
        '/backend-api/files'::text,
        '/backend-api/files/uploaded'::text,
        '/api/codex/usage'::text,
        '/wham/usage'::text,
        '/backend-api/wham/usage'::text,
        '/v1/models'::text,
        '/v1/usage'::text,
        '/v1/files'::text,
        '/v1/files/content'::text,
        '/v1/files/delete'::text
      ])))
      """
    )
  end
end
