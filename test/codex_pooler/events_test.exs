defmodule CodexPooler.EventsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Events
  alias CodexPooler.Events.Event
  alias CodexPooler.Events.PostgresBridge

  import CodexPooler.PoolerFixtures

  test "broadcasts exact pool event shapes for LiveView topics" do
    pool = pool_fixture()
    assert :ok = Events.subscribe_pool(pool.id)

    assert {:ok, request_logs} =
             publish_from_task(fn ->
               Events.broadcast_request_logs(pool.id, "request_log_created", %{
                 request_id: "request-test"
               })
             end)

    assert_receive {Events, ^request_logs}
    assert_event_shape(request_logs, pool.id, ["request_logs"], "request_log_created")
    assert request_logs.payload == %{"request_id" => "request-test"}

    assert {:ok, usage} =
             publish_from_task(fn ->
               Events.broadcast_usage(pool.id, "usage_updated", %{request_count: 1})
             end)

    assert_receive {Events, ^usage}
    assert_event_shape(usage, pool.id, ["usage"], "usage_updated")
    assert usage.payload == %{"request_count" => 1}

    assert {:ok, job_status} =
             publish_from_task(fn ->
               Events.broadcast_job_status(pool.id, "job_status_updated", %{
                 id: "job-test",
                 status: "complete"
               })
             end)

    assert_receive {Events, ^job_status}
    assert_event_shape(job_status, pool.id, ["job_status"], "job_status_updated")
    assert job_status.payload == %{"id" => "job-test", "status" => "complete"}

    assert {:ok, model_sync} =
             publish_from_task(fn ->
               Events.broadcast_model_sync(pool.id, "model_sync_completed", %{status: "succeeded"})
             end)

    assert_receive {Events, ^model_sync}
    assert_event_shape(model_sync, pool.id, ["model_sync"], "model_sync_completed")
    assert model_sync.payload == %{"status" => "succeeded"}

    assert {:ok, pools} =
             publish_from_task(fn ->
               Events.broadcast_pools(pool.id, "pool_routing_settings_updated", %{
                 routing_strategy: "bridge_ring"
               })
             end)

    assert_receive {Events, ^pools}
    assert_event_shape(pools, pool.id, ["pools"], "pool_routing_settings_updated")
    assert pools.payload == %{"routing_strategy" => "bridge_ring"}

    assert {:ok, upstreams} =
             publish_from_task(fn ->
               Events.broadcast_upstreams(pool.id, "upstream_account_imported", %{
                 upstream_identity_id: "upstream-test"
               })
             end)

    assert_receive {Events, ^upstreams}
    assert_event_shape(upstreams, pool.id, ["upstreams"], "upstream_account_imported")
    assert upstreams.payload == %{"upstream_identity_id" => "upstream-test"}
  end

  test "does not deliver local pool events back to the broadcasting subscriber" do
    pool = pool_fixture()
    assert :ok = Events.subscribe_pool(pool.id)

    assert {:ok, event} = Events.broadcast_pools(pool.id, "pool_routing_settings_updated", %{})

    refute_receive {Events, ^event}
  end

  test "rejects invalid event topics" do
    pool = pool_fixture()

    assert {:error, :invalid_topics} =
             Events.broadcast_pool_event(pool.id, ["unknown"], "invalid", %{})
  end

  test "relays postgres notification payloads back into local pool PubSub" do
    pool = pool_fixture()
    assert :ok = Events.subscribe_pool(pool.id)

    event = %Event{
      version: 1,
      id: Ecto.UUID.generate(),
      pool_id: pool.id,
      topics: ["upstreams"],
      reason: "upstream_quota_windows_updated",
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      payload: %{"upstream_identity_id" => Ecto.UUID.generate()}
    }

    assert {:ok, payload} = Events.event_to_postgres_payload(event)
    assert :ok = publish_from_task(fn -> PostgresBridge.relay_payload(payload) end)

    assert_receive {Events, ^event}
  end

  defp publish_from_task(fun) when is_function(fun, 0) do
    fun
    |> Task.async()
    |> Task.await(5_000)
  end

  defp assert_event_shape(event, pool_id, topics, reason) do
    assert %Events.Event{
             version: 1,
             pool_id: ^pool_id,
             topics: ^topics,
             reason: ^reason,
             payload: payload
           } = event

    assert is_binary(event.id)
    assert {:ok, _uuid} = Ecto.UUID.cast(event.id)
    assert %DateTime{} = event.emitted_at
    assert is_map(payload)
  end
end
