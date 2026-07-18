defmodule CodexPooler.Accounting.ObservatoryDashboardPrincipalSupport do
  @moduledoc false

  alias CodexPooler.Accounting.{Attempt, DailyRollup, LedgerEntry, Request, RequestLogFact}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Repo

  def bucket_signature(bucket) do
    {
      bucket.requests.total,
      bucket.requests.succeeded,
      bucket.requests.failed,
      bucket.requests.in_progress,
      bucket.tokens.total,
      bucket.cost.settled.status,
      bucket.cost.settled.micros,
      bucket.cost.estimated.status,
      bucket.cost.estimated.micros,
      bucket.cost.unavailable_requests
    }
  end

  def collect_repo_queries(fun, metadata? \\ false) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          value =
            if metadata?,
              do: inspect(metadata, limit: :infinity),
              else: get_in(metadata, [:options, :reporting_projection])

          send(test_pid, {handler_id, value})
        end,
        nil
      )

    try do
      {fun.(), drain(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  def accounting_counts do
    %{
      attempts: Repo.aggregate(Attempt, :count, :id),
      daily_rollups: Repo.aggregate(DailyRollup, :count, :id),
      ledger_entries: Repo.aggregate(LedgerEntry, :count, :id),
      request_log_facts: Repo.aggregate(RequestLogFact, :count, :request_id),
      requests: Repo.aggregate(Request, :count, :id)
    }
  end

  def audit_count, do: Repo.aggregate(AuditEvent, :count)

  defp drain(handler_id, values) do
    receive do
      {^handler_id, value} -> drain(handler_id, [value | values])
    after
      0 -> Enum.reverse(values)
    end
  end
end
