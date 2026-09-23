defmodule CodexPooler.Platform.TransientDatabaseError do
  @moduledoc """
  Recognizes a database failure that says nothing about the work that met it.

  The database could not be reached or stopped answering in time
  (`DBConnection.ConnectionError`: a refused or dropped connection, a pool
  queue that dropped the checkout, a statement that outlived its client-side
  timeout), or PostgreSQL reported a connection, shutdown, start-up, resource
  or cancellation condition. Retrying the same work later can succeed; a
  constraint, a syntax error or a missing column cannot, so those stay out.

  Readiness uses the same list to tell connectivity from schema problems, and
  the runtime surfaces use it to answer a retryable `503` before any work was
  reserved or sent instead of letting the exception render a `500`
  (findings#206 row 206-358).
  """

  @postgres_codes [
    :admin_shutdown,
    :cannot_connect_now,
    :connection_does_not_exist,
    :connection_exception,
    :connection_failure,
    :crash_shutdown,
    :database_dropped,
    :query_canceled,
    :sqlclient_unable_to_establish_sqlconnection,
    :sqlserver_rejected_establishment_of_sqlconnection,
    :too_many_connections,
    :transaction_resolution_unknown
  ]

  @doc "PostgreSQL error codes that count as transient."
  @spec postgres_codes() :: [atom()]
  def postgres_codes, do: @postgres_codes

  @doc "Whether `error` is a transient database failure."
  @spec transient?(term()) :: boolean()
  def transient?(%DBConnection.ConnectionError{}), do: true
  def transient?(%Postgrex.Error{postgres: %{code: code}}) when code in @postgres_codes, do: true
  def transient?(_error), do: false

  @doc """
  A bounded token naming the failure for a log line: the exception module, or
  the PostgreSQL condition name. Messages, which can quote statements and
  parameters, never reach it.
  """
  @spec reason_class(Exception.t()) :: String.t()
  def reason_class(%Postgrex.Error{postgres: %{code: code}}) when code in @postgres_codes, do: "postgres_" <> Atom.to_string(code)
  def reason_class(%module{}), do: inspect(module)
end
