defmodule CodexPooler.Gateway.Transports.RetryAfterTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.RetryAfter

  test "seconds are captured once and expire without restarting the deadline" do
    captured_at = 10_000
    {:ok, response} = RetryAfter.capture({:ok, response("2")}, captured_at)
    assert RetryAfter.header(response, captured_at) == "2"
    assert RetryAfter.header(response, captured_at + 1_000) == "1"
    assert RetryAfter.header(response, captured_at + 2_000) == "0"
    assert RetryAfter.header(response, captured_at + 20_000) == "0"
  end

  test "HTTP dates retain the original deadline, including expired advice" do
    for date <- ["Mon, 28 Sep 2026 12:00:00 GMT", "Wed, 28 Sep 2050 12:00:00 GMT"] do
      {:ok, response} = RetryAfter.capture({:ok, response(date)})
      assert RetryAfter.header(response, System.monotonic_time(:millisecond) + 99_000) == date
    end
  end

  test "valid long seconds use the released client unsigned 64-bit bound" do
    for seconds <- [2_764_800, 18_446_744_073_709_551_615] do
      {:ok, response} = RetryAfter.capture({:ok, response(Integer.to_string(seconds))}, 10_000)
      assert RetryAfter.header(response, 10_000) == Integer.to_string(seconds)
    end
  end

  test "invalid, signed, oversized and success hints do not become retry advice" do
    for value <- ["", "-1", "+1", "1.2", "a", "99999999999999999999999", String.duplicate("x", 129), "30\r\n", "\t30", "30\u007f", <<255>>, "Mon, +1 Jan 2024 09:00:00 GMT"] do
      {:ok, response} = RetryAfter.capture({:ok, response(value)})
      assert RetryAfter.header(response) == nil
    end

    {:ok, response} = RetryAfter.capture({:ok, %{response("2") | status: 200}})
    assert RetryAfter.header(response) == nil
  end

  defp response(value), do: %Req.Response{status: 429, headers: %{"retry-after" => [value]}}
end
