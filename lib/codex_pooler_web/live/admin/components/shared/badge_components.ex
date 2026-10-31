defmodule CodexPoolerWeb.Admin.BadgeComponents do
  @moduledoc """
  Shared admin status, count, routing, and plan presentation helpers.
  """
  use CodexPoolerWeb, :html

  # The curated labels cover both raw `chatgpt_plan_type` claims (underscored)
  # and their slugified plan_family forms (dashed). Product plan names remain
  # verbatim; generic subscription tiers are translated at render time.
  # Pro display names follow https://help.openai.com/en/articles/9793128-about-chatgpt-pro-tiers.

  @spec routing_strategy_presentation(term()) :: map() | nil
  def routing_strategy_presentation("bridge_ring") do
    %{
      label: gettext("Cache locality"),
      icon: "hero-circle-stack",
      description: gettext("Stable routing with a preference for matching prompt-cache keys."),
      feature: gettext("Prefer cache locality"),
      detail: gettext("Matching cache keys prefer the same eligible upstream."),
      cache_title: gettext("Cache affinity can improve reuse"),
      cache_description: gettext("It does not guarantee a cache hit.")
    }
  end

  def routing_strategy_presentation("deterministic_rotation") do
    %{
      label: gettext("Rotation"),
      icon: "hero-arrow-path",
      description: gettext("Varies the starting upstream for independent requests."),
      feature: gettext("Vary the starting upstream"),
      detail: gettext("Independent requests use a deterministic rotation."),
      cache_title: gettext("Cache keys do not override rotation"),
      cache_description: gettext("Provider caching remains available.")
    }
  end

  def routing_strategy_presentation("least_recent_success") do
    %{
      label: gettext("Least recent success"),
      icon: "hero-clock",
      description: gettext("Prefers upstreams whose last successful request was longest ago."),
      feature: gettext("Prefer the least recent success"),
      detail: gettext("Prefers accounts without successes, then the oldest success."),
      cache_title: gettext("Cache keys do not override success history"),
      cache_description: gettext("Provider caching remains available.")
    }
  end

  def routing_strategy_presentation("quota_first") do
    %{
      label: gettext("Quota first"),
      icon: "hero-chart-bar-square",
      description: gettext("Prefers upstreams with more usable quota for the requested model."),
      feature: gettext("Prefer available quota"),
      detail: gettext("Prioritizes usable remaining quota for the requested model."),
      cache_title: gettext("Quota takes priority over cache locality"),
      cache_description: gettext("Provider caching remains available.")
    }
  end

  def routing_strategy_presentation(_strategy), do: nil

  @consumer_plan_tones %{
    "go" => :go,
    "plus" => :plus,
    "chatgpt plus" => :plus,
    "pro" => :pro,
    "promax" => :pro,
    "chatgpt pro" => :pro,
    "prolite" => :prolite,
    "pro lite" => :prolite
  }

  @plan_text_tone_classes %{
    primary: "text-primary",
    success: "text-success",
    warning: "text-warning",
    error: "text-error",
    info: "text-info"
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
    [chip_class(:neutral), "tabular-nums"]
  end

  def metadata_chip_class(tone \\ :neutral), do: chip_class(tone)

  @spec alert_severity_chip_class(String.t() | nil) :: String.t()
  def alert_severity_chip_class("critical"), do: chip_class(:error)
  def alert_severity_chip_class("warning"), do: chip_class(:warning)
  def alert_severity_chip_class("info"), do: chip_class(:info)
  def alert_severity_chip_class(_severity), do: chip_class(:neutral)

  @spec routing_strategy_label(term()) :: String.t() | nil
  def routing_strategy_label(strategy) do
    case routing_strategy_presentation(strategy) do
      %{label: label} -> label
      nil -> nil
    end
  end

  @spec routing_strategy_icon(term()) :: String.t()
  def routing_strategy_icon("bridge_ring"), do: "hero-circle-stack"
  def routing_strategy_icon("deterministic_rotation"), do: "hero-arrow-path"
  def routing_strategy_icon("least_recent_success"), do: "hero-clock"
  def routing_strategy_icon("quota_first"), do: "hero-chart-bar-square"
  def routing_strategy_icon(_strategy), do: "hero-server-stack"

  def lifecycle_chip_class("active"), do: chip_class(:success)
  def lifecycle_chip_class("disabled"), do: chip_class(:warning)
  def lifecycle_chip_class("paused"), do: chip_class(:warning)
  def lifecycle_chip_class("archived"), do: chip_class(:error)
  def lifecycle_chip_class("deleted"), do: chip_class(:error)
  def lifecycle_chip_class(_status), do: chip_class(:neutral)

  attr :id, :string, default: nil
  attr :label, :string, default: nil
  attr :family, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  @spec plan_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def plan_badge(assigns) do
    assigns =
      assigns
      |> assign(
        :badge_label,
        plan_badge_label(assigns.label, assigns.family, assigns.placeholder || gettext("Plan unknown"))
      )
      |> assign(:badge_class, plan_badge_class(assigns.label || assigns.family))

    ~H"""
    <span id={@id} class={[@badge_class, @class]} {@rest}>
      {@badge_label}
    </span>
    """
  end

  @spec plan_badge_label(String.t() | nil) :: String.t()
  def plan_badge_label(plan_label), do: plan_badge_text(plan_label, gettext("Plan unknown"))

  def plan_badge_class(plan_label) do
    plan_label
    |> plan_tone()
    |> plan_badge_class_for_tone()
  end

  @spec plan_text_class(String.t() | nil) :: String.t()
  def plan_text_class(plan_label) do
    case plan_tone(plan_label) do
      :unknown -> "text-base-content/70"
      :free -> "admin-plan-text"
      {:generated, key} -> Map.fetch!(@plan_text_tone_classes, generated_chip_tone(key))
      tone -> "admin-plan-text admin-plan-badge--#{tone}"
    end
  end

  defp chip_class(:primary),
    do: "inline-flex items-center rounded-full border border-primary/20 bg-primary/10 px-2.5 py-1 text-xs font-medium leading-none text-primary"

  defp chip_class(:success),
    do: "inline-flex items-center rounded-full border border-success/20 bg-success/10 px-2.5 py-1 text-xs font-medium leading-none text-success"

  defp chip_class(:warning),
    do: "inline-flex items-center rounded-full border border-warning/20 bg-warning/10 px-2.5 py-1 text-xs font-medium leading-none text-warning"

  defp chip_class(:error),
    do: "inline-flex items-center rounded-full border border-error/20 bg-error/10 px-2.5 py-1 text-xs font-medium leading-none text-error"

  defp chip_class(:info),
    do: "inline-flex items-center rounded-full border border-info/20 bg-info/10 px-2.5 py-1 text-xs font-medium leading-none text-info"

  defp chip_class(_tone),
    do: "inline-flex items-center rounded-full border border-base-300 bg-base-200 px-2.5 py-1 text-xs font-medium leading-none text-base-content/70"

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
    canonical_plan_label(normalized, plan_label)
  end

  defp canonical_plan_label("business", _), do: pgettext("subscription plan", "Business")
  defp canonical_plan_label("chatgpt plus", _), do: "ChatGPT Plus"
  defp canonical_plan_label("chatgpt pro", _), do: "ChatGPT Pro"
  defp canonical_plan_label("chatgpt team", _), do: "ChatGPT Team"
  defp canonical_plan_label("team", _), do: "Team"
  defp canonical_plan_label("edu", _), do: "Edu"
  defp canonical_plan_label(value, _) when value in ["edu-plus", "edu_plus"], do: "Edu Plus"
  defp canonical_plan_label(value, _) when value in ["edu-pro", "edu_pro"], do: "Edu Pro"
  defp canonical_plan_label("education", _), do: pgettext("subscription plan", "Education")
  defp canonical_plan_label(value, _) when value in ["ent26", "enterprise", "hc"], do: pgettext("subscription plan", "Enterprise")
  defp canonical_plan_label(value, _) when value in ["enterprise-cbp-automation", "enterprise_cbp_automation"], do: pgettext("subscription plan", "Enterprise Automation")
  defp canonical_plan_label(value, _) when value in ["enterprise-cbp-usage-based", "enterprise_cbp_usage_based"], do: pgettext("subscription plan", "Enterprise CBP Usage Based")
  defp canonical_plan_label(value, _) when value in ["free", "free plan"], do: pgettext("subscription plan", "Free")
  defp canonical_plan_label("go", _), do: "Go"
  defp canonical_plan_label("plus", _), do: "Plus"
  defp canonical_plan_label("pro", _), do: "Pro 200"
  defp canonical_plan_label("prolite", _), do: "Pro 100"
  defp canonical_plan_label("promax", _), do: "Pro 500"
  defp canonical_plan_label(value, _) when value in ["self-serve-business-prolite", "self_serve_business_prolite"], do: pgettext("subscription plan", "Self Serve Business ProLite")
  defp canonical_plan_label(value, _) when value in ["self-serve-business-usage-based", "self_serve_business_usage_based"], do: pgettext("subscription plan", "Self Serve Business Usage Based")
  defp canonical_plan_label(_normalized, original), do: original

  defp plan_tone(plan_label) when is_binary(plan_label) do
    normalized = plan_label |> String.downcase() |> String.trim()

    cond do
      normalized in ["free", "free plan"] ->
        :free

      Map.has_key?(@consumer_plan_tones, normalized) ->
        Map.fetch!(@consumer_plan_tones, normalized)

      normalized in [
        "team",
        "chatgpt team",
        "self-serve-business-prolite",
        "self_serve_business_prolite",
        "self-serve-business-usage-based",
        "self_serve_business_usage_based"
      ] ->
        :team

      normalized == "business" ->
        :business

      normalized in ["edu", "edu-plus", "edu-pro", "edu_plus", "edu_pro", "education"] ->
        :edu

      normalized in [
        "enterprise",
        "ent26",
        "hc",
        "enterprise-cbp-automation",
        "enterprise_cbp_automation",
        "enterprise-cbp-usage-based",
        "enterprise_cbp_usage_based"
      ] ->
        :enterprise

      normalized == "" ->
        :unknown

      true ->
        {:generated, normalized}
    end
  end

  defp plan_tone(_plan_label), do: :unknown

  defp plan_badge_class_for_tone(tone)
       when tone in [:free, :go, :plus, :pro, :prolite, :team, :business, :enterprise, :edu],
       do: "admin-plan-badge admin-plan-badge--#{tone}"

  defp plan_badge_class_for_tone({:generated, key}),
    do: key |> generated_chip_tone() |> chip_class()

  defp plan_badge_class_for_tone(_tone), do: chip_class(:neutral)

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
