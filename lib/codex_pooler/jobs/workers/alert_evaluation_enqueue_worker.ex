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

  alias CodexPooler.Jobs

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Jobs.enqueue_alert_evaluations_for_active_rules(trigger_kind: "scheduled") do
      {:ok, %{errors: []}} -> :ok
      {:ok, %{errors: errors}} -> {:error, {:enqueue_failed, length(errors)}}
    end
  end
end
