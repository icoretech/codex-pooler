defmodule CodexPooler.Accounting.PreAttemptRelease do
  @moduledoc """
  Bounded vocabulary for reservation releases written with no attempt row.

  A reservation released before any upstream attempt exists used to record only
  `release_reason`, which every caller fills with its own error code, and a
  `request_status` that is always the terminal status the same write just set.
  Nothing said *where* in the pre-attempt sequence the reservation was let go,
  and nothing separated a pre-attempt release from a settlement-time release
  without joining `attempts`. The only durable trace of a recurring pre-attempt
  abandonment was therefore a `stale_reservation_recovered` row the six-hour
  backstop wrote, six hours late, using the same error code as the sweeper's
  dispatched-attempt branch.

  `detail_key/0` is written into every reservation-failure release entry so
  three states stay distinguishable, per the repository's sanitizer rule:

    * the key is **absent** — the entry is not a pre-attempt release (a
      settlement-time release carries an `attempt_id`), or it predates this
      field;
    * `"unrecorded"` — this *is* a pre-attempt release, and the caller declared
      no phase: we let the reservation go without an attempt and cannot say
      where;
    * any other member of `phases/0` — the declared phase.

  The vocabulary describes the boundary that released the reservation, not the
  cause. The cause stays in `release_reason`, which the release entry already
  carries.
  """

  @detail_key "pre_attempt_phase"

  @routing_rejected "routing_rejected"
  @stale_sweep "stale_sweep"
  @unrecorded "unrecorded"

  @phases [@routing_rejected, @stale_sweep, @unrecorded]

  @telemetry_event [:codex_pooler, :accounting, :reservation, :pre_attempt_release]

  @doc "Ledger-entry `details` key carrying the bounded phase."
  @spec detail_key() :: String.t()
  def detail_key, do: @detail_key

  @doc "Every phase this vocabulary admits."
  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc """
  Routing refused to dispatch before any attempt existed.

  A deliberate refusal, not an abandonment: the turn never had an upstream to
  reach. Counting these apart from the rest is what keeps a rise in genuine
  abandonment visible.
  """
  @spec routing_rejected() :: String.t()
  def routing_rejected, do: @routing_rejected

  @doc """
  The six-hour backstop released a reservation no live path ever closed.

  Distinct from `unrecorded/0`: here we know that nothing reached the turn at
  all, which is the condition worth alerting on.
  """
  @spec stale_sweep() :: String.t()
  def stale_sweep, do: @stale_sweep

  @doc """
  A live path released the reservation without declaring its phase.

  Preserved as its own value rather than left absent, so it never reads as a
  row written before the field existed.
  """
  @spec unrecorded() :: String.t()
  def unrecorded, do: @unrecorded

  @doc """
  Bounds a caller-supplied phase to `phases/0`.

  Anything outside the vocabulary — including `nil` and unknown strings —
  becomes `unrecorded/0`, so an unbounded value can never reach the ledger and
  an unclassified release is still recorded as one.
  """
  @spec phase(term()) :: String.t()
  def phase(value) when value in @phases, do: value
  def phase(value) when is_atom(value) and not is_nil(value), do: phase(Atom.to_string(value))
  def phase(_value), do: @unrecorded

  @doc "Telemetry event name emitted once per committed pre-attempt release."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  Counts one committed pre-attempt release.

  Emitted after the transaction commits, so a rolled-back finalization is not
  counted. `transport` and `phase` are both bounded, and no request, session,
  or key identifier is carried.
  """
  @spec emit(String.t(), String.t() | nil, String.t() | nil) :: :ok
  def emit(phase, transport, release_reason) do
    :telemetry.execute(
      @telemetry_event,
      %{count: 1},
      %{phase: phase(phase), transport: transport, release_reason: release_reason}
    )
  end
end
