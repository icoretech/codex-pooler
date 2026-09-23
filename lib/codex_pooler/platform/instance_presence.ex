defmodule CodexPooler.Platform.InstancePresence do
  @moduledoc """
  Shared-Postgres presence for the running application instances.

  Every instance publishes one row keyed by its identity and refreshes
  `last_seen_at` on an interval (`CodexPooler.Platform.InstanceHeartbeat`).
  Recovery uses this table to find stale-owner candidates. A stale heartbeat
  cannot distinguish a killed VM from a live VM unable to reach PostgreSQL.
  Modern execution recovery therefore requires exact execution-death evidence.

  Identity is the node name *and* the VM incarnation that minted it
  (`CodexPooler.Platform.InstancePresence.Identity`). The node name alone
  derives from the pod IP, so a container that restarts in place reuses it and
  republishes against its predecessor's row; that row then never goes stale and
  the orphans the previous VM left behind can never be recovered. One row per
  incarnation means each VM's row ages on its own schedule, including the two
  incarnations of one in-place restart.

  Absence is deliberately one-directional. An instance counts as absent only
  when its row exists *and* has not been refreshed inside the liveness window;
  a missing row means "unknown", never "gone", so an instance that never
  published (an older release, a failed first write) keeps its work and falls
  back to the six-hour stale-reservation sweep. A stale row alone is never
  proof that its owner ended (a live owner's heartbeat writes can fail); a
  *later-started* incarnation publishing under the same node name is, because
  a node name is held by one VM at a time, and `nonode@nohost`, the name every
  undistributed VM shares, is excluded (`superseded?/1`). Presence is
  therefore safe to miss and never safe to invent.

  The candidate window is eight heartbeat intervals and exceeds the rollout
  drain budget. It is not an outage-safety guarantee. Recovery requires a
  fresh observer; modern attempts additionally require exact death evidence.
  Unreachable executions remain unknown and retain the six-hour fallback.
  """

  import Ecto.Query

  alias CodexPooler.Platform.InstancePresence.{Identity, Instance}
  alias CodexPooler.Repo

  @heartbeat_interval_ms 15_000
  @heartbeat_write_budget_ms 1_000
  @liveness_window_seconds 120
  @retention_seconds 7 * 24 * 60 * 60

  @type prune_summary :: %{required(:instance_presence_rows_pruned) => non_neg_integer()}

  @spec heartbeat_interval_ms() :: pos_integer()
  def heartbeat_interval_ms, do: @heartbeat_interval_ms

  @spec liveness_window_seconds() :: pos_integer()
  def liveness_window_seconds, do: @liveness_window_seconds

  @doc """
  Identity of the instance this process runs on.
  """
  @spec local_identity() :: Identity.t()
  def local_identity, do: Identity.local()

  @spec record_heartbeat(Identity.t()) :: {:ok, Instance.t()} | {:error, term()}
  def record_heartbeat(identity \\ local_identity()) do
    options = heartbeat_query_options()
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [], options)
    insert_heartbeat(identity, now, options)
  end

  @spec record_heartbeat(Identity.t(), DateTime.t()) :: {:ok, Instance.t()} | {:error, term()}
  def record_heartbeat(%Identity{} = identity, %DateTime{} = now),
    do: insert_heartbeat(identity, now, heartbeat_query_options())

  # One budget for the whole beat. DBConnection enforces it by disconnecting the
  # pooled connection the write holds; without `checkout_retries: 0` a statement
  # cut while it was being prepared is retried on another connection, which the
  # already expired deadline disconnects too (or, for a statement without a
  # deadline, waits out a second budget). A database stall then cost every
  # role's pool two connections per missed beat (findings#206 row 206-358).
  defp heartbeat_query_options do
    [timeout: @heartbeat_write_budget_ms, deadline: System.monotonic_time(:millisecond) + @heartbeat_write_budget_ms, checkout_retries: 0]
  end

  defp insert_heartbeat(%Identity{} = identity, %DateTime{} = now, options) do
    now = DateTime.truncate(now, :microsecond)

    Repo.insert(
      %Instance{
        instance_id: identity.instance_id,
        node_name: identity.node_name,
        boot_id: identity.boot_id,
        started_at: now,
        last_seen_at: now,
        updated_at: now
      },
      [on_conflict: [set: [last_seen_at: now, updated_at: now]], conflict_target: :instance_id] ++ options
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
  Whether `identity` has a presence row that stopped being refreshed.

  Unknown incarnations and incarnations still inside the liveness window answer
  `false`: an existing stale row is only an absence candidate. An owner
  that names no incarnation — `nil`, or an attempt written before incarnations
  existed — answers `false` as well.
  """
  @spec absent?(Identity.t() | nil, DateTime.t(), keyword()) :: boolean()
  def absent?(identity, now, opts \\ [])

  def absent?(
        %Identity{node_name: node_name, boot_id: boot_id} = identity,
        %DateTime{} = now,
        opts
      ) do
    cutoff = absent_cutoff(now, opts)

    identity != local_identity() and
      Repo.exists?(
        from instance in Instance,
          where:
            instance.node_name == ^node_name and instance.boot_id == ^boot_id and
              instance.last_seen_at <= ^cutoff
      )
  end

  def absent?(_identity, %DateTime{}, _opts), do: false

  @doc """
  Whether a newer incarnation of the same node name has published presence.

  A node name is held by one VM at a time (the pod address when clustered, the
  pod hostname otherwise), so a successor incarnation publishing under it is
  exact proof that the older VM is gone: it is the in-place container restart
  that a stale row alone could never distinguish from a live owner whose
  heartbeat writes fail. Rows are compared by their own `started_at`, both
  written from the database clock. The anonymous `nonode@nohost` name is shared
  by every undistributed VM and proves nothing. The premise is one name per
  live VM: an operator who pins one fixed `RELEASE_NODE` for several VMs that
  run concurrently against one database would defeat it (nothing in the chart
  or the self-host compose does so, and such VMs would already collide on
  epmd inside a shared network namespace).
  """
  @spec superseded?(Identity.t() | nil) :: boolean()
  def superseded?(%Identity{node_name: "nonode@nohost"}), do: false

  def superseded?(%Identity{node_name: node_name, boot_id: boot_id, instance_id: instance_id}) do
    Repo.exists?(
      from newer in Instance,
        join: older in Instance,
        on: older.node_name == newer.node_name,
        where:
          older.instance_id == ^instance_id and newer.node_name == ^node_name and
            newer.boot_id != ^boot_id and newer.started_at > older.started_at
    )
  end

  def superseded?(_identity), do: false

  @doc "A stale observer cannot authorize another incarnation's absence recovery."
  @spec observer_fresh?(DateTime.t(), keyword()) :: boolean()
  def observer_fresh?(now, opts \\ []) do
    local = local_identity()
    cutoff = absent_cutoff(now, opts)

    Repo.exists?(
      from instance in Instance,
        where: instance.instance_id == ^local.instance_id and instance.last_seen_at > ^cutoff
    )
  end

  @doc "Exact reachable VM identity; missing connectivity remains unknown."
  @spec status(Identity.t() | nil) :: :alive | :dead | :unknown
  def status(%Identity{} = identity) do
    case Enum.find([node() | Node.list()], &(Atom.to_string(&1) == identity.node_name)) do
      nil ->
        :unknown

      target when target == node() ->
        compare_identity(identity, local_identity())

      target ->
        compare_identity(identity, :erpc.call(target, __MODULE__, :local_identity, [], 1_000))
    end
  catch
    _, _ -> :unknown
  end

  def status(_identity), do: :unknown

  defp compare_identity(identity, identity), do: :alive
  defp compare_identity(%Identity{node_name: "nonode@nohost"}, %Identity{}), do: :unknown
  defp compare_identity(%Identity{node_name: name}, %Identity{node_name: name}), do: :dead
  defp compare_identity(_expected, _actual), do: :unknown

  @spec database_now() :: DateTime.t()
  def database_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    now
  end

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
end
