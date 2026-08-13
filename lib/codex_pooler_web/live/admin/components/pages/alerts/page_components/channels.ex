defmodule CodexPoolerWeb.Admin.AlertsPageComponents.Channels do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Alerts.Schemas.AlertChannel
  alias CodexPoolerWeb.Admin.AlertChannelForm
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :selected_tab, :string, required: true
  attr :channels, :list, required: true
  attr :channel_form_mode, :atom, required: true
  attr :channel_form, :any, required: true
  attr :editing_channel, :any, default: nil

  def channels_section(assigns) do
    ~H"""
    <div
      :if={@selected_tab == "channels"}
      id="alerts-channels-section"
      class="grid min-w-0 gap-4 xl:grid-cols-[minmax(0,1fr)_24rem] xl:items-start"
    >
      <AdminComponents.admin_surface
        id="alerts-channels-list"
        title="Channels"
        description="Email and webhook delivery targets with write-only endpoint secrets."
        count={channel_count_label(@channels)}
        overflow={:visible}
      >
        <AdminComponents.empty_state
          :if={@channels == []}
          id="alerts-channels-empty-state"
          title="No alert channels"
          description="Create an email or webhook channel before linking alerts to delivery targets."
          icon="hero-paper-airplane"
        />

        <div
          :if={@channels != []}
          id="alerts-channel-table-scroll-region"
          class="overflow-x-auto"
        >
          <table id="alerts-channel-table" class="table min-w-[56rem]">
            <thead>
              <tr>
                <th>Channel</th>
                <th>Endpoint</th>
                <th class="text-center">State</th>
                <th>Secret</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={channel <- @channels}
                id={"alert-channel-row-#{channel.id}"}
                class="text-sm transition-colors hover:bg-base-200/80"
              >
                <td class="min-w-52">
                  <div class="grid min-w-0 gap-1">
                    <span class="truncate font-semibold text-base-content">
                      {channel.display_name}
                    </span>
                    <span
                      id={"alert-channel-row-#{channel.id}-type"}
                      class="text-xs text-base-content/60"
                    >
                      {AlertChannelForm.channel_type_label(channel.channel_type)}
                    </span>
                  </div>
                </td>
                <td id={"alert-channel-row-#{channel.id}-endpoint"} class="min-w-64">
                  <div class="grid min-w-0 gap-1">
                    <span class="break-all font-mono text-xs text-base-content/75">
                      {channel_endpoint_label(channel)}
                    </span>
                    <span
                      :if={channel.endpoint_fingerprint}
                      id={"alert-channel-row-#{channel.id}-fingerprint"}
                      class="font-mono text-xs text-base-content/45"
                    >
                      Fingerprint {channel.endpoint_fingerprint}
                    </span>
                  </div>
                </td>
                <td class="text-center">
                  <span
                    id={"alert-channel-row-#{channel.id}-state"}
                    class={AdminBadges.status_chip_class(channel.state)}
                  >
                    {AlertChannelForm.state_label(channel.state)}
                  </span>
                </td>
                <td
                  id={"alert-channel-row-#{channel.id}-secret"}
                  class="text-xs text-base-content/70"
                >
                  Signing secret {AlertChannelForm.secret_status_label(
                    channel.webhook_signing_secret_key_version
                  )}
                </td>
                <td class="text-right">
                  <div class="flex justify-end gap-2">
                    <AdminComponents.action_button
                      id={"alert-channel-edit-#{channel.id}"}
                      icon="hero-pencil-square"
                      label="Edit"
                      phx-click="open_edit_channel"
                      phx-value-id={channel.id}
                    />
                    <AdminComponents.action_button
                      :if={channel.state == AlertChannel.active_state()}
                      id={"alert-channel-disable-#{channel.id}"}
                      icon="hero-pause"
                      label="Disable"
                      phx-click="disable_channel"
                      phx-value-id={channel.id}
                    />
                    <AdminComponents.action_button
                      id={"alert-channel-delete-#{channel.id}"}
                      icon="hero-trash"
                      label="Delete"
                      phx-click="open_delete_channel"
                      phx-value-id={channel.id}
                      variant={:danger}
                    />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </AdminComponents.admin_surface>

      <AdminComponents.admin_surface
        id="alerts-channel-form-panel"
        title={channel_form_title(@channel_form_mode)}
        description="Store delivery endpoints without revealing full webhook URLs or signing secrets after save."
        overflow={:visible}
      >
        <.form
          id="alerts-channel-form"
          for={@channel_form}
          phx-change="change_channel_form"
          phx-submit="save_channel"
          autocomplete="off"
          class="grid gap-4 p-4"
        >
          <input
            :if={@channel_form_mode == :edit}
            type="hidden"
            name="alert_channel[channel_type]"
            value={AlertChannelForm.value(@channel_form[:channel_type])}
          />
          <div class="grid gap-4">
            <.input
              id="alert-channel-display-name"
              field={@channel_form[:display_name]}
              type="text"
              label="Channel name"
              placeholder="Operations alerts"
              required
            />
            <.input
              id="alert-channel-type"
              field={@channel_form[:channel_type]}
              type="select"
              label="Channel type"
              options={AlertChannelForm.channel_type_options()}
              disabled={@channel_form_mode == :edit}
              required
            />
            <.input
              id="alert-channel-state"
              field={@channel_form[:state]}
              type="select"
              label="Channel state"
              options={AlertChannelForm.state_options()}
            />
          </div>

          <div
            id="alert-channel-kind-fields"
            class="grid gap-4 rounded-box border border-base-300 bg-base-200 p-4"
          >
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
              Delivery endpoint
            </p>

            <.input
              :if={AlertChannelForm.value(@channel_form[:channel_type]) == "email"}
              id="alert-channel-email-to"
              field={@channel_form[:email_to]}
              type="email"
              label="Email recipient"
              placeholder="alerts@example.com"
              required
            />

            <div
              :if={AlertChannelForm.value(@channel_form[:channel_type]) == "webhook"}
              class="grid gap-4"
            >
              <.input
                id="alert-channel-webhook-url"
                field={@channel_form[:endpoint_url]}
                type="url"
                label="Webhook URL"
                placeholder={webhook_url_placeholder(@channel_form_mode)}
                required={@channel_form_mode == :create}
              />
              <div class="grid gap-2">
                <.input
                  id="alert-channel-webhook-signing-secret"
                  field={@channel_form[:webhook_signing_secret]}
                  type="password"
                  label="Signing secret"
                  placeholder="Leave blank to preserve"
                  autocomplete="new-password"
                />
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <p
                    id="alert-channel-webhook-signing-secret-status"
                    class="text-xs leading-5 text-base-content/60"
                  >
                    Stored signing secret:
                    <span class="font-semibold text-base-content/70">
                      {channel_form_secret_status(@editing_channel)}
                    </span>
                  </p>
                  <input
                    type="hidden"
                    name="alert_channel[webhook_signing_secret_action]"
                    value="preserve"
                  />
                  <label class="flex cursor-pointer items-center gap-2 text-xs font-medium text-base-content/70">
                    <input
                      id="alert-channel-webhook-signing-secret-clear"
                      type="checkbox"
                      name="alert_channel[webhook_signing_secret_action]"
                      value="clear"
                      checked={
                        AlertChannelForm.value(@channel_form[:webhook_signing_secret_action]) ==
                          "clear"
                      }
                      class="checkbox checkbox-primary checkbox-sm"
                    /> Clear stored signing secret
                  </label>
                </div>
              </div>
              <p
                id="alert-channel-webhook-url-help"
                class="text-xs leading-5 text-base-content/55"
              >
                After save, only scheme, host, masked path prefix, fingerprint, and key-version metadata are shown.
              </p>
            </div>
          </div>

          <div class="flex flex-wrap justify-end gap-2">
            <AdminComponents.action_button
              id="alert-channel-cancel"
              label="Cancel"
              phx-click="cancel_channel_form"
            />
            <AdminComponents.action_button
              id="alert-channel-submit"
              icon="hero-check"
              label={channel_form_submit_label(@channel_form_mode)}
              type="submit"
              variant={:primary}
            />
          </div>
        </.form>
      </AdminComponents.admin_surface>
    </div>
    """
  end

  defp channel_form_title(:edit), do: "Edit channel"
  defp channel_form_title(_mode), do: "Create channel"

  defp channel_form_submit_label(:edit), do: "Save channel"
  defp channel_form_submit_label(_mode), do: "Create channel"

  defp webhook_url_placeholder(:edit), do: "Leave blank to preserve stored webhook URL"
  defp webhook_url_placeholder(_mode), do: "https://hooks.example.com/alerts"

  defp channel_count_label([]), do: "0 channels"
  defp channel_count_label([_channel]), do: "1 channel"
  defp channel_count_label(channels), do: "#{length(channels)} channels"

  defp channel_endpoint_label(%{channel_type: "email", email_to: email_to}), do: email_to

  defp channel_endpoint_label(%{endpoint_scheme: scheme, endpoint_host: host} = channel)
       when is_binary(scheme) and is_binary(host) do
    scheme <> "://" <> host <> (channel.endpoint_path_prefix || "")
  end

  defp channel_endpoint_label(_channel), do: "not configured"

  defp channel_form_secret_status(%{webhook_signing_secret_key_version: key_version}),
    do: AlertChannelForm.secret_status_label(key_version)

  defp channel_form_secret_status(_channel), do: "not configured"
end
