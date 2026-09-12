defmodule CodexPooler.Platform.InstancePresenceTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Platform.InstanceHeartbeat
  alias CodexPooler.Platform.InstancePresence
  alias CodexPooler.Platform.InstancePresence.Instance
  alias CodexPooler.Repo

  defp instance_id, do: "codex_pooler@10.0.0.#{System.unique_integer([:positive])}"

  test "record_heartbeat upserts one row and advances only the reporting timestamps" do
    instance = instance_id()

    started_at =
      DateTime.utc_now() |> DateTime.add(-90, :second) |> DateTime.truncate(:microsecond)

    later = DateTime.add(started_at, 45, :second)

    assert {:ok, first} = InstancePresence.record_heartbeat(instance, started_at)
    assert {:ok, second} = InstancePresence.record_heartbeat(instance, later)

    assert first.started_at == started_at
    assert second.last_seen_at == later
    assert Repo.get!(Instance, instance).started_at == started_at
    assert Repo.get!(Instance, instance).last_seen_at == later
    assert Repo.aggregate(Instance, :count, :instance_id) >= 1
  end

  test "absence needs a stale row: unknown and recently reporting instances are present" do
    instance = instance_id()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    refute InstancePresence.absent?(instance, now)
    refute InstancePresence.absent?(nil, now)

    {:ok, _inside_window} =
      InstancePresence.record_heartbeat(instance, DateTime.add(now, -30, :second))

    refute InstancePresence.absent?(instance, now)

    {:ok, _outside_window} =
      InstancePresence.record_heartbeat(instance, DateTime.add(now, -180, :second))

    assert InstancePresence.absent?(instance, now)
  end

  test "the liveness window outlasts the rollout drain budget" do
    # A pod that is still draining is still serving. The window has to clear the
    # largest configured drain budget, otherwise recovery could race a live drain.
    assert InstancePresence.liveness_window_seconds() >= 120
    assert InstancePresence.liveness_window_seconds() * 1000 > 85_000
  end

  test "prune removes long-gone rows and keeps rows recovery still reasons about" do
    gone = instance_id()
    recent = instance_id()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _gone} = InstancePresence.record_heartbeat(gone, DateTime.add(now, -30, :day))
    {:ok, _recent} = InstancePresence.record_heartbeat(recent, DateTime.add(now, -10, :minute))

    assert {:ok, %{instance_presence_rows_pruned: pruned}} = InstancePresence.prune(now)
    assert pruned >= 1
    refute Repo.get(Instance, gone)
    assert Repo.get(Instance, recent)
  end

  test "the heartbeat process publishes this instance's row on start" do
    instance = instance_id()

    pid =
      start_supervised!(
        {InstanceHeartbeat,
         enabled: true, instance_id: instance, interval_ms: 60_000, name: :instance_presence_test}
      )

    # The publish runs in the process's own continue, so one synchronous state
    # read is enough to know it has happened; no timer is waited out.
    _state = :sys.get_state(pid)

    assert %Instance{} = Repo.get(Instance, instance)
  end

  test "the heartbeat process does not start when it is disabled" do
    assert :ignore =
             InstanceHeartbeat.start_link(enabled: false, name: :instance_presence_disabled_test)
  end
end
