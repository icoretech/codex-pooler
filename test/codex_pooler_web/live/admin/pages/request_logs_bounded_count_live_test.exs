defmodule CodexPoolerWeb.Admin.RequestLogsBoundedCountLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.LogPagination

  @detection_timeout_ms 15_000

  setup :register_and_log_in_user

  # The page counted every matching request on every load and live refresh:
  # 600 all-Pools loads read 10M blocks on production (findings#206 row
  # 206-385). It now counts at most a window past the current page, and the
  # arrivals behind a pinned page up to the banner's limit, so every count the
  # page issues over `requests` is bounded.
  test "every request count the page issues is bounded, on the live page and behind a pin", %{conn: conn} do
    %{pool: pool, api_key: api_key} = active_api_key_fixture()
    [oldest | newer] = for offset <- 3..1//-1, do: aged_request!(pool, api_key, offset)

    {view, counts} = with_request_counts(fn -> open_request_logs!(conn, ~p"/admin/request-logs") end)
    assert has_element?(view, "#request-log-row-#{oldest.id}")
    assert has_element?(view, "[data-role='pagination-range']", "1-3 of 3")
    assert counts != []
    assert Enum.all?(counts, &bounded?/1), "unbounded request counts: #{inspect(Enum.reject(counts, &bounded?/1))}"

    pin = %{"as_of" => DateTime.to_iso8601(oldest.admitted_at), "as_of_id" => oldest.id, "pool_id" => pool.id}
    {view, counts} = with_request_counts(fn -> open_request_logs!(conn, ~p"/admin/request-logs?#{pin}") end)
    assert has_element?(view, "[data-role='request-log-newer-count']", "#{length(newer)} newer")
    refute has_element?(view, "[data-role='request-log-newer-count']", "+")
    assert length(counts) >= 2
    assert Enum.all?(counts, &bounded?/1), "unbounded request counts: #{inspect(Enum.reject(counts, &bounded?/1))}"
  end

  # A count that stopped at its limit is a lower bound, and the pager says so
  # instead of printing it as the total: the range and the page count carry a
  # "+", and the next page stays reachable.
  test "the pager reads an inexact total as a lower bound" do
    exact = LogPagination.metadata(%{items: [], total: 120, total_exact?: true, limit: 50, offset: 100})
    assert %{range: "101-120 of 120", total_pages_label: "3", has_next_page: false} = exact

    bounded = LogPagination.metadata(%{items: [], total: 10_000, total_exact?: false, limit: 50, offset: 0})
    assert %{range: "1-50 of 10000+", total_pages_label: "200+", has_next_page: true, current_page: 1} = bounded
    assert LogPagination.last_page(%{total: 10_000, limit: 50}) == 200

    legacy = LogPagination.metadata(%{items: [], total: 7, limit: 50, offset: 0})
    assert %{range: "1-7 of 7", total_pages_label: "1", has_next_page: false} = legacy

    html = render_component(&LogPagination.pager/1, id: "bounded-pager", label: "Bounded", page: bounded, next_path: "/next")
    assert html =~ "Page 1 of 200+"
    assert html =~ "1-50 of 10000+"
    assert html =~ ~s(href="/next")
  end

  defp aged_request!(pool, api_key, minutes_ago) do
    request = request_fixture(%{pool: pool, api_key: api_key})
    admitted_at = DateTime.add(request.admitted_at, -minutes_ago, :minute)
    request |> Ecto.Changeset.change(admitted_at: admitted_at) |> Repo.update!()
  end

  defp bounded?(sql), do: sql =~ ~r/LIMIT \$\d+/

  # Every `count(...)` over `requests` issued by the page process or a task it
  # started, so a count from another test module cannot enter the sample.
  defp with_request_counts(fun) do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata.query =~ ~r/count\(/ and metadata.query =~ ~s(FROM "requests"),
            do: send(test_pid, {:request_count, [self() | Process.get(:"$callers", [])], metadata.query})
        end,
        nil
      )

    view = fun.()
    :telemetry.detach(handler_id)
    {view, drain_counts(view.pid, [])}
  end

  defp drain_counts(view_pid, acc) do
    receive do
      {:request_count, pids, sql} -> drain_counts(view_pid, if(view_pid in pids, do: [sql | acc], else: acc))
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp open_request_logs!(conn, path) do
    {:ok, view, _html} = live(conn, path)
    await_request_logs(view, System.monotonic_time(:millisecond) + @detection_timeout_ms)
    view
  end

  defp await_request_logs(view, deadline) do
    _ = render_async(view, 5_000)
    assigns = :sys.get_state(view.pid).socket.assigns

    if assigns.request_logs_loading? or assigns.request_logs_running? do
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("request logs did not finish loading")

      receive do
      after
        1 -> await_request_logs(view, deadline)
      end
    end
  end
end
