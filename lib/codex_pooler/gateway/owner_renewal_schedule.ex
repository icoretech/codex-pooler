defmodule CodexPooler.Gateway.OwnerRenewalSchedule do
  @moduledoc false

  @type milliseconds :: pos_integer()

  # The smallest `bridge_owner_lease_ttl_seconds` an HTTP request's lease can
  # rely on. A request acquires (or renews) its lease in continuity, runs its
  # pre-dispatch work, and then renews synchronously before it reserves; an
  # expired lease at that renewal is refused with 503 `owner_unavailable`
  # (findings#206 row 206-498), because an expired lease may already belong to
  # another node. The ttl must therefore cover one pre-dispatch database
  # statement at its full budget (Ecto's default `:timeout`, which
  # `CodexPooler.Repo` does not override) plus the synchronous renewal's own
  # call budget: one renewal interval, at most ttl / 3 (`base_interval_ms/2`),
  # plus the heartbeat's reply allowance. Solving
  # `ttl >= statement + ttl / 3 + allowance` gives
  # `ttl >= 3 / 2 * (statement + allowance)`, 24 s. It depends only on these
  # code budgets, not on any installation's latency.
  @pre_dispatch_statement_budget_ms 15_000
  @synchronous_renewal_reply_allowance_ms 1_000
  @minimum_lease_ttl_seconds div(
                               3 * (@pre_dispatch_statement_budget_ms + @synchronous_renewal_reply_allowance_ms) + 2 * 1_000 - 1,
                               2 * 1_000
                             )

  @spec minimum_lease_ttl_seconds() :: pos_integer()
  def minimum_lease_ttl_seconds, do: @minimum_lease_ttl_seconds

  @doc """
  The lease ttl in effect for a stored setting: values below
  `minimum_lease_ttl_seconds/0` (stored before the minimum existed) are raised
  to it at read time rather than rewritten.
  """
  @spec effective_lease_ttl_seconds(term(), pos_integer()) :: pos_integer()
  def effective_lease_ttl_seconds(ttl_seconds, _default) when is_integer(ttl_seconds) and ttl_seconds > 0,
    do: max(ttl_seconds, @minimum_lease_ttl_seconds)

  def effective_lease_ttl_seconds(_ttl_seconds, default) when is_integer(default) and default > 0,
    do: max(default, @minimum_lease_ttl_seconds)

  @doc """
  The longest renewal interval, in whole seconds, a lease of `ttl_seconds`
  allows: a third of the ttl, the same cap `base_interval_ms/2` applies to
  every renewal cadence, so a live owner gets at least two renewal attempts
  before its lease expires.
  """
  @spec maximum_renewal_seconds(pos_integer()) :: pos_integer()
  def maximum_renewal_seconds(ttl_seconds) when is_integer(ttl_seconds) and ttl_seconds > 0,
    do: max(div(ttl_seconds, 3), 1)

  @doc """
  The renewal interval in effect for a stored setting and the effective lease
  ttl: a value above `maximum_renewal_seconds/1` (stored before the bound
  existed, or left unchanged while the ttl was lowered) is lowered to it at
  read time rather than rewritten.
  """
  @spec effective_renewal_seconds(term(), pos_integer(), pos_integer()) :: pos_integer()
  def effective_renewal_seconds(renewal_seconds, ttl_seconds, _default)
      when is_integer(renewal_seconds) and renewal_seconds > 0,
      do: min(renewal_seconds, maximum_renewal_seconds(ttl_seconds))

  def effective_renewal_seconds(_renewal_seconds, ttl_seconds, default) when is_integer(default) and default > 0,
    do: min(default, maximum_renewal_seconds(ttl_seconds))

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
