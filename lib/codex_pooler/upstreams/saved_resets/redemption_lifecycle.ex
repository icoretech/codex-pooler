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

  # Minimum spacing between an applied consume and the next automatic consume.
  # Deliberately larger than the probe window: the provider has been observed
  # re-serving pre-reset quota values with fresh observation timestamps for
  # ~18 minutes after a reset, and post-consume classification can settle a
  # threshold-mode record to `confirmed_by_quota` on exactly that stale data.
  @gateway_auto_consume_cooldown_ms 30 * 60 * 1000
  @future_consume_tolerance_ms 60 * 1000

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
  # same phase) is rejected. `expired` is terminal for the probe but not for the
  # record: fresh provider evidence may still settle it, otherwise one elapsed
  # confirmation window would disable saved resets on the identity forever.
  @transitions %{
    @consuming => [@consumed_pending_probe, @reblocked, @expired],
    @consumed_pending_probe => [
      @confirmed_by_upstream,
      @confirmed_by_quota,
      @reblocked,
      @expired
    ],
    @confirmed_by_upstream => [@confirmed_by_quota, @reblocked, @expired],
    @expired => [@confirmed_by_quota, @reblocked]
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

  @spec gateway_auto_consume_cooldown_ms() :: pos_integer()
  def gateway_auto_consume_cooldown_ms, do: @gateway_auto_consume_cooldown_ms

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

  Fail-closed by construction: a consumed-but-unconfirmed credit blocks even
  past its window, a consumed credit that fresh evidence reblocked remains
  one-shot, the `expired` phase blocks (recovery is only via fresh evidence
  through convergence), and an unrecognized phase blocks. The
  `consuming` phase is deliberately NOT blocked here: it keeps the legacy
  `redeeming` status, so the pre-existing freshness gates govern the in-flight
  window and the stale-recovery path can resume the attempt after a crash.
  Legacy records without a phase also return `false` for the same reason.
  """
  @spec blocks_new_redemption?(redemption() | term(), DateTime.t()) :: boolean()
  def blocks_new_redemption?(redemption, %DateTime{} = _now) do
    case phase(redemption) do
      @consumed_pending_probe -> true
      @reblocked -> consumed_credit?(redemption)
      @expired -> true
      :unknown -> true
      _absent_in_flight_or_settled -> false
    end
  end

  defp consumed_credit?(%{"result" => %{"applied" => true}}), do: true
  defp consumed_credit?(_redemption), do: false

  @doc """
  True when the record represents a consume that actually spent a credit —
  regardless of who triggered it. Any applied consume arms the automatic
  latch below: a manual redemption is the operator's own spend, and a
  follow-on automatic spend against the same not-yet-converged evidence is
  still an automatic spend the operator did not ask for.
  """
  @spec applied_consume?(redemption() | term()) :: boolean()
  def applied_consume?(redemption), do: consumed_credit?(redemption)

  @doc """
  At most one automatic consume per exhaustion episode. After any applied
  consume, another automatic consume is not allowed to trust quota evidence
  the provider may still be serving from the pre-reset cycle (observation
  timestamps refresh even while the values stay stale, so recency alone
  proves nothing — and in threshold mode that same stale data can settle the
  record to `confirmed_by_quota` within seconds of the consume):

    * `:blocked_awaiting_quota` — the credit was spent but fresh post-consume
      provider evidence has not superseded the stale state (`confirmed_by_quota`
      not reached). This closes the `confirmed_by_upstream` gap; the other
      spent phases already block through `blocks_new_redemption?/2`.
    * `:cooldown` — evidence converged (or the record predates the lifecycle),
      but the consume is younger than the automatic-consume cooldown. This is
      the load-bearing floor for threshold mode, where stale sub-exhausted
      values self-confirm; it is sized above the observed provider staleness.
    * `:clear` — no applied consume is latching automatic redemption.

  Legacy records without a phase can never reach `confirmed_by_quota`, so they
  get only the temporal floor — a latch that never lifts would disable saved
  resets on the identity forever. Manual redemption never consults this latch:
  it is the operator override.
  """
  @spec gateway_auto_latch(redemption() | term(), DateTime.t()) ::
          :blocked_awaiting_quota | :cooldown | :clear
  def gateway_auto_latch(redemption, %DateTime{} = now) do
    cond do
      not applied_consume?(redemption) ->
        if within_carried_consume_cooldown?(redemption, now), do: :cooldown, else: :clear

      phase(redemption) in [nil, @confirmed_by_quota] ->
        if within_consume_cooldown?(redemption, now), do: :cooldown, else: :clear

      true ->
        :blocked_awaiting_quota
    end
  end

  @doc """
  The applied-consume timestamp a replacement claim must carry so an
  unapplied overwrite (for example a failed manual attempt) cannot disarm
  the cooldown inside the same provider-staleness window.
  """
  @spec carried_applied_consume_at(redemption() | term()) :: String.t() | nil
  def carried_applied_consume_at(redemption) do
    if applied_consume?(redemption) do
      case consumed_or_started_at(redemption) do
        %DateTime{} = consumed_at -> DateTime.to_iso8601(consumed_at)
        nil -> carried_consume_value(redemption)
      end
    else
      carried_consume_value(redemption)
    end
  end

  defp carried_consume_value(%{"last_applied_consume_at" => value}) when is_binary(value),
    do: value

  defp carried_consume_value(_redemption), do: nil

  defp within_carried_consume_cooldown?(redemption, now) do
    case redemption do
      %{"last_applied_consume_at" => value} when is_binary(value) ->
        case parse_datetime(value) do
          %DateTime{} = carried_at -> within_cooldown_window?(carried_at, now)
          nil -> false
        end

      _redemption ->
        false
    end
  end

  defp within_consume_cooldown?(redemption, now) do
    case consumed_or_started_at(redemption) do
      %DateTime{} = consumed_at ->
        within_cooldown_window?(consumed_at, now)

      nil ->
        false
    end
  end

  # A grossly future-dated consume timestamp (broken writer clock) must not
  # hold the latch until the reader's clock catches up; small skew keeps the
  # cooldown, anything beyond the tolerance fails open per the
  # no-permanent-latch rule.
  defp within_cooldown_window?(%DateTime{} = consumed_at, now) do
    elapsed_ms = DateTime.diff(now, consumed_at, :millisecond)

    elapsed_ms >= -@future_consume_tolerance_ms and
      elapsed_ms < @gateway_auto_consume_cooldown_ms
  end

  defp consumed_or_started_at(%{"consumed_at" => consumed_at} = redemption)
       when is_binary(consumed_at) do
    parse_datetime(consumed_at) || started_at(redemption)
  end

  defp consumed_or_started_at(redemption), do: started_at(redemption)

  defp started_at(%{"started_at" => started_at}) when is_binary(started_at),
    do: parse_datetime(started_at)

  defp started_at(_redemption), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  @doc """
  Whether the identity is currently routeable on the strength of the lifecycle
  alone: a confirmed redemption within its bounded window. Outside the window
  the lifecycle grants nothing — routing must rest on quota evidence again, or
  an identity that ever redeemed successfully would bypass a later genuine
  exhaustion forever.
  """
  @spec routeable?(redemption() | term(), DateTime.t()) :: boolean()
  def routeable?(redemption, %DateTime{} = now) do
    case phase(redemption) do
      phase when phase in [@confirmed_by_quota, @confirmed_by_upstream] ->
        not expired?(redemption, now)

      _other ->
        false
    end
  end

  @doc """
  The correlation token currently holding the one-shot probe claim, or `nil`.
  """
  @spec probe_holder(redemption() | term()) :: String.t() | nil
  def probe_holder(%{"probe" => %{"token" => token}}) when is_binary(token), do: token
  def probe_holder(_redemption), do: nil

  @doc "True when `token` holds the probe claim on this redemption."
  @spec holds_probe?(redemption() | term(), String.t()) :: boolean()
  def holds_probe?(redemption, token) when is_binary(token), do: probe_holder(redemption) == token
  def holds_probe?(_redemption, _token), do: false

  @doc """
  Whether a fresh probe claim can still be made: the redemption is pending, no
  token holds the probe yet, and the bounded window has not elapsed. Irreversible
  by design — a claimed or expired probe is never re-claimable.
  """
  @spec probe_claimable?(redemption() | term(), DateTime.t()) :: boolean()
  def probe_claimable?(redemption, %DateTime{} = now) do
    phase(redemption) == @consumed_pending_probe and probe_holder(redemption) == nil and
      not expired?(redemption, now)
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
