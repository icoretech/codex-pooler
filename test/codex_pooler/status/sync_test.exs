defmodule CodexPooler.Status.SyncTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.OpenAIStatus
  alias CodexPooler.Status.Events
  alias CodexPooler.Status.Schemas.{FeedState, Incident}
  alias CodexPooler.Status.Sync
  alias Ecto.Adapters.SQL.Sandbox

  @notification_timeout 15_000

  defp item(guid, status \\ "Investigating") do
    now = ~U[2026-09-10 10:00:00.000000Z]

    %{
      guid: guid,
      title: "Incident #{guid}",
      status: status,
      active?: status != "Resolved",
      summary: "bounded",
      component: "api",
      link: "https://status.openai.com/incidents/#{guid}",
      published_at: now
    }
  end

  test "persists a parsed poll atomically and emits metadata after commit" do
    now = ~U[2026-09-10 10:00:00.000000Z]
    guid = "committed-#{System.unique_integer([:positive])}"

    fetcher = fn _state, _opts ->
      {:ok, %{items: [item(guid)], content_hash: "feed-1", etag: "e1"}}
    end

    with_committed_status(guid, fn listener ->
      assert {:ok, %{changed_count: 1, active_count: 1, aggregate_revision: 1}} =
               Sync.sync(fetcher: fetcher, now: now)

      assert_status_event(listener, 1, 1, now)
      assert [%{guid: ^guid, first_seen_at: ^now, revision: 1}] = OpenAIStatus.list_incidents()
    end)
  end

  test "increments omissions and retires exactly on the third successful poll, then reopens" do
    now = ~U[2026-09-10 10:00:00.000000Z]
    seed = fn _state, _opts -> {:ok, %{items: [item("a")], content_hash: "feed-1"}} end
    empty = fn _state, _opts -> {:ok, %{items: [], content_hash: "feed-empty"}} end

    assert {:ok, _} = Sync.sync(fetcher: seed, now: now)
    assert {:ok, _} = Sync.sync(fetcher: empty, now: DateTime.add(now, 1, :second))
    assert {:ok, _} = Sync.sync(fetcher: empty, now: DateTime.add(now, 2, :second))

    assert {:ok, %{changed_count: 1}} =
             Sync.sync(fetcher: empty, now: DateTime.add(now, 3, :second))

    retired = hd(OpenAIStatus.list_incidents())
    assert retired.omission_count == 3
    assert retired.retired_at

    assert {:ok, _} = Sync.sync(fetcher: seed, now: DateTime.add(now, 4, :second))
    reopened = hd(OpenAIStatus.list_incidents())
    assert reopened.retired_at == nil
    assert reopened.revision == retired.revision + 1
  end

  test "304 refreshes aggregate metadata while preserving incident revisions and omission state" do
    now = ~U[2026-09-10 10:00:00.000000Z]
    guid = "not-modified-#{System.unique_integer([:positive])}"

    seed = fn _state, _opts ->
      {:ok, %{items: [item(guid)], content_hash: "feed-1", etag: "e1"}}
    end

    not_modified = fn _state, _opts ->
      {:not_modified, %{etag: "e2", last_modified: "yesterday"}}
    end

    with_committed_status(guid, fn listener ->
      assert {:ok, _} = Sync.sync(fetcher: seed, now: now)
      assert_status_event(listener, 1, 1, now)
      incidents = OpenAIStatus.list_incidents()
      refreshed_at = DateTime.add(now, 1, :second)

      assert {:not_modified, %{changed_count: 0, aggregate_revision: 2}} =
               Sync.sync(fetcher: not_modified, now: refreshed_at)

      assert_status_event(listener, 0, 2, refreshed_at)
      assert OpenAIStatus.list_incidents() == incidents
      state = OpenAIStatus.feed_state()
      assert state.etag == "e2"
      assert state.last_modified == "yesterday"
      assert state.last_success_at == refreshed_at
      assert state.last_attempt_at == refreshed_at
    end)
  end

  test "304 from an unchanged or older poll leaves metadata untouched and emits no event" do
    now = ~U[2026-09-10 10:00:00.000000Z]
    guid = "stale-#{System.unique_integer([:positive])}"
    seed = fn _state, _opts -> {:ok, %{items: [item(guid)], content_hash: "feed-1"}} end
    not_modified = fn _state, _opts -> {:not_modified, %{etag: "stale-validator"}} end

    with_committed_status(guid, fn listener ->
      assert {:ok, _} = Sync.sync(fetcher: seed, now: now)
      assert_status_event(listener, 1, 1, now)
      state = OpenAIStatus.feed_state()
      incidents = OpenAIStatus.list_incidents()

      for attempted_at <- [now, DateTime.add(now, -1, :second)] do
        assert {:not_modified, _} = Sync.sync(fetcher: not_modified, now: attempted_at)
        assert OpenAIStatus.feed_state() == state
        assert OpenAIStatus.list_incidents() == incidents
      end

      refute_status_event(listener)
    end)
  end

  test "failure and 304 recovery invalidate aggregate metadata without changing incidents" do
    now = ~U[2026-09-10 10:00:00.000000Z]
    guid = "failure-#{System.unique_integer([:positive])}"
    seed = fn _state, _opts -> {:ok, %{items: [item(guid)], content_hash: "feed-1"}} end
    failure = fn _state, _opts -> {:error, %{code: :upstream_unavailable, message: "ignored"}} end

    with_committed_status(guid, fn listener ->
      assert {:ok, _} = Sync.sync(fetcher: seed, now: now)
      assert_status_event(listener, 1, 1, now)
      incidents = OpenAIStatus.list_incidents()
      failed_at = DateTime.add(now, 1, :second)

      assert {:error, %{code: "upstream_unavailable"}} =
               Sync.sync(fetcher: failure, now: failed_at)

      assert_status_event(listener, 0, 2, failed_at)
      assert OpenAIStatus.list_incidents() == incidents
      assert OpenAIStatus.feed_state().last_success_at == now
      assert OpenAIStatus.feed_state().last_error_code == "upstream_unavailable"

      recovered_at = DateTime.add(now, 2, :second)

      assert {:not_modified, %{changed_count: 0, aggregate_revision: 3}} =
               Sync.sync(fetcher: fn _, _ -> {:not_modified, %{}} end, now: recovered_at)

      assert_status_event(listener, 0, 3, recovered_at)
      assert OpenAIStatus.list_incidents() == incidents
      assert OpenAIStatus.feed_state().last_success_at == recovered_at
      assert OpenAIStatus.feed_state().last_error_code == nil
      assert OpenAIStatus.feed_state().last_error_at == nil
    end)
  end

  test "preserves transient network failures for worker retry classification" do
    now = ~U[2026-09-10 10:00:00.000000Z]

    assert {:error, %{code: "network_error"}} =
             Sync.sync(
               fetcher: fn _state, _opts ->
                 {:error, %{code: :network_error, message: "transport unavailable"}}
               end,
               now: now
             )

    assert OpenAIStatus.feed_state().last_error_code == "network_error"
  end

  test "an enclosing rollback removes sync rows and suppresses its notification" do
    now = ~U[2026-09-10 10:00:00.000000Z]
    guid = "rollback-#{System.unique_integer([:positive])}"

    with_committed_status(guid, fn listener ->
      assert {:error, :rolled_back} =
               Repo.transaction(fn ->
                 assert {:ok, _} =
                          Sync.sync(
                            fetcher: fn _, _ -> {:ok, %{items: [item(guid)]}} end,
                            now: now
                          )

                 assert [%{guid: ^guid}] = OpenAIStatus.list_incidents()
                 Repo.rollback(:rolled_back)
               end)

      assert OpenAIStatus.list_incidents() == []
      assert OpenAIStatus.feed_state() == nil
      refute_status_event(listener)
    end)
  end

  test "persists normalized feed summaries up to the parser limit" do
    now = ~U[2026-09-10 10:00:00.000000Z]
    summary = String.duplicate("status detail ", 50)

    fetcher = fn _state, _opts ->
      {:ok, %{items: [%{item("long-summary") | summary: summary}], content_hash: "feed-long"}}
    end

    assert {:ok, %{changed_count: 1, active_count: 1}} =
             Sync.sync(fetcher: fetcher, now: now)

    assert [%{summary: ^summary}] = OpenAIStatus.list_incidents()
  end

  test "preserves prior incidents and records bounded metadata for invalid items" do
    now = ~U[2026-09-10 10:00:00.000000Z]
    seed = fn _state, _opts -> {:ok, %{items: [item("existing")], content_hash: "feed-1"}} end

    invalid = fn _state, _opts ->
      {:ok,
       %{
         items: [item("partial"), %{item("invalid") | title: String.duplicate("x", 4_001)}],
         content_hash: "feed-2"
       }}
    end

    assert {:ok, _} = Sync.sync(fetcher: seed, now: now)

    assert {:error, %{code: "invalid_feed"}} =
             Sync.sync(fetcher: invalid, now: DateTime.add(now, 1, :second))

    assert [%{guid: "existing"}] = OpenAIStatus.list_incidents()
    assert OpenAIStatus.feed_state().last_error_code == "invalid_feed"
  end

  test "cleanup deletes only old resolved or retired rows and is idempotent" do
    old = ~U[2026-01-01 00:00:00.000000Z]
    now = ~U[2026-09-10 10:00:00.000000Z]

    assert {:ok, resolved} =
             OpenAIStatus.upsert_incident(
               Map.put(item("resolved", "Resolved"), :content_hash, "h"),
               old
             )

    assert {:ok, _active} =
             OpenAIStatus.upsert_incident(Map.put(item("active"), :content_hash, "h2"), now)

    assert {:ok, 1} = Sync.cleanup(now, retention_days: 90, batch_size: 10)
    assert Enum.map(OpenAIStatus.list_incidents(), & &1.guid) == ["active"]
    assert {:ok, 0} = Sync.cleanup(now, retention_days: 90, batch_size: 10)
    refute Repo.get(CodexPooler.Status.Schemas.Incident, resolved.id)
  end

  defp with_committed_status(guid, fun) do
    :ok = OpenAIStatus.subscribe()
    assert %{status_listen_ref: bridge_ref} = :sys.get_state(CodexPooler.Events.PostgresBridge)
    assert is_reference(bridge_ref)

    notifications =
      start_supervised!(
        {Postgrex.Notifications,
         Keyword.take(Repo.config(), [:hostname, :port, :database, :username, :password, :ssl])}
      )

    channel = Events.postgres_channel()
    assert {:ok, ref} = Postgrex.Notifications.listen(notifications, channel)

    Sandbox.unboxed_run(Repo, fn ->
      assert OpenAIStatus.feed_state() == nil
      assert OpenAIStatus.list_incidents() == []

      try do
        fun.({notifications, ref, channel})
      after
        Repo.delete_all(from(i in Incident, where: i.guid == ^guid))
        Repo.delete_all(from(s in FeedState, where: s.singleton == true))
        assert Repo.get_by(Incident, guid: guid) == nil
        assert OpenAIStatus.feed_state() == nil
      end
    end)
  end

  defp assert_status_event({notifications, ref, channel}, changed_count, revision, emitted_at) do
    assert_receive {:notification, ^notifications, ^ref, ^channel, payload}, @notification_timeout
    assert {:ok, decoded} = CodexPooler.JSON.decode(payload)

    event = %{
      event_version: 1,
      changed_count: changed_count,
      active_count: 1,
      aggregate_revision: revision,
      emitted_at: emitted_at
    }

    assert {:ok, ^event} = Events.decode(decoded)
    assert_receive {:openai_status_updated, ^event}, @notification_timeout
    refute_received {:notification, ^notifications, ^ref, ^channel, _}
    refute_received {:openai_status_updated, _}
  end

  defp refute_status_event({notifications, ref, channel}) do
    refute_receive {:notification, ^notifications, ^ref, ^channel, _}, 100
    refute_received {:openai_status_updated, _}
  end
end
