defmodule CodexPooler.Platform.InstancePresence do
  @moduledoc """
  Shared-Postgres presence for the running application instances.

  Every instance publishes one row keyed by its node identity and refreshes
  `last_seen_at` on an interval (`CodexPooler.Platform.InstanceHeartbeat`).
  Recovery paths that must decide whether work owned by another instance can
  still be finishing read this table instead of node-local process state: a
  killed pod, a crashed VM, and a drain that ran out of budget all stop
  refreshing, while node-local registries only ever see the current node.

  Absence is deliberately one-directional. An instance counts as absent only
  when its row exists *and* has not been refreshed inside the liveness window;
  a missing row means "unknown", never "gone", so an instance that never
  published (an older release, a failed first write) keeps its work and falls
  back to the six-hour stale-reservation sweep. Presence is therefore safe to
  miss and never safe to invent.

  The liveness window is eight heartbeat intervals. It has to outlast a
  scheduler stall, a brief database outage, and the full rollout drain budget,
  because an instance that is still draining is still serving; two minutes
  clears the 50–85 s drain budget with room to spare while keeping recovery on
  a minutes-scale instead of the six-hour backstop.
  """

  import Ecto.Query

  alias CodexPooler.Platform.InstancePresence.Instance
  alias CodexPooler.Repo

  @heartbeat_interval_ms 15_000
  @liveness_window_seconds 120
  @retention_seconds 7 * 24 * 60 * 60

  @type prune_summary :: %{required(:instance_presence_rows_pruned) => non_neg_integer()}

  @spec heartbeat_interval_ms() :: pos_integer()
  def heartbeat_interval_ms, do: @heartbeat_interval_ms

  @spec liveness_window_seconds() :: pos_integer()
  def liveness_window_seconds, do: @liveness_window_seconds

  @doc """
  Identity of the instance this process runs on.

  The node name is already the durable owner identity for websocket sessions
  and owner leases, so attempts record the same value and the two ownership
  stories stay comparable.
  """
  @spec local_instance_id() :: String.t()
  def local_instance_id, do: Atom.to_string(node())

  @spec record_heartbeat(String.t(), DateTime.t()) :: {:ok, Instance.t()} | {:error, term()}
  def record_heartbeat(instance_id \\ local_instance_id(), now \\ now())

  def record_heartbeat(instance_id, %DateTime{} = now) when is_binary(instance_id) do
    now = DateTime.truncate(now, :microsecond)

    Repo.insert(
      %Instance{
        instance_id: instance_id,
        started_at: now,
        last_seen_at: now,
        updated_at: now
      },
      on_conflict: [set: [last_seen_at: now, updated_at: now]],
      conflict_target: :instance_id
    )
  end

  @doc """
  Timestamp an instance must have reported after to count as present.
  """
  @spec absent_cutoff(DateTime.t(), keyword()) :: DateTime.t()
  def absent_cutoff(%DateTime{} = now, opts \\ []) do
    DateTime.add(now, -absent_after_seconds(opts), :second)
  end

  @doc """
  Whether `instance_id` has a presence row that stopped being refreshed.

  Unknown instances and instances still inside the liveness window answer
  `false`: only a row that exists and is stale proves the owner is gone.
  """
  @spec absent?(String.t() | nil, DateTime.t(), keyword()) :: boolean()
  def absent?(instance_id, now, opts \\ [])

  def absent?(instance_id, %DateTime{} = now, opts) when is_binary(instance_id) do
    cutoff = absent_cutoff(now, opts)

    Repo.exists?(
      from instance in Instance,
        where: instance.instance_id == ^instance_id and instance.last_seen_at <= ^cutoff
    )
  end

  def absent?(_instance_id, %DateTime{}, _opts), do: false

  @doc """
  Removes presence rows for instances that have been gone far longer than any
  recovery window still cares about.
  """
  @spec prune(DateTime.t(), keyword()) :: {:ok, prune_summary()}
  def prune(%DateTime{} = now, opts \\ []) do
    retention_seconds = Keyword.get(opts, :retention_seconds, @retention_seconds)
    cutoff = DateTime.add(now, -retention_seconds, :second)

    {pruned, _returned} =
      Instance
      |> where([instance], instance.last_seen_at <= ^cutoff)
      |> Repo.delete_all()

    {:ok, %{instance_presence_rows_pruned: pruned}}
  end

  defp absent_after_seconds(opts) do
    case Keyword.get(opts, :absent_after_seconds, @liveness_window_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _invalid -> @liveness_window_seconds
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
