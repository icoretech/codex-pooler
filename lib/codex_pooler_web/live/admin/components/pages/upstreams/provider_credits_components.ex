defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.ProviderCreditsComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  @type balance_state :: :finite | :unlimited | :unknown
  @type availability :: :available | :conditional | :disabled | :unavailable | :unknown
  @type summary :: %{
          required(:balance_state) => balance_state(),
          required(:display_row?) => boolean(),
          required(:balance_label) => String.t() | nil,
          optional(:balance_exact_label) => String.t() | nil,
          required(:observed_baseline_label) => String.t() | nil,
          required(:observed_percent) => Decimal.t() | nil,
          required(:allow_provider_credits) => boolean(),
          required(:availability) => availability(),
          required(:availability_label) => String.t(),
          required(:availability_detail) => String.t(),
          optional(:capacity_basis) => CodexPooler.Upstreams.Quota.CapacityAssessment.capacity_basis(),
          optional(:qualification) => :established | :provider_attested | :supported | :unverified | :legacy_attested | :not_applicable,
          optional(:reason_codes) => [String.t()]
        }

  attr :form, Phoenix.HTML.Form, required: true
  attr :change_event, :string, default: "validate_provider_credits_policy"
  attr :submit_event, :string, default: "save_provider_credits_policy"
  attr :disabled, :boolean, default: false

  @spec provider_credits_policy_form(map()) :: Phoenix.LiveView.Rendered.t()
  def provider_credits_policy_form(assigns) do
    field = assigns.form[:allow_provider_credits]

    errors =
      if assigns.form.action == :submit or Phoenix.Component.used_input?(field) do
        Enum.map(field.errors, &translate_error/1)
      else
        []
      end

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:checked?, field.value in [true, "true", "1"])
      |> assign(:errors, errors)
      |> assign(:policy_help, gettext("Use available provider credits when compatible included capacity cannot serve the request, before blocked-request banked-reset recovery. Proactive threshold and expiry reset policies remain separate. Applies to every Pool using this upstream. This is an admission policy, not a provider spending limit; already admitted requests and other clients may still spend credits."))
      |> assign(:described_by, Enum.join(["provider-credits-policy-help" | if(errors == [], do: [], else: ["provider-credits-policy-errors"])], " "))

    ~H"""
    <.form
      id="provider-credits-policy-form"
      for={@form}
      phx-change={@change_event}
      phx-submit={@submit_event}
      autocomplete="off"
      class="grid gap-4"
    >
      <div class="grid gap-2">
        <label for="provider-credits-enabled" class="flex items-center justify-between gap-3 text-sm font-semibold text-base-content">
          <span>{gettext("Use provider credits")}</span>
          <input type="hidden" name={@field.name} value="false" disabled={@disabled} />
          <input
            id="provider-credits-enabled"
            type="checkbox"
            name={@field.name}
            value="true"
            checked={@checked?}
            disabled={@disabled}
            class="toggle toggle-primary toggle-md shrink-0"
            aria-describedby={@described_by}
            aria-invalid={if @errors != [], do: "true", else: nil}
          />
        </label>
        <p id="provider-credits-policy-help" class="text-xs leading-5 text-base-content/60">{@policy_help}</p>
        <div :if={@errors != []} id="provider-credits-policy-errors" role="alert" class="grid gap-1 text-sm text-error">
          <p :for={error <- @errors}>{error}</p>
        </div>
      </div>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :summary, :map, required: true, doc: "Sanitized observations and the shared domain decision, never raw capacity facts."
  attr :open_policy, :any, default: nil
  attr :trigger_id, :string, default: nil
  slot :included_windows, doc: "Independently projected included-window meters; omit for windowless accounts."

  @spec provider_credits_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def provider_credits_summary(assigns) do
    assigns = assign_observed_percent(assigns)

    ~H"""
    <section
      :if={Map.get(@summary, :display_row?, false)}
      id={@id}
      data-role="provider-credits-summary"
      data-balance-state={@summary.balance_state}
      data-policy-enabled={to_string(@summary.allow_provider_credits)}
      data-availability={@summary.availability}
      data-capacity-basis={Map.get(@summary, :capacity_basis)}
      data-qualification={Map.get(@summary, :qualification)}
      data-reason-codes={Enum.join(Map.get(@summary, :reason_codes, []), " ")}
      aria-labelledby={"#{@id}-title"}
      class="relative grid min-w-0 gap-1.5"
      title={row_title(@summary, @percent_label)}
    >
      <button
        :if={@open_policy}
        id={@trigger_id || "#{@id}-policy-open"}
        type="button"
        class={[
          "absolute -inset-x-2 -inset-y-1.5 z-10 cursor-pointer rounded border border-transparent transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2",
          trigger_tone(@summary.observed_percent)
        ]}
        aria-label={gettext("Provider credits: %{balance}. Open provider credits policy", balance: balance_label(@summary))}
        aria-haspopup="dialog"
        aria-controls="provider-credits-policy-dialog"
        phx-click={@open_policy}
      ><span class="sr-only">{gettext("Open provider credits policy")}</span></button>
      <div class="flex min-w-0 items-center justify-between gap-3 text-xs">
        <span id={"#{@id}-title"} class="min-w-0 truncate font-medium text-base-content">{gettext("Credits")}</span>
        <span :if={@percent_label} id={"#{@id}-percent"} class={["shrink-0 font-medium tabular-nums", percent_tone(@summary.observed_percent)]}>{@percent_label}</span>
      </div>
      <progress
        :if={@percent_label}
        id={"#{@id}-progress"}
        data-role="provider-credits-observed-progress"
        value={@percent_value}
        max="100"
        aria-label={gettext("Observed provider credit balance relative to observed baseline")}
        aria-valuetext={gettext("%{percent} of observed baseline", percent: @percent_label)}
        aria-describedby={"#{@id}-baseline-description"}
        class={["progress admin-live-progress progress-striped h-1.5 w-full", progress_tone(@summary.observed_percent)]}
      >
        {@percent_label}
      </progress>
      <div class="flex items-center justify-between gap-3 text-[11px] text-base-content/60">
        <span id={"#{@id}-policy"}>{if @summary.allow_provider_credits, do: gettext("Enabled"), else: gettext("Disabled")}</span>
        <span id={"#{@id}-balance"} data-role="provider-credits-balance" class="tabular-nums" title={Map.get(@summary, :balance_exact_label)}>{balance_label(@summary)}</span>
      </div>
      <span :if={@percent_label} id={"#{@id}-baseline-description"} class="sr-only">{gettext("Observed baseline: %{baseline}. This reference is not the purchased total or confirmed credit use.", baseline: @summary.observed_baseline_label)}</span>
      <span :if={@percent_label} id={"#{@id}-baseline"} class="sr-only" aria-hidden="true">{@summary.observed_baseline_label}</span>
      <section :if={@included_windows != []} id={"#{@id}-included-windows"} data-role="provider-credits-included-windows" aria-labelledby={"#{@id}-included-title"} class="grid gap-3 border-t border-base-300 pt-4">
        <h3 id={"#{@id}-included-title"} class="text-sm font-semibold text-base-content">{gettext("Included quota windows")}</h3>
        {render_slot(@included_windows)}
      </section>
    </section>
    """
  end

  attr :summary, :map, required: true

  @spec provider_credits_details(map()) :: Phoenix.LiveView.Rendered.t()
  def provider_credits_details(assigns) do
    ~H"""
    <dl id="provider-credits-details" class="grid gap-x-5 gap-y-3 text-xs sm:grid-cols-2">
      <div class="grid gap-1">
        <dt class="text-base-content/60">{gettext("Observed balance")}</dt>
        <dd class="break-words font-semibold tabular-nums text-base-content" title={Map.get(@summary, :balance_exact_label)}>{balance_label(@summary)}</dd>
      </div>
      <div :if={@summary.balance_state == :finite && @summary.observed_baseline_label} class="grid gap-1">
        <dt class="text-base-content/60">{gettext("Observed baseline")}</dt>
        <dd class="tabular-nums text-base-content">{@summary.observed_baseline_label}</dd>
      </div>
      <div class="grid gap-1 sm:col-span-2">
        <dt class="text-base-content/60">{gettext("Availability")}</dt>
        <dd class="font-semibold text-base-content">{@summary.availability_label}</dd>
        <dd class="leading-5 text-base-content/60">{@summary.availability_detail}</dd>
      </div>
      <div class="grid gap-1 sm:col-span-2">
        <dt class="text-base-content/60">{gettext("Balance reference")}</dt>
        <dd class="leading-5 text-base-content/60">{gettext("The baseline is a retained observation, not a purchased total, original allowance or proof of credit use. Credit expiry is not reported.")}</dd>
      </div>
    </dl>
    """
  end

  defp balance_label(%{balance_state: :finite, balance_label: label}), do: label
  defp balance_label(%{balance_state: :unlimited}), do: gettext("Unlimited")
  defp balance_label(_summary), do: gettext("Balance unavailable")

  defp row_title(summary, nil), do: summary.availability_label
  defp row_title(summary, percent), do: gettext("%{availability}; %{percent} of observed baseline (not purchased allocation)", availability: summary.availability_label, percent: percent)

  defp meter_tone(%Decimal{} = percent) do
    cond do
      Decimal.compare(percent, Decimal.new(70)) != :lt -> :success
      Decimal.compare(percent, Decimal.new(30)) != :lt -> :warning
      true -> :error
    end
  end

  defp meter_tone(_percent), do: :neutral

  defp progress_tone(percent) do
    case meter_tone(percent) do
      :success -> "progress-success"
      :warning -> "progress-warning"
      :error -> "progress-error"
      :neutral -> "progress-neutral"
    end
  end

  defp percent_tone(percent) do
    case meter_tone(percent) do
      :success -> "text-success"
      :warning -> "text-warning"
      :error -> "text-error"
      :neutral -> "text-base-content/50"
    end
  end

  defp trigger_tone(percent) do
    case meter_tone(percent) do
      :success -> "hover:border-success/25 hover:bg-success/5 focus-visible:outline-success"
      :warning -> "hover:border-warning/25 hover:bg-warning/5 focus-visible:outline-warning"
      :error -> "hover:border-error/25 hover:bg-error/5 focus-visible:outline-error"
      :neutral -> "hover:border-base-content/25 hover:bg-base-content/5 focus-visible:outline-base-content"
    end
  end

  @spec assign_observed_percent(map()) :: map()
  defp assign_observed_percent(%{summary: %{balance_state: :finite, observed_baseline_label: baseline, observed_percent: %Decimal{coef: coefficient} = percent}} = assigns)
       when is_binary(baseline) and baseline != "" and is_integer(coefficient) do
    places = if Decimal.eq?(percent, 0) or Decimal.eq?(percent, 100), do: 0, else: 1
    value = percent |> Decimal.round(places, :down) |> Decimal.to_string(:normal)

    assigns
    |> assign(:percent_value, value)
    |> assign(:percent_label, "#{value}%")
  end

  defp assign_observed_percent(assigns) do
    assigns
    |> assign(:percent_value, nil)
    |> assign(:percent_label, nil)
  end
end
