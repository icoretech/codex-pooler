defmodule CodexPoolerWeb.Admin.JobsPresentation.State do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  @default_job_state_presentation %{
    icon: "hero-question-mark-circle",
    icon_class: "mx-auto size-5 text-base-content/60",
    tone: :neutral,
    label: nil
  }

  @job_state_presentations %{
    "completed" => %{
      icon: "hero-check-circle",
      icon_class: "mx-auto size-5 text-success",
      tone: :success,
      label: nil
    },
    "discarded" => %{
      icon: "hero-x-circle",
      icon_class: "mx-auto size-5 text-error",
      tone: :error,
      label: nil
    },
    "cancelled" => %{
      icon: "hero-no-symbol",
      icon_class: "mx-auto size-5 text-warning",
      tone: :warning,
      label: nil
    },
    "executing" => %{
      icon: "hero-clock",
      icon_class: "mx-auto size-5 text-info",
      tone: :info,
      label: nil
    },
    "retryable" => %{
      icon: "hero-exclamation-triangle",
      icon_class: "mx-auto size-5 text-warning",
      tone: :warning,
      label: nil
    },
    "available" => %{
      icon: "hero-clock",
      icon_class: "mx-auto size-5 text-info",
      tone: :info,
      label: nil
    },
    "scheduled" => %{
      icon: "hero-clock",
      icon_class: "mx-auto size-5 text-info",
      tone: :info,
      label: nil
    },
    "awaiting_first_run" => %{
      icon: "hero-clock",
      icon_class: "mx-auto size-5 text-info",
      tone: :info,
      label: nil
    },
    "idle" => %{
      icon: "hero-minus-circle",
      icon_class: "mx-auto size-5 text-base-content/40",
      tone: :neutral,
      label: nil
    }
  }

  @spec tone(String.t() | nil) :: atom()
  def tone(state), do: presentation(state).tone

  @spec icon(String.t() | nil) :: String.t()
  def icon(state), do: presentation(state).icon

  @spec icon_class(String.t() | nil) :: String.t()
  def icon_class(state), do: presentation(state).icon_class

  @spec label(String.t() | nil) :: String.t()
  def label(nil), do: gettext("Unknown")
  def label("completed"), do: gettext("Completed")
  def label("discarded"), do: gettext("Discarded")
  def label("cancelled"), do: gettext("Cancelled")
  def label("executing"), do: gettext("Executing")
  def label("retryable"), do: gettext("Retryable")
  def label("available"), do: gettext("Available")
  def label("scheduled"), do: gettext("Scheduled")
  def label("awaiting_first_run"), do: gettext("Awaiting first run")
  def label("idle"), do: gettext("No observed run")
  def label("suspended"), do: gettext("Suspended")
  def label("unknown_state"), do: gettext("Unknown state")
  def label(_state), do: gettext("Unknown")

  defp presentation(state),
    do: Map.get(@job_state_presentations, state, @default_job_state_presentation)
end
