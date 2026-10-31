defmodule CodexPoolerWeb.Admin.SystemPageComponents.Metrics do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.SystemPageComponents.FormControls

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :form_params, :map, required: true
  attr :settings, :any, required: true
  attr :card_statuses, :map, required: true

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    assigns =
      assign(assigns, :exposure, metrics_exposure(assigns.settings.metrics.bearer_token_status))

    ~H"""
    <FormControls.settings_card
      :if={@selected_tab == "metrics"}
      group="metrics"
      form={@forms["metrics"]}
      status={@card_statuses["metrics"]}
    >
      <FormControls.settings_group
        id="instance-settings-metrics"
        eyebrow={gettext("Metrics")}
        title={gettext("Metrics bearer token")}
        description={gettext("Protect the Prometheus metrics endpoint with an HMAC-only write-once token.")}
        hint={gettext("Blank saves preserve the current token. Choose clear to intentionally remove it. The raw token cannot be recovered after save.")}
      >
        <section
          id="instance-settings-metrics-exposure-status"
          data-state={@exposure.state}
          class="grid gap-3 rounded-box border border-base-300 bg-base-100 p-3"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="grid gap-1">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
                {gettext("/metrics exposure")}
              </p>
              <p class="text-sm font-semibold text-base-content">{@exposure.title}</p>
            </div>
            <span class={@exposure.badge_class}>{@exposure.label}</span>
          </div>
          <p class="text-sm leading-6 text-base-content/70">{@exposure.description}</p>
          <p class="text-xs leading-5 text-base-content/60">
            {gettext("The runtime firewall does not apply to /metrics. Exposure is controlled only by this metrics bearer token.")}
          </p>
        </section>

        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_16rem]">
          <FormControls.write_only_secret_input
            id="instance-settings-metrics-token"
            name="instance_settings[metrics][bearer_token]"
            action_name="instance_settings[metrics][bearer_token_action]"
            label={gettext("Metrics bearer token")}
            status_label={gettext("Stored token")}
            clear_label={gettext("Clear stored token — reopens /metrics")}
            action={param_secret_action(@form_params, "metrics", "bearer_token_action")}
            status={@settings.metrics.bearer_token_status}
          />
          <div class="grid content-start gap-2 rounded-box border border-base-300 bg-base-200/60 p-3 text-sm">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
              {gettext("Safe metadata")}
            </p>
            <p
              id="instance-settings-metrics-token-fingerprint"
              class="break-all text-base-content/70"
            >
              {gettext("Fingerprint: %{fingerprint}", fingerprint: safe_value(@settings.metrics.bearer_token_fingerprint))}
            </p>
            <p class="break-all text-base-content/70">
              {gettext("Key version: %{version}", version: safe_value(@settings.metrics.bearer_token_key_version))}
            </p>
          </div>
        </div>

        <p
          :if={param_secret_action(@form_params, "metrics", "bearer_token_action") == "clear"}
          id="instance-settings-metrics-clear-warning"
          class="rounded-box border border-warning/25 bg-warning/10 px-3 py-2 text-sm font-medium text-warning"
          role="alert"
        >
          {gettext("Clearing the stored token reopens /metrics without authentication.")}
        </p>
      </FormControls.settings_group>
    </FormControls.settings_card>
    """
  end

  defp param_secret_action(params, group, field) do
    case get_in(params, [group, field]) do
      "clear" -> "clear"
      _other -> "preserve"
    end
  end

  defp safe_value(value) when is_binary(value) and value != "", do: value
  defp safe_value(_value), do: gettext("not configured")

  defp metrics_exposure(:intentionally_unset) do
    %{
      state: "open",
      label: pgettext("metrics exposure", "Open"),
      title: gettext("Unauthenticated scrapes allowed"),
      description: gettext("No metrics bearer token is stored, so /metrics returns 200 without Authorization."),
      badge_class: "badge badge-warning badge-sm font-semibold"
    }
  end

  defp metrics_exposure(:configured) do
    %{
      state: "protected",
      label: gettext("Protected"),
      title: gettext("Exact bearer token required"),
      description: gettext("A metrics bearer token is stored, so /metrics requires the exact Bearer token."),
      badge_class: "badge badge-success badge-sm font-semibold"
    }
  end

  defp metrics_exposure(_status) do
    %{
      state: "unavailable",
      label: gettext("Unavailable"),
      title: gettext("Requests fail closed"),
      description: gettext("Metrics settings are unavailable, so /metrics fails closed with 401."),
      badge_class: "badge badge-error badge-sm font-semibold"
    }
  end
end
