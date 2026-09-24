defmodule CodexPoolerWeb.Admin.AuditLogsBoundedCountLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  @count_window 10_000

  setup :register_and_log_in_user

  setup %{scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "audit-bounded", name: "Audit Bounded"})
    Repo.delete_all(AuditEvent)
    %{pool: pool}
  end

  # The page counted every matching audit event on every load, and
  # `audit_events` has no retention, so the all-Pools count read the whole audit
  # history (findings#206 row 206-414). It now counts at most a window past the
  # current page, like the request-log page.
  test "every audit-event count the page issues is bounded, for all Pools and for one", %{conn: conn, pool: pool} do
    insert_events!(pool.id, 2)
    insert_events!(nil, 1)

    for path <- [~p"/admin/audit-logs", ~p"/admin/audit-logs?#{%{"pool_id" => pool.id}}"] do
      {view, counts} = with_audit_counts(fn -> live(conn, path) end)
      assert has_element?(view, "[data-role='pagination-range']")
      assert counts != []
      assert Enum.all?(counts, &bounded?/1), "unbounded audit counts on #{path}: #{inspect(Enum.reject(counts, &bounded?/1))}"
    end
  end

  test "a total past the window reads as a lower bound and the next page stays reachable", %{conn: conn, pool: pool} do
    insert_events!(pool.id, @count_window + 2)

    {:ok, view, _html} = live(conn, ~p"/admin/audit-logs")

    assert has_element?(view, "[data-role='pagination-range']", "1-50 of #{@count_window}+")
    assert has_element?(view, "[data-role='pagination-status']", "Page 1 of 200+")
    assert has_element?(view, "a#audit-log-pagination-next")
    assert render(view) =~ "Audit logs, #{@count_window} or more matching redacted audit events"
  end

  test "an exact total keeps its plain number", %{conn: conn, pool: pool} do
    insert_events!(pool.id, 3)

    {:ok, view, _html} = live(conn, ~p"/admin/audit-logs?#{%{"pool_id" => pool.id}}")

    assert has_element?(view, "[data-role='pagination-range']", "1-3 of 3")
    refute has_element?(view, "[data-role='pagination-range']", "+")
    refute render(view) =~ "or more matching"
  end

  defp insert_events!(pool_id, count) do
    Repo.query!(
      """
      INSERT INTO audit_events (id, occurred_at, actor_type, pool_id, action, target_type, outcome, details)
      SELECT gen_random_uuid(), now() - make_interval(secs => g), 'system', $1::uuid, 'pool.update', 'pool', 'success', '{}'::jsonb
        FROM generate_series(1, $2::integer) g
      """,
      [pool_id && Ecto.UUID.dump!(pool_id), count]
    )
  end

  defp bounded?(sql), do: sql =~ ~r/LIMIT \$\d+/

  # Every `count(...)` over `audit_events` issued by the test process (the
  # disconnected render) or the connected page, so a count from another test
  # module cannot enter the sample.
  defp with_audit_counts(fun) do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata.query =~ ~r/count\(/ and metadata.query =~ ~s(FROM "audit_events"),
            do: send(test_pid, {:audit_count, [self() | Process.get(:"$callers", [])], metadata.query})
        end,
        nil
      )

    {:ok, view, _html} = fun.()
    :telemetry.detach(handler_id)
    {view, drain_counts([test_pid, view.pid], [])}
  end

  defp drain_counts(owners, acc) do
    receive do
      {:audit_count, pids, sql} -> drain_counts(owners, if(Enum.any?(pids, &(&1 in owners)), do: [sql | acc], else: acc))
    after
      0 -> Enum.reverse(acc)
    end
  end
end
