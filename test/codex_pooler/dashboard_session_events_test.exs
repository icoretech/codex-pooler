defmodule CodexPooler.DashboardSessionEventsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Events
  alias CodexPooler.Events.Event
  alias CodexPooler.Events.PostgresBridge

  import CodexPooler.PoolerFixtures

  test "the Postgres bridge routes sanitized invalidation to the exact API key topic" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    other_api_key_id = Ecto.UUID.generate()

    assert :ok = Events.subscribe_dashboard_sessions(api_key.id)
    assert :ok = Events.subscribe_dashboard_sessions(other_api_key_id)

    event = dashboard_event(pool.id, api_key.id)

    assert {:ok, payload} = Events.event_to_postgres_payload(event)

    assert :ok =
             Task.async(fn -> PostgresBridge.relay_payload(payload) end)
             |> Task.await(5_000)

    assert_receive {Events, ^event}
    refute_receive {Events, %Event{payload: %{"api_key_id" => ^other_api_key_id}}}

    assert event.payload == %{
             "api_key_id" => api_key.id,
             "cause" => "api_key_rotated",
             "pool_id" => pool.id,
             "status" => "active"
           }
  end

  test "a relayed dashboard event without API key identity is rejected from the key topic" do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    assert :ok = Events.subscribe_dashboard_sessions(api_key.id)

    event = %{dashboard_event(pool.id, api_key.id) | payload: %{"cause" => "api_key_rotated"}}

    assert {:ok, payload} = Events.event_to_postgres_payload(event)

    assert {:error, :api_key_id_required} =
             Task.async(fn -> PostgresBridge.relay_payload(payload) end)
             |> Task.await(5_000)

    refute_receive {Events, ^event}
  end

  defp dashboard_event(pool_id, api_key_id) do
    %Event{
      version: 1,
      id: Ecto.UUID.generate(),
      pool_id: pool_id,
      topics: ["dashboard_sessions"],
      reason: "dashboard_session_invalidated",
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      payload: %{
        "api_key_id" => api_key_id,
        "cause" => "api_key_rotated",
        "pool_id" => pool_id,
        "status" => "active"
      }
    }
  end
end
