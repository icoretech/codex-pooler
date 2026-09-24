defmodule CodexPooler.Gateway.Routing.CandidateEligibility.UsageLimit do
  @moduledoc """
  The terminal answer of a Pool whose every candidate is quota-exhausted with a
  known reset (findings#206 row 206-508).

  The provider answers an exhausted account with `429`, `error.type`
  `usage_limit_reached`, `resets_at` (epoch seconds) and `resets_in_seconds`;
  the released Codex client ends the turn on it and names the reset, where it
  resends a `503` as a transient fault. When routing excluded every candidate
  for exhaustion and each exhausted window carries a reset still ahead, the
  Pool is in the same state, and the advice is the soonest reset among the
  exhausted windows of all its candidates.

  Soonest, not the moment a candidate is certainly back, because the listed
  windows do not say which one binds: a model meter the provider refused
  (`allowed: false`) marks every window of the meter exhausted whatever its
  percentage, and a 100% account window stays listed next to a model-meter
  block even when an affirmative account permission would let it serve.
  Taking the latest of a candidate's windows advised a week for a meter that
  could return with its 5-hour window. `Retry-After` is the earliest moment a
  retry can succeed: a hint too early costs the client one more refused
  request, whose answer carries the next reset; one too late keeps it away for
  hours or days (findings#206 rows 206-508, 206-522).

  A candidate with any exclusion that is not a reset-bearing exhaustion (stale,
  resetless or missing evidence, a pending saved-reset probe, a provider
  `blocked` availability with no fresh reset-bearing account window) has no
  known return time, so the
  answer stays the retryable `503`. So does a Pool where the circuit filter
  removed a candidate before quota classification: an open circuit probes
  again after `circuit_open_seconds`, which no reset bounds.

  The time is advice, not a promise: an auto-redeemed saved reset can bring an
  account back before it.
  """

  @type t :: %{required(:resets_at) => integer(), required(:resets_in_seconds) => pos_integer()}

  @doc """
  The earliest reset of a Pool whose candidates `exclusions` lists, or
  `:unknown` when any candidate's return time is not known.
  """
  @spec earliest_reset([map()], DateTime.t()) :: {:ok, t()} | :unknown
  def earliest_reset(exclusions, %DateTime{} = now) when is_list(exclusions) do
    resets = Enum.map(exclusions, &candidate_reset(&1, now))

    if resets != [] and Enum.all?(resets, &match?(%DateTime{}, &1)),
      do: {:ok, usage_limit(Enum.min(resets, DateTime), now)},
      else: :unknown
  end

  @doc """
  The same refusal as the retryable `503` it was before this answer existed,
  for a Pool whose quota refusal did not see every candidate.
  """
  @spec retryable(map()) :: map()
  def retryable(%{usage_limit: _usage_limit} = error), do: error |> Map.delete(:usage_limit) |> Map.put(:status, 503)
  def retryable(error), do: error

  defp candidate_reset(exclusion, now) do
    case field(exclusion, :reasons) do
      [_ | _] = reasons ->
        resets = Enum.map(reasons, &exhaustion_reset(&1, now))
        if Enum.all?(resets, &match?(%DateTime{}, &1)), do: Enum.min(resets, DateTime)

      _none ->
        nil
    end
  end

  defp exhaustion_reset(reason, now) when is_map(reason) do
    with true <- exhaustion?(reason),
         %DateTime{} = reset_at <- reset_at(reset_field(reason)),
         :gt <- DateTime.compare(reset_at, now) do
      reset_at
    else
      _unknown -> nil
    end
  end

  defp exhaustion_reset(_reason, _now), do: nil

  # A refusal that does not name its binding window carries its own advice:
  # a workspace-level provider denial (findings#206 row 206-522) and a
  # provider-blocked account availability (row 206-508). Every other
  # exhaustion returns with its window.
  defp reset_field(reason) do
    cond do
      provider_denied?(reason) -> field(reason, :hint_reset_at)
      is_nil(field(reason, :reset_at)) -> field(reason, :hint_reset_at)
      true -> field(reason, :reset_at)
    end
  end

  defp provider_denied?(reason), do: is_list(field(reason, :reason_codes)) and "provider_denied" in field(reason, :reason_codes)

  defp exhaustion?(reason) do
    field(reason, :code) == "quota_weekly_exhausted" or
      (is_list(field(reason, :reason_codes)) and "exhausted" in field(reason, :reason_codes))
  end

  defp reset_at(%DateTime{} = reset_at), do: reset_at

  defp reset_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, reset_at, _offset} -> reset_at
      {:error, _reason} -> nil
    end
  end

  defp reset_at(_value), do: nil

  defp usage_limit(reset_at, now) do
    seconds = max(ceil_div(DateTime.diff(reset_at, now, :millisecond), 1_000), 1)
    %{resets_at: ceil_unix(reset_at), resets_in_seconds: seconds}
  end

  defp ceil_unix(%DateTime{microsecond: {0, _precision}} = reset_at), do: DateTime.to_unix(reset_at)
  defp ceil_unix(reset_at), do: DateTime.to_unix(reset_at) + 1

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
