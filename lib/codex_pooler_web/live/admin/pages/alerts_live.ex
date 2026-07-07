defmodule CodexPoolerWeb.Admin.AlertsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertChannel
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPoolerWeb.Admin.AlertChannelForm
  alias CodexPoolerWeb.Admin.AlertIncidentsReadModel
  alias CodexPoolerWeb.Admin.AlertRuleForm
  alias CodexPoolerWeb.Admin.AlertsPageComponents
  alias CodexPoolerWeb.Admin.AlertsPageComponents.{Channels, Incidents, Rules}
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  @default_tab "rules"
  @tabs ~w(rules channels incidents)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Alerts",
        selected_tab: @default_tab,
        current_params: %{},
        rule_form_mode: :create,
        channel_form_mode: :create,
        editing_rule: nil,
        editing_channel: nil,
        deleting_rule: nil,
        deleting_channel: nil,
        rule_form: AlertRuleForm.create_form([]),
        rule_delete_form: AlertRuleForm.delete_form(nil),
        channel_form: AlertChannelForm.create_form(),
        channel_delete_form: AlertChannelForm.delete_form(nil)
      )
      |> assign_alert_state()
      |> reset_rule_form()
      |> reset_channel_form()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(selected_tab: normalize_tab(params["tab"]), current_params: params)
     |> assign_alert_state(params)}
  end

  @impl true
  def handle_event("filter_incidents", params, socket),
    do: {:noreply, filter_incidents(socket, params)}

  def handle_event("select_incident_pool_filter", params, socket),
    do: {:noreply, select_incident_pool_filter(socket, params)}

  def handle_event("acknowledge_incident", params, socket),
    do: {:noreply, acknowledge_incident(socket, params)}

  def handle_event("resolve_incident", params, socket),
    do: {:noreply, resolve_incident(socket, params)}

  def handle_event("open_edit_rule", params, socket),
    do: {:noreply, open_edit_rule(socket, params)}

  def handle_event("cancel_rule_form", _params, socket), do: {:noreply, cancel_rule_form(socket)}

  def handle_event("change_rule_form", params, socket),
    do: {:noreply, change_rule_form(socket, params)}

  def handle_event("save_rule", params, socket), do: {:noreply, save_rule_event(socket, params)}

  def handle_event("disable_rule", params, socket), do: {:noreply, disable_rule(socket, params)}

  def handle_event("open_delete_rule", params, socket),
    do: {:noreply, open_delete_rule(socket, params)}

  def handle_event("cancel_delete_rule", _params, socket),
    do: {:noreply, cancel_delete_rule(socket)}

  def handle_event("confirm_delete_rule", params, socket),
    do: {:noreply, confirm_delete_rule(socket, params)}

  def handle_event("open_edit_channel", params, socket),
    do: {:noreply, open_edit_channel(socket, params)}

  def handle_event("cancel_channel_form", _params, socket),
    do: {:noreply, cancel_channel_form(socket)}

  def handle_event("change_channel_form", params, socket),
    do: {:noreply, change_channel_form(socket, params)}

  def handle_event("save_channel", params, socket),
    do: {:noreply, save_channel_event(socket, params)}

  def handle_event("disable_channel", params, socket),
    do: {:noreply, disable_channel(socket, params)}

  def handle_event("open_delete_channel", params, socket),
    do: {:noreply, open_delete_channel(socket, params)}

  def handle_event("cancel_delete_channel", _params, socket),
    do: {:noreply, cancel_delete_channel(socket)}

  def handle_event("confirm_delete_channel", params, socket),
    do: {:noreply, confirm_delete_channel(socket, params)}

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:alerts}
      alert_notification_center={@alert_notification_center}
    >
      <section id="admin-alerts-live" class="grid min-w-0 gap-6">
        <AdminComponents.page_header
          id="alerts-page-header"
          title="Alerts"
          description="Configure Pool-scoped alert rules and safe delivery channels for serving risk, quota evidence, and upstream account state."
        />

        <section id="alerts-workspace" class="grid gap-4">
          <AlertsPageComponents.workspace_header selected_tab={@selected_tab} />

          <Rules.rules_section
            selected_tab={@selected_tab}
            manageable_pools={@manageable_pools}
            rules={@rules}
            pool_lookup={@pool_lookup}
            rule_form_mode={@rule_form_mode}
            rule_form={@rule_form}
          />

          <Channels.channels_section
            selected_tab={@selected_tab}
            channels={@channels}
            channel_form_mode={@channel_form_mode}
            channel_form={@channel_form}
            editing_channel={@editing_channel}
          />

          <Incidents.incidents_section
            selected_tab={@selected_tab}
            incident_filter_form={@incident_filter_form}
            incident_filter_values={@incident_filter_values}
            incident_pool_filter_options={@incident_pool_filter_options}
            incident_severity_filter_options={@incident_severity_filter_options}
            incident_state_filter_options={@incident_state_filter_options}
            incident_rule_filter_options={@incident_rule_filter_options}
            incident_channel_filter_options={@incident_channel_filter_options}
            incident_filter_errors={@incident_filter_errors}
            incidents={@incidents}
            incident_total_count={@incident_total_count}
            incident_page_size={@incident_page_size}
          />
        </section>
        <dialog :if={@deleting_rule} id="alert-rule-delete-dialog" class="modal" open>
          <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
            <div class="border-b border-base-300 px-6 py-5">
              <p class="text-sm font-semibold uppercase tracking-wide text-error">Delete rule</p>
              <h2 class="mt-1 text-2xl font-bold text-base-content">Delete alert rule</h2>
              <p class="mt-2 text-sm leading-6 text-base-content/70">
                This removes the rule definition. Existing incident records stay available to later alert workflows.
              </p>
            </div>

            <.form
              id="alert-rule-delete-form"
              for={@rule_delete_form}
              phx-submit="confirm_delete_rule"
              autocomplete="off"
              class="grid gap-5 p-6"
            >
              <.input field={@rule_delete_form[:id]} type="hidden" />
              <div class="alert alert-warning items-start">
                <.icon name="hero-exclamation-triangle" class="size-5" />
                <div class="grid gap-1">
                  <p class="font-semibold">This deletes {@deleting_rule.display_name}.</p>
                  <p class="text-sm">
                    Create it again later if this condition should be evaluated again.
                  </p>
                </div>
              </div>
              <div class="modal-action mt-0">
                <AdminComponents.action_button
                  id="alert-rule-delete-cancel"
                  icon="hero-x-mark"
                  label="Cancel"
                  phx-click="cancel_delete_rule"
                />
                <AdminComponents.action_button
                  id="alert-rule-delete-submit"
                  icon="hero-trash"
                  label="Delete rule"
                  type="submit"
                  variant={:danger}
                />
              </div>
            </.form>
          </div>
          <form method="dialog" class="modal-backdrop">
            <button type="button" phx-click="cancel_delete_rule">close</button>
          </form>
        </dialog>

        <dialog :if={@deleting_channel} id="alert-channel-delete-dialog" class="modal" open>
          <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
            <div class="border-b border-base-300 px-6 py-5">
              <p class="text-sm font-semibold uppercase tracking-wide text-error">Delete channel</p>
              <h2 class="mt-1 text-2xl font-bold text-base-content">Delete alert channel</h2>
              <p class="mt-2 text-sm leading-6 text-base-content/70">
                This removes the delivery target. Existing delivery attempts stay available to later alert workflows.
              </p>
            </div>

            <.form
              id="alert-channel-delete-form"
              for={@channel_delete_form}
              phx-submit="confirm_delete_channel"
              autocomplete="off"
              class="grid gap-5 p-6"
            >
              <.input field={@channel_delete_form[:id]} type="hidden" />
              <div class="alert alert-warning items-start">
                <.icon name="hero-exclamation-triangle" class="size-5" />
                <div class="grid gap-1">
                  <p class="font-semibold">This deletes {@deleting_channel.display_name}.</p>
                  <p class="text-sm">
                    Rules using this channel will no longer deliver to it.
                  </p>
                </div>
              </div>
              <div class="modal-action mt-0">
                <AdminComponents.action_button
                  id="alert-channel-delete-cancel"
                  icon="hero-x-mark"
                  label="Cancel"
                  phx-click="cancel_delete_channel"
                />
                <AdminComponents.action_button
                  id="alert-channel-delete-submit"
                  icon="hero-trash"
                  label="Delete channel"
                  type="submit"
                  variant={:danger}
                />
              </div>
            </.form>
          </div>
          <form method="dialog" class="modal-backdrop">
            <button type="button" phx-click="cancel_delete_channel">close</button>
          </form>
        </dialog>
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp filter_incidents(socket, %{"filters" => filter_params}) do
    push_patch(socket,
      to: ~p"/admin/alerts?#{AlertIncidentsReadModel.query_params(filter_params)}"
    )
  end

  defp select_incident_pool_filter(socket, %{"pool-id" => pool_id}) do
    params = Map.put(socket.assigns.incident_filter_values, "pool_id", pool_id)

    push_patch(socket, to: ~p"/admin/alerts?#{AlertIncidentsReadModel.query_params(params)}")
  end

  defp acknowledge_incident(socket, %{"id" => incident_id}) do
    case Alerts.acknowledge_incident(socket.assigns.current_scope, incident_id) do
      {:ok, _incident} ->
        socket
        |> assign_alert_state()
        |> put_flash(:info, "Alert incident acknowledged")

      {:error, _reason} ->
        socket
        |> assign_alert_state()
        |> put_flash(:error, "Alert incident could not be acknowledged")
    end
  end

  defp resolve_incident(socket, %{"id" => incident_id}) do
    case Alerts.resolve_incident(socket.assigns.current_scope, incident_id) do
      {:ok, _incident} ->
        socket
        |> assign_alert_state()
        |> put_flash(:info, "Alert incident resolved")

      {:error, _reason} ->
        socket
        |> assign_alert_state()
        |> put_flash(:error, "Alert incident could not be resolved")
    end
  end

  defp open_edit_rule(socket, %{"id" => rule_id}) do
    case find_visible_rule(socket.assigns.rules, rule_id) do
      %AlertRule{} = rule ->
        assign(socket,
          rule_form_mode: :edit,
          editing_rule: rule,
          deleting_rule: nil,
          rule_delete_form: AlertRuleForm.delete_form(nil),
          rule_form: AlertRuleForm.edit_form(rule)
        )

      nil ->
        socket
        |> assign_alert_state()
        |> put_flash(:error, "Alert rule was not found")
    end
  end

  defp cancel_rule_form(socket) do
    socket
    |> assign(rule_form_mode: :create, editing_rule: nil)
    |> reset_rule_form()
  end

  defp change_rule_form(socket, %{"alert_rule" => params}) do
    assign(socket, :rule_form, rule_form(socket, params))
  end

  defp save_rule_event(socket, %{"alert_rule" => params}) do
    mode = socket.assigns.rule_form_mode

    attrs =
      AlertRuleForm.normalize_submit(params, default_severity: editing_rule_severity(socket))

    case save_rule(mode, socket.assigns.current_scope, socket.assigns.editing_rule, attrs) do
      {:ok, _rule} ->
        socket
        |> assign(rule_form_mode: :create, editing_rule: nil)
        |> assign_alert_state()
        |> reset_rule_form()
        |> put_flash(:info, success_message(mode))

      {:error, %Ecto.Changeset{} = changeset} ->
        assign(
          socket,
          :rule_form,
          rule_form(socket, params, AlertRuleForm.changeset_errors(changeset))
        )

      {:error, %{code: code}} ->
        socket
        |> assign(:rule_form, rule_form(socket, params, access_errors(code)))
        |> put_flash(:error, access_error_message(code))
    end
  end

  defp disable_rule(socket, %{"id" => rule_id}) do
    case Alerts.update_rule(socket.assigns.current_scope, rule_id, %{
           state: AlertRule.disabled_state()
         }) do
      {:ok, _rule} ->
        socket
        |> assign_alert_state()
        |> put_flash(:info, "Alert rule disabled")

      {:error, _reason} ->
        socket
        |> assign_alert_state()
        |> put_flash(:error, "Alert rule could not be disabled")
    end
  end

  defp open_delete_rule(socket, %{"id" => rule_id}) do
    case find_visible_rule(socket.assigns.rules, rule_id) do
      %AlertRule{} = rule ->
        assign(socket, deleting_rule: rule, rule_delete_form: AlertRuleForm.delete_form(rule))

      nil ->
        socket
        |> assign_alert_state()
        |> put_flash(:error, "Alert rule was not found")
    end
  end

  defp cancel_delete_rule(socket) do
    assign(socket, deleting_rule: nil, rule_delete_form: AlertRuleForm.delete_form(nil))
  end

  defp confirm_delete_rule(socket, %{"alert_rule_delete" => %{"id" => rule_id}}) do
    case Alerts.delete_rule(socket.assigns.current_scope, rule_id) do
      {:ok, _rule} ->
        socket
        |> assign(deleting_rule: nil, rule_delete_form: AlertRuleForm.delete_form(nil))
        |> assign_alert_state()
        |> reset_rule_form()
        |> put_flash(:info, "Alert rule deleted")

      {:error, _reason} ->
        socket
        |> assign(deleting_rule: nil, rule_delete_form: AlertRuleForm.delete_form(nil))
        |> assign_alert_state()
        |> put_flash(:error, "Alert rule could not be deleted")
    end
  end

  defp open_edit_channel(socket, %{"id" => channel_id}) do
    case find_visible_channel(socket.assigns.channels, channel_id) do
      %{} = channel ->
        assign(socket,
          channel_form_mode: :edit,
          editing_channel: channel,
          deleting_channel: nil,
          channel_delete_form: AlertChannelForm.delete_form(nil),
          channel_form: AlertChannelForm.edit_form(channel)
        )

      nil ->
        socket
        |> assign_alert_state()
        |> put_flash(:error, "Alert channel was not found")
    end
  end

  defp cancel_channel_form(socket) do
    socket
    |> assign(channel_form_mode: :create, editing_channel: nil)
    |> reset_channel_form()
  end

  defp change_channel_form(socket, %{"alert_channel" => params}) do
    assign(socket, :channel_form, channel_form(socket, params))
  end

  defp save_channel_event(socket, %{"alert_channel" => params}) do
    mode = socket.assigns.channel_form_mode
    attrs = AlertChannelForm.normalize_submit(params, mode)

    case save_channel(mode, socket.assigns.current_scope, socket.assigns.editing_channel, attrs) do
      {:ok, _channel} ->
        socket
        |> assign(channel_form_mode: :create, editing_channel: nil)
        |> assign_alert_state()
        |> reset_channel_form()
        |> put_flash(:info, channel_success_message(mode))

      {:error, %Ecto.Changeset{} = changeset} ->
        assign(
          socket,
          :channel_form,
          channel_form(socket, params, AlertChannelForm.changeset_errors(changeset))
        )

      {:error, %{code: code}} ->
        socket
        |> assign(:channel_form, channel_form(socket, params, channel_access_errors(code)))
        |> put_flash(:error, channel_access_error_message(code))
    end
  end

  defp disable_channel(socket, %{"id" => channel_id}) do
    case Alerts.update_channel(socket.assigns.current_scope, channel_id, %{
           state: AlertChannel.disabled_state()
         }) do
      {:ok, _channel} ->
        socket
        |> assign_alert_state()
        |> put_flash(:info, "Alert channel disabled")

      {:error, _reason} ->
        socket
        |> assign_alert_state()
        |> put_flash(:error, "Alert channel could not be disabled")
    end
  end

  defp open_delete_channel(socket, %{"id" => channel_id}) do
    case find_visible_channel(socket.assigns.channels, channel_id) do
      %{} = channel ->
        assign(socket,
          deleting_channel: channel,
          channel_delete_form: AlertChannelForm.delete_form(channel)
        )

      nil ->
        socket
        |> assign_alert_state()
        |> put_flash(:error, "Alert channel was not found")
    end
  end

  defp cancel_delete_channel(socket) do
    assign(socket,
      deleting_channel: nil,
      channel_delete_form: AlertChannelForm.delete_form(nil)
    )
  end

  defp confirm_delete_channel(socket, %{"alert_channel_delete" => %{"id" => channel_id}}) do
    case Alerts.delete_channel(socket.assigns.current_scope, channel_id) do
      {:ok, _channel} ->
        socket
        |> assign(deleting_channel: nil, channel_delete_form: AlertChannelForm.delete_form(nil))
        |> assign_alert_state()
        |> reset_channel_form()
        |> put_flash(:info, "Alert channel deleted")

      {:error, _reason} ->
        socket
        |> assign(deleting_channel: nil, channel_delete_form: AlertChannelForm.delete_form(nil))
        |> assign_alert_state()
        |> put_flash(:error, "Alert channel could not be deleted")
    end
  end

  defp assign_alert_state(socket) do
    assign_alert_state(socket, socket.assigns.current_params)
  end

  defp assign_alert_state(socket, params) do
    scope = socket.assigns.current_scope
    state = AlertIncidentsReadModel.load(scope, params || %{})

    assign(socket,
      manageable_pools: state.manageable_pools,
      pool_lookup: state.pool_lookup,
      rules: state.rules,
      channels: state.channels,
      incidents: state.incidents,
      incident_filter_form: state.filter_form,
      incident_filter_values: state.filter_values,
      incident_filter_errors: state.filter_errors,
      incident_pool_filter_options: state.pool_filter_options,
      incident_severity_filter_options: state.severity_filter_options,
      incident_state_filter_options: state.state_filter_options,
      incident_rule_filter_options: state.rule_filter_options,
      incident_channel_filter_options: state.channel_filter_options,
      incident_total_count: state.total_count,
      incident_page_size: state.page_size
    )
  end

  defp reset_rule_form(socket) do
    assign(socket, :rule_form, AlertRuleForm.create_form(socket.assigns.manageable_pools))
  end

  defp reset_channel_form(socket) do
    assign(socket, :channel_form, AlertChannelForm.create_form())
  end

  defp rule_form(socket, params), do: rule_form(socket, params, [])

  defp rule_form(
         %{assigns: %{rule_form_mode: :edit, editing_rule: %AlertRule{} = rule}},
         params,
         errors
       ) do
    AlertRuleForm.edit_form(rule, params, errors: errors)
  end

  defp rule_form(socket, params, errors) do
    AlertRuleForm.create_form(socket.assigns.manageable_pools, params, errors: errors)
  end

  defp save_rule(:edit, scope, %AlertRule{} = rule, attrs),
    do: Alerts.update_rule(scope, rule, attrs)

  defp save_rule(_mode, scope, _rule, attrs), do: Alerts.create_rule(scope, attrs)

  defp editing_rule_severity(%{
         assigns: %{rule_form_mode: :edit, editing_rule: %AlertRule{} = rule}
       }),
       do: rule.severity

  defp editing_rule_severity(_socket), do: nil

  defp channel_form(socket, params), do: channel_form(socket, params, [])

  defp channel_form(
         %{assigns: %{channel_form_mode: :edit, editing_channel: channel}},
         params,
         errors
       )
       when is_map(channel) do
    AlertChannelForm.edit_form(channel, params, errors: errors)
  end

  defp channel_form(_socket, params, errors) do
    AlertChannelForm.create_form(params, errors: errors)
  end

  defp save_channel(:edit, scope, %{id: channel_id}, attrs),
    do: Alerts.update_channel(scope, channel_id, attrs)

  defp save_channel(_mode, scope, _channel, attrs), do: Alerts.create_channel(scope, attrs)

  defp success_message(:edit), do: "Alert rule updated"
  defp success_message(_mode), do: "Alert rule created"

  defp channel_success_message(:edit), do: "Alert channel updated"
  defp channel_success_message(_mode), do: "Alert channel created"

  defp find_visible_rule(rules, rule_id), do: Enum.find(rules, &(&1.id == rule_id))

  defp find_visible_channel(channels, channel_id), do: Enum.find(channels, &(&1.id == channel_id))

  defp normalize_tab(tab) when tab in @tabs, do: tab
  defp normalize_tab(_tab), do: @default_tab

  defp access_errors(:capability_denied), do: [pool_id: {"Pool is not available", []}]
  defp access_errors(:rule_not_found), do: [pool_id: {"Rule is not available", []}]

  defp access_errors(:channel_not_found),
    do: [display_name: {"Delivery channel is not available", []}]

  defp access_errors(_code), do: [display_name: {"Rule could not be saved", []}]

  defp access_error_message(:capability_denied), do: "Pool is not available for this operator"
  defp access_error_message(:rule_not_found), do: "Alert rule was not found"
  defp access_error_message(:channel_not_found), do: "Delivery channel was not found"
  defp access_error_message(_code), do: "Alert rule could not be saved"

  defp channel_access_errors(:channel_not_found),
    do: [display_name: {"Channel is not available", []}]

  defp channel_access_errors(_code), do: [display_name: {"Channel could not be saved", []}]

  defp channel_access_error_message(:channel_not_found), do: "Alert channel was not found"
  defp channel_access_error_message(_code), do: "Alert channel could not be saved"
end
