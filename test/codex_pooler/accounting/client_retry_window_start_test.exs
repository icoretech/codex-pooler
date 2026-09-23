defmodule CodexPooler.Accounting.ClientRetryWindowStartTest do
  # Where the client-retry window of a predecessor starts (findings#232 row
  # 232-261): at its completion, or, when its final attempt's delivery receipt
  # names a failed downstream write, at that failure, bounded by the completion
  # and by two minutes after it or the database's now. A client that stops
  # reading is noticed only by the 30 s send timeout, so a window from the
  # completion refused every resend of a turn the receipt proves undelivered.
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.{Attempt, ClientRetry, Request}

  @completed_at ~U[2026-09-23 10:00:00.000000Z]
  @now ~U[2026-09-23 10:01:00.000000Z]

  test "a predecessor without a write failure keeps its completion" do
    assert ClientRetry.retry_window_start(request(), nil, @now) == @completed_at
    assert ClientRetry.retry_window_start(request(), %Attempt{response_metadata: nil}, @now) == @completed_at
    assert ClientRetry.retry_window_start(request(), attempt(%{"outcome" => "delivered", "terminal_class" => "response.completed"}), @now) == @completed_at
    assert ClientRetry.retry_window_start(request(), attempt(%{"outcome" => "aborted", "write_failure" => "timeout"}), @now) == @completed_at
  end

  test "a write failure after the completion starts the window" do
    receipt = %{"outcome" => "aborted", "write_failure" => "timeout", "write_failed_at" => "2026-09-23T10:00:31.250Z"}
    assert ClientRetry.retry_window_start(request(), attempt(receipt), @now) == ~U[2026-09-23 10:00:31.250Z]

    for failure <- ~w(closed other) do
      receipt = %{receipt | "write_failure" => failure}
      assert ClientRetry.retry_window_start(request(), attempt(receipt), @now) == ~U[2026-09-23 10:00:31.250Z]
    end
  end

  test "the failure moves the start only between the completion and two minutes after it or now" do
    earlier = %{"write_failure" => "timeout", "write_failed_at" => "2026-09-23T09:59:50Z"}
    assert ClientRetry.retry_window_start(request(), attempt(earlier), @now) == @completed_at

    late = %{"write_failure" => "timeout", "write_failed_at" => "2026-09-23T10:05:00Z"}
    assert ClientRetry.retry_window_start(request(), attempt(late), ~U[2026-09-23 10:05:10Z]) == ~U[2026-09-23 10:02:00.000000Z]

    ahead_of_now = %{"write_failure" => "timeout", "write_failed_at" => "2026-09-23T10:01:05Z"}
    assert ClientRetry.retry_window_start(request(), attempt(ahead_of_now), @now) == @now

    # A database clock behind the completion keeps the completion, which is
    # refused as before.
    assert ClientRetry.retry_window_start(request(), attempt(ahead_of_now), ~U[2026-09-23 09:59:00Z]) == @completed_at
  end

  test "a failure time outside the receipt's shape is ignored" do
    for receipt <- [
          %{"write_failure" => "synthetic", "write_failed_at" => "2026-09-23T10:00:31Z"},
          %{"write_failure" => "timeout", "write_failed_at" => "2026-09-23T12:00:31+02:00"},
          %{"write_failure" => "timeout", "write_failed_at" => "not a time"},
          %{"write_failure" => "timeout", "write_failed_at" => 1_790_000_000},
          %{"write_failure" => "timeout", "write_failed_at" => String.duplicate("9", 65)}
        ] do
      assert ClientRetry.retry_window_start(request(), attempt(receipt), @now) == @completed_at
    end
  end

  test "a predecessor that has not completed has no window" do
    assert ClientRetry.retry_window_start(%Request{completed_at: nil}, attempt(%{"write_failure" => "timeout", "write_failed_at" => "2026-09-23T10:00:31Z"}), @now) == nil
  end

  defp request, do: %Request{completed_at: @completed_at}
  defp attempt(receipt), do: %Attempt{response_metadata: %{"downstream_delivery" => receipt}}
end
