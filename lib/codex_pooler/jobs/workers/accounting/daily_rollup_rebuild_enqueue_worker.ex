defmodule CodexPooler.Jobs.DailyRollupRebuildEnqueueWorker do
  @moduledoc """
  Periodically enqueues daily rollup rebuilds for every completed UTC day whose coverage is
  missing, incomplete, incompatible or published before the day ended.

  The first pass after 00:00 UTC rebuilds the previous day, which has no coverage row yet. Later
  passes repair what that one rebuild cannot: a day whose rebuild never ran or never committed,
  a day changed after its rebuild (a commit that crossed midnight after the rebuild, a Pool
  deletion, a rebuild that lost its race with a concurrent write), within the lookback that
  `CodexPooler.Accounting.daily_rollup_dates_needing_rebuild/1` bounds and batch-limits. Each
  day goes through `CodexPooler.Jobs.enqueue_daily_rollup_rebuild/2`, so a day already queued
  or running is not enqueued twice. A pass with nothing to repair enqueues nothing.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 3,
    tags: ["daily_rollup_rebuild_enqueue"],
    unique: [
      fields: [:worker, :queue],
      states: :incomplete,
      period: {1, :day}
    ]

  require Logger

  alias CodexPooler.Accounting
  alias CodexPooler.Jobs

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    dates = Accounting.daily_rollup_dates_needing_rebuild()
    log_repaired_days(dates)

    failed =
      dates
      |> Enum.map(&Jobs.enqueue_daily_rollup_rebuild/1)
      |> Enum.count(&match?({:error, _reason}, &1))

    if failed == 0, do: :ok, else: {:error, {:enqueue_failed, failed}}
  end

  # The previous day is the ordinary nightly rebuild; any older day means a rebuild did not
  # publish or a day changed after it, which nothing else records once Oban prunes the job.
  defp log_repaired_days(dates) do
    yesterday = Date.add(Date.utc_today(), -1)

    case Enum.filter(dates, &(Date.compare(&1, yesterday) == :lt)) do
      [] ->
        :ok

      older ->
        Logger.info(
          "daily rollup coverage repair enqueued #{length(older)} rebuild(s) for days before the previous UTC day: " <>
            Enum.map_join(older, ",", &Date.to_iso8601/1)
        )
    end
  end
end
