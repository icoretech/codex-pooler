defmodule CodexPooler.Upstreams.SavedResets.RedemptionLifecycle do
  @moduledoc """
  Single source of truth for the saved-reset redemption lifecycle.

  A provider `reset` is an authoritative external side effect: the credit is
  consumed even when the immediate usage refresh is partial, omitted, or fails.
  To keep that truthful without fabricating quota, the redemption metadata
  carries a versioned `phase` alongside the legacy `status` field:

    * `consuming` — the consume POST is in flight; ambiguous (the provider may
      or may not have consumed a credit yet).
    * `consumed_pending_probe` — the provider returned `reset`; a credit was
      consumed and we are within the bounded window awaiting confirmation.
    * `confirmed_by_upstream` — the single guarded probe request completed
      successfully; the identity is temporarily routeable while fresh quota
      converges.
    * `confirmed_by_quota` — fresh matching provider quota evidence superseded
      the pending state; normal evidence-based routing is restored.
    * `reblocked` — fresh evidence proved genuine exhaustion, or the outcome was
      a non-consuming failure; the identity is blocked again.
    * `expired` — the bounded window elapsed without confirmation; fail-closed.

  The nonterminal phases (`consuming`, `consumed_pending_probe`) project to the
  legacy top-level `status` of `"redeeming"` so that readers written before the
  lifecycle existed keep treating an unconfirmed redemption as in progress and
  never start a second one.

  This module is pure: it never touches the repo. Callers persist transitions
  under the existing `FOR UPDATE` identity lock and use `can_transition?/4` as
  the compare-and-set guard so that late or duplicate events cannot reopen a
  settled lifecycle.
  """

  @consuming "consuming"
  @consumed_pending_probe "consumed_pending_probe"
  @confirmed_by_upstream "confirmed_by_upstream"
  @confirmed_by_quota "confirmed_by_quota"
  @reblocked "reblocked"
  @expired "expired"

  @phases [
    @consuming,
    @consumed_pending_probe,
    @confirmed_by_upstream,
    @confirmed_by_quota,
    @reblocked,
    @expired
  ]

  # Nonterminal phases still hold the consume/probe claim: they must block any
  # further credit consumption or probe on the same identity.
  @nonterminal [@consuming, @consumed_pending_probe]
  @terminal [@confirmed_by_upstream, @confirmed_by_quota, @reblocked, @expired]

  # The single bounded post-consume window. Long enough for scheduler
  # convergence, strictly fail-closed afterwards.
  @probe_grace_ms 15 * 60 * 1000

  @legacy_status_by_phase %{
    @consuming => "redeeming",
    @consumed_pending_probe => "redeeming",
    @confirmed_by_upstream => "succeeded",
    @confirmed_by_quota => "succeeded",
    @reblocked => "failed",
    @expired => "failed"
  }

  # Allowed compare-and-set transitions. A transition is valid only from one of
  # the listed predecessor phases; every other move (including a repeat of the
  # same phase or a jump from a terminal phase) is rejected.
  @transitions %{
    @consuming => [@consumed_pending_probe, @reblocked, @expired],
    @consumed_pending_probe => [
      @confirmed_by_upstream,
      @confirmed_by_quota,
      @reblocked,
      @expired
    ],
    @confirmed_by_upstream => [@confirmed_by_quota, @reblocked, @expired]
  }

  @type phase :: String.t()
  @type redemption :: map()

  @spec consuming() :: phase()
  def consuming, do: @consuming

  @spec consumed_pending_probe() :: phase()
  def consumed_pending_probe, do: @consumed_pending_probe

  @spec confirmed_by_upstream() :: phase()
  def confirmed_by_upstream, do: @confirmed_by_upstream

  @spec confirmed_by_quota() :: phase()
  def confirmed_by_quota, do: @confirmed_by_quota

  @spec reblocked() :: phase()
  def reblocked, do: @reblocked

  @spec expired() :: phase()
  def expired, do: @expired

  @spec phases() :: [phase()]
  def phases, do: @phases

  @spec probe_grace_ms() :: pos_integer()
  def probe_grace_ms, do: @probe_grace_ms

  @doc """
  Returns the recognized lifecycle phase carried by a redemption metadata map,
  or `nil` for legacy records that predate the lifecycle. An unrecognized
  `phase` value returns `:unknown` so callers can stay fail-closed.
  """
  @spec phase(redemption() | term()) :: phase() | :unknown | nil
  def phase(%{"phase" => phase}) when phase in @phases, do: phase
  def phase(%{"phase" => phase}) when is_binary(phase), do: :unknown
  def phase(_redemption), do: nil

  @spec known_phase?(term()) :: boolean()
  def known_phase?(phase), do: phase in @phases

  @spec terminal?(term()) :: boolean()
  def terminal?(phase), do: phase in @terminal

  @spec nonterminal?(term()) :: boolean()
  def nonterminal?(phase), do: phase in @nonterminal

  @doc """
  Maps a lifecycle phase to the legacy top-level `status` string so that a
  writer keeps the record readable by code that only knows `status`.
  """
  @spec legacy_status_for(phase()) :: String.t() | nil
  def legacy_status_for(phase), do: Map.get(@legacy_status_by_phase, phase)

  @doc """
  The deadline for the bounded probe window, computed from the consume time.
  """
  @spec deadline_at(DateTime.t()) :: DateTime.t()
  def deadline_at(%DateTime{} = consumed_at),
    do: DateTime.add(consumed_at, @probe_grace_ms, :millisecond)

  @doc """
  True once the bounded window has elapsed for a still-pending redemption.
  Reads the persisted `deadline_at`, falling back to `consumed_at + window`.
  """
  @spec expired?(redemption() | term(), DateTime.t()) :: boolean()
  def expired?(redemption, %DateTime{} = now) do
    case deadline(redemption) do
      %DateTime{} = deadline -> DateTime.compare(now, deadline) != :lt
      nil -> false
    end
  end

  @doc """
  Whether the identity must be held out of any further credit consumption or
  probe because a prior redemption is unconfirmed or fail-closed.

  Fail-closed by construction: nonterminal phases block, an elapsed pending
  window blocks (the credit is spent but unconfirmed), the terminal `expired`
  phase blocks (recovery is only via fresh evidence), and an unrecognized phase
  blocks. Legacy records without a phase return `false` here and are governed by
  the pre-existing freshness logic.
  """
  @spec blocks_new_redemption?(redemption() | term(), DateTime.t()) :: boolean()
  def blocks_new_redemption?(redemption, %DateTime{} = _now) do
    case phase(redemption) do
      phase when phase in @nonterminal -> true
      @expired -> true
      :unknown -> true
      _absent_or_settled -> false
    end
  end

  @doc """
  Whether the identity is currently routeable on the strength of the lifecycle
  alone: a successful probe within its window, or quota-confirmed recovery.
  """
  @spec routeable?(redemption() | term(), DateTime.t()) :: boolean()
  def routeable?(redemption, %DateTime{} = now) do
    case phase(redemption) do
      @confirmed_by_quota -> true
      @confirmed_by_upstream -> not expired?(redemption, now)
      _other -> false
    end
  end

  @doc """
  Compare-and-set guard for a lifecycle transition. The move is permitted only
  when the record still matches the expected `generation` and `attempt_id` and
  the target phase is a declared successor of the current phase. A record
  without a phase may only enter `consuming` (the lifecycle entry point).
  """
  @spec can_transition?(redemption() | term(), phase(), integer(), term()) :: boolean()
  def can_transition?(redemption, to_phase, expected_generation, expected_attempt_id) do
    to_phase in @phases and
      matches_identity?(redemption, expected_generation, expected_attempt_id) and
      allowed_transition?(phase(redemption), to_phase)
  end

  defp allowed_transition?(nil, @consuming), do: true
  defp allowed_transition?(nil, _to_phase), do: false
  defp allowed_transition?(:unknown, _to_phase), do: false

  defp allowed_transition?(from_phase, to_phase) when from_phase in @phases,
    do: to_phase in Map.get(@transitions, from_phase, [])

  defp allowed_transition?(_from_phase, _to_phase), do: false

  defp matches_identity?(%{} = redemption, expected_generation, expected_attempt_id) do
    generation_matches?(Map.get(redemption, "generation"), expected_generation) and
      attempt_matches?(Map.get(redemption, "attempt_id"), expected_attempt_id)
  end

  defp matches_identity?(_redemption, _expected_generation, _expected_attempt_id), do: false

  defp generation_matches?(_actual, nil), do: true
  defp generation_matches?(actual, expected), do: actual == expected

  defp attempt_matches?(_actual, nil), do: true
  defp attempt_matches?(actual, expected), do: actual == expected

  defp deadline(%{"deadline_at" => deadline_at}) when is_binary(deadline_at) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, deadline, _offset} -> deadline
      _invalid -> nil
    end
  end

  defp deadline(%{"consumed_at" => consumed_at}) when is_binary(consumed_at) do
    case DateTime.from_iso8601(consumed_at) do
      {:ok, consumed, _offset} -> deadline_at(consumed)
      _invalid -> nil
    end
  end

  defp deadline(_redemption), do: nil
end
