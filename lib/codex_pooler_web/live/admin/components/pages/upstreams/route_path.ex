defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.RoutePath do
  @moduledoc """
  Shared route-path model for an upstream assignment: the three gates a
  request crosses (assignment → health → quota), each with a readiness flag,
  tone, and a spoken detail label. Rendered as chevron segments by the
  upstream index card and the cockpit routing lanes.
  """

  @type segment :: %{
          key: String.t(),
          label: String.t(),
          detail_label: String.t(),
          ready?: boolean(),
          tone: :success | :warning | :error
        }

  @spec segments(map()) :: [segment()]
  def segments(assignment) do
    [
      %{
        key: "assignment",
        label: "Assignment",
        detail_label: assignment_state_label(Map.get(assignment, :status)),
        ready?: Map.get(assignment, :status) == "active",
        tone: assignment_state_tone(Map.get(assignment, :status))
      },
      %{
        key: "health",
        label: "Health",
        detail_label: assignment_health_label(Map.get(assignment, :health_status)),
        ready?: Map.get(assignment, :health_status) == "active",
        tone: assignment_health_tone(Map.get(assignment, :health_status))
      },
      %{
        key: "quota",
        label: "Quota",
        detail_label: Map.get(assignment, :quota_priming_label) || "Quota unknown",
        ready?: quota_priming_ready?(Map.get(assignment, :quota_priming_status)),
        tone: quota_priming_tone(Map.get(assignment, :quota_priming_status))
      }
    ]
  end

  @spec ready_count(map()) :: non_neg_integer()
  def ready_count(assignment) do
    assignment
    |> segments()
    |> Enum.count(& &1.ready?)
  end

  @spec aria_label(map()) :: String.t()
  def aria_label(assignment) do
    segment_labels =
      assignment
      |> segments()
      |> Enum.map_join(", ", & &1.detail_label)

    "#{Map.get(assignment, :pool_label, "Pool")} route path: #{segment_labels}"
  end

  @spec segment_class(segment()) :: [String.t()]
  def segment_class(%{tone: :success}),
    do: [segment_base_class(), "bg-success/80 text-success-content"]

  def segment_class(%{tone: :warning}),
    do: [segment_base_class(), "bg-warning/80 text-warning-content"]

  def segment_class(%{tone: :error}), do: [segment_base_class(), "bg-error/80 text-error-content"]
  def segment_class(_segment), do: [segment_base_class(), "bg-base-300/70 text-base-content/55"]

  defp segment_base_class, do: "route-chevron"

  defp assignment_state_label("active"), do: "Assignment active"
  defp assignment_state_label("paused"), do: "Assignment paused"
  defp assignment_state_label("disabled"), do: "Assignment disabled"
  defp assignment_state_label("deleted"), do: "Assignment deleted"
  defp assignment_state_label(status), do: "Assignment #{human_status_label(status)}"

  defp assignment_health_label("active"), do: "Health active"
  defp assignment_health_label("degraded"), do: "Health degraded"
  defp assignment_health_label("errored"), do: "Health errored"
  defp assignment_health_label(status), do: "Health #{human_status_label(status)}"

  defp assignment_state_tone("active"), do: :success
  defp assignment_state_tone("paused"), do: :warning
  defp assignment_state_tone("deleted"), do: :error
  defp assignment_state_tone("disabled"), do: :error
  defp assignment_state_tone(_status), do: :warning

  defp assignment_health_tone("active"), do: :success
  defp assignment_health_tone("degraded"), do: :warning
  defp assignment_health_tone("errored"), do: :error
  defp assignment_health_tone(_status), do: :warning

  defp quota_priming_ready?(status), do: status in ["known", "weekly_only_probe"]

  defp quota_priming_tone(status) when status in ["known", "weekly_only_probe"], do: :success
  defp quota_priming_tone(status) when status in ["failed", "blocked", "expired"], do: :error
  defp quota_priming_tone(_status), do: :warning

  defp human_status_label(value) when is_binary(value) and value != "" do
    value
    |> String.replace("_", " ")
    |> String.downcase()
  end

  defp human_status_label(_value), do: "unknown"
end
