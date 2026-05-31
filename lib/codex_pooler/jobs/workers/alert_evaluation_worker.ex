defmodule CodexPooler.Jobs.AlertEvaluationWorker do
  @moduledoc """
  Evaluates one alert rule against persisted metadata and records incident state.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 1,
    tags: ["alert_evaluation"],
    unique: [
      fields: [:args, :queue, :worker],
      keys: [:alert_rule_id, :evaluation_window_started_at],
      states: :incomplete,
      period: {7, :days}
    ]

  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Evaluator
  alias CodexPooler.Alerts.Schemas.AlertIncident

  @type evaluation_error ::
          :alert_rule_not_found
          | :invalid_alert_evaluation_args
          | :invalid_evaluation_window_started_at
          | %{required(:action) => String.t(), required(:code) => String.t()}

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "alert_rule_id" => rule_id,
          "evaluation_window_started_at" => evaluation_window_started_at
        }
      }) do
    with {:ok, timestamp} <- parse_evaluation_window(evaluation_window_started_at),
         {:ok, rule} <- Alerts.fetch_rule_for_evaluation(rule_id),
         :ok <- evaluate_and_record(rule, timestamp) do
      :ok
    else
      {:error, reason}
      when reason in [:alert_rule_not_found, :invalid_evaluation_window_started_at] ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_alert_evaluation_args}

  @spec evaluate_and_record(term(), DateTime.t()) :: :ok | {:error, evaluation_error()}
  defp evaluate_and_record(rule, timestamp) do
    rule
    |> Alerts.evaluate_rule(at: timestamp)
    |> Enum.reduce_while(:ok, fn candidate, :ok ->
      case record_candidate(candidate) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec record_candidate(Evaluator.candidate()) :: :ok | {:error, evaluation_error()}
  defp record_candidate(%{action: :match, match_attrs: attrs}) do
    case Alerts.record_incident_match(attrs) do
      {:ok, %AlertIncident{} = incident} -> enqueue_match_deliveries(incident)
      {:error, reason} -> {:error, candidate_error(:match, reason)}
    end
  end

  defp record_candidate(%{action: :clear, clear_attrs: attrs}) do
    case Alerts.clear_incident_condition(attrs) do
      {:ok, %AlertIncident{}} -> :ok
      {:ok, nil} -> :ok
      {:error, reason} -> {:error, candidate_error(:clear, reason)}
    end
  end

  defp record_candidate(_candidate), do: {:error, :invalid_alert_evaluation_args}

  defp enqueue_match_deliveries(%AlertIncident{} = incident) do
    case CodexPooler.Jobs.enqueue_alert_deliveries_for_incident(incident,
           trigger_kind: "incident_match",
           now: incident.last_seen_at
         ) do
      {:ok, %{errors: []}} ->
        :ok

      {:ok, %{errors: errors}} when is_list(errors) ->
        {:error, candidate_error(:match, %{code: :alert_delivery_enqueue_failed})}

      {:error, reason} ->
        {:error, candidate_error(:match, reason)}
    end
  end

  defp parse_evaluation_window(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, DateTime.truncate(timestamp, :microsecond)}
      {:error, _reason} -> {:error, :invalid_evaluation_window_started_at}
    end
  end

  defp parse_evaluation_window(_value), do: {:error, :invalid_evaluation_window_started_at}

  defp candidate_error(action, %Ecto.Changeset{}),
    do: %{action: Atom.to_string(action), code: "invalid_incident_attrs"}

  defp candidate_error(action, %{code: code}) when is_atom(code),
    do: %{action: Atom.to_string(action), code: Atom.to_string(code)}

  defp candidate_error(action, _reason),
    do: %{action: Atom.to_string(action), code: "incident_lifecycle_failed"}
end
