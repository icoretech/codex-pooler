defmodule CodexPooler.Alerts.StatusVocabulary.AssignmentState do
  @moduledoc """
  Bounded vocabulary of the per-assignment states an alert evaluation records
  in an incident's `state_counts` evidence, and their operator wording.

  Deliveries and the admin incident view only ever show counts for these
  states; anything else in stored evidence is dropped.
  """

  @labels [
    {"model_not_served", "model not served"},
    {"exhausted", "quota exhausted"},
    {"stale", "quota stale"},
    {"missing_evidence", "quota evidence missing"},
    {"weekly_only", "weekly-only quota evidence"},
    {"credit_backed_probe", "credit-backed quota probe"},
    {"usable", "quota usable"},
    {"reauth_required", "reauthorization required"},
    {"refresh_failed", "token refresh failed"}
  ]
  @states Enum.map(@labels, &elem(&1, 0))
  @max_count 1_000_000

  @spec states() :: [String.t()]
  def states, do: @states

  @doc """
  Known states with a positive integer count, keyed by state; nil when none
  remain. Unknown states, non-integer or out-of-range counts are dropped.
  """
  @spec bounded_counts(term()) :: %{optional(String.t()) => pos_integer()} | nil
  def bounded_counts(counts) when is_map(counts) do
    counts
    |> Enum.flat_map(fn {state, count} ->
      state = if is_atom(state), do: Atom.to_string(state), else: state

      if state in @states and is_integer(count) and count > 0 and count <= @max_count,
        do: [{state, count}],
        else: []
    end)
    |> case do
      [] -> nil
      entries -> Map.new(entries)
    end
  end

  def bounded_counts(_counts), do: nil

  @doc "Operator wording for bounded counts, in vocabulary order, e.g. `1 model not served, 2 quota stale`."
  @spec describe(term()) :: String.t() | nil
  def describe(counts) do
    case bounded_counts(counts) do
      nil ->
        nil

      bounded ->
        @labels
        |> Enum.filter(fn {state, _label} -> Map.has_key?(bounded, state) end)
        |> Enum.map_join(", ", fn {state, label} -> "#{Map.fetch!(bounded, state)} #{label}" end)
    end
  end
end
