defmodule CodexPooler.Jobs.AlertEvaluationEnqueueWorker do
  @moduledoc """
  Periodically enqueues alert rule evaluation jobs for active alert rules.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 1,
    tags: ["alert_evaluation_enqueue"],
    unique: [
      fields: [:worker, :queue],
      states: :incomplete,
      period: {5, :minutes}
    ]

  require Logger

  alias CodexPooler.Alerts
  alias CodexPooler.Jobs

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{scheduled_at: %DateTime{} = scheduled_at}) do
    # Incidents whose rules were all deleted are resolved here, because no
    # per-rule evaluation will ever clear them (findings#260 row 260-31). A
    # failed resolution never holds back the evaluations themselves.
    case Alerts.resolve_orphaned_incidents(scheduled_at) do
      {:ok, _resolved} -> :ok
      {:error, %Ecto.Changeset{}} -> Logger.warning("alert orphaned incident resolution failed error=invalid_incident_changeset")
    end

    case Jobs.enqueue_alert_evaluations_for_active_rules(
           trigger_kind: "scheduled",
           now: scheduled_at
         ) do
      {:ok, %{errors: []}} -> :ok
      {:ok, %{errors: errors}} -> {:error, {:enqueue_failed, length(errors)}}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_alert_evaluation_args}
end
