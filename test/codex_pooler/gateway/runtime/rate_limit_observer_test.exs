defmodule CodexPooler.Gateway.Runtime.RateLimitObserverTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Runtime.RateLimitObserver
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  describe "record_complete_events/2" do
    test "records a whole event payload without exposing streaming state" do
      identity = %UpstreamIdentity{id: Ecto.UUID.generate()}

      assert :ok =
               RateLimitObserver.record_complete_events(
                 identity,
                 "event: codex.rate_limits\n"
               )
    end

    test "persists reset-bearing codex.rate_limits events through quota windows" do
      identity = active_upstream_assignment_fixture().identity
      reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

      assert :ok =
               RateLimitObserver.record_complete_events(
                 identity,
                 "event: codex.rate_limits\n" <>
                   "data: #{Jason.encode!(codex_rate_limits_payload(42, reset_at))}\n\n"
               )

      assert window = wait_for_rate_limit_event_window(identity, "primary")
      assert window.source == "codex_rate_limit_event"
      assert Decimal.equal?(window.used_percent, Decimal.new("42.0"))
      assert DateTime.compare(window.reset_at, reset_at) == :eq

      wait_for_rate_limit_event_tasks()
    end

    test "persists rate-limit events while other persistence tasks are running" do
      identity = active_upstream_assignment_fixture().identity
      reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)
      blocker_pids = start_rate_limit_event_task_blockers(4)

      on_exit(fn ->
        Enum.each(blocker_pids, &send(&1, :release_rate_limit_event_task))
      end)

      assert :ok =
               RateLimitObserver.record_complete_events(
                 identity,
                 "event: codex.rate_limits\n" <>
                   "data: #{Jason.encode!(codex_rate_limits_payload(42, reset_at))}\n\n"
               )

      assert window = wait_for_rate_limit_event_window(identity, "primary")
      assert window.source == "codex_rate_limit_event"
      assert Decimal.equal?(window.used_percent, Decimal.new("42.0"))
      assert DateTime.compare(window.reset_at, reset_at) == :eq

      Enum.each(blocker_pids, &send(&1, :release_rate_limit_event_task))
      wait_for_rate_limit_event_tasks()
    end

    test "ignores local usage-limit response.failed events as quota evidence" do
      identity = active_upstream_assignment_fixture().identity

      assert :ok =
               RateLimitObserver.record_complete_events(
                 identity,
                 "event: response.failed\n" <>
                   "data: #{Jason.encode!(usage_limit_terminal_payload())}\n\n"
               )

      wait_for_rate_limit_event_tasks()

      refute identity
             |> QuotaWindows.list_quota_windows()
             |> Enum.any?(&(&1.source == "codex_rate_limit_event"))
    end

    test "ignores non-rate-limit websocket JSON before quota DB work" do
      identity = active_upstream_assignment_fixture().identity

      {_result, repo_events} =
        collect_repo_query_events(fn ->
          assert :ok =
                   RateLimitObserver.record_complete_events(
                     identity,
                     Jason.encode!(%{
                       "type" => "response.output_text.delta",
                       "delta" => "sample"
                     })
                   )

          wait_for_rate_limit_event_tasks()
        end)

      assert repo_events == []
    end
  end

  describe "record_events/3" do
    test "returns incomplete SSE buffer in explicit state" do
      identity = %UpstreamIdentity{id: Ecto.UUID.generate()}

      assert {:ok, %{buffer: "event: codex.rate_limits\n"}} =
               RateLimitObserver.record_events(
                 identity,
                 "event: codex.rate_limits\n",
                 RateLimitObserver.event_state()
               )

      refute Process.get({:codex_rate_limit_event_buffer, identity.id})
    end

    test "bounds incomplete SSE buffer state" do
      identity = %UpstreamIdentity{id: Ecto.UUID.generate()}

      assert {:ok, %{buffer: ""}} =
               RateLimitObserver.record_events(
                 identity,
                 String.duplicate("x", 16_385),
                 RateLimitObserver.event_state()
               )
    end

    test "normalizes non-streaming fallback states" do
      assert {:ok, %{buffer: "kept"}} =
               RateLimitObserver.record_events(:not_an_identity, :not_binary, %{buffer: "kept"})

      assert {:ok, %{buffer: ""}} =
               RateLimitObserver.record_events(:not_an_identity, :not_binary, %{buffer: 1})

      assert :ok =
               RateLimitObserver.clear_event_buffer(%UpstreamIdentity{id: Ecto.UUID.generate()})
    end

    test "keeps partial SSE tail when later blocks are complete" do
      identity = %UpstreamIdentity{id: Ecto.UUID.generate()}

      assert {:ok, %{buffer: "event: codex.rate_limits\n"}} =
               RateLimitObserver.record_events(
                 identity,
                 "event: response.output_text.delta\n" <>
                   "data: #{Jason.encode!(%{"type" => "response.output_text.delta"})}\n\n" <>
                   "event: codex.rate_limits\n",
                 RateLimitObserver.event_state()
               )
    end

    test "persists a literal rate-limit marker split at every junction" do
      identity = active_upstream_assignment_fixture().identity
      reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

      event =
        "event: codex.rate_limits\n" <>
          "data: #{Jason.encode!(codex_rate_limits_payload(42, reset_at))}\n\n"

      {marker_offset, marker_size} = :binary.match(event, "codex.rate_limits")

      for split_at <- marker_offset..(marker_offset + marker_size) do
        <<first::binary-size(^split_at), second::binary>> = event

        assert {:ok, state} =
                 RateLimitObserver.record_events(identity, first, RateLimitObserver.event_state())

        assert {:ok, %{buffer: ""}} = RateLimitObserver.record_events(identity, second, state)
      end

      assert window = wait_for_rate_limit_event_window(identity, "primary")
      assert DateTime.compare(window.reset_at, reset_at) == :eq
      wait_for_rate_limit_event_tasks()
    end

    test "keeps a carriage-return junction while finding a split marker" do
      identity = active_upstream_assignment_fixture().identity
      reset_at = DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)

      event =
        "event: codex.rate_limits\r\n" <>
          "data: #{Jason.encode!(codex_rate_limits_payload(43, reset_at))}\r\n\r\n"

      {split_at, _length} = :binary.match(event, "\r\n")
      split_at = split_at + 1
      <<first::binary-size(^split_at), second::binary>> = event

      assert {:ok, state} =
               RateLimitObserver.record_events(identity, first, RateLimitObserver.event_state())

      assert {:ok, %{buffer: ""}} = RateLimitObserver.record_events(identity, second, state)
      assert window = wait_for_rate_limit_event_window(identity, "primary")
      assert Decimal.equal?(window.used_percent, Decimal.new("43.0"))
      wait_for_rate_limit_event_tasks()
    end
  end

  describe "saved reset convergence from runtime evidence" do
    test "exhausted weekly headers reblock a pending reset immediately" do
      identity = pending_reset_identity()

      assert :ok =
               RateLimitObserver.record_headers(identity, %Req.Response{
                 headers: weekly_headers("100")
               })

      assert redemption_phase(identity) == "reblocked"
    end

    test "usable weekly headers confirm a pending reset immediately" do
      identity = pending_reset_identity()

      assert :ok =
               RateLimitObserver.record_headers(identity, %Req.Response{
                 headers: weekly_headers("4")
               })

      assert redemption_phase(identity) == "confirmed_by_quota"
    end

    test "later usable weekly headers confirm an applied reblocked reset immediately" do
      identity = pending_reset_identity("reblocked")

      assert :ok =
               RateLimitObserver.record_headers(identity, %Req.Response{
                 headers: weekly_headers("4")
               })

      assert redemption_phase(identity) == "confirmed_by_quota"
    end

    test "later usable weekly headers leave a non-applied reblock unchanged" do
      identity =
        pending_reset_identity("reblocked", %{
          "result" => %{"code" => "provider_not_dispatched", "applied" => false}
        })

      assert :ok =
               RateLimitObserver.record_headers(identity, %Req.Response{
                 headers: weekly_headers("4")
               })

      assert redemption_phase(identity) == "reblocked"
    end

    test "identities without a pending lifecycle are untouched" do
      identity = active_upstream_assignment_fixture().identity

      {result, repo_events} =
        collect_repo_query_events(fn ->
          RateLimitObserver.record_headers(identity, %Req.Response{
            headers: weekly_headers("100")
          })
        end)

      assert :ok = result
      assert Enum.any?(repo_events, &convergence_lock_query?/1)

      persisted = Repo.reload!(identity)
      refute Map.has_key?(persisted.metadata || %{}, "saved_reset_redemption")
    end

    test "websocket frame headers drive the same convergence" do
      identity = pending_reset_identity()

      assert :ok =
               RateLimitObserver.record_websocket_frame_headers(
                 identity,
                 Map.new(weekly_headers("100"))
               )

      assert redemption_phase(identity) == "reblocked"
    end

    @tag :saved_reset_stale_snapshot_contract
    test "usable synchronous headers converge a DB-authoritative applied reblock" do
      stale_identity = stale_snapshot_after_applied_reblock()

      assert redemption_phase(stale_identity) == "reblocked"

      assert :ok =
               RateLimitObserver.record_headers(stale_identity, %Req.Response{
                 headers: weekly_headers("4")
               })

      assert redemption_phase(stale_identity) == "confirmed_by_quota"
    end

    @tag :saved_reset_stale_snapshot_contract
    test "usable websocket upgrade headers converge a DB-authoritative applied reblock" do
      stale_identity = stale_snapshot_after_applied_reblock()

      assert redemption_phase(stale_identity) == "reblocked"

      assert :ok =
               RateLimitObserver.record_websocket_upgrade_headers(
                 stale_identity,
                 weekly_headers("4")
               )

      assert redemption_phase(stale_identity) == "confirmed_by_quota"
    end

    @tag :saved_reset_stale_snapshot_contract
    test "usable websocket frame headers converge a DB-authoritative applied reblock" do
      stale_identity = stale_snapshot_after_applied_reblock()

      assert redemption_phase(stale_identity) == "reblocked"

      assert :ok =
               RateLimitObserver.record_websocket_frame_headers(
                 stale_identity,
                 Map.new(weekly_headers("4"))
               )

      assert redemption_phase(stale_identity) == "confirmed_by_quota"
    end

    @tag :saved_reset_stale_snapshot_contract
    test "usable async codex.rate_limits evidence converges a DB-authoritative applied reblock" do
      stale_identity = stale_snapshot_after_applied_reblock()
      reset_at = DateTime.add(DateTime.utc_now(), 3, :minute) |> DateTime.truncate(:second)

      assert redemption_phase(stale_identity) == "reblocked"

      assert :ok =
               await_rate_limit_event_commit(stale_identity.id, fn ->
                 RateLimitObserver.record_complete_event(
                   stale_identity,
                   codex_rate_limits_payload(4, reset_at)
                 )
               end)

      assert redemption_phase(stale_identity) == "confirmed_by_quota"
    end

    @tag :saved_reset_stale_snapshot_contract
    test "exhausted rate-limit error evidence keeps a DB-authoritative applied reblock" do
      stale_identity = stale_snapshot_after_applied_reblock()

      assert :ok =
               RateLimitObserver.record_error(
                 stale_identity,
                 Jason.encode!(exhausted_account_rate_limit_error())
               )

      assert redemption_phase(stale_identity) == "reblocked"

      assert Enum.any?(QuotaWindows.list_quota_windows(stale_identity), fn window ->
               window.source == "codex_rate_limit_error" and window.quota_key == "account" and
                 Decimal.equal?(window.used_percent, Decimal.new("100"))
             end)
    end

    @tag :saved_reset_stale_snapshot_contract
    test "malformed and non-account errors do not falsely confirm an applied reblock" do
      stale_identity = stale_snapshot_after_applied_reblock()

      {result, repo_events} =
        collect_repo_query_events(fn ->
          assert :ok = RateLimitObserver.record_error(stale_identity, "not-json")

          RateLimitObserver.record_error(
            stale_identity,
            Jason.encode!(%{
              "limit_id" => "codex_future_family",
              "window_kind" => "secondary",
              "window_minutes" => "10080",
              "used_percent" => "4",
              "reset_after_seconds" => "180"
            })
          )
        end)

      assert :ok = result
      refute Enum.any?(repo_events, &convergence_lock_query?/1)
      assert redemption_phase(stale_identity) == "reblocked"
    end
  end

  describe "observer failure logging" do
    test "records header and error failures with sanitized metadata" do
      identity = %UpstreamIdentity{id: Ecto.UUID.generate()}
      headers = reset_bearing_headers()
      log_opts = [metadata: [:operation, :reason, :upstream_identity_id]]

      header_log =
        capture_log(log_opts, fn ->
          assert :ok = RateLimitObserver.record_headers(identity, %Req.Response{headers: headers})
        end)

      assert header_log =~ "gateway observer failure"
      assert header_log =~ "operation=rate_limit_headers"
      assert header_log =~ "reason=upstream_identity_not_found"
      assert header_log =~ "upstream_identity_id=#{identity.id}"

      frame_log =
        capture_log(log_opts, fn ->
          assert :ok =
                   RateLimitObserver.record_websocket_frame_headers(identity, Map.new(headers))
        end)

      assert frame_log =~ "operation=rate_limit_websocket_frame_headers"
      assert frame_log =~ "reason=upstream_identity_not_found"
      assert frame_log =~ "upstream_identity_id=#{identity.id}"

      error_log =
        capture_log(log_opts, fn ->
          assert :ok =
                   RateLimitObserver.record_error(
                     identity,
                     Jason.encode!(%{
                       "limit_id" => "codex_future_family",
                       "window_kind" => "secondary",
                       "window_minutes" => "10080",
                       "used_percent" => "100",
                       "reset_after_seconds" => "120"
                     })
                   )
        end)

      assert error_log =~ "operation=rate_limit_error"
      assert error_log =~ "reason=upstream_identity_not_found"
      assert error_log =~ "upstream_identity_id=#{identity.id}"
    end

    test "normalizes explicit failure reasons" do
      reasons = [
        {%Ecto.Changeset{}, "changeset_invalid"},
        {%{code: :quota_window_invalid}, "quota_window_invalid"},
        {%{code: "quota_window_invalid"}, "quota_window_invalid"},
        {{:quota_refresh_failed, %{}}, "quota_refresh_failed"},
        {{"opaque", %{}}, "tuple_error"},
        {:timeout, "timeout"},
        {"upstream closed", "upstream closed"},
        {123, "unknown_error"}
      ]

      for {reason, code} <- reasons do
        log =
          capture_log([metadata: [:operation, :reason]], fn ->
            assert :ok = RateLimitObserver.log_failure("rate_limit_test", [], reason)
          end)

        assert log =~ "operation=rate_limit_test"
        assert log =~ "reason=#{code}"
      end
    end

    test "ignores malformed error bodies" do
      assert :ok =
               RateLimitObserver.record_error(%UpstreamIdentity{id: Ecto.UUID.generate()}, :bad)

      assert :ok = RateLimitObserver.record_error(:not_an_identity, "{}")
    end
  end

  defp usage_limit_terminal_payload do
    %{
      "type" => "response.failed",
      "response" => %{
        "id" => "resp_usage_limit_terminal",
        "status" => "failed",
        "error" => %{"code" => "usage_limit_exceeded"},
        "usage" => %{
          "input_tokens" => 10,
          "cached_input_tokens" => 4,
          "output_tokens" => 2,
          "reasoning_tokens" => 1,
          "total_tokens" => 12
        }
      }
    }
  end

  defp start_rate_limit_event_task_blockers(count) do
    parent = self()

    blocker_pids =
      for _index <- 1..count do
        {:ok, pid} =
          Task.Supervisor.start_child(CodexPooler.RateLimitEventSupervisor, fn ->
            send(parent, {:rate_limit_event_task_blocked, self()})

            receive do
              :release_rate_limit_event_task -> :ok
            end
          end)

        pid
      end

    for _index <- 1..count do
      assert_receive {:rate_limit_event_task_blocked, _pid}, 1_000
    end

    blocker_pids
  end

  defp codex_rate_limits_payload(used_percent, reset_at) do
    %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "primary" => %{
          "used_percent" => used_percent,
          "window_minutes" => 300,
          "reset_at" => DateTime.to_unix(reset_at)
        }
      }
    }
  end

  defp pending_reset_identity(phase \\ "consumed_pending_probe", overrides \\ %{}) do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    redemption =
      Map.merge(
        %{
          "status" => if(phase == "reblocked", do: "failed", else: "redeeming"),
          "phase" => phase,
          "attempt_id" => Ecto.UUID.generate(),
          "generation" => 3,
          "trigger_kind" => "gateway_auto",
          "consumed_at" => DateTime.to_iso8601(consumed_at),
          "deadline_at" => consumed_at |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
          "result" => %{"code" => "reset", "applied" => true}
        },
        overrides
      )

    active_upstream_assignment_fixture(pool_fixture(), %{
      metadata: %{"saved_reset_redemption" => redemption}
    }).identity
  end

  defp stale_snapshot_after_applied_reblock do
    stale_identity = active_upstream_assignment_fixture().identity
    persisted_identity = Repo.reload!(stale_identity)

    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    redemption = %{
      "status" => "failed",
      "phase" => "reblocked",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 3,
      "trigger_kind" => "gateway_auto",
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "deadline_at" => consumed_at |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
      "result" => %{"code" => "reset", "applied" => true}
    }

    persisted_identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(persisted_identity.metadata || %{}, "saved_reset_redemption", redemption)
    })
    |> Repo.update!()

    stale_identity
  end

  defp exhausted_account_rate_limit_error do
    %{
      "error" => %{
        "code" => "rate_limit_exceeded",
        "limit_id" => "codex",
        "window_kind" => "secondary",
        "window_minutes" => "10080",
        "used_percent" => "100",
        "reset_after_seconds" => "180"
      }
    }
  end

  defp redemption_phase(identity) do
    identity
    |> Repo.reload!()
    |> Map.get(:metadata)
    |> Kernel.||(%{})
    |> get_in(["saved_reset_redemption", "phase"])
  end

  defp weekly_headers(used_percent) do
    reset_at =
      DateTime.utc_now()
      |> DateTime.add(3, :day)
      |> DateTime.truncate(:second)

    [
      {"x-codex-secondary-used-percent", [used_percent]},
      {"x-codex-secondary-window-minutes", ["10080"]},
      {"x-codex-secondary-reset-at", [DateTime.to_iso8601(reset_at)]}
    ]
  end

  defp reset_bearing_headers do
    reset_at =
      DateTime.utc_now()
      |> DateTime.add(600, :second)
      |> DateTime.truncate(:second)

    [
      {"x-codex-primary-used-percent", ["12"]},
      {"x-codex-primary-window-minutes", ["300"]},
      {"x-codex-primary-reset-at", [DateTime.to_iso8601(reset_at)]}
    ]
  end

  defp wait_for_rate_limit_event_window(identity, window_kind, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    identity
    |> QuotaWindows.list_quota_windows()
    |> Enum.find(&(&1.source == "codex_rate_limit_event" and &1.window_kind == window_kind))
    |> case do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> wait_for_rate_limit_event_window(identity, window_kind, deadline)
          end
        else
          flunk("expected codex.rate_limits quota window for #{window_kind}")
        end

      window ->
        window
    end
  end

  defp wait_for_rate_limit_event_tasks(deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    case Task.Supervisor.children(CodexPooler.RateLimitEventSupervisor) do
      [] ->
        :ok

      _children ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> wait_for_rate_limit_event_tasks(deadline)
          end
        else
          flunk("expected codex.rate_limits persistence tasks to finish")
        end
    end
  end

  defp collect_repo_query_events(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(
              parent,
              {handler_id, metadata[:source] || "unknown", metadata[:query] || ""}
            )
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_query_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_query_events(handler_id, events) do
    receive do
      {^handler_id, source, query} ->
        drain_repo_query_events(handler_id, [{source, query} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp convergence_lock_query?({"upstream_identities", query}) do
    query
    |> String.upcase()
    |> String.contains?("FOR UPDATE")
  end

  defp convergence_lock_query?(_event), do: false

  defp await_rate_limit_event_commit(identity_id, fun) when is_function(fun, 0) do
    parent = self()
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(parent, {
              handler_id,
              self(),
              metadata[:source],
              metadata[:query] || "",
              metadata[:params] || []
            })
          end
        end,
        nil
      )

    try do
      result = fun.()
      task_pid = await_identity_quota_write(handler_id, identity_id)
      await_task_commit(handler_id, task_pid)
      monitor_ref = Process.monitor(task_pid)
      assert_receive {:DOWN, ^monitor_ref, :process, ^task_pid, :normal}, 1_000
      result
    after
      :telemetry.detach(handler_id)
      drain_tagged_repo_events(handler_id)
    end
  end

  defp await_identity_quota_write(handler_id, identity_id) do
    dumped_identity_id = Ecto.UUID.dump!(identity_id)

    receive do
      {^handler_id, task_pid, "account_quota_windows", query, params} ->
        if String.starts_with?(String.upcase(String.trim_leading(query)), "INSERT") and
             Enum.any?(params, &(&1 in [identity_id, dumped_identity_id])) do
          task_pid
        else
          await_identity_quota_write(handler_id, identity_id)
        end

      {^handler_id, _pid, _source, _query, _params} ->
        await_identity_quota_write(handler_id, identity_id)
    after
      1_000 -> flunk("expected async codex.rate_limits quota write for fixture identity")
    end
  end

  defp await_task_commit(handler_id, task_pid) do
    receive do
      {^handler_id, ^task_pid, _source, query, _params} ->
        if String.upcase(String.trim(query)) == "COMMIT" do
          :ok
        else
          await_task_commit(handler_id, task_pid)
        end

      {^handler_id, _other_pid, _source, _query, _params} ->
        await_task_commit(handler_id, task_pid)
    after
      1_000 -> flunk("expected async codex.rate_limits Repo COMMIT")
    end
  end

  defp drain_tagged_repo_events(handler_id) do
    receive do
      {^handler_id, _pid, _source, _query, _params} -> drain_tagged_repo_events(handler_id)
    after
      0 -> :ok
    end
  end
end
