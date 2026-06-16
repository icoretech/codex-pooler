defmodule CodexPoolerWeb.Admin.SystemPageComponents.Metrics do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.SystemPageComponents.FormControls

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :form_params, :map, required: true
  attr :settings, :any, required: true
  attr :card_statuses, :map, required: true

  def card(assigns) do
    ~H"""
    <FormControls.settings_card
      :if={@selected_tab == "metrics"}
      group="metrics"
      form={@forms["metrics"]}
      status={@card_statuses["metrics"]}
    >
      <FormControls.settings_group
        id="instance-settings-metrics"
        eyebrow="Metrics"
        title="Metrics bearer token"
        description="Protect the Prometheus metrics endpoint with an HMAC-only write-once token."
        hint="Blank saves preserve the current token. Choose clear to intentionally remove it. The raw token cannot be recovered after save."
      >
        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_16rem]">
          <FormControls.write_only_secret_input
            id="instance-settings-metrics-token"
            name="instance_settings[metrics][bearer_token]"
            action_name="instance_settings[metrics][bearer_token_action]"
            label="Metrics bearer token"
            status_label="Stored token"
            clear_label="Clear stored token"
            action={param_secret_action(@form_params, "metrics", "bearer_token_action")}
            status={@settings.metrics.bearer_token_status}
          />
          <div class="grid content-start gap-2 rounded-box border border-base-300 bg-base-200/60 p-3 text-sm">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
              Safe metadata
            </p>
            <p
              id="instance-settings-metrics-token-fingerprint"
              class="break-all text-base-content/70"
            >
              Fingerprint: {safe_value(@settings.metrics.bearer_token_fingerprint)}
            </p>
            <p class="break-all text-base-content/70">
              Key version: {safe_value(@settings.metrics.bearer_token_key_version)}
            </p>
          </div>
        </div>
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
  defp safe_value(_value), do: "not configured"
end
