defmodule CodexPooler.Gateway.Routing.CandidateEligibility.UsageLimit do
  @moduledoc """
  The terminal answer of a Pool whose every candidate is quota-exhausted with a
  known reset (findings#206 row 206-508).

  The provider answers an exhausted account with `429`, `error.type`
  `usage_limit_reached`, `resets_at` (epoch seconds) and `resets_in_seconds`;
  the released Codex client ends the turn on it and names the reset, where it
  resends a `503` as a transient fault. When routing excluded every candidate
  for exhaustion and each exhausted window carries a reset still ahead, the
  Pool is in the same state, and its earliest availability is the soonest of
  the candidates' own resets (a candidate is back when the last of its
  exhausted windows resets).

  A candidate with any exclusion that is not a reset-bearing exhaustion (stale,
  resetless or missing evidence, a pending saved-reset probe, a provider
  `blocked` availability without a window) has no known return time, so the
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
        if Enum.all?(resets, &match?(%DateTime{}, &1)), do: Enum.max(resets, DateTime)

      _none ->
        nil
    end
  end

  defp exhaustion_reset(reason, now) when is_map(reason) do
    with true <- exhaustion?(reason),
         %DateTime{} = reset_at <- reset_at(field(reason, :reset_at)),
         :gt <- DateTime.compare(reset_at, now) do
      reset_at
    else
      _unknown -> nil
    end
  end

  defp exhaustion_reset(_reason, _now), do: nil

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
