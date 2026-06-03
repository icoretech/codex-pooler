defmodule CodexPoolerWeb.Admin.SystemLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.{Catalog, InstanceSettings, MCP, Pools}
  alias CodexPooler.Dev.Seeds, as: DevSeeds
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.SystemPageComponents
  alias CodexPoolerWeb.Admin.SystemSettingsForm
  alias CodexPoolerWeb.DateTimeDisplay

  @default_tab "smtp"
  @base_system_tabs [
    %{
      id: "smtp",
      label: "SMTP"
    },
    %{
      id: "mcp",
      label: "MCP"
    },
    %{
      id: "metrics",
      label: "Metrics"
    },
    %{
      id: "gateway",
      label: "Gateway"
    }
  ]
  @development_tab %{id: "development", label: "Development"}
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
         page_title: "System",
         owner_authorized?: true,
         selected_tab: @default_tab,
         system_tabs: system_tabs(development_helpers_available?),
         settings: settings,
         development_helpers_available?: development_helpers_available?,
         mcp_key_count: MCP.count_operator_tokens(),
         form_params: form_params,
         group_snapshots: SystemSettingsForm.group_snapshots(form_params),
         card_statuses: SystemSettingsForm.initial_card_statuses(),
         development_action_status: nil,
         smtp_test_status: nil
       )
       |> assign_forms()}
    else
      {:ok, assign(socket, page_title: "System", owner_authorized?: false)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns.owner_authorized? do
      development_helpers_available? = CodexPoolerWeb.DevFeatures.enabled?()

      {:noreply,
       socket
       |> assign(:development_helpers_available?, development_helpers_available?)
       |> assign(:system_tabs, system_tabs(development_helpers_available?))
       |> assign(:mcp_key_count, MCP.count_operator_tokens())
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
             socket.assigns.current_scope
           ) do
        {:ok, %{code: :smtp_test_email_sent}} ->
          %{
            tone: :success,
            message:
              "Test email sent to #{operator_email_for_status(socket.assigns.current_scope)}"
          }

        {:error, %Ecto.Changeset{} = changeset} ->
          smtp_changeset_status(changeset)

        {:error, %{message: message}} ->
          %{tone: :error, message: message}

        {:error, _reason} ->
          %{tone: :error, message: "SMTP test email failed"}
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
           |> put_flash(:info, "Sample data imported")}

        {:error, message} ->
          {:noreply,
           socket
           |> assign(:development_action_status, %{tone: :error, message: message})
           |> put_flash(:error, "Sample data could not be imported")}
      end
    else
      {:noreply, put_flash(socket, :error, "Development helpers are not available")}
    end
  end

  def handle_event("import_pricing_catalog", _params, socket) do
    if socket.assigns.development_helpers_available? do
      source_url = socket.assigns.settings.catalog.openai_pricing_url

      case Catalog.import_openai_pricing_from_url(source_url) do
        {:ok, result} ->
          message =
            "Pricing imported: #{result.inserted} inserted, #{result.skipped} skipped, #{result.total} total."

          {:noreply,
           socket
           |> assign(:development_action_status, %{tone: :success, message: message})
           |> put_flash(:info, "Pricing catalog imported")}

        {:error, reason} ->
          message = pricing_import_error_message(reason)

          {:noreply,
           socket
           |> assign(:development_action_status, %{tone: :error, message: message})
           |> put_flash(:error, "Pricing catalog could not be imported")}
      end
    else
      {:noreply, put_flash(socket, :error, "Development helpers are not available")}
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
      |> put_card_status(group, %{tone: :error, message: "Reload this card and retry."})
      |> put_group_form(group, changeset)

    if autosave? do
      {:noreply, socket}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "#{card_title(group)} was updated by another operator. Reload and retry."
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
      active_nav={:system}
      alert_notification_center={@alert_notification_center}
    >
      <section id="admin-system-live" class="grid min-w-0 gap-6">
        <AdminComponents.page_header
          id="system-page-header"
          title="System"
          description="Review and adjust instance-wide runtime settings without exposing stored credentials."
        />

        <AdminComponents.empty_state
          :if={!@owner_authorized?}
          id="admin-system-owner-denied"
          title="System settings require owner access"
          description="Only instance owners can inspect or change global system settings."
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
            datetime_preferences={@datetime_preferences}
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
    put_flash(socket, :error, "Only instance owners can manage system settings")
  end

  defp put_group_form(socket, group, %Ecto.Changeset{} = changeset) do
    assign(
      socket,
      :forms,
      Map.put(socket.assigns.forms, group, to_form(changeset, as: :instance_settings))
    )
  end

  defp save_group_settings(socket, latest_settings, form_params, group, opts \\ []) do
    autosave? = Keyword.get(opts, :autosave?, false)

    params =
      latest_settings
      |> SystemSettingsForm.group_only_params(form_params, group)
      |> Map.put(:current_scope, socket.assigns.current_scope)

    case InstanceSettings.update(latest_settings, params) do
      {:ok, settings} ->
        saved_params = SystemSettingsForm.params_from_settings(settings)

        form_params =
          SystemSettingsForm.refresh_saved_group_params(form_params, saved_params, group)

        group_snapshots =
          SystemSettingsForm.refresh_group_snapshots(socket.assigns, saved_params, group)

        card_statuses =
          SystemSettingsForm.saved_card_statuses(form_params, group_snapshots, group)

        {:noreply,
         socket
         |> assign(
           settings: settings,
           development_helpers_available?: CodexPoolerWeb.DevFeatures.enabled?(),
           form_params: form_params,
           group_snapshots: group_snapshots,
           card_statuses: card_statuses,
           development_action_status: nil,
           smtp_test_status: nil
         )
         |> assign_forms()
         |> maybe_put_save_feedback(group, autosave?)}

      {:error, %Ecto.Changeset{} = changeset} ->
        status =
          if stale_changeset?(changeset),
            do: %{tone: :error, message: "Reload this card and retry."},
            else: %{tone: :error, message: "Review errors before saving this card."}

        socket =
          if stale_changeset?(changeset) do
            put_flash(
              socket,
              :error,
              "#{card_title(group)} was updated by another operator. Reload and retry."
            )
          else
            put_flash(socket, :error, "#{card_title(group)} could not be saved")
          end

        {:noreply,
         socket
         |> assign(settings: latest_settings, form_params: form_params, smtp_test_status: nil)
         |> put_card_status(group, status)
         |> put_group_form(group, Map.put(changeset, :action, :validate))}
    end
  end

  defp put_card_status(socket, group, status) do
    assign(socket, :card_statuses, Map.put(socket.assigns.card_statuses, group, status))
  end

  defp card_title("gateway"), do: "Gateway controls"
  defp card_title("ingress"), do: "Runtime ingress"
  defp card_title("files"), do: "File bridge limits"
  defp card_title("transcription"), do: "Audio upload limit"
  defp card_title("operator"), do: "Public operator app URL"
  defp card_title("catalog"), do: "Pricing catalog source"
  defp card_title("development"), do: "Development helpers"
  defp card_title("mcp"), do: "MCP service"
  defp card_title("metrics"), do: "Metrics bearer token"
  defp card_title("smtp"), do: "SMTP delivery"

  defp maybe_put_save_feedback(socket, group, true) do
    dismiss_ref = make_ref()
    Process.send_after(self(), {:clear_card_status, group, dismiss_ref}, 2_500)

    put_card_status(socket, group, %{tone: :success, message: "Saved", dismiss_ref: dismiss_ref})
  end

  defp maybe_put_save_feedback(socket, group, false) do
    put_flash(socket, :info, "#{card_title(group)} saved")
  end

  defp import_sample_data do
    {:ok, DevSeeds.full()}
  rescue
    error in RuntimeError -> {:error, Exception.message(error)}
  end

  defp sample_data_import_status(result) do
    %{
      tone: :success,
      message:
        "Sample data imported: #{length(result.pools)} pools, #{length(result.api_keys)} API keys, #{length(result.upstream_identities)} upstream accounts, #{length(result.assignments)} assignments, #{length(result.models)} models, #{length(result.quota_windows)} quota windows, #{length(result.request_logs)} request logs, #{length(result.invites)} invites, #{length(result.audit_events)} audit events, and #{length(result.jobs)} jobs."
    }
  end

  defp pricing_import_error_message(%{code: code, message: message}) do
    "Pricing import failed: #{code} #{message}"
  end

  defp system_tabs(true), do: @base_system_tabs ++ [@development_tab]
  defp system_tabs(false), do: @base_system_tabs

  defp normalize_tab(tab, development_helpers_available?) do
    if Enum.any?(system_tabs(development_helpers_available?), &(&1.id == tab)) do
      tab
    else
      @default_tab
    end
  end

  defp smtp_changeset_status(_changeset) do
    %{tone: :error, message: "SMTP settings need correction before testing."}
  end

  defp operator_email_for_status(%{user: %{email: email}}) when is_binary(email) do
    case String.trim(email) do
      "" -> "the signed-in operator"
      trimmed -> trimmed
    end
  end

  defp operator_email_for_status(_scope), do: "the signed-in operator"

  defp stale_changeset?(changeset), do: Keyword.has_key?(changeset.errors, :lock_version)
end
