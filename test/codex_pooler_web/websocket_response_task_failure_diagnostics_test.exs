defmodule CodexPoolerWeb.WebsocketResponseTaskFailureDiagnosticsTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.WebsocketResponseTaskFailureDiagnostics

  test "retains bounded PostgreSQL diagnostics without query or parameter content" do
    error = %Postgrex.Error{
      message: "sensitive database message",
      query: "SELECT sensitive_payload FROM requests WHERE id = $1",
      postgres: %{
        code: :unique_violation,
        constraint: "codex_turns_session_sequence_uq",
        table: "codex_turns",
        detail: "Key contains sensitive values"
      }
    }

    stacktrace = [
      {Ecto.Adapters.SQL, :raise_sql_call_error, 1,
       [file: ~c"lib/ecto/adapters/sql.ex", line: 1]},
      {CodexPooler.Gateway.Persistence.SessionContinuity.TurnLifecycle, :start_codex_turn, 3,
       [
         file: ~c"lib/codex_pooler/gateway/persistence/session_continuity/turn_lifecycle.ex",
         line: 1
       ]}
    ]

    assert WebsocketResponseTaskFailureDiagnostics.metadata(error, stacktrace) == [
             postgres_code: "unique_violation",
             failure_operation:
               "CodexPooler.Gateway.Persistence.SessionContinuity.TurnLifecycle.start_codex_turn/3",
             stacktrace_fingerprint: "4fb2824a4782"
           ]

    diagnostics = inspect(WebsocketResponseTaskFailureDiagnostics.metadata(error, stacktrace))
    refute diagnostics =~ "sensitive"
    refute diagnostics =~ "SELECT"
    refute diagnostics =~ "$1"
  end

  test "does not expose PostgreSQL identifiers" do
    error = %Postgrex.Error{
      postgres: %{
        code: :unique_violation,
        constraint: "unsafe value with spaces",
        table: String.duplicate("x", 81)
      }
    }

    assert [
             postgres_code: "unique_violation",
             failure_operation: nil,
             stacktrace_fingerprint: fingerprint
           ] = WebsocketResponseTaskFailureDiagnostics.metadata(error, [])

    assert fingerprint =~ ~r/\A[0-9a-f]{12}\z/
  end
end
