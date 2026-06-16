defmodule CodexPoolerWeb.Admin.OperatorComponents do
  @moduledoc """
  Operator identity presentation components for admin surfaces.
  """
  use CodexPoolerWeb, :html

  alias CodexPooler.Accounts.User
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.OperatorComponents.Identity
  alias CodexPoolerWeb.DateTimeDisplay
  alias Phoenix.LiveView.JS

  attr :form, Phoenix.HTML.Form, required: true

  def operator_filter_form(assigns) do
    ~H"""
    <AdminComponents.filter_form
      id="operator-filter-form"
      for={@form}
      phx-change="filter_operators"
      phx-submit="filter_operators"
      autocomplete="off"
    >
      <.operator_query_filter_input field={@form[:query]} />
      <.operator_status_filter_dropdown
        selected_value={@form[:status].value}
        selected={selected_operator_status_filter_option(@form[:status].value)}
      />
    </AdminComponents.filter_form>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp operator_query_filter_input(assigns) do
    assigns = assign(assigns, :value, operator_query_filter_value(assigns.field))

    ~H"""
    <div class="grid gap-2">
      <label for={@field.id} class="sr-only">Search</label>
      <div class="input input-bordered flex min-h-10 w-full items-center gap-2">
        <input
          id={@field.id}
          name={@field.name}
          type="text"
          value={@value}
          placeholder="Search operators..."
          class="peer grow text-sm font-normal"
        />
        <button
          id="operator-filter-query-clear"
          type="button"
          class="grid size-6 shrink-0 place-items-center rounded-full text-base-content/50 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary peer-placeholder-shown:hidden"
          phx-click="clear_operator_query_filter"
          aria-label="Clear operator search"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :selected_value, :string, required: true
  attr :selected, :map, required: true

  defp operator_status_filter_dropdown(assigns) do
    ~H"""
    <div class="grid gap-2">
      <label for="operator-status-filter" class="sr-only">Status</label>
      <input
        type="hidden"
        id="operator_filters_status"
        name="operator_filters[status]"
        value={@selected_value}
      />
      <details
        id="operator-status-filter"
        class="dropdown w-full"
        phx-click-away={JS.remove_attribute("open", to: "#operator-status-filter")}
      >
        <summary
          data-role="status-filter-trigger"
          class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
        >
          <.icon name={@selected.icon} class={["size-4 shrink-0", @selected.icon_class]} />
          <span class="truncate">{@selected.label}</span>
        </summary>
        <ul
          data-role="status-filter-menu"
          class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
        >
          <li :for={option <- operator_status_filter_options()}>
            <button
              type="button"
              phx-click="select_operator_status_filter"
              phx-value-status={option.value}
              data-role="status-filter-option"
              data-status={option.value}
              class={[
                "flex items-center gap-2 text-sm",
                option.value == @selected_value && "active"
              ]}
              aria-current={option.value == @selected_value && "true"}
            >
              <span data-role="status-filter-icon" class="shrink-0">
                <.icon name={option.icon} class={["size-4", option.icon_class]} />
              </span>
              <span class="truncate">{option.label}</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  defp selected_operator_status_filter_option(status) do
    Enum.find(operator_status_filter_options(), &(&1.value == status)) ||
      all_operator_status_filter_option()
  end

  defp operator_status_filter_options do
    [
      all_operator_status_filter_option(),
      %{
        label: "Active",
        value: "active",
        icon: "hero-check-circle",
        icon_class: "text-success"
      },
      %{
        label: "Disabled",
        value: "disabled",
        icon: "hero-pause-circle",
        icon_class: "text-warning"
      }
    ]
  end

  defp all_operator_status_filter_option do
    %{
      label: "Status: All",
      value: "all",
      icon: "hero-users",
      icon_class: "text-base-content/60"
    }
  end

  defp operator_query_filter_value(%{value: value}) when is_binary(value), do: value
  defp operator_query_filter_value(_field), do: ""

  attr :operators, :any, required: true
  attr :current_scope, :any, required: true
  attr :active_operator_count, :integer, required: true
  attr :filter_form, Phoenix.HTML.Form, required: true
  attr :datetime_preferences, :map, required: true

  def operators_table(assigns) do
    ~H"""
    <section id="operator-inventory-surface" class="grid min-w-0 gap-4 overflow-visible">
      <.operator_filter_form form={@filter_form} />

      <div class="min-w-0 rounded-box border border-base-300 bg-base-100 shadow-sm">
        <div id="operators-table-scroll-region" class="overflow-x-auto md:overflow-visible">
          <table class="table min-w-[56rem]">
            <thead>
              <tr>
                <th>Operator</th>
                <th class="text-center">Status</th>
                <th class="text-center">TOTP</th>
                <th>Password policy</th>
                <th>Last login</th>
                <th class="text-center">Actions</th>
              </tr>
            </thead>
            <tbody id="operators-table" phx-update="stream">
              <tr id="operator-empty-row" class="hidden only:table-row">
                <td colspan="6" class="py-8 text-center text-sm text-base-content/60">
                  No operators match the current filters.
                </td>
              </tr>
              <tr
                :for={{row_id, operator} <- @operators}
                id={row_id}
                class="text-sm transition-colors hover:bg-base-200/80"
              >
                <td class="min-w-72 align-middle">
                  <div class="flex items-center gap-3">
                    <Identity.operator_avatar
                      id={"operator-row-#{operator.id}-avatar"}
                      operator={operator}
                      status={operator.status}
                    />
                    <div class="grid gap-1.5">
                      <span class="font-medium leading-5 text-base-content">
                        {Identity.operator_display_name(operator)}
                      </span>
                      <span class="text-sm leading-5 text-base-content/60">{operator.email}</span>
                    </div>
                  </div>
                </td>
                <td class="align-middle text-center">
                  <span
                    id={"operator-row-#{operator.id}-status"}
                    class={AdminBadges.lifecycle_chip_class(operator.status)}
                  >
                    {operator.status}
                  </span>
                </td>
                <td id={"operator-row-#{operator.id}-totp"} class="w-20 align-middle text-center">
                  <span
                    class={totp_state_class(operator)}
                    aria-label={totp_state_label(operator)}
                    title={totp_state_label(operator)}
                  >
                    <.icon name={totp_state_icon(operator)} class="size-4" />
                    <span class="sr-only">{totp_state_label(operator)}</span>
                  </span>
                </td>
                <td
                  id={"operator-row-#{operator.id}-password-policy"}
                  class="min-w-60 align-middle text-sm text-base-content/70"
                >
                  {password_policy_label(operator)}
                </td>
                <td
                  id={"operator-row-#{operator.id}-activity"}
                  class="min-w-44 align-middle text-sm leading-5 text-base-content/60"
                >
                  <span id={"operator-row-#{operator.id}-last-login-at"}>
                    {format_datetime(operator.last_login_at, @datetime_preferences)}
                  </span>
                </td>
                <td class="w-16 align-middle text-center">
                  <.operator_action_menu
                    operator={operator}
                    current_scope={@current_scope}
                    active_operator_count={@active_operator_count}
                  />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  attr :operator, :any, required: true
  attr :current_scope, :any, required: true
  attr :active_operator_count, :integer, required: true

  defp operator_action_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end inline-block">
      <button
        id={"operator-actions-menu-#{@operator.id}"}
        type="button"
        class="btn btn-ghost btn-sm btn-square"
        tabindex="0"
        aria-label={"Actions for #{Identity.operator_display_name(@operator)}"}
      >
        <.icon name="hero-ellipsis-vertical" class="size-5" />
      </button>
      <ul
        tabindex="0"
        class="menu dropdown-content z-20 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
      >
        <li>
          <AdminComponents.dropdown_action_item
            id={"edit-operator-#{@operator.id}"}
            icon="hero-pencil-square"
            label="Edit"
            phx-click="edit_operator"
            phx-value-id={@operator.id}
          />
        </li>
        <li :if={@operator.status == "active"}>
          <AdminComponents.dropdown_action_item
            id={"deactivate-operator-#{@operator.id}"}
            icon="hero-pause"
            label="Deactivate"
            variant={:danger}
            disabled={
              !can_deactivate_operator?(
                @operator,
                @current_scope,
                @active_operator_count
              )
            }
            title={deactivate_title(@operator, @current_scope, @active_operator_count)}
            phx-click="deactivate_operator"
            phx-value-id={@operator.id}
          />
        </li>
        <li :if={@operator.status != "active"}>
          <AdminComponents.dropdown_action_item
            id={"reactivate-operator-#{@operator.id}"}
            icon="hero-play"
            label="Reactivate"
            variant={:positive}
            phx-click="reactivate_operator"
            phx-value-id={@operator.id}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"reset-operator-password-#{@operator.id}"}
            icon="hero-arrow-path"
            label="Reset password"
            disabled={self_operator?(@operator, @current_scope)}
            title={self_action_title(@operator, @current_scope)}
            phx-click="reset_operator_password"
            phx-value-id={@operator.id}
          />
        </li>
      </ul>
    </div>
    """
  end

  defp password_policy_label(%User{password_change_required: true}),
    do: "Password change required"

  defp password_policy_label(_operator), do: "No password change required"

  defp totp_state_label(%User{totp_status: "active"}), do: "TOTP enabled"
  defp totp_state_label(_operator), do: "TOTP not set up"

  defp totp_state_icon(%User{totp_status: "active"}), do: "hero-shield-check"
  defp totp_state_icon(_operator), do: "hero-shield-exclamation"

  defp totp_state_class(%User{totp_status: "active"}) do
    "inline-flex size-8 items-center justify-center rounded-full border border-success/20 bg-success/10 text-success"
  end

  defp totp_state_class(_operator) do
    "inline-flex size-8 items-center justify-center rounded-full border border-base-300 bg-base-200 text-base-content/35"
  end

  defp can_deactivate_operator?(
         %User{status: "active"} = operator,
         current_scope,
         active_operator_count
       ),
       do: active_operator_count > 1 and not self_operator?(operator, current_scope)

  defp can_deactivate_operator?(_operator, _current_scope, _active_operator_count), do: false

  defp deactivate_title(%User{status: "active"} = operator, current_scope, active_operator_count) do
    cond do
      self_operator?(operator, current_scope) ->
        "Use account settings for your own account"

      can_deactivate_operator?(operator, current_scope, active_operator_count) ->
        "Deactivate operator"

      true ->
        "At least one active operator must remain"
    end
  end

  defp deactivate_title(_operator, _current_scope, _active_operator_count),
    do: "Deactivate operator"

  defp self_action_title(%User{} = operator, current_scope) do
    if self_operator?(operator, current_scope) do
      "Use account settings for your own account"
    else
      nil
    end
  end

  defp self_operator?(%User{id: operator_id}, %{user: %{id: operator_id}}), do: true
  defp self_operator?(_operator, _current_scope), do: false

  defp format_datetime(nil, _datetime_preferences), do: "not yet"

  defp format_datetime(%DateTime{} = datetime, datetime_preferences),
    do: DateTimeDisplay.format_datetime(datetime, datetime_preferences, missing_label: "not yet")
end
