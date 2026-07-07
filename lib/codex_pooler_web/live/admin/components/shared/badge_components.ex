defmodule CodexPoolerWeb.Admin.BadgeComponents do
  @moduledoc """
  Shared admin status, count, routing, and plan presentation helpers.
  """
  use CodexPoolerWeb, :html

  @canonical_plan_labels %{
    "business" => "Business",
    "chatgpt plus" => "ChatGPT Plus",
    "chatgpt pro" => "ChatGPT Pro",
    "chatgpt team" => "ChatGPT Team",
    "edu" => "Edu",
    "education" => "Education",
    "enterprise" => "Enterprise",
    "free" => "Free",
    "free plan" => "Free",
    "plus" => "Plus",
    "pro" => "Pro",
    "team" => "Team"
  }

  @routing_strategy_presentations %{
    "bridge_ring" => %{
      label: "Bridge ring",
      icon: "hero-arrow-path-rounded-square"
    },
    "deterministic_rotation" => %{
      label: "Deterministic rotation",
      icon: "hero-arrow-path"
    },
    "least_recent_success" => %{
      label: "Least recent success",
      icon: "hero-clock"
    },
    "quota_first" => %{
      label: "Quota first",
      icon: "hero-chart-bar-square"
    }
  }

  def status_chip_class(status) when is_atom(status),
    do: status |> Atom.to_string() |> status_chip_class()

  def status_chip_class(status) do
    case to_string(status) do
      status
      when status in ["active", "accepted", "succeeded", "eligible", "present", "known", "ok"] ->
        chip_class(:success)

      status
      when status in [
             "disabled",
             "paused",
             "cancelled",
             "interrupted",
             "refresh_due",
             "half_open",
             "resetless_unprimed",
             "weekly_only_probe",
             "weekly_only_evidence"
           ] ->
        chip_class(:warning)

      status
      when status in [
             "archived",
             "revoked",
             "failed",
             "rejected",
             "refresh_failed",
             "reauth_required",
             "expired",
             "blocked",
             "open",
             "deleted"
           ] ->
        chip_class(:error)

      status when status in ["in_progress", "pending", "refreshing", "stale"] ->
        chip_class(:info)

      _status ->
        chip_class(:neutral)
    end
  end

  def count_chip_class do
    "inline-flex items-center justify-center rounded-box bg-base-200 px-2.5 py-1 text-xs font-semibold tabular-nums text-base-content"
  end

  def metadata_chip_class(tone \\ :neutral), do: chip_class(tone)

  @spec alert_severity_chip_class(String.t() | nil) :: String.t()
  def alert_severity_chip_class("critical"), do: chip_class(:error)
  def alert_severity_chip_class("warning"), do: chip_class(:warning)
  def alert_severity_chip_class("info"), do: chip_class(:info)
  def alert_severity_chip_class(_severity), do: chip_class(:neutral)

  def routing_strategy_label(strategy) do
    case routing_strategy_presentation(strategy) do
      %{label: label} -> label
      nil -> nil
    end
  end

  def routing_strategy_icon(strategy) do
    case routing_strategy_presentation(strategy) do
      %{icon: icon} -> icon
      nil -> "hero-server-stack"
    end
  end

  def lifecycle_chip_class("active"), do: chip_class(:success)
  def lifecycle_chip_class("disabled"), do: chip_class(:warning)
  def lifecycle_chip_class("paused"), do: chip_class(:warning)
  def lifecycle_chip_class("archived"), do: chip_class(:error)
  def lifecycle_chip_class("deleted"), do: chip_class(:error)
  def lifecycle_chip_class(_status), do: chip_class(:neutral)

  attr :id, :string, default: nil
  attr :label, :string, default: nil
  attr :family, :string, default: nil
  attr :placeholder, :string, default: "Plan unknown"
  attr :variant, :atom, default: :badge, values: [:badge, :metadata]
  attr :class, :any, default: nil
  attr :rest, :global

  def plan_badge(assigns) do
    assigns =
      assigns
      |> assign(
        :badge_label,
        plan_badge_label(assigns.label, assigns.family, assigns.placeholder)
      )
      |> assign(:badge_class, plan_badge_class(assigns.label || assigns.family, assigns.variant))

    ~H"""
    <span id={@id} class={[@badge_class, @class]} {@rest}>
      {@badge_label}
    </span>
    """
  end

  def plan_badge_label(plan_label), do: plan_badge_text(plan_label, "Plan unknown")

  def plan_badge_class(plan_label, variant \\ :badge) do
    plan_label
    |> plan_tone()
    |> plan_badge_class_for_tone(variant)
  end

  defp chip_class(:primary),
    do:
      "inline-flex items-center rounded-full border border-primary/20 bg-primary/10 px-2.5 py-1 text-xs font-medium leading-none text-primary"

  defp chip_class(:success),
    do:
      "inline-flex items-center rounded-full border border-success/20 bg-success/10 px-2.5 py-1 text-xs font-medium leading-none text-success"

  defp chip_class(:warning),
    do:
      "inline-flex items-center rounded-full border border-warning/20 bg-warning/10 px-2.5 py-1 text-xs font-medium leading-none text-warning"

  defp chip_class(:error),
    do:
      "inline-flex items-center rounded-full border border-error/20 bg-error/10 px-2.5 py-1 text-xs font-medium leading-none text-error"

  defp chip_class(:info),
    do:
      "inline-flex items-center rounded-full border border-info/20 bg-info/10 px-2.5 py-1 text-xs font-medium leading-none text-info"

  defp chip_class(_tone),
    do:
      "inline-flex items-center rounded-full border border-base-300 bg-base-200 px-2.5 py-1 text-xs font-medium leading-none text-base-content/70"

  defp plan_badge_label(plan_label, plan_family, placeholder) do
    label = plan_badge_text(plan_label || plan_family, placeholder)

    family =
      plan_family
      |> blank_to_nil()
      |> then(fn value -> value && plan_badge_text(value, value) end)

    if family && family != label do
      "#{label} (#{family})"
    else
      label
    end
  end

  defp plan_badge_text(value, placeholder) do
    value
    |> blank_to_nil()
    |> case do
      nil -> placeholder
      value -> canonical_plan_label(value)
    end
  end

  defp canonical_plan_label(plan_label) do
    normalized = plan_label |> String.downcase() |> String.trim()
    Map.get(@canonical_plan_labels, normalized, plan_label)
  end

  defp routing_strategy_presentation(strategy) when is_binary(strategy) do
    Map.get(@routing_strategy_presentations, strategy)
  end

  defp routing_strategy_presentation(_strategy), do: nil

  defp plan_tone(plan_label) when is_binary(plan_label) do
    normalized = plan_label |> String.downcase() |> String.trim()

    cond do
      normalized in ["free", "free plan"] -> :free
      normalized in ["pro", "plus", "chatgpt pro", "chatgpt plus"] -> :pro
      normalized in ["team", "business", "chatgpt team"] -> :team
      normalized in ["enterprise", "edu", "education"] -> :enterprise
      normalized == "" -> :unknown
      true -> {:generated, normalized}
    end
  end

  defp plan_tone(_plan_label), do: :unknown

  defp plan_badge_class_for_tone(:free, :badge),
    do: "badge badge-success badge-sm whitespace-nowrap font-semibold"

  defp plan_badge_class_for_tone(:pro, :badge),
    do: "badge badge-primary badge-sm whitespace-nowrap font-semibold"

  defp plan_badge_class_for_tone(:team, :badge),
    do: "badge badge-info badge-sm whitespace-nowrap font-semibold"

  defp plan_badge_class_for_tone(:enterprise, :badge),
    do: "badge badge-secondary badge-sm whitespace-nowrap font-semibold"

  defp plan_badge_class_for_tone({:generated, _key}, :badge),
    do: "badge badge-accent badge-sm whitespace-nowrap font-semibold"

  defp plan_badge_class_for_tone(:free, :metadata), do: chip_class(:success)
  defp plan_badge_class_for_tone(:pro, :metadata), do: chip_class(:primary)
  defp plan_badge_class_for_tone(:team, :metadata), do: chip_class(:info)
  defp plan_badge_class_for_tone(:enterprise, :metadata), do: chip_class(:warning)

  defp plan_badge_class_for_tone({:generated, key}, :metadata),
    do: key |> generated_chip_tone() |> chip_class()

  defp plan_badge_class_for_tone(_tone, :metadata), do: chip_class(:neutral)

  defp plan_badge_class_for_tone(_tone, :badge),
    do: "badge badge-ghost badge-sm whitespace-nowrap font-semibold"

  defp generated_chip_tone(key) do
    tones = [:primary, :success, :warning, :error, :info]
    index = :erlang.phash2(key, length(tones))
    Enum.at(tones, index)
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
