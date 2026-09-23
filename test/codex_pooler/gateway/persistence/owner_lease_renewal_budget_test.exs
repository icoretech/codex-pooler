defmodule CodexPooler.Gateway.Persistence.OwnerLeaseRenewalBudgetTest do
  # A synchronous owner lease renewal (the HTTP session lease heartbeat's
  # first renewal) bounds its whole transaction with `timeout` plus `deadline`,
  # which DBConnection enforces by disconnecting the pooled connection the
  # renewal holds. When the server stops answering while `BEGIN` is in flight,
  # the disconnect closes the socket under it, Postgrex answers
  # `disconnect_and_retry`, and DBConnection used to check out a second
  # connection under the already expired deadline and disconnect that one too:
  # the heartbeat shape fixed for the presence and relay writes (findings#206
  # rows 206-358 and 206-369). One node, a production-style
  # `DBConnection.ConnectionPool` of two connections behind a stalling proxy.
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Repo
  alias CodexPooler.StallingPostgresProxy

  @budget_ms 1_000

  @tag slow: "the renewal waits out its one-second production budget against a stalled server"
  test "a synchronous renewal that outlives its budget disconnects one pooled connection, not a second one on a retry" do
    proxy = StallingPostgresProxy.start!()
    repo = StallingPostgresProxy.start_repo!(proxy, :owner_lease_renewal_budget_repo, 2)
    StallingPostgresProxy.stall!(proxy)

    # The session and token are never read: the stall holds `BEGIN`, the
    # renewal's first statement.
    session_id = Ecto.UUID.generate()
    lease_token = Ecto.UUID.generate()

    {{outcome, elapsed_ms}, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Task.async(fn ->
          _previous = Repo.put_dynamic_repo(repo)
          started = System.monotonic_time(:millisecond)

          outcome =
            try do
              case SessionContinuity.renew_owner_token(session_id, lease_token, RequestOptions.for_websocket(%{}), lock_timeout_ms: div(@budget_ms, 2), timeout_ms: @budget_ms) do
                {:error, _reason} -> :bounded_failure
                other -> {:returned, other}
              end
            rescue
              _ in [DBConnection.ConnectionError, Postgrex.Error] -> :bounded_failure
            catch
              :exit, _ -> :bounded_failure
            end

          {outcome, System.monotonic_time(:millisecond) - started}
        end)
        |> Task.await(15_000)
      end)

    :ok = stop_supervised(:owner_lease_renewal_budget_repo)
    StallingPostgresProxy.stop!(proxy)

    disconnects = length(Regex.scan(~r/timed out because it queued and checked out the connection/, log))
    # The margin covers the disconnect and scheduling, not a second attempt.
    assert {outcome, disconnects, elapsed_ms < @budget_ms + 500} == {:bounded_failure, 1, true}
  end
end
