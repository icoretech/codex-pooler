defmodule CodexPooler.Gateway.OwnerRenewalSchedule do
  @moduledoc false

  @type milliseconds :: pos_integer()

  @spec base_interval_ms(milliseconds(), milliseconds()) :: milliseconds()
  def base_interval_ms(configured_interval_ms, ttl_ms)
      when is_integer(configured_interval_ms) and configured_interval_ms > 0 and
             is_integer(ttl_ms) and ttl_ms > 0 do
    min(configured_interval_ms, max(div(ttl_ms, 3), 1))
  end

  @spec staggered_delay(milliseconds()) :: milliseconds()
  def staggered_delay(timeout) when is_integer(timeout) and timeout > 0 do
    minimum = max(timeout - div(timeout, 5), 1)
    minimum + :rand.uniform(timeout - minimum + 1) - 1
  end

  @spec bounded_delay(term(), milliseconds()) :: milliseconds()
  def bounded_delay(delay, timeout)
      when is_integer(delay) and delay > 0 and is_integer(timeout) and timeout > 0 and
             delay <= timeout,
      do: delay

  def bounded_delay(_delay, timeout) when is_integer(timeout) and timeout > 0, do: timeout
end
