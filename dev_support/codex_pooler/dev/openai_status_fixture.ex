defmodule CodexPooler.Dev.OpenAIStatusFixture do
  @moduledoc "Deterministic, provider-free OpenAI status rows for local admin QA."

  import Ecto.Query

  alias CodexPooler.OpenAIStatus
  alias CodexPooler.Repo
  alias CodexPooler.Status.Schemas.Incident

  @prefix "dev-openai-status-"

  @spec seed(atom()) :: {:ok, map()} | {:error, String.t()}
  def seed(scenario) when scenario in [:active, :mixed, :stale] do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.delete_all(from(i in Incident, where: like(i.guid, ^(@prefix <> "%"))))

    rows = rows(scenario, now)

    Enum.each(rows, fn attrs ->
      {:ok, _incident} = OpenAIStatus.upsert_incident(attrs, now)
    end)

    last_success_at = if scenario == :stale, do: DateTime.add(now, -90_000, :second), else: now

    {:ok, state} =
      OpenAIStatus.upsert_feed_state(%{
        last_success_at: last_success_at,
        last_attempt_at: now,
        active_count: Enum.count(rows, &(&1.status != "Resolved")),
        aggregate_revision: now |> DateTime.to_unix(),
        updated_at: now,
        last_error_code: nil,
        last_error_at: nil
      })

    {:ok,
     %{scenario: scenario, incidents: length(rows), aggregate_revision: state.aggregate_revision}}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  def seed(_scenario), do: {:error, "scenario must be active, mixed, or stale"}

  defp rows(:active, now),
    do: [row("active", "Investigating", "Synthetic API availability incident", now)]

  defp rows(:mixed, now) do
    [
      row("one", "Investigating", "Synthetic API availability incident", now),
      row("two", "Identified", "Synthetic response delay incident", now),
      row("three", "Monitoring", "Synthetic degraded service incident", now),
      row(
        "resolved",
        "Resolved",
        "Synthetic resolved incident",
        DateTime.add(now, -3600, :second)
      )
    ]
  end

  defp rows(:stale, now),
    do: [
      row(
        "stale",
        "Investigating",
        "Synthetic stale incident",
        DateTime.add(now, -90_000, :second)
      )
    ]

  defp row(id, status, title, published_at) do
    %{
      guid: @prefix <> id,
      title: title,
      status: status,
      summary: "Synthetic local fixture data for responsive admin QA.",
      component: "Synthetic component",
      link: "https://status.openai.com/incidents/" <> @prefix <> id,
      published_at: published_at,
      content_hash: "fixture-" <> id
    }
  end
end
