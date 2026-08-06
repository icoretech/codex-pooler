defmodule CodexPoolerWeb.Admin.SystemPageComponents.Development do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.SystemPageComponents.FormControls

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :settings, :any, required: true
  attr :card_statuses, :map, required: true
  attr :development_action_status, :map, default: nil
  attr :development_helpers_available?, :boolean, required: true
  attr :impeccable_live_status, :any, default: :unavailable

  def card(assigns) do
    ~H"""
    <FormControls.settings_card
      :if={@selected_tab == "development" and @development_helpers_available?}
      group="development"
      form={@forms["development"]}
      status={@card_statuses["development"]}
      autosave
    >
      <.inputs_for :let={development_form} field={@forms["development"][:development]}>
        <FormControls.settings_group
          id="instance-settings-development"
          eyebrow="Development helpers"
          title="Development-only local safeguards"
          description="Controls local-only helpers and pauses fake-account jobs that would otherwise call upstream accounts."
        >
          <div class="grid gap-4 xl:grid-cols-2">
            <FormControls.toggle_input
              id="instance-settings-account-reconciliation-paused"
              field={development_form[:account_reconciliation_paused]}
              label="Pause account reconciliation jobs"
              hint="Stops scheduled and queued reconciliation jobs before they call upstream accounts in development."
            />
            <FormControls.toggle_input
              id="instance-settings-impeccable-live-enabled"
              field={development_form[:impeccable_live_enabled]}
              label="Enable Impeccable live helper"
              hint="Loads the live client from the running local Impeccable helper on the next full page load."
            />
          </div>
          <div
            id="instance-settings-impeccable-live"
            class="grid gap-3 rounded-box border border-base-300 bg-base-200/40 p-3"
          >
            <div class="grid gap-1">
              <h4 class="text-sm font-semibold text-base-content">Impeccable live helper</h4>
              <p class="text-xs leading-5 text-base-content/55">
                This instance reads the helper's port and session token from
                <span class="font-mono text-[11px]">.impeccable/live/server.json</span>
                on every full page load, so the helper can bind any port and be restarted
                without restarting the app. Nothing is written to the layout.
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <AdminComponents.action_button
                id="instance-settings-impeccable-live-recheck"
                icon="hero-arrow-path"
                label="Recheck Helper"
                phx-click="recheck_impeccable_live"
                phx-disable-with="Checking..."
              />
            </div>
            <.impeccable_live_notice
              id="instance-settings-impeccable-live-status"
              status={@impeccable_live_status}
            />
          </div>
          <div
            id="instance-settings-development-actions"
            class="grid gap-3 rounded-box border border-base-300 bg-base-200/40 p-3"
          >
            <div class="grid gap-1">
              <h4 class="text-sm font-semibold text-base-content">Development data imports</h4>
              <p class="text-xs leading-5 text-base-content/55">
                Import deterministic fake data for the admin UI, or refresh pricing snapshots from <a
                  id="instance-settings-development-pricing-url"
                  href={@settings.catalog.openai_pricing_url}
                  class="text-primary underline-offset-2 hover:underline"
                >
                    {@settings.catalog.openai_pricing_url}
                  </a>.
                Change the URL in <.link
                  id="instance-settings-development-catalog-link"
                  patch={~p"/admin/system?#{%{"tab" => "gateway"}}"}
                  class="font-medium text-primary underline-offset-2 hover:underline"
                >
                    Gateway settings
                  </.link>.
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <AdminComponents.action_button
                id="instance-settings-import-sample-data"
                icon="hero-circle-stack"
                label="Import Sample Data"
                phx-click="import_sample_data"
                phx-disable-with="Importing..."
              />
              <AdminComponents.action_button
                id="instance-settings-import-pricing-catalog"
                icon="hero-arrow-path"
                label="Import Pricing"
                phx-click="import_pricing_catalog"
                phx-disable-with="Importing..."
              />
            </div>
            <.development_action_notice
              id="instance-settings-development-action-status"
              status={@development_action_status}
            />
          </div>
        </FormControls.settings_group>
      </.inputs_for>
    </FormControls.settings_card>
    """
  end

  attr :id, :string, required: true
  attr :status, :any, required: true

  defp impeccable_live_notice(assigns) do
    assigns = assign(assigns, :notice, impeccable_live_notice_content(assigns.status))

    ~H"""
    <AdminComponents.extended_notice
      id={@id}
      icon={@notice.icon}
      tone={@notice.tone}
      title={@notice.title}
      description={@notice.message}
    />
    """
  end

  defp impeccable_live_notice_content({:ready, origin}) do
    %{
      icon: "hero-check-circle",
      tone: :success,
      title: "Helper ready at #{origin}",
      message: "Reload any admin page to attach the live client."
    }
  end

  defp impeccable_live_notice_content({:helper_unreachable, origin}) do
    %{
      icon: "hero-exclamation-triangle",
      tone: :error,
      title: "Helper not responding",
      message:
        "A handshake file points at #{origin} but nothing is listening there. " <>
          "The helper stopped without cleaning up; start it again and recheck."
    }
  end

  defp impeccable_live_notice_content(:helper_missing) do
    %{
      icon: "hero-exclamation-triangle",
      tone: :warning,
      title: "No helper detected",
      message:
        "Start the Impeccable live server, then recheck. It writes its port and " <>
          "session token to .impeccable/live/server.json when it comes up."
    }
  end

  defp impeccable_live_notice_content(:externally_injected) do
    %{
      icon: "hero-exclamation-triangle",
      tone: :warning,
      title: "Injected script tag detected",
      message:
        "A live-mode injector wrote its own tag into the layout, so this instance " <>
          "is standing down to avoid a second widget. Stop the live server to remove it."
    }
  end

  defp impeccable_live_notice_content(:disabled) do
    %{
      icon: "hero-information-circle",
      tone: :info,
      title: "Live client off",
      message: "Turn on the toggle above to load the live client on the next page load."
    }
  end

  defp impeccable_live_notice_content(_status) do
    %{
      icon: "hero-information-circle",
      tone: :info,
      title: "Live client unavailable",
      message: "Development helpers are not enabled for this build."
    }
  end

  attr :id, :string, required: true
  attr :status, :map, default: nil

  defp development_action_notice(assigns) do
    assigns = assign(assigns, :notice, development_action_notice_content(assigns.status))

    ~H"""
    <AdminComponents.extended_notice
      id={@id}
      icon={@notice.icon}
      tone={@notice.tone}
      title={@notice.title}
      description={@notice.message}
    />
    """
  end

  defp development_action_notice_content(nil) do
    %{
      icon: "hero-information-circle",
      tone: :info,
      title: "Ready to import",
      message: "Run a development import when you need fresh fake data or pricing snapshots."
    }
  end

  defp development_action_notice_content(%{tone: :success, message: message}) do
    %{icon: "hero-check-circle", tone: :success, title: "Import complete", message: message}
  end

  defp development_action_notice_content(%{tone: :error, message: message}) do
    %{icon: "hero-exclamation-triangle", tone: :error, title: "Import failed", message: message}
  end

  defp development_action_notice_content(%{message: message}) do
    %{icon: "hero-information-circle", tone: :info, title: "Import status", message: message}
  end
end
