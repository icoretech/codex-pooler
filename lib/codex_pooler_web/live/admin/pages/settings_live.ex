defmodule CodexPoolerWeb.Admin.SettingsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.SettingsPageComponents
  alias CodexPoolerWeb.DateTimeDisplay
  alias CodexPoolerWeb.UserAuth

  @default_tab "appearance"
  @settings_tabs [
    %{id: "appearance", label: "Appearance", description: "Theme and display defaults"},
    %{id: "account", label: "Account", description: "Identity details"},
    %{id: "security", label: "Security", description: "Password and second factor"}
  ]
  @tab_ids Enum.map(@settings_tabs, & &1.id)

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_scope.user

    socket =
      assign(socket,
        page_title: "Settings",
        selected_tab: @default_tab,
        settings_tabs: @settings_tabs,
        current_user_token: session["user_token"],
        account_form: account_form(user),
        datetime_format_options: DateTimeDisplay.format_options(),
        timezone_options: DateTimeDisplay.timezone_options(),
        password_form: password_form(),
        totp_enabled?: Accounts.totp_enabled?(user),
        totp_setup: nil,
        mcp_created_secret: nil,
        mcp_delete_key: nil,
        mcp_delete_form: mcp_delete_form(nil)
      )

    {:ok,
     socket
     |> assign_datetime_preferences()
     |> assign_browser_sessions()
     |> assign_mcp_panel()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :selected_tab, normalize_tab(params["tab"]))}
  end

  @impl true
  def handle_event("save_account", %{"user" => user_params}, socket) do
    case Accounts.update_current_operator_profile(
           socket.assigns.current_scope.user,
           user_params,
           %{}
         ) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_scope, Scope.for_user(user))
         |> assign(:account_form, account_form(user))
         |> assign_datetime_preferences()
         |> assign_mcp_panel()
         |> put_flash(:info, "Account settings updated")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :account_form, to_form(changeset, as: :user))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Account settings could not be updated")}
    end
  end

  def handle_event("toggle_operator_mcp", %{"mcp_account" => params}, socket) do
    enabled? = truthy_param?(params["enabled"])

    case MCP.set_operator_mcp_enabled(socket.assigns.current_scope.user, enabled?) do
      {:ok, _settings} ->
        message =
          if enabled?, do: "MCP enabled for this operator", else: "MCP disabled for this operator"

        {:noreply,
         socket
         |> assign_mcp_panel()
         |> put_flash(:info, message)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "MCP account setting could not be updated")}
    end
  end

  def handle_event("create_mcp_key", %{"mcp_key" => params}, socket) do
    case MCP.create_operator_token(socket.assigns.current_scope.user, params) do
      {:ok, %{key: key, raw_token: raw_token}} ->
        {:noreply,
         socket
         |> assign_mcp_panel()
         |> assign(:mcp_created_secret, %{key: key, raw_token: raw_token})
         |> put_flash(:info, "MCP key created. Copy the token now.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :mcp_key_form, to_form(changeset, as: :mcp_key))}
    end
  end

  def handle_event("close_mcp_created_token", _params, socket) do
    {:noreply, assign(socket, :mcp_created_secret, nil)}
  end

  def handle_event("rename_mcp_key", %{"mcp_key" => %{"id" => key_id} = params}, socket) do
    case MCP.update_operator_token(socket.assigns.current_scope.user, key_id, params) do
      {:ok, _key} ->
        {:noreply,
         socket
         |> assign_mcp_panel()
         |> put_flash(:info, "MCP key label updated")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "MCP key label could not be updated")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign_mcp_panel()
         |> put_flash(:error, "MCP key was not found")}
    end
  end

  def handle_event("open_delete_mcp_key", %{"id" => key_id}, socket) do
    case MCP.get_operator_token(socket.assigns.current_scope.user, key_id) do
      {:ok, key} ->
        {:noreply,
         socket
         |> assign(:mcp_delete_key, key)
         |> assign(:mcp_delete_form, mcp_delete_form(key))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign_mcp_panel()
         |> put_flash(:error, "MCP key was not found")}
    end
  end

  def handle_event("cancel_delete_mcp_key", _params, socket) do
    {:noreply,
     socket |> assign(:mcp_delete_key, nil) |> assign(:mcp_delete_form, mcp_delete_form(nil))}
  end

  def handle_event("confirm_delete_mcp_key", %{"mcp_key_delete" => %{"id" => key_id}}, socket) do
    case MCP.delete_operator_token(socket.assigns.current_scope.user, key_id) do
      {:ok, _key} ->
        {:noreply,
         socket
         |> assign(:mcp_delete_key, nil)
         |> assign(:mcp_delete_form, mcp_delete_form(nil))
         |> assign_mcp_panel()
         |> put_flash(:info, "MCP key deleted")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:mcp_delete_key, nil)
         |> assign(:mcp_delete_form, mcp_delete_form(nil))
         |> assign_mcp_panel()
         |> put_flash(:error, "MCP key was not found")}
    end
  end

  def handle_event("enable_totp", _params, socket) do
    if socket.assigns.totp_enabled? do
      {:noreply, put_flash(socket, :info, "TOTP is already enabled")}
    else
      case Accounts.enable_totp_for_user(socket.assigns.current_scope.user) do
        {:ok, setup} ->
          {:noreply,
           socket
           |> assign(totp_enabled?: true, totp_setup: setup)
           |> put_flash(:info, "TOTP enabled. Save the setup details now.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "TOTP setup failed")}
      end
    end
  end

  def handle_event("save_password", %{"user" => user_params}, socket) do
    with :ok <- validate_password_confirmation(user_params),
         {:ok, user} <-
           Accounts.change_current_user_password(
             socket.assigns.current_scope.user,
             user_params,
             %{},
             socket.assigns.current_user_token
           ) do
      UserAuth.disconnect_user_sessions(user.id,
        except_live_socket_id:
          UserAuth.live_socket_id_for_token(socket.assigns.current_user_token)
      )

      {:noreply,
       socket
       |> assign(:current_scope, Scope.for_user(user))
       |> assign(:password_form, password_form())
       |> assign_browser_sessions()
       |> put_flash(:info, "Password updated")}
    else
      {:error, :password_confirmation_mismatch} ->
        {:noreply,
         socket
         |> assign(:password_form, password_form())
         |> put_flash(:error, "Passwords do not match.")}

      {:error, :invalid_current_password} ->
        {:noreply,
         socket
         |> assign(:password_form, password_form())
         |> put_flash(:error, "Current password is incorrect.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:password_form, password_form())
         |> put_flash(:error, changeset_error(changeset))}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:password_form, password_form())
         |> put_flash(:error, "Password could not be updated")}
    end
  end

  def handle_event("logout_other_sessions", _params, socket) do
    user = socket.assigns.current_scope.user
    current_token = socket.assigns.current_user_token

    case Accounts.revoke_other_user_sessions(user, current_token, %{}) do
      {:ok, count} when count > 0 ->
        UserAuth.disconnect_user_sessions(user.id,
          except_live_socket_id: UserAuth.live_socket_id_for_token(current_token)
        )

        {:noreply,
         socket
         |> assign_browser_sessions()
         |> put_flash(:info, "Other sessions signed out")}

      {:ok, _count} ->
        {:noreply,
         socket
         |> assign_browser_sessions()
         |> put_flash(:info, "No other sessions to sign out")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Other sessions could not be signed out")}
    end
  end

  def handle_event("logout_session", %{"id" => session_id}, socket) do
    user = socket.assigns.current_scope.user
    current_token = socket.assigns.current_user_token

    case Accounts.revoke_user_session(user, session_id, current_token, %{}) do
      {:ok, %{current?: true, revoked_count: count}} when count > 0 ->
        UserAuth.disconnect_user_session(user.id, session_id)

        {:noreply,
         socket
         |> put_flash(:info, "Browser session signed out")
         |> redirect(to: ~p"/login")}

      {:ok, %{current?: false, revoked_count: count}} when count > 0 ->
        UserAuth.disconnect_user_session(user.id, session_id)

        {:noreply,
         socket
         |> assign_browser_sessions()
         |> put_flash(:info, "Browser session signed out")}

      {:ok, _result} ->
        {:noreply,
         socket
         |> assign_browser_sessions()
         |> put_flash(:info, "Browser session was already signed out")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Browser session could not be signed out")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:settings}
      alert_notification_center={@alert_notification_center}
    >
      <section id="admin-settings-live" class="grid min-w-0 gap-6">
        <AdminComponents.page_header
          id="settings-page-header"
          title="Settings"
          description="Manage this browser session, your operator profile, and account security."
        />

        <section id="settings-workspace" class="grid gap-4">
          <SettingsPageComponents.tab_picker tabs={@settings_tabs} selected_tab={@selected_tab} />

          <SettingsPageComponents.appearance_panel :if={@selected_tab == "appearance"} />

          <SettingsPageComponents.account_panel
            :if={@selected_tab == "account"}
            account_form={@account_form}
            datetime_preferences={@datetime_preferences}
            datetime_format_options={@datetime_format_options}
            timezone_options={@timezone_options}
            mcp_global_enabled?={@mcp_global_enabled?}
            mcp_account_enabled?={@mcp_account_enabled?}
            mcp_toggle_form={@mcp_toggle_form}
            mcp_key_form={@mcp_key_form}
            mcp_keys={@mcp_keys}
            mcp_rename_forms={@mcp_rename_forms}
            mcp_created_secret={@mcp_created_secret}
            mcp_delete_key={@mcp_delete_key}
            mcp_delete_form={@mcp_delete_form}
          />

          <SettingsPageComponents.security_panel
            :if={@selected_tab == "security"}
            current_scope={@current_scope}
            datetime_preferences={@datetime_preferences}
            totp_enabled?={@totp_enabled?}
            totp_setup={@totp_setup}
            password_form={@password_form}
            browser_sessions={@browser_sessions}
          />
        </section>
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp account_form(user), do: to_form(Accounts.change_operator(user), as: :user)
  defp password_form, do: to_form(%{}, as: :user)
  defp mcp_key_form, do: to_form(%{"label" => ""}, as: :mcp_key)
  defp mcp_delete_form(nil), do: to_form(%{"id" => ""}, as: :mcp_key_delete)
  defp mcp_delete_form(key), do: to_form(%{"id" => key.id}, as: :mcp_key_delete)

  defp mcp_toggle_form(enabled?) do
    to_form(%{"enabled" => enabled?}, as: :mcp_account)
  end

  defp mcp_rename_forms(keys) do
    Map.new(keys, fn key ->
      {key.id, to_form(%{"id" => key.id, "label" => key.label}, as: :mcp_key)}
    end)
  end

  defp assign_datetime_preferences(socket) do
    assign(
      socket,
      :datetime_preferences,
      DateTimeDisplay.preferences_for_user(socket.assigns.current_scope.user)
    )
  end

  defp assign_mcp_panel(socket) do
    user = socket.assigns.current_scope.user
    {:ok, keys} = MCP.list_operator_tokens(user)
    account_enabled? = MCP.operator_mcp_enabled?(user)

    assign(socket,
      mcp_global_enabled?: InstanceSettings.current().mcp.enabled,
      mcp_account_enabled?: account_enabled?,
      mcp_toggle_form: mcp_toggle_form(account_enabled?),
      mcp_key_form: mcp_key_form(),
      mcp_keys: keys,
      mcp_rename_forms: mcp_rename_forms(keys)
    )
  end

  defp truthy_param?(value) when value in [true, "true", "on", "1", 1], do: true
  defp truthy_param?(_value), do: false

  defp assign_browser_sessions(socket) do
    assign(
      socket,
      :browser_sessions,
      Accounts.list_user_sessions(
        socket.assigns.current_scope.user,
        socket.assigns.current_user_token
      )
    )
  end

  defp normalize_tab(tab) when tab in @tab_ids, do: tab
  defp normalize_tab(_tab), do: @default_tab

  defp validate_password_confirmation(%{
         "new_password" => password,
         "new_password_confirmation" => password
       })
       when password not in [nil, ""] do
    :ok
  end

  defp validate_password_confirmation(%{
         "new_password" => password,
         "new_password_confirmation" => confirmation
       })
       when password != confirmation or confirmation in [nil, ""] do
    {:error, :password_confirmation_mismatch}
  end

  defp validate_password_confirmation(_params), do: {:error, :password_confirmation_mismatch}

  defp changeset_error(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} ->
      "#{Phoenix.Naming.humanize(field)} #{message}"
    end)
    |> List.first()
    |> Kernel.||("Password change failed.")
  end
end
