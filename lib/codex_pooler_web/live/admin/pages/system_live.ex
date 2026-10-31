defmodule CodexPoolerWeb.Admin.SystemLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.{Accounts, Catalog, Dev, InstanceSettings, MCP, Pools}
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.NotificationCenterHooks
  alias CodexPoolerWeb.Admin.SystemPageComponents
  alias CodexPoolerWeb.Admin.SystemSettingsForm
  alias CodexPoolerWeb.DateTimeDisplay

  @default_tab "smtp"
  @base_system_tabs ~w(smtp mcp metrics gateway firewall)
  @development_tab "development"
  @settings_groups ~w(gateway ingress files transcription operator catalog development mcp metrics smtp)

  @impl true
  def mount(_params, _session, socket) do
    if Pools.owner?(socket.assigns.current_scope) do
      settings = InstanceSettings.ensure_singleton!()
      form_params = SystemSettingsForm.params_from_settings(settings)
      development_helpers_available? = CodexPoolerWeb.DevFeatures.enabled?()

      {:ok,
       socket
       |> assign(
         page_title: gettext("System"),
         owner_authorized?: true,
         selected_tab: @default_tab,
         system_tabs: system_tabs(development_helpers_available?),
         settings: settings,
         development_helpers_available?: development_helpers_available?,
         impeccable_live_status: CodexPoolerWeb.DevFeatures.impeccable_live_status(),
         mcp_key_count: MCP.count_operator_tokens(),
         form_params: form_params,
         group_snapshots: SystemSettingsForm.group_snapshots(form_params),
         card_statuses: SystemSettingsForm.initial_card_statuses(),
         development_action_status: nil,
         smtp_test_status: nil,
         current_session_ip:
           Accounts.current_user_session_ip(
             socket.assigns.current_scope.user,
             socket.assigns[:user_session_id]
           )
       )
       |> assign_forms()
       |> NotificationCenterHooks.follow_viewer_visibility()}
    else
      {:ok,
       socket
       |> assign(page_title: gettext("System"), owner_authorized?: false)
       |> NotificationCenterHooks.follow_viewer_visibility()}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns.owner_authorized? do
      development_helpers_available? = CodexPoolerWeb.DevFeatures.enabled?()

      {:noreply,
       socket
       |> assign(:development_helpers_available?, development_helpers_available?)
       |> assign(:impeccable_live_status, CodexPoolerWeb.DevFeatures.impeccable_live_status())
       |> assign(:system_tabs, system_tabs(development_helpers_available?))
       |> assign(:mcp_key_count, MCP.count_operator_tokens())
       |> assign(
         :current_session_ip,
         Accounts.current_user_session_ip(
           socket.assigns.current_scope.user,
           socket.assigns[:user_session_id]
         )
       )
       |> assign(:selected_tab, normalize_tab(params["tab"], development_helpers_available?))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(_event, _params, %{assigns: %{owner_authorized?: false}} = socket) do
    {:noreply, owner_denied(socket)}
  end

  def handle_event("validate_instance_settings", %{"instance_settings" => params}, socket) do
    group = SystemSettingsForm.submitted_group(params)

    params =
      params |> SystemSettingsForm.strip_form_meta() |> SystemSettingsForm.normalize_params()

    form_params = SystemSettingsForm.merge_group_params(socket.assigns.form_params, group, params)

    changeset =
      socket.assigns.settings
      |> SystemSettingsForm.group_changeset(form_params, group)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form_params, form_params)
     |> assign(:smtp_test_status, nil)
     |> put_card_status(
       group,
       SystemSettingsForm.dirty_card_status(form_params, socket.assigns.group_snapshots, group)
     )
     |> put_group_form(group, changeset)}
  end

  def handle_event("save_instance_settings", %{"instance_settings" => params}, socket) do
    save_instance_settings(socket, params, autosave?: false)
  end

  def handle_event("autosave_instance_settings", %{"instance_settings" => params}, socket) do
    save_instance_settings(socket, params, autosave?: true)
  end

  def handle_event("apply_bulkhead_preset", %{"preset" => preset}, socket) do
    case SystemSettingsForm.apply_bulkhead_preset(socket.assigns.form_params, preset) do
      {:ok, form_params} ->
        {:noreply, put_gateway_form_params(socket, form_params)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("restore_gateway_group_defaults", %{"group" => group}, socket) do
    case SystemSettingsForm.restore_gateway_group_defaults(socket.assigns.form_params, group) do
      {:ok, form_params} -> {:noreply, put_gateway_form_params(socket, form_params)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("test_smtp", _params, socket) do
    params =
      SystemSettingsForm.group_only_params(
        socket.assigns.settings,
        socket.assigns.form_params,
        "smtp"
      )

    status =
      case InstanceSettings.send_smtp_test_email(
             socket.assigns.settings,
             params,
             socket.assigns.current_scope,
             socket.assigns.locale.tag
           ) do
        {:ok, %{code: :smtp_test_email_sent}} ->
          %{
            tone: :success,
            message: gettext("Test email sent to %{recipient}", recipient: operator_email_for_status(socket.assigns.current_scope))
          }

        {:error, %Ecto.Changeset{} = changeset} ->
          smtp_changeset_status(changeset)

        {:error, %{code: _code} = error} ->
          %{tone: :error, message: smtp_error_message(error)}

        {:error, _reason} ->
          %{tone: :error, message: gettext("SMTP test email failed")}
      end

    {:noreply, assign(socket, :smtp_test_status, status)}
  end

  def handle_event("import_sample_data", _params, socket) do
    if socket.assigns.development_helpers_available? do
      case import_sample_data() do
        {:ok, result} ->
          {:noreply,
           socket
           |> assign(:development_action_status, sample_data_import_status(result))
           |> put_flash(:info, gettext("Sample data imported"))}

        {:error, reason} ->
          message = sample_data_import_error_message(reason)

          {:noreply,
           socket
           |> assign(:development_action_status, %{tone: :error, message: message})
           |> put_flash(:error, gettext("Sample data could not be imported"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Development helpers are not available"))}
    end
  end

  def handle_event("recheck_impeccable_live", _params, socket) do
    if socket.assigns.development_helpers_available? do
      {:noreply,
       assign(
         socket,
         :impeccable_live_status,
         CodexPoolerWeb.DevFeatures.impeccable_live_status()
       )}
    else
      {:noreply, put_flash(socket, :error, gettext("Development helpers are not available"))}
    end
  end

  def handle_event("import_pricing_catalog", _params, socket) do
    if socket.assigns.development_helpers_available? do
      source_url = socket.assigns.settings.catalog.openai_pricing_url

      case Catalog.import_openai_pricing_from_url(source_url) do
        {:ok, result} ->
          message =
            ngettext(
              "Pricing imported: %{inserted} inserted, %{skipped} skipped, %{total} total.",
              "Pricing imported: %{inserted} inserted, %{skipped} skipped, %{total} total.",
              result.total,
              inserted: result.inserted,
              skipped: result.skipped,
              total: result.total
            )

          {:noreply,
           socket
           |> assign(:development_action_status, %{tone: :success, message: message})
           |> put_flash(:info, gettext("Pricing catalog imported"))}

        {:error, reason} ->
          message = pricing_import_error_message(reason)

          {:noreply,
           socket
           |> assign(:development_action_status, %{tone: :error, message: message})
           |> put_flash(:error, gettext("Pricing catalog could not be imported"))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Development helpers are not available"))}
    end
  end

  defp save_instance_settings(socket, params, opts) do
    autosave? = Keyword.fetch!(opts, :autosave?)
    group = SystemSettingsForm.submitted_group(params)

    params =
      params |> SystemSettingsForm.strip_form_meta() |> SystemSettingsForm.normalize_params()

    form_params = SystemSettingsForm.merge_group_params(socket.assigns.form_params, group, params)
    latest_settings = InstanceSettings.get!()

    if SystemSettingsForm.group_stale?(socket.assigns.group_snapshots, latest_settings, group) do
      stale_group_settings(socket, latest_settings, form_params, group, autosave?)
    else
      if autosave?,
        do: save_group_settings(socket, latest_settings, form_params, group, autosave?: true),
        else: save_group_settings(socket, latest_settings, form_params, group)
    end
  end

  defp stale_group_settings(socket, latest_settings, form_params, group, autosave?) do
    changeset =
      latest_settings
      |> SystemSettingsForm.group_changeset(form_params, group)
      |> Ecto.Changeset.add_error(:lock_version, "was updated by another operator")
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(settings: latest_settings, form_params: form_params, smtp_test_status: nil)
      |> put_card_status(group, %{tone: :error, message: gettext("Reload this card and retry.")})
      |> put_group_form(group, changeset)

    if autosave? do
      {:noreply, socket}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("%{card} was updated by another operator. Reload and retry.", card: card_title(group))
       )}
    end
  end

  @impl true
  def handle_info({:clear_card_status, group}, socket) when group in @settings_groups do
    {:noreply, put_card_status(socket, group, nil)}
  end

  def handle_info({:clear_card_status, group, dismiss_ref}, socket)
      when group in @settings_groups do
    case Map.get(socket.assigns.card_statuses, group) do
      %{dismiss_ref: ^dismiss_ref} -> {:noreply, put_card_status(socket, group, nil)}
      _status -> {:noreply, socket}
    end
  end

  # Instance settings belong to owners. A viewer who lost or gained the owner
  # role reloads the page, which mounts it again with the role it has now: a
  # demoted owner's settings forms go, a promoted admin's appear. Any other
  # change of the viewer's Pools leaves an owner's open forms alone (findings#206
  # row 206-329).
  def handle_info({NotificationCenterHooks, :viewer_visibility_changed}, socket) do
    if Pools.owner?(socket.assigns.current_scope) == socket.assigns.owner_authorized? do
      {:noreply, socket}
    else
      {:noreply, push_navigate(socket, to: system_path(socket.assigns[:selected_tab]))}
    end
  end

  defp system_path(tab) when is_binary(tab), do: ~p"/admin/system?#{%{tab: tab}}"
  defp system_path(_tab), do: ~p"/admin/system"

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :datetime_preferences,
        DateTimeDisplay.preferences_for_user(assigns.current_scope.user)
      )

    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      locale={@locale}
      locale_preference={@locale_preference}
      active_nav={:system}
      alert_notification_center={@alert_notification_center}
      openai_status_aggregate={@openai_status_aggregate}
    >
      <section id="admin-system-live" class="grid min-w-0 gap-6">
        <AdminComponents.page_header
          id="system-page-header"
          title={gettext("System")}
          description={gettext("Instance-wide runtime settings, from gateway and ingress behavior to metrics and SMTP delivery.")}
        />

        <AdminComponents.empty_state
          :if={!@owner_authorized?}
          id="admin-system-owner-denied"
          title={gettext("System settings require owner access")}
          description={gettext("Only instance owners can inspect or change global system settings.")}
          icon="hero-lock-closed"
        />

        <section :if={@owner_authorized?} id="system-workspace" class="grid gap-4">
          <SystemPageComponents.system_tab_picker tabs={@system_tabs} selected_tab={@selected_tab} />

          <SystemPageComponents.instance_settings_panel
            selected_tab={@selected_tab}
            forms={@forms}
            form_params={@form_params}
            settings={@settings}
            mcp_key_count={@mcp_key_count}
            card_statuses={@card_statuses}
            development_action_status={@development_action_status}
            smtp_test_status={@smtp_test_status}
            development_helpers_available?={@development_helpers_available?}
            impeccable_live_status={@impeccable_live_status}
            datetime_preferences={@datetime_preferences}
            current_session_ip={@current_session_ip}
          />
        </section>
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp assign_forms(socket) do
    assign(
      socket,
      :forms,
      SystemSettingsForm.forms(socket.assigns.settings, socket.assigns.form_params)
    )
  end

  defp owner_denied(socket) do
    put_flash(socket, :error, gettext("Only instance owners can manage system settings"))
  end

  defp put_group_form(socket, group, %Ecto.Changeset{} = changeset) do
    assign(
      socket,
      :forms,
      Map.put(socket.assigns.forms, group, to_form(changeset, as: :instance_settings))
    )
  end

  defp put_gateway_form_params(socket, form_params) do
    changeset =
      socket.assigns.settings
      |> SystemSettingsForm.group_changeset(form_params, "gateway")
      |> Map.put(:action, :validate)

    socket
    |> assign(:form_params, form_params)
    |> assign(:smtp_test_status, nil)
    |> put_card_status(
      "gateway",
      SystemSettingsForm.dirty_card_status(
        form_params,
        socket.assigns.group_snapshots,
        "gateway"
      )
    )
    |> put_group_form("gateway", changeset)
  end

  defp save_group_settings(socket, latest_settings, form_params, group, opts \\ []) do
    autosave? = Keyword.get(opts, :autosave?, false)

    params =
      latest_settings
      |> SystemSettingsForm.group_only_params(form_params, group)

    case InstanceSettings.update(socket.assigns.current_scope, latest_settings, params) do
      {:ok, settings} ->
        saved_params = SystemSettingsForm.params_from_settings(settings)

        form_params =
          SystemSettingsForm.refresh_saved_group_params(form_params, saved_params, group)

        group_snapshots =
          SystemSettingsForm.refresh_group_snapshots(socket.assigns, saved_params, group)

        card_statuses =
          form_params
          |> SystemSettingsForm.saved_card_statuses(group_snapshots, group)
          |> maybe_put_clear_card_status(group, params)

        {:noreply,
         socket
         |> assign(
           settings: settings,
           development_helpers_available?: CodexPoolerWeb.DevFeatures.enabled?(),
           impeccable_live_status: CodexPoolerWeb.DevFeatures.impeccable_live_status(),
           form_params: form_params,
           group_snapshots: group_snapshots,
           card_statuses: card_statuses,
           development_action_status: nil,
           smtp_test_status: nil
         )
         |> assign_forms()
         |> maybe_put_save_feedback(group, autosave?, save_feedback_message(group, params))}

      {:error, %Ecto.Changeset{} = changeset} ->
        status =
          if stale_changeset?(changeset),
            do: %{tone: :error, message: gettext("Reload this card and retry.")},
            else: %{tone: :error, message: gettext("Review errors before saving this card.")}

        socket =
          if stale_changeset?(changeset) do
            put_flash(
              socket,
              :error,
              gettext("%{card} was updated by another operator. Reload and retry.", card: card_title(group))
            )
          else
            put_flash(socket, :error, gettext("%{card} could not be saved", card: card_title(group)))
          end

        {:noreply,
         socket
         |> assign(settings: latest_settings, form_params: form_params, smtp_test_status: nil)
         |> put_card_status(group, status)
         |> put_group_form(group, Map.put(changeset, :action, :validate))}

      {:error, %{code: :capability_denied}} ->
        {:noreply, owner_denied(socket)}
    end
  end

  defp put_card_status(socket, group, status) do
    assign(socket, :card_statuses, Map.put(socket.assigns.card_statuses, group, status))
  end

  defp card_title("gateway"), do: gettext("Gateway controls")
  defp card_title("ingress"), do: gettext("Runtime ingress")
  defp card_title("files"), do: gettext("File bridge limits")
  defp card_title("transcription"), do: gettext("Audio upload limit")
  defp card_title("operator"), do: gettext("Public operator app URL")
  defp card_title("catalog"), do: gettext("Pricing catalog source")
  defp card_title("development"), do: gettext("Development helpers")
  defp card_title("mcp"), do: gettext("MCP service")
  defp card_title("metrics"), do: gettext("Metrics bearer token")
  defp card_title("smtp"), do: gettext("SMTP delivery")

  defp maybe_put_save_feedback(socket, group, true, _message) do
    dismiss_ref = make_ref()
    Process.send_after(self(), {:clear_card_status, group, dismiss_ref}, 2_500)

    put_card_status(socket, group, %{tone: :success, message: gettext("Saved"), dismiss_ref: dismiss_ref})
  end

  defp maybe_put_save_feedback(socket, _group, false, message) do
    put_flash(socket, :info, message)
  end

  defp save_feedback_message("metrics", %{
         "metrics" => %{"bearer_token_action" => "clear"}
       }),
       do: gettext("Metrics bearer token cleared")

  defp save_feedback_message(group, _params), do: gettext("%{card} saved", card: card_title(group))

  defp maybe_put_clear_card_status(card_statuses, "metrics", %{
         "metrics" => %{"bearer_token_action" => "clear"}
       }) do
    Map.put(card_statuses, "metrics", %{tone: :success, message: gettext("Cleared")})
  end

  defp maybe_put_clear_card_status(card_statuses, _group, _params), do: card_statuses

  defp import_sample_data do
    case Dev.seed_full() do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sample_data_import_error_message(%{code: :dev_support_unavailable, message: "Development support is not compiled for this environment"}),
    do: gettext("Development support is not compiled for this environment")

  defp sample_data_import_error_message(%{message: message}) when is_binary(message), do: message

  defp sample_data_import_status(result) do
    %{
      tone: :success,
      message:
        ngettext(
          "Sample data imported: %{pools} pools, %{api_keys} API keys, %{upstream_accounts} upstream accounts, %{assignments} assignments, %{models} models, %{quota_windows} quota windows, %{request_logs} request logs, %{invites} invites, %{audit_events} audit events, and %{jobs} jobs.",
          "Sample data imported: %{pools} pools, %{api_keys} API keys, %{upstream_accounts} upstream accounts, %{assignments} assignments, %{models} models, %{quota_windows} quota windows, %{request_logs} request logs, %{invites} invites, %{audit_events} audit events, and %{jobs} jobs.",
          length(result.jobs),
          pools: length(result.pools),
          api_keys: length(result.api_keys),
          upstream_accounts: length(result.upstream_identities),
          assignments: length(result.assignments),
          models: length(result.models),
          quota_windows: length(result.quota_windows),
          request_logs: length(result.request_logs),
          invites: length(result.invites),
          audit_events: length(result.audit_events),
          jobs: length(result.jobs)
        )
    }
  end

  defp pricing_import_error_message(%{code: code, message: message}) do
    gettext("Pricing import failed: %{code} %{message}", code: code, message: pricing_import_message(message))
  end

  defp pricing_import_message("url must be a string"), do: gettext("url must be a string")
  defp pricing_import_message("url must be an absolute HTTP or HTTPS URL"), do: gettext("url must be an absolute HTTP or HTTPS URL")
  defp pricing_import_message("pricing catalog transport failed"), do: gettext("pricing catalog transport failed")
  defp pricing_import_message("pricing catalog is not valid JSON"), do: gettext("pricing catalog is not valid JSON")
  defp pricing_import_message("pricing catalog is incompatible with the supported format"), do: gettext("pricing catalog is incompatible with the supported format")
  defp pricing_import_message("concurrent pricing snapshot conflicts with candidate semantics"), do: gettext("concurrent pricing snapshot conflicts with candidate semantics")
  defp pricing_import_message("fast and priority pricing aliases conflict"), do: gettext("fast and priority pricing aliases conflict")
  defp pricing_import_message("pricing catalog returned HTTP " <> status), do: gettext("pricing catalog returned HTTP %{status}", status: status)
  defp pricing_import_message(message), do: message

  defp system_tabs(development_helpers_available?) do
    ids = if development_helpers_available?, do: @base_system_tabs ++ [@development_tab], else: @base_system_tabs
    Enum.map(ids, &%{id: &1, label: system_tab_label(&1)})
  end

  defp system_tab_label("smtp"), do: gettext("SMTP")
  defp system_tab_label("mcp"), do: gettext("MCP")
  defp system_tab_label("metrics"), do: gettext("Metrics")
  defp system_tab_label("gateway"), do: gettext("Gateway")
  defp system_tab_label("firewall"), do: gettext("Firewall")
  defp system_tab_label("development"), do: gettext("Development")

  defp normalize_tab(tab, development_helpers_available?) do
    if Enum.any?(system_tabs(development_helpers_available?), &(&1.id == tab)) do
      tab
    else
      @default_tab
    end
  end

  defp smtp_changeset_status(_changeset) do
    %{tone: :error, message: gettext("SMTP settings need correction before testing.")}
  end

  defp smtp_error_message(%{code: :smtp_disabled}), do: gettext("SMTP is disabled")
  defp smtp_error_message(%{code: :smtp_test_email_recipient_missing}), do: gettext("Signed-in operator email is required for SMTP test email")
  defp smtp_error_message(%{code: :smtp_test_email_timeout}), do: gettext("SMTP test email timed out")
  defp smtp_error_message(%{code: :smtp_test_email_auth_failed}), do: gettext("SMTP authentication failed")
  defp smtp_error_message(%{code: :smtp_test_email_auth_unavailable}), do: gettext("SMTP server does not support the requested authentication flow")
  defp smtp_error_message(%{code: :smtp_test_email_tls_unavailable}), do: gettext("SMTP server does not support the requested TLS mode")
  defp smtp_error_message(%{code: :smtp_test_email_tls_failed}), do: gettext("SMTP TLS handshake failed; verify SSL/TLS mode and certificate settings")
  defp smtp_error_message(%{code: :smtp_test_email_rejected}), do: gettext("SMTP server rejected the test email")
  defp smtp_error_message(%{code: :smtp_test_email_unexpected_response}), do: gettext("SMTP server returned an unexpected response")
  defp smtp_error_message(%{code: :smtp_test_email_connection_failed}), do: gettext("SMTP connection failed")
  defp smtp_error_message(%{code: :smtp_test_email_temporary_failure}), do: gettext("SMTP server temporarily rejected the test email")
  defp smtp_error_message(%{code: :smtp_test_email_failed}), do: gettext("SMTP test email failed")
  defp smtp_error_message(%{code: :smtp_password_unavailable}), do: gettext("SMTP password is unavailable")

  defp smtp_error_message(%{code: code, message: message}) when code in [:invalid_mailer_config, :smtp_test_email_invalid_config],
    do: smtp_configuration_message(message)

  defp smtp_error_message(%{code: code}) when code in [:app_secret_key_missing, :app_secret_key_invalid, :app_secret_decryption_failed, :app_secret_invalid_ciphertext],
    do: gettext("instance setting secret operation failed")

  defp smtp_error_message(_error), do: gettext("SMTP test email failed")

  defp smtp_configuration_message("SMTP relay host is required"), do: gettext("SMTP relay host is required")
  defp smtp_configuration_message("SMTP port must be a positive integer"), do: gettext("SMTP port must be a positive integer")
  defp smtp_configuration_message("SMTP username and password are both required for authentication"), do: gettext("SMTP username and password are both required for authentication")
  defp smtp_configuration_message("SMTP from address must be configured"), do: gettext("SMTP from address must be configured")
  defp smtp_configuration_message("SMTP password must be present when SMTP username is set"), do: gettext("SMTP password must be present when SMTP username is set")
  defp smtp_configuration_message("SMTP username must be present when SMTP password is set"), do: gettext("SMTP username must be present when SMTP password is set")
  defp smtp_configuration_message("SMTP host must be present when SMTP is enabled"), do: gettext("SMTP host must be present when SMTP is enabled")
  defp smtp_configuration_message("SMTP from address must be present when SMTP is enabled"), do: gettext("SMTP from address must be present when SMTP is enabled")
  defp smtp_configuration_message("SMTP host must be a string"), do: gettext("SMTP host must be a string")
  defp smtp_configuration_message("SMTP from address must be a string"), do: gettext("SMTP from address must be a string")
  defp smtp_configuration_message("SMTP username must be a string"), do: gettext("SMTP username must be a string")
  defp smtp_configuration_message("SMTP password must be a string"), do: gettext("SMTP password must be a string")
  defp smtp_configuration_message("SMTP retries must be a non-negative integer"), do: gettext("SMTP retries must be a non-negative integer")
  defp smtp_configuration_message("SMTP SSL must be true or false"), do: gettext("SMTP SSL must be true or false")
  defp smtp_configuration_message("SMTP TLS must be one of always, if_available, or never"), do: gettext("SMTP TLS must be one of always, if_available, or never")
  defp smtp_configuration_message(_message), do: gettext("SMTP settings need correction before testing.")

  defp operator_email_for_status(%{user: %{email: email}}) when is_binary(email) do
    case String.trim(email) do
      "" -> gettext("the signed-in operator")
      trimmed -> trimmed
    end
  end

  defp operator_email_for_status(_scope), do: gettext("the signed-in operator")

  defp stale_changeset?(changeset), do: Keyword.has_key?(changeset.errors, :lock_version)
end
