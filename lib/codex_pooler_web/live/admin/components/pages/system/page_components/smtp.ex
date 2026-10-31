defmodule CodexPoolerWeb.Admin.SystemPageComponents.SMTP do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.SystemPageComponents.FormControls

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :form_params, :map, required: true
  attr :settings, :any, required: true
  attr :card_statuses, :map, required: true
  attr :smtp_test_status, :map, default: nil

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    ~H"""
    <FormControls.settings_card
      :if={@selected_tab == "smtp"}
      group="smtp"
      form={@forms["smtp"]}
      status={@card_statuses["smtp"]}
    >
      <.inputs_for :let={smtp_form} field={@forms["smtp"][:smtp]}>
        <FormControls.settings_group
          id="instance-settings-smtp"
          eyebrow={gettext("SMTP")}
          title={gettext("SMTP delivery")}
          description={gettext("Delivery-time email settings for operator mail.")}
          hint={gettext("Leave the SMTP password blank to keep the stored value.")}
        >
          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            <FormControls.scalar_controls
              form={smtp_form}
              controls={smtp_scalar_controls(:before_password)}
            />
            <FormControls.write_only_secret_input
              id="instance-settings-smtp-password"
              name="instance_settings[smtp][password]"
              action_name="instance_settings[smtp][password_action]"
              label={gettext("SMTP password")}
              status_label={gettext("Stored password")}
              clear_label={gettext("Clear stored password")}
              action={param_secret_action(@form_params, "smtp", "password_action")}
              status={@settings.smtp.password_status}
            />
            <FormControls.scalar_controls
              form={smtp_form}
              controls={smtp_scalar_controls(:after_password)}
            />
          </div>
          <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
            <p class="text-xs leading-5 text-base-content/60">
              {gettext("Send a deterministic test email to the signed-in operator with the unsaved SMTP values from this form.")}
            </p>
            <AdminComponents.action_button
              id="instance-settings-smtp-test"
              icon="hero-paper-airplane"
              label={gettext("Send test email to me")}
              phx-click="test_smtp"
              variant={:secondary}
            />
          </div>
          <div
            id="instance-settings-smtp-test-status"
            class={smtp_status_class(@smtp_test_status)}
            role="status"
          >
            {smtp_status_message(@smtp_test_status)}
          </div>
        </FormControls.settings_group>
      </.inputs_for>
    </FormControls.settings_card>
    """
  end

  defp smtp_scalar_controls(:before_password) do
    [
      %{
        type: :toggle,
        id: "instance-settings-smtp-enabled",
        field: :enabled,
        label: gettext("SMTP enabled"),
        hint: gettext("Use these settings for operator email.")
      },
      %{
        type: :input,
        id: "instance-settings-smtp-host",
        field: :host,
        input_type: "text",
        label: gettext("SMTP host")
      },
      %{type: :number, id: "instance-settings-smtp-port", field: :port, label: gettext("SMTP port")},
      %{
        type: :input,
        id: "instance-settings-smtp-from",
        field: :from,
        input_type: "email",
        label: gettext("From address")
      },
      %{
        type: :input,
        id: "instance-settings-smtp-username",
        field: :username,
        input_type: "text",
        label: gettext("SMTP username")
      }
    ]
  end

  defp smtp_scalar_controls(:after_password) do
    [
      %{
        type: :select,
        id: "instance-settings-smtp-tls",
        field: :tls,
        label: gettext("TLS"),
        options: [{gettext("Always"), "always"}, {gettext("If available"), "if_available"}, {gettext("Never"), "never"}]
      },
      %{
        type: :toggle,
        id: "instance-settings-smtp-ssl",
        field: :ssl,
        label: gettext("SSL"),
        hint: gettext("Connect with SSL from the start.")
      },
      %{type: :number, id: "instance-settings-smtp-retries", field: :retries, label: gettext("Retries")}
    ]
  end

  defp param_secret_action(params, group, field) do
    case get_in(params, [group, field]) do
      "clear" -> "clear"
      _other -> "preserve"
    end
  end

  defp smtp_status_message(nil), do: gettext("No SMTP test email has been sent in this form session.")
  defp smtp_status_message(%{message: message}), do: message

  defp smtp_status_class(nil) do
    "rounded-box border border-base-300 bg-base-200/70 px-3 py-2 text-sm text-base-content/60"
  end

  defp smtp_status_class(%{tone: :success}) do
    "rounded-box border border-success/25 bg-success/10 px-3 py-2 text-sm font-medium text-success"
  end

  defp smtp_status_class(%{tone: :error}) do
    "rounded-box border border-error/25 bg-error/10 px-3 py-2 text-sm font-medium text-error"
  end
end
