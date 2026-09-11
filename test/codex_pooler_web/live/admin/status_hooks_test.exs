defmodule CodexPoolerWeb.Admin.StatusHooksTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.OpenAIStatus
  alias CodexPooler.Status.Events

  setup :register_and_log_in_user

  test "mounts the aggregate and refreshes on a valid event while paused", %{conn: conn} do
    assert {:ok, _} =
             OpenAIStatus.upsert_feed_state(%{
               aggregate_revision: 101,
               active_count: 3,
               updated_at: DateTime.utc_now()
             })

    {:ok, view, _html} = live(conn, "/admin/request-logs")
    state = :sys.get_state(view.pid).socket.assigns
    assert is_map(state.openai_status_aggregate)

    Phoenix.LiveViewTest.render_hook(view, "set_live_updates", %{"paused" => true})

    assert {:ok, _} =
             OpenAIStatus.upsert_feed_state(%{
               aggregate_revision: 102,
               active_count: 4,
               updated_at: DateTime.utc_now()
             })

    event = %{
      event_version: 1,
      changed_count: 1,
      active_count: 4,
      aggregate_revision: 102,
      emitted_at: DateTime.utc_now()
    }

    assert {:ok, event} = Events.decode(event)
    send(view.pid, {:openai_status_updated, event})

    _ = render(view)

    assert :sys.get_state(view.pid).socket.assigns.openai_status_aggregate.aggregate_revision ==
             102

    assert :sys.get_state(view.pid).socket.assigns.live_updates_paused? == true
  end

  test "ignores stale and malformed status events", %{conn: conn} do
    assert {:ok, _} =
             OpenAIStatus.upsert_feed_state(%{
               aggregate_revision: 7,
               active_count: 1,
               updated_at: DateTime.utc_now()
             })

    {:ok, view, _html} = live(conn, "/admin/request-logs")
    assert :sys.get_state(view.pid).socket.assigns.openai_status_aggregate.aggregate_revision == 7
    send(view.pid, {:openai_status_updated, %{event_version: 2, aggregate_revision: 999}})
    send(view.pid, {:openai_status_updated, "raw"})
    _ = :sys.get_state(view.pid)
    assert :sys.get_state(view.pid).socket.assigns.openai_status_aggregate.aggregate_revision == 7
  end
end
