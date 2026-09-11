defmodule CodexPooler.Status.EventsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Repo
  alias CodexPooler.Status.Events
  alias Ecto.Adapters.SQL.Sandbox

  test "broadcasts a strict metadata envelope on the global topic" do
    :ok = Events.subscribe()
    at = ~U[2026-09-11 10:00:00.123456Z]

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               Events.broadcast(%{
                 event_version: 1,
                 changed_count: 2,
                 active_count: 1,
                 aggregate_revision: 9,
                 emitted_at: at
               })
             end)

    assert_receive {:openai_status_updated,
                    %{
                      event_version: 1,
                      changed_count: 2,
                      active_count: 1,
                      aggregate_revision: 9,
                      emitted_at: ^at
                    }}
  end

  test "ignores stale, malformed, and raw payloads" do
    refute match?(
             {:ok, _},
             Events.decode(%{
               event_version: 2,
               changed_count: 1,
               active_count: 1,
               aggregate_revision: 1,
               emitted_at: DateTime.utc_now()
             })
           )

    assert :ignore = Events.decode(%{"event_version" => 1, "changed_count" => -1})
    assert :ignore = Events.decode("raw-fragment")

    assert {:ok, _} =
             Events.decode(%{
               "event_version" => 1,
               "changed_count" => 0,
               "active_count" => 0,
               "aggregate_revision" => 0,
               "emitted_at" => "2026-09-11T10:00:00Z"
             })

    assert :ignore =
             Events.decode(%{
               event_version: 1,
               changed_count: 0,
               active_count: 0,
               aggregate_revision: 0,
               emitted_at: ~U[2026-09-11 10:00:00Z],
               provider: "<html>secret</html>"
             })

    assert :ignore =
             Events.decode(%{
               event_version: 1,
               changed_count: 0,
               active_count: 0,
               aggregate_revision: 0,
               emitted_at: "2026-09-11T10:00:00+01:00"
             })

    assert {:error, :invalid_event} = Events.relay_payload("<html>raw</html>")
  end

  test "notification is delivered after commit and not after rollback" do
    :ok = Events.subscribe()
    parent = self()

    subscriber =
      spawn(fn ->
        :ok = Events.subscribe()
        send(parent, :independent_subscriber_ready)

        receive do
          {:openai_status_updated, event} -> send(parent, {:independent_subscriber, event})
        after
          5_000 -> send(parent, :independent_subscriber_timeout)
        end
      end)

    on_exit(fn -> if Process.alive?(subscriber), do: Process.exit(subscriber, :normal) end)
    assert_receive :independent_subscriber_ready

    event = %{
      event_version: 1,
      changed_count: 1,
      active_count: 1,
      aggregate_revision: 10,
      emitted_at: ~U[2026-09-11 10:00:00Z]
    }

    assert {:error, :rolled_back} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 assert :ok = Events.broadcast(event)
                 Repo.rollback(:rolled_back)
               end)
             end)

    refute_receive {:openai_status_updated, _}

    assert {:ok, :committed} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 assert :ok = Events.broadcast(event)
                 :committed
               end)
             end)

    assert_receive {:openai_status_updated, ^event}
    assert_receive {:independent_subscriber, ^event}
  end
end
