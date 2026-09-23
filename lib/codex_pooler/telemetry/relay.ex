defmodule CodexPooler.Telemetry.Relay do
  @moduledoc false
  import Ecto.Query
  alias CodexPooler.{Repo, Telemetry.RelayEvent}

  @heartbeat_stale_seconds 60
  @cleanup_batch_size 100

  # `rejected_sample` is a sample the storage layer will never accept, counted
  # where it is refused rather than re-queued into a buffer slot it can never
  # leave. The other three are rows or samples lost to time, space and
  # shutdown.
  @loss_reasons ["expired_unclaimed", "buffer_overflow", "shutdown_unflushed", "rejected_sample"]
  @checkpointed_loss_reasons ["buffer_overflow", "shutdown_unflushed", "rejected_sample"]

  @doc false
  @spec loss_reasons() :: [String.t()]
  def loss_reasons, do: @loss_reasons

  @spec record_loss(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def record_loss(reason, rows, samples) when reason in @loss_reasons do
    Repo.query!(
      """
      INSERT INTO telemetry_relay_losses(reason, rows, samples) VALUES ($1,$2,$3)
      ON CONFLICT(reason) DO UPDATE SET rows=telemetry_relay_losses.rows+EXCLUDED.rows,
        samples=telemetry_relay_losses.samples+EXCLUDED.samples
      """,
      [reason, rows, samples]
    )

    :ok
  end

  @spec checkpoint_loss(String.t(), String.t(), non_neg_integer()) ::
          {:ok, :ok} | {:error, term()}
  def checkpoint_loss(owner, reason, total)
      when is_binary(owner) and reason in @checkpointed_loss_reasons and
             is_integer(total) and total >= 0 do
    Repo.transaction(
      fn ->
        Repo.query!(
          "INSERT INTO telemetry_relay_loss_checkpoints(owner,reason,samples,updated_at) VALUES ($1,$2,0,clock_timestamp()) ON CONFLICT DO NOTHING",
          [owner, reason]
        )

        %{rows: [[previous]]} =
          Repo.query!(
            "SELECT samples FROM telemetry_relay_loss_checkpoints WHERE owner=$1 AND reason=$2 FOR UPDATE",
            [owner, reason]
          )

        delta = max(total - previous, 0)
        if delta > 0, do: record_loss(reason, 0, delta)

        Repo.query!(
          "UPDATE telemetry_relay_loss_checkpoints SET samples=GREATEST(samples,$3),updated_at=clock_timestamp() WHERE owner=$1 AND reason=$2",
          [owner, reason, total]
        )

        :ok
      end,
      bounded_write_options()
    )
  end

  @spec consumer_heartbeat(String.t(), boolean()) :: :ok
  def consumer_heartbeat(owner, quiesced \\ false) do
    Repo.query!(
      "INSERT INTO telemetry_relay_consumers(owner,heartbeat_at,quiesced) VALUES ($1,clock_timestamp(),$2) ON CONFLICT(owner) DO UPDATE SET heartbeat_at=EXCLUDED.heartbeat_at,quiesced=EXCLUDED.quiesced",
      [owner, quiesced],
      bounded_write_options()
    )

    :ok
  end

  @spec health() :: map()
  def health do
    %{rows: [[rows, samples]]} =
      Repo.query!("SELECT count(*),COALESCE(sum(count),0)::bigint FROM telemetry_relay_events WHERE claimed_at IS NULL")

    %{rows: [[consumers]]} =
      Repo.query!("SELECT count(*) FROM telemetry_relay_consumers WHERE NOT quiesced AND heartbeat_at > clock_timestamp()-interval '60 seconds'")

    %{rows: losses} = Repo.query!("SELECT reason,rows,samples FROM telemetry_relay_losses")
    %{backlog_rows: rows, backlog_samples: samples, fresh_consumers: consumers, losses: losses}
  end

  @spec prune_heartbeats() :: :ok
  def prune_heartbeats do
    Repo.query!("DELETE FROM telemetry_relay_loss_checkpoints WHERE ctid IN (SELECT c.ctid FROM telemetry_relay_loss_checkpoints c WHERE c.updated_at<clock_timestamp()-interval '7 days' AND NOT EXISTS (SELECT 1 FROM telemetry_relay_heartbeats h WHERE h.owner=c.owner AND h.heartbeat_at>clock_timestamp()-interval '7 days') LIMIT 100 FOR UPDATE SKIP LOCKED)")

    for {table, timestamp} <- [
          {"telemetry_relay_heartbeats", "heartbeat_at"},
          {"telemetry_relay_consumers", "heartbeat_at"}
        ] do
      Repo.query!("DELETE FROM #{table} WHERE ctid IN (SELECT ctid FROM #{table} WHERE #{timestamp}<clock_timestamp()-interval '7 days' LIMIT 100 FOR UPDATE SKIP LOCKED)")
    end

    :ok
  end

  def refresh_heartbeat(owner) when is_binary(owner) do
    case Repo.query(
           "INSERT INTO telemetry_relay_heartbeats (owner, heartbeat_at) VALUES ($1, NOW()) ON CONFLICT (owner) DO UPDATE SET heartbeat_at = EXCLUDED.heartbeat_at",
           [owner],
           bounded_write_options()
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  def heartbeat_fresh?(owner) when is_binary(owner) do
    case Repo.query(
           "SELECT heartbeat_at > NOW() - ($2 * INTERVAL '1 second') FROM telemetry_relay_heartbeats WHERE owner = $1",
           [owner, @heartbeat_stale_seconds],
           query_options()
         ) do
      {:ok, %{rows: [[fresh]]}} -> fresh
      _ -> false
    end
  end

  def insert(event, labels, count \\ 1, measurements \\ %{}, owner \\ "relay-runtime") do
    if heartbeat_fresh?(owner),
      do: do_insert(event, labels, count, measurements),
      else: {:error, :stale_heartbeat}
  end

  defp do_insert(event, labels, count, measurements) do
    %RelayEvent{}
    |> RelayEvent.changeset(%{
      event: event,
      labels: labels,
      count: count,
      measurements: measurements,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert(query_options())
  end

  # Heartbeat and checkpoint writes get one second in total. DBConnection
  # enforces it by disconnecting the pooled connection; `checkout_retries: 0`
  # keeps a statement cut while it was being prepared from being retried on a
  # second connection that the expired deadline would disconnect as well
  # (findings#206 row 206-358).
  defp bounded_write_options do
    [timeout: 1_000, deadline: System.monotonic_time(:millisecond) + 1_000, checkout_retries: 0]
  end

  defp query_options do
    case Process.get({CodexPooler.Telemetry.RelayRuntime, :flush_deadline}) do
      deadline when is_integer(deadline) ->
        [deadline: deadline, timeout: max(deadline - System.monotonic_time(:millisecond), 1), checkout_retries: 0]

      _ ->
        []
    end
  end

  def claim(limit \\ 100, owner \\ "relay") do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL statement_timeout = '5s'")

      from(e in RelayEvent,
        where: e.inserted_at > ago(1, "hour") and is_nil(e.claimed_at),
        order_by: [asc: e.inserted_at],
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED"
      )
      |> Repo.all()
      |> Enum.map(&Repo.update!(Ecto.Changeset.change(&1, claimed_at: DateTime.utc_now(), claimed_by: owner)))
    end)
  end

  def expire_counted do
    delete_bounded(:hour, dynamic([e], is_nil(e.claimed_at)))
  end

  def prune do
    delete_bounded(
      :day,
      dynamic([_e], true)
    )
  end

  @spec cleanup() :: :more | :done
  def cleanup do
    {expired, _} = expire_counted()
    {pruned, _} = prune()
    :ok = prune_heartbeats()
    if expired == @cleanup_batch_size or pruned == @cleanup_batch_size, do: :more, else: :done
  end

  defp delete_bounded(age, claim_filter) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL statement_timeout = '5s'")

        cutoff =
          if age == :day,
            do: DateTime.add(DateTime.utc_now(), -86_400, :second),
            else: DateTime.add(DateTime.utc_now(), -3_600, :second)

        ids =
          from(e in RelayEvent,
            where: e.inserted_at < ^cutoff,
            where: ^claim_filter,
            order_by: [asc: e.inserted_at, asc: e.id],
            limit: ^@cleanup_batch_size,
            lock: "FOR UPDATE SKIP LOCKED",
            select: {e.id, e.count, e.claimed_at}
          )
          |> Repo.all()

        unclaimed = Enum.filter(ids, fn {_, _, claimed} -> is_nil(claimed) end)
        lost_samples = Enum.reduce(unclaimed, 0, fn {_, count, _}, total -> total + count end)

        if unclaimed != [],
          do: record_loss("expired_unclaimed", length(unclaimed), lost_samples)

        row_ids = Enum.map(ids, &elem(&1, 0))
        Repo.delete_all(from e in RelayEvent, where: e.id in ^row_ids)
      end)

    result
  end
end
