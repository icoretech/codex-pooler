defmodule CodexPoolerWeb.Admin.OperatorsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.User
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.OperatorComponents
  alias CodexPoolerWeb.Admin.OperatorComponents.Dialogs
  alias CodexPoolerWeb.Admin.OperatorForm
  alias CodexPoolerWeb.DateTimeDisplay

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Operators",
       operator_filters: OperatorForm.filter(),
       operator_filter_form: OperatorForm.filter_form(),
       subscribed_operator_events?: false,
       creating_operator: false,
       create_form: OperatorForm.create_form(),
       editing_operator: nil,
       edit_form: nil,
       pool_options: [],
       pool_options_stale?: false,
       resetting_operator: nil,
       reset_operation: nil,
       reset_form: OperatorForm.reset_form(),
       password_dialog_receipt: nil,
       temporary_password_receipt: nil
     )
     |> maybe_subscribe_operator_events()
     |> assign_operator_management()
     |> operator_management_socket()}
  end

  @impl true
  def handle_event("create_operator", %{"operator" => operator_params}, socket) do
    attrs = OperatorForm.create_attrs(operator_params)

    case Accounts.create_operator(socket.assigns.current_scope, attrs, operator_metadata()) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Operator created")
         |> assign(:creating_operator, true)
         |> assign(:create_form, OperatorForm.create_form())
         |> clear_editing()
         |> clear_resetting()
         |> assign(
           :temporary_password_receipt,
           OperatorForm.temporary_password_receipt(result, "Operator created")
         )
         |> reload_operators()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(changeset))
         |> assign(:creating_operator, true)
         |> assign(:create_form, OperatorForm.create_form_for_changeset(changeset))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(:creating_operator, true)}
    end
  end

  def handle_event("open_create_operator", _params, socket) do
    if operator_management_denied?(socket) do
      {:noreply, put_flash(socket, :error, error_message(:operator_management_denied))}
    else
      {:noreply,
       socket
       |> assign(:creating_operator, true)
       |> assign(:create_form, OperatorForm.create_form())
       |> clear_editing()
       |> clear_resetting()
       |> assign(:temporary_password_receipt, nil)}
    end
  end

  def handle_event("cancel_create_operator", _params, socket) do
    {:noreply, close_create_dialog(socket)}
  end

  def handle_event("filter_operators", %{"operator_filters" => filter_params}, socket) do
    filters = OperatorForm.filter(filter_params)

    {:noreply,
     socket
     |> assign(:operator_filters, filters)
     |> assign(:operator_filter_form, OperatorForm.filter_form(filters))
     |> reload_operators()}
  end

  def handle_event("clear_operator_query_filter", _params, socket) do
    filters = OperatorForm.filter(Map.put(socket.assigns.operator_filters, "query", ""))

    {:noreply,
     socket
     |> assign(:operator_filters, filters)
     |> assign(:operator_filter_form, OperatorForm.filter_form(filters))
     |> reload_operators()}
  end

  def handle_event("select_operator_status_filter", %{"status" => status}, socket) do
    filters = OperatorForm.filter(Map.put(socket.assigns.operator_filters, "status", status))

    {:noreply,
     socket
     |> assign(:operator_filters, filters)
     |> assign(:operator_filter_form, OperatorForm.filter_form(filters))
     |> reload_operators()}
  end

  def handle_event("edit_operator", %{"id" => operator_id}, socket) do
    case find_operator(socket, operator_id) do
      %User{} = operator ->
        {:noreply,
         socket
         |> close_create_dialog()
         |> assign(:editing_operator, operator)
         |> assign(:edit_form, OperatorForm.edit_form(operator))
         |> clear_resetting()
         |> assign(:temporary_password_receipt, nil)}

      nil ->
        {:noreply, put_flash(socket, :error, "Operator was not found")}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, clear_editing(socket)}
  end

  def handle_event("save_operator", %{"operator_edit" => operator_params}, socket) do
    operator_id = operator_params["id"]

    case Accounts.update_operator(
           socket.assigns.current_scope,
           operator_id,
           OperatorForm.edit_attrs(operator_params),
           operator_metadata()
         ) do
      {:ok, _operator} ->
        {:noreply,
         socket
         |> put_flash(:info, "Operator updated")
         |> clear_editing()
         |> assign(:temporary_password_receipt, nil)
         |> reload_operators()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(changeset))
         |> assign(:edit_form, OperatorForm.edit_form_for_changeset(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("deactivate_operator", %{"id" => operator_id}, socket) do
    case reject_self_operator_action(socket, operator_id) do
      :ok -> deactivate_operator(socket, operator_id)
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("reactivate_operator", %{"id" => operator_id}, socket) do
    prepare_temporary_password_form(socket, operator_id, :reactivate)
  end

  def handle_event("reset_operator_password", %{"id" => operator_id}, socket) do
    case reject_self_operator_action(socket, operator_id) do
      :ok -> prepare_temporary_password_form(socket, operator_id, :reset)
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("cancel_reset", _params, socket) do
    {:noreply, close_password_dialog(socket)}
  end

  def handle_event("save_temporary_password", %{"operator_reset" => operator_params}, socket) do
    operator_id = operator_params["id"]
    operation = OperatorForm.reset_operation(operator_params["operation"])

    operation_fun =
      case operation do
        :reactivate -> &Accounts.reactivate_operator/4
        :reset -> &Accounts.reset_operator_password/4
      end

    case operation_fun.(
           socket.assigns.current_scope,
           operator_id,
           OperatorForm.password_attrs(operator_params),
           operator_metadata()
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, OperatorForm.temporary_password_success(operation))
         |> clear_editing()
         |> assign(:resetting_operator, nil)
         |> assign(:reset_operation, nil)
         |> assign(:reset_form, OperatorForm.reset_form())
         |> assign(
           :password_dialog_receipt,
           OperatorForm.temporary_password_receipt(
             result,
             OperatorForm.temporary_password_success(operation)
           )
         )
         |> assign(:temporary_password_receipt, nil)
         |> reload_operators()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(changeset))
         |> assign(:reset_form, OperatorForm.reset_form_for_changeset(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp deactivate_operator(socket, operator_id) do
    case Accounts.deactivate_operator(
           socket.assigns.current_scope,
           operator_id,
           %{},
           operator_metadata()
         ) do
      {:ok, _operator} ->
        {:noreply,
         socket
         |> put_flash(:info, "Operator deactivated")
         |> clear_editing()
         |> clear_resetting()
         |> assign(:temporary_password_receipt, nil)
         |> reload_operators()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  @impl true
  def handle_info({:email, _email}, socket) do
    {:noreply, socket}
  end

  def handle_info({CodexPooler.Accounts.OperatorEvents, _event}, socket) do
    {:noreply, reload_operators(socket)}
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
      active_nav={:operators}
      alert_notification_center={@alert_notification_center}
    >
      <section id="admin-operators-live" class="grid min-w-0 gap-6">
        <AdminComponents.page_header
          id="operators-page-header"
          title="Operators"
          description="Invite and manage the people who can access this admin area, reset passwords, and deactivate accounts."
        >
          <:actions>
            <AdminComponents.action_button
              :if={!@operator_management_denied?}
              id="operator-page-create-action"
              icon="hero-user-plus"
              label="Create operator"
              phx-click="open_create_operator"
              size={:md}
              variant={:primary}
            />
          </:actions>
        </AdminComponents.page_header>

        <div
          :if={@operator_management_denied?}
          id="operator-management-denied"
          class="alert alert-warning items-start"
        >
          <.icon name="hero-lock-closed" class="size-5" />
          <div class="grid gap-1">
            <p class="font-semibold">Only instance owners can manage operators.</p>
            <p class="text-sm">
              Ask an instance owner to create, update, deactivate, or reset local operator accounts.
            </p>
          </div>
        </div>

        <Dialogs.operator_create_dialog
          :if={!@operator_management_denied?}
          creating_operator={@creating_operator}
          create_form={@create_form}
          temporary_password_receipt={@temporary_password_receipt}
          pool_options={@pool_options}
        />
        <Dialogs.operator_edit_dialog
          :if={!@operator_management_denied?}
          editing_operator={@editing_operator}
          edit_form={@edit_form}
          pool_options={@pool_options}
        />
        <Dialogs.operator_password_dialog
          :if={!@operator_management_denied?}
          resetting_operator={@resetting_operator}
          password_dialog_receipt={@password_dialog_receipt}
          reset_operation={@reset_operation}
          reset_form={@reset_form}
        />
        <OperatorComponents.operators_table
          :if={!@operator_management_denied?}
          filter_form={@operator_filter_form}
          operators={@streams.operators}
          current_scope={@current_scope}
          active_operator_count={@active_operator_count}
          datetime_preferences={@datetime_preferences}
        />
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp reload_operators(socket) do
    case assign_operator_management(socket) do
      {:ok, socket} ->
        socket

      {:error, :operator_management_denied, socket} ->
        put_flash(socket, :error, error_message(:operator_management_denied))
    end
  end

  defp operator_management_socket({:ok, socket}), do: socket
  defp operator_management_socket({:error, :operator_management_denied, socket}), do: socket

  defp maybe_subscribe_operator_events(socket) do
    if connected?(socket) and !socket.assigns.subscribed_operator_events? do
      :ok = Accounts.subscribe_operator_updates()
      assign(socket, :subscribed_operator_events?, true)
    else
      socket
    end
  end

  defp prepare_temporary_password_form(socket, operator_id, operation) do
    case find_operator(socket, operator_id) do
      %User{} = operator ->
        {:noreply,
         socket
         |> close_create_dialog()
         |> assign(:resetting_operator, operator)
         |> assign(:reset_operation, operation)
         |> assign(:reset_form, OperatorForm.reset_form(operator.id, operation))
         |> clear_editing()
         |> assign(:password_dialog_receipt, nil)
         |> assign(:temporary_password_receipt, nil)}

      nil ->
        {:noreply, put_flash(socket, :error, "Operator was not found")}
    end
  end

  defp reject_self_operator_action(socket, operator_id) do
    if self_operator_id?(operator_id, socket.assigns.current_scope) do
      {:error, "Use account settings to change your own password."}
    else
      :ok
    end
  end

  defp clear_editing(socket) do
    socket
    |> assign(editing_operator: nil, edit_form: nil)
    |> flush_stale_pool_options()
  end

  defp close_create_dialog(socket) do
    socket
    |> assign(
      creating_operator: false,
      create_form: OperatorForm.create_form(),
      temporary_password_receipt: nil
    )
    |> flush_stale_pool_options()
  end

  # Operator events must not rebuild :pool_options while a create/edit dialog
  # is open: the pool checkbox group is submit-only, so a re-render reverts
  # un-submitted ticks. Mark the options stale and refetch on dialog close.
  defp assign_pool_options(socket) do
    if socket.assigns.creating_operator or socket.assigns.editing_operator do
      assign(socket, :pool_options_stale?, true)
    else
      assign(socket,
        pool_options: management_pool_options(socket.assigns.current_scope),
        pool_options_stale?: false
      )
    end
  end

  defp flush_stale_pool_options(socket) do
    if socket.assigns.pool_options_stale? do
      assign(socket,
        pool_options: management_pool_options(socket.assigns.current_scope),
        pool_options_stale?: false
      )
    else
      socket
    end
  end

  defp clear_resetting(socket) do
    assign(socket,
      resetting_operator: nil,
      reset_operation: nil,
      reset_form: OperatorForm.reset_form(),
      password_dialog_receipt: nil
    )
  end

  defp close_password_dialog(socket), do: clear_resetting(socket)

  defp find_operator(socket, operator_id) do
    socket.assigns.current_scope
    |> Accounts.list_operators_for_management()
    |> case do
      {:ok, operators} -> Enum.find(operators, &(&1.id == operator_id))
      {:error, :operator_management_denied} -> nil
    end
  end

  defp assign_operator_management(socket) do
    case Accounts.list_operators_for_management(socket.assigns.current_scope) do
      {:ok, operators} ->
        filtered_operators =
          OperatorForm.filter_operators(operators, socket.assigns.operator_filters)

        socket =
          socket
          |> assign(:operator_management_denied?, false)
          |> assign_pool_options()
          |> assign(:operator_count, length(operators))
          |> assign(:active_operator_count, OperatorForm.active_operator_count(operators))
          |> stream(:operators, filtered_operators, reset: true, dom_id: &"operator-row-#{&1.id}")

        {:ok, socket}

      {:error, :operator_management_denied} ->
        socket =
          socket
          |> assign(:operator_management_denied?, true)
          |> assign(:pool_options, [])
          |> assign(:operator_count, 0)
          |> assign(:active_operator_count, 0)
          |> stream(:operators, [], reset: true, dom_id: &"operator-row-#{&1.id}")

        {:error, :operator_management_denied, socket}
    end
  end

  defp operator_management_denied?(socket), do: socket.assigns.operator_management_denied?

  defp management_pool_options(current_scope) do
    case Pools.list_pools_for_management(current_scope) do
      {:ok, pools} -> pools
      {:error, _reason} -> []
    end
  end

  defp self_operator_id?(operator_id, %{user: %{id: operator_id}}), do: true
  defp self_operator_id?(_operator_id, _current_scope), do: false

  defp error_message(:last_active_owner), do: "At least one active instance owner must remain."
  defp error_message(:last_active_admin), do: "At least one active instance owner must remain."
  defp error_message(:invalid_operator_role), do: "Role must be instance owner or instance admin."
  defp error_message(:invalid_pool_assignment), do: "Assigned Pools were not valid."
  defp error_message(:invalid_operator), do: "Operator was not found"

  defp error_message(:operator_management_denied),
    do: "Only instance owners can manage operators."

  defp error_message(%{message: message}) when is_binary(message), do: message

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> List.first()
    |> case do
      nil -> "Operator was not saved"
      message -> message
    end
  end

  defp error_message(_reason), do: "Operator action failed"

  defp operator_metadata, do: %{}
end
