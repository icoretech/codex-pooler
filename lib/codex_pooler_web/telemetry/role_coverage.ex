defmodule CodexPoolerWeb.Telemetry.RoleCoverage do
  @moduledoc """
  Declares which telemetry events this application emits from an `OBAN_MODE`
  role whose series never reach Prometheus.

  `CodexPoolerWeb.Telemetry.prometheus_reporter_enabled?/0` switches the
  Prometheus reporter off for `OBAN_MODE=worker` and `OBAN_MODE=scheduler`, and
  the public Helm chart's `ServiceMonitor` selects only the `app` pods, so on a
  split-role deployment an event emitted from a job never becomes a series. The
  event fires, in-process handlers see it, a focused test is green and a panel
  renders — and the graph is empty forever. An operator reads that as "this
  never happens" rather than "this is not measured here".

  Nothing at the point of declaration says so: a counter for a job-run event
  looks exactly like a counter for a request event. This module is the place
  where it does say so, and `CodexPoolerWeb.Telemetry.RoleCoverageTest` derives
  the same set from the compiled application and fails when the two disagree,
  so the next metric in this shape cannot arrive unnoticed.

  ## What a declaration asserts

  Each entry names the event, the Oban worker modules whose `perform/1` can
  reach an emission site for it, whether web traffic also emits it, and the
  durable rows an operator reads instead. Those `entrypoints` are checked
  against the derived call graph too, so a second worker reaching an
  already-declared event also fails the guard.

  ## What the derivation cannot see

  The derived call graph is intra-process: local calls, remote calls, function
  captures and inline closures, walked from each Oban worker's `perform/1`.
  That matches where `:telemetry.execute/3` runs, because telemetry is emitted
  in the calling process, and a `Task` started by a job still runs on the job's
  node. It deliberately does not follow a message to another process: a
  `GenServer.call/3` into a session owner is served wherever that owner lives,
  which is usually a web node, and treating it as a worker emission produced a
  false member during the audit. The cost of that choice is a blind spot for a
  process started by the supervision tree on every role and messaged from a
  job; when a metric is emitted from such a callback, declare it here by hand
  with `entrypoints: []` and say so in the note.

  The scheduler role runs Oban's cron, lifeline and pruner plugins and no
  application emitter of its own: cron *inserts* the jobs that the worker role
  then executes. Both roles are unscraped, so the conclusion is unchanged, but
  a declaration names the worker that runs the job rather than the scheduler
  that enqueued it.
  """

  @typedoc "How much of an event's traffic reaches Prometheus."
  @type coverage :: :partial | :unscraped_only

  @typedoc "One declared event whose emissions cross the unscraped-role boundary."
  @type declaration :: %{
          entrypoints: [module()],
          coverage: coverage(),
          fallback: String.t(),
          note: String.t()
        }

  # Mirrors the modes `CodexPoolerWeb.Telemetry.prometheus_reporter_enabled?/0`
  # refuses to start the reporter for. The test asserts the two agree by calling
  # that function rather than by reading its source, so changing the gate
  # without revisiting this list fails.
  @unscraped_oban_modes ~w(worker scheduler)

  # A metric and panel description for a declared event has to name the gate
  # that empties it. `OBAN_MODE` is that name: it is what an operator greps for
  # and what the chart sets, and no honest caveat avoids it.
  @caveat_marker "OBAN_MODE"

  @unscraped_emissions %{
    [:codex_pooler, :accounting, :reservation, :pre_attempt_release] => %{
      entrypoints: [CodexPooler.Jobs.RuntimeStateCleanupWorker],
      coverage: :partial,
      fallback: "the request ledger's pre_attempt_phase detail",
      note:
        "The runtime cleanup job releases reservations no live turn ever reached and stamps " <>
          "them stale_sweep, so that phase is exported only under OBAN_MODE=all. Every other " <>
          "phase is released on the request path and is exported normally."
    },
    [:codex_pooler, :saved_reset, :convergence] => %{
      entrypoints: [
        CodexPooler.Jobs.AccountReconciliationWorker,
        CodexPooler.Jobs.SavedResetRedemptionWorker
      ],
      coverage: :partial,
      fallback: "the saved-reset audit trail",
      note:
        "The redemption finalizer emits convergence, and it runs both on the request path and " <>
          "inside the redemption and reconciliation jobs. The rate and latency panels chart " <>
          "the web share only."
    },
    [:codex_pooler, :quota, :cycle, :decision] => %{
      entrypoints: [
        CodexPooler.Jobs.AccountReconciliationWorker,
        CodexPooler.Jobs.AlertEvaluationWorker,
        CodexPooler.Jobs.SavedResetRedemptionWorker
      ],
      coverage: :partial,
      fallback: "the account quota window rows and their evidence history",
      note:
        "Account reconciliation is the bulk writer of quota evidence and decides cycles while " <>
          "persisting it; saved-reset redemption classifies post-reset evidence and alert " <>
          "evaluation reads routing snapshots, and both reject superseded primary windows on " <>
          "the way. All three run as jobs, so the decision counter under-reports by however " <>
          "much reconciliation does."
    },
    [:codex_pooler, :gateway, :stream, :outcome] => %{
      entrypoints: [CodexPooler.Jobs.RuntimeStateCleanupWorker],
      coverage: :partial,
      fallback: "the accounting request and attempt rows for interrupted turns",
      note:
        "Recovering an expired owner lease settles the turns it abandoned and emits their " <>
          "interrupted outcome from the runtime cleanup job, so the interrupted slice is " <>
          "under-counted while the outcomes settled on the request path are complete."
    }
  }

  @doc "OBAN_MODE values whose processes run no Prometheus reporter."
  @spec unscraped_oban_modes() :: [String.t()]
  def unscraped_oban_modes, do: @unscraped_oban_modes

  @doc "Substring every metric and panel description for a declared event must contain."
  @spec caveat_marker() :: String.t()
  def caveat_marker, do: @caveat_marker

  @doc "The declared events, each with the roles that emit them and the durable fallback."
  @spec unscraped_emissions() :: %{[atom()] => declaration()}
  def unscraped_emissions, do: @unscraped_emissions

  @doc "Telemetry events declared to have at least one emission on an unscraped role."
  @spec declared_events() :: [[atom()]]
  def declared_events, do: Map.keys(@unscraped_emissions)

  @doc "Whether `event` is declared to emit on an unscraped role."
  @spec declared?([atom()]) :: boolean()
  def declared?(event) when is_list(event), do: Map.has_key?(@unscraped_emissions, event)

  @doc """
  Whether `description` carries the caveat a declared event's metric and panels owe an operator.
  """
  @spec caveat_present?(term()) :: boolean()
  def caveat_present?(description) when is_binary(description),
    do: String.contains?(description, @caveat_marker)

  def caveat_present?(_description), do: false
end
