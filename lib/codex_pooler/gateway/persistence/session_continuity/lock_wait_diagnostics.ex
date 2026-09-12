defmodule CodexPooler.Gateway.Persistence.SessionContinuity.LockWaitDiagnostics do
  @moduledoc false

  # Names the transaction that still holds the row a bounded owner renewal gave
  # up on. It runs inside the renewal transaction after the timed-out lock
  # statement was rolled back to its savepoint, while the holder is normally
  # still live: the row's `xmax` records the locking transaction (or a
  # multixact of share lockers), which `pg_stat_activity.backend_xid` maps to a
  # backend. Only bounded facts leave this module; the holder's query text is
  # reduced to a fingerprint here and never returned. Both backend pids are
  # returned so operators can join the Pooler warning to PostgreSQL lock-wait
  # log lines, which name waiter and holder by pid.
  #
  # A blocker that is itself waiting is named by the relation it waits on, and
  # when that wait is on no relation at all -- the key-wide reservation mutex is
  # a transaction-scoped advisory lock -- by the mutex's own bounded label. A
  # holder blocked on the reservation mutex would otherwise report no wait,
  # which is the one case this diagnostic exists to explain.

  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL

  @type relation :: :codex_sessions | :bridge_owner_leases | :unknown

  @type blocker :: %{
          pid: integer(),
          state: String.t() | nil,
          wait_event_type: String.t() | nil,
          transaction_age_ms: integer() | nil,
          application_name: String.t() | nil,
          query_fingerprint: String.t() | nil,
          waiting_relation: String.t() | nil
        }

  @type t :: %{relation: relation(), waiter_pid: integer() | nil, blocker: blocker() | nil}

  @statement_timeout "100ms"
  @fingerprint_length 12

  @blocker_columns """
  a.pid,
  a.state,
  a.wait_event_type,
  (EXTRACT(EPOCH FROM clock_timestamp() - a.xact_start) * 1000)::bigint,
  a.application_name,
  a.query,
  CASE WHEN a.wait_event_type = 'Lock' THEN COALESCE(
    (
      SELECT c.relname
      FROM pg_locks AS l
      JOIN pg_class AS c ON c.oid = l.relation
      WHERE l.pid = a.pid AND (l.locktype = 'tuple' OR NOT l.granted)
      ORDER BY l.granted
      LIMIT 1
    ),
    (
      SELECT CASE
               WHEN l.classid = hashtext('api_key_reservation_window')
                 THEN 'api_key_reservation_window'
               ELSE 'advisory'
             END
      FROM pg_locks AS l
      WHERE l.pid = a.pid AND l.locktype = 'advisory' AND NOT l.granted
      LIMIT 1
    )
  ) END
  """

  @locker_rows %{
    codex_sessions: "SELECT s.xmax AS xmax FROM codex_sessions AS s WHERE s.id = $1",
    bridge_owner_leases: """
    SELECT l.xmax AS xmax
    FROM bridge_owner_leases AS l
    WHERE l.codex_session_id = $1 AND l.status = 'active'
    ORDER BY l.renewed_at DESC, l.created_at DESC
    LIMIT 1
    """
  }

  @spec unresolved(relation()) :: t()
  def unresolved(relation), do: %{relation: relation, waiter_pid: nil, blocker: nil}

  @spec capture(:codex_sessions | :bridge_owner_leases, Ecto.UUID.t()) :: t()
  def capture(relation, session_id) when is_map_key(@locker_rows, relation) do
    _timeout =
      SQL.query!(Repo, "SELECT set_config('statement_timeout', $1, true)", [@statement_timeout],
        mode: :savepoint
      )

    %{rows: [[waiter_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [], mode: :savepoint)
    session_id = Ecto.UUID.dump!(session_id)

    %{
      relation: relation,
      waiter_pid: waiter_pid,
      blocker: single_locker(relation, session_id) || multixact_locker(relation, session_id)
    }
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError, ArgumentError, MatchError] ->
      unresolved(relation)
  end

  defp single_locker(relation, session_id) do
    """
    WITH locker AS (#{Map.fetch!(@locker_rows, relation)})
    SELECT #{@blocker_columns}
    FROM locker
    JOIN pg_stat_activity AS a ON a.backend_xid = locker.xmax AND a.pid <> pg_backend_pid()
    ORDER BY a.xact_start
    LIMIT 1
    """
    |> blocker_row(session_id)
  end

  # A row share-locked by several transactions (for example concurrent
  # foreign-key inserts) records a multixact in `xmax`; its members are the
  # lockers. A value that is not a live multixact raises, which the savepoint
  # contains and which leaves the blocker unresolved.
  defp multixact_locker(relation, session_id) do
    """
    WITH locker AS (#{Map.fetch!(@locker_rows, relation)})
    SELECT #{@blocker_columns}
    FROM locker
    CROSS JOIN LATERAL pg_get_multixact_members(locker.xmax) AS member
    JOIN pg_stat_activity AS a ON a.backend_xid = member.xid AND a.pid <> pg_backend_pid()
    ORDER BY a.xact_start
    LIMIT 1
    """
    |> blocker_row(session_id)
  rescue
    _error in Postgrex.Error -> nil
  end

  defp blocker_row(statement, session_id) do
    case SQL.query!(Repo, statement, [session_id], mode: :savepoint).rows do
      [[pid, state, wait_event_type, age_ms, application_name, query, waiting_relation]] ->
        %{
          pid: pid,
          state: state,
          wait_event_type: wait_event_type,
          transaction_age_ms: age_ms,
          application_name: application_name,
          query_fingerprint: fingerprint(query),
          waiting_relation: waiting_relation
        }

      [] ->
        nil
    end
  end

  defp fingerprint(query) when is_binary(query) and query != "" do
    :sha256
    |> :crypto.hash(query)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @fingerprint_length)
  end

  defp fingerprint(_query), do: nil
end
