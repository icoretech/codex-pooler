defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.UsageCapComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :form, Phoenix.HTML.Form, required: true
  attr :change_event, :string, default: "validate_usage_cap_policy"
  attr :submit_event, :string, default: "save_usage_cap_policy"
  attr :disabled, :boolean, default: false

  @spec usage_cap_policy_form(map()) :: Phoenix.LiveView.Rendered.t()
  def usage_cap_policy_form(assigns) do
    field = assigns.form[:usage_cap_percent]

    errors =
      if assigns.form.action == :submit or Phoenix.Component.used_input?(field) do
        Enum.map(field.errors, &translate_error/1)
      else
        []
      end

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:errors, errors)
      |> assign(:cap_help, gettext("Routing stops giving this account new work once its weekly window, or its 30-day window on plans without a weekly one, reaches this share used, in every Pool using this upstream, so the rest stays available to the account owner. A turn already running finishes; the next turn moves to another account. The cap is approximate: requests already in flight, the rest of a running turn and requests that need a file stored on this account can take it past the cap. Leave blank for no cap."))
      |> assign(:redemption_help, gettext("For automatic saved-reset redemption a capped account counts as paused: it never holds other accounts' banked resets back, and Pool traffic never spends its own."))
      |> assign(:described_by, Enum.join(["usage-cap-policy-help", "usage-cap-policy-redemption-help" | if(errors == [], do: [], else: ["usage-cap-policy-errors"])], " "))

    ~H"""
    <.form
      id="usage-cap-policy-form"
      for={@form}
      phx-change={@change_event}
      phx-submit={@submit_event}
      autocomplete="off"
      class="grid gap-4"
    >
      <div class="grid gap-2">
        <label for="usage-cap-percent" class="text-sm font-semibold text-base-content">
          {gettext("Usage cap (% of the weekly or 30-day quota)")}
        </label>
        <input
          id="usage-cap-percent"
          type="number"
          name={@field.name}
          value={@field.value}
          min="1"
          max="99"
          step="1"
          inputmode="numeric"
          placeholder={gettext("No cap")}
          disabled={@disabled}
          class="input input-bordered w-full"
          aria-describedby={@described_by}
          aria-invalid={if @errors != [], do: "true", else: nil}
        />
        <p id="usage-cap-policy-help" class="text-xs leading-5 text-base-content/60">{@cap_help}</p>
        <p id="usage-cap-policy-redemption-help" class="text-xs leading-5 text-base-content/60">{@redemption_help}</p>
        <div :if={@errors != []} id="usage-cap-policy-errors" role="alert" class="grid gap-1 text-sm text-error">
          <p :for={error <- @errors}>{error}</p>
        </div>
      </div>
    </.form>
    """
  end
end
