defmodule CodexPooler.Gateway.Runtime.RateLimitObserverTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Runtime.RateLimitObserver
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
end
