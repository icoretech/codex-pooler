defmodule CodexPooler.Admin.ActivityReadModel do
  @moduledoc """
  Safe recent activity projection for admin dashboards.
  """

  import Ecto.Query

  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Repo

  @type activity_source_counts :: %{
          required(:audit_events) => non_neg_integer(),
          required(:jobs) => non_neg_integer()
        }
  @type activity_summary :: %{
          required(:recent_activity) => [map()],
          required(:source_counts) => activity_source_counts()
        }

  @spec activity_summary_for_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) ::
          activity_summary()
  def activity_summary_for_pool_ids([], _started_at, _ended_at) do
    %{recent_activity: [], source_counts: %{audit_events: 0, jobs: 0}}
  end

  def activity_summary_for_pool_ids(pool_ids, started_at, ended_at) do
    audit_activity = audit_events_for(pool_ids, started_at, ended_at)
    job_activity = jobs_for(pool_ids, started_at, ended_at)

    %{
      recent_activity: recent_activity(audit_activity, job_activity),
      source_counts: %{
        audit_events: source_total(audit_activity),
        jobs: source_total(job_activity)
      }
    }
  end

  @spec recent_activity_for_pool_ids([Ecto.UUID.t()], DateTime.t(), DateTime.t()) :: [map()]
  def recent_activity_for_pool_ids([], _started_at, _ended_at), do: []

  def recent_activity_for_pool_ids(pool_ids, started_at, ended_at) do
    pool_ids
    |> audit_events_for(started_at, ended_at)
    |> recent_activity(jobs_for(pool_ids, started_at, ended_at))
  end

  @spec activity_source_counts([Ecto.UUID.t()], DateTime.t(), DateTime.t()) ::
          activity_source_counts()
  def activity_source_counts([], _started_at, _ended_at), do: %{audit_events: 0, jobs: 0}

  def activity_source_counts(pool_ids, started_at, ended_at) do
    %{
      audit_events: source_total(audit_events_for(pool_ids, started_at, ended_at)),
      jobs: source_total(jobs_for(pool_ids, started_at, ended_at))
    }
  end

  defp audit_events_for(pool_ids, started_at, ended_at) do
    Repo.all(
      from event in AuditEvent,
        where:
          event.pool_id in ^pool_ids and event.occurred_at >= ^started_at and
            event.occurred_at <= ^ended_at,
        windows: [all: []],
        order_by: [desc: event.occurred_at, desc: event.id],
        limit: 10,
        select: %{
          type: :audit_event,
          id: event.id,
          occurred_at: event.occurred_at,
          pool_id: event.pool_id,
          action: event.action,
          target_type: event.target_type,
          outcome: event.outcome,
          source_rank: 0,
          source_order_id: event.id,
          source_total: over(count(event.id), :all)
        }
    )
  end

  defp jobs_for(pool_ids, started_at, ended_at) do
    Repo.all(
      from job in Oban.Job,
        where:
          fragment("?->>?", job.args, "pool_id") in ^pool_ids and
            job.inserted_at >= ^started_at and job.inserted_at <= ^ended_at,
        windows: [all: []],
        order_by: [desc: job.inserted_at, desc: job.id],
        limit: 10,
        select: %{
          type: :job,
          id: job.id,
          occurred_at: job.inserted_at,
          state: job.state,
          worker: job.worker,
          queue: job.queue,
          source_rank: 1,
          source_order_id: fragment("lpad(?::text, 20, '0')", job.id),
          source_total: over(count(job.id), :all)
        }
    )
  end

  defp recent_activity(audit_activity, job_activity) do
    (audit_activity ++ job_activity)
    |> Enum.sort(&activity_before?/2)
    |> Enum.take(10)
    |> Enum.map(&strip_internal_fields/1)
  end

  defp activity_before?(left, right) do
    case DateTime.compare(left.occurred_at, right.occurred_at) do
      :gt -> true
      :lt -> false
      :eq -> activity_tie_before?(left, right)
    end
  end

  defp activity_tie_before?(left, right) do
    cond do
      left.source_rank < right.source_rank -> true
      left.source_rank > right.source_rank -> false
      true -> left.source_order_id > right.source_order_id
    end
  end

  defp source_total([]), do: 0
  defp source_total([%{source_total: source_total} | _rows]), do: source_total

  defp strip_internal_fields(row) do
    Map.drop(row, [:source_rank, :source_order_id, :source_total])
  end
end
