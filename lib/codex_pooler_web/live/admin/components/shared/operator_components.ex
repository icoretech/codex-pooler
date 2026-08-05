defmodule CodexPoolerWeb.Admin.OperatorComponents do
  @moduledoc """
  Operator identity presentation components for admin surfaces.
  """
  use CodexPoolerWeb, :html

  alias CodexPooler.Accounts.User
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

  attr :operators, :list, required: true
  attr :panel_views, :map, required: true
  attr :current_scope, :any, required: true
  attr :active_operator_count, :integer, required: true
  attr :filter_form, Phoenix.HTML.Form, required: true
  attr :datetime_preferences, :map, required: true

  def operator_cards(assigns) do
    ~H"""
    <section id="operator-inventory-surface" class="grid min-w-0 gap-4 overflow-visible">
      <.operator_filter_form form={@filter_form} />

      <AdminComponents.empty_state
        :if={@operators == []}
        id="operators-empty-state"
        icon="hero-users"
        title="No operators match"
        description="No operators match the current filters."
      />

      <div
        :if={@operators != []}
        id="operators-cards"
        class="grid min-w-0 items-stretch gap-3 md:grid-cols-2 xl:grid-cols-3"
      >
        <.operator_card
          :for={entry <- @operators}
          entry={entry}
          current_scope={@current_scope}
          active_operator_count={@active_operator_count}
          datetime_preferences={@datetime_preferences}
          pools_panel_open?={Map.get(@panel_views, entry.operator.id) == :pools}
        />
      </div>
    </section>
    """
  end

  attr :entry, :map, required: true
  attr :current_scope, :any, required: true
  attr :active_operator_count, :integer, required: true
  attr :datetime_preferences, :map, required: true
  attr :pools_panel_open?, :boolean, required: true

  defp operator_card(assigns) do
    operator = assigns.entry.operator

    assigns =
      assigns
      |> assign(:operator, operator)
      |> assign(:owner?, assigns.entry.role == "instance_owner")
      |> assign(:role_label, operator_role_label(assigns.entry.role))
      |> assign(:pool_names, assigns.entry.pool_names)
      |> assign(:dom, "operator-row-#{operator.id}")

    ~H"""
    <article
      id={@dom}
      data-role="operator-card"
      class="flex min-w-0 flex-col rounded-box border border-base-300 bg-base-100"
    >
      <div class="flex min-w-0 items-center gap-3 border-b border-base-300 bg-base-200/35 px-4 py-3">
        <Identity.operator_avatar
          id={"#{@dom}-avatar"}
          operator={@operator}
          status={@operator.status}
        />
        <div class="grid min-w-0 flex-1 gap-0.5">
          <span class="flex min-w-0 items-baseline gap-1.5">
            <span class="truncate font-medium leading-5 text-base-content">
              {Identity.operator_display_name(@operator)}
            </span>
            <span
              :if={self_operator?(@operator, @current_scope)}
              class="shrink-0 text-[9px] font-bold uppercase tracking-[0.06em] text-primary/75"
            >
              you
            </span>
          </span>
          <span class="truncate text-xs leading-4 text-base-content/55">{@operator.email}</span>
          <span id={"#{@dom}-role"} class={operator_role_class(@owner?)}>{@role_label}</span>
        </div>
        <.operator_action_menu
          operator={@operator}
          current_scope={@current_scope}
          active_operator_count={@active_operator_count}
        />
      </div>

      <dl class="grid grid-cols-2 gap-x-3 gap-y-2.5 px-4 py-3">
        <div id={"#{@dom}-totp"} class="min-w-0">
          <dt class={card_vital_label_class()}>TOTP</dt>
          <dd
            class={["truncate text-xs leading-5", totp_value_class(@operator)]}
            aria-label={totp_state_label(@operator)}
            title={totp_state_label(@operator)}
          >
            {totp_value_label(@operator)}
          </dd>
        </div>
        <div id={"#{@dom}-password-policy"} class="min-w-0">
          <dt class={card_vital_label_class()}>Password policy</dt>
          <dd
            class={["truncate text-xs leading-5", password_policy_value_class(@operator)]}
            title={password_policy_label(@operator)}
          >
            {password_policy_label(@operator)}
          </dd>
        </div>
        <div class="min-w-0">
          <dt class={card_vital_label_class()}>Last login</dt>
          <dd
            id={"#{@dom}-last-login-at"}
            class="truncate text-xs leading-5 text-base-content/65 tabular-nums"
          >
            {format_datetime(@operator.last_login_at, @datetime_preferences)}
          </dd>
        </div>
        <div class="min-w-0">
          <dt class={card_vital_label_class()}>Joined</dt>
          <dd
            id={"#{@dom}-joined-at"}
            class="truncate text-xs leading-5 text-base-content/65 tabular-nums"
          >
            {format_datetime(@operator.created_at, @datetime_preferences)}
          </dd>
        </div>
      </dl>

      <div class="min-h-0 flex-1"></div>

      <section
        id={"#{@dom}-pools-panel"}
        data-role="operator-pools-panel"
        aria-hidden={aria_bool(!@pools_panel_open?)}
        inert={!@pools_panel_open?}
        class={operator_panel_class(@pools_panel_open?)}
      >
        <div class="mx-4 grid gap-2 border-t border-base-300/70 py-3">
          <p class={card_vital_label_class()}>
            {if @owner?, do: "Pool visibility", else: "Assigned Pools"}
          </p>
          <p :if={@owner?} class="text-xs leading-5 text-base-content/60">
            The instance owner is not Pool-scoped: every current and future Pool is visible and manageable.
          </p>
          <p :if={!@owner? and @pool_names == []} class="text-xs leading-5 text-base-content/60">
            No Pools assigned yet.
          </p>
          <p
            :for={pool_name <- @pool_names}
            :if={!@owner?}
            class="flex min-w-0 items-center gap-2 text-xs leading-5 text-base-content/80"
          >
            <.icon name="hero-rectangle-stack" class="size-3.5 shrink-0 text-base-content/45" />
            <span class="truncate">{pool_name}</span>
          </p>
        </div>
      </section>

      <AdminComponents.card_fact_strip id={"#{@dom}-facts"} data-role="operator-card-footer">
        <:fact role="operator-status-cell">
          <AdminComponents.card_fact_label>Status</AdminComponents.card_fact_label>
          <AdminComponents.card_fact_value
            id={"#{@dom}-status"}
            tone_class={operator_status_value_tone(@operator.status)}
          >
            {String.capitalize(@operator.status)}
          </AdminComponents.card_fact_value>
        </:fact>
        <:fact role="operator-pools-cell" interactive>
          <AdminComponents.card_fact_label
            tone_class={footer_panel_label_tone(@pools_panel_open?)}
            class="transition-colors"
          >
            <button
              id={"#{@dom}-pools-panel-trigger"}
              type="button"
              class={footer_panel_trigger_class(@pools_panel_open?)}
              phx-click="toggle_operator_pools_panel"
              phx-value-id={@operator.id}
              aria-controls={"#{@dom}-pools-panel"}
              aria-expanded={aria_bool(@pools_panel_open?)}
              aria-label={pools_trigger_label(@pools_panel_open?, @owner?, @pool_names)}
            >
              <span class="sr-only">Pools</span>
            </button>
            <span class="pointer-events-none relative z-30 block max-w-full truncate text-left">
              Pools
            </span>
          </AdminComponents.card_fact_label>
          <AdminComponents.card_fact_value
            id={"#{@dom}-pools-count"}
            tone_class={footer_panel_value_tone(@pools_panel_open?)}
            class="pointer-events-none relative z-30 transition-colors"
          >
            {pool_count_label(@owner?, @pool_names)}
          </AdminComponents.card_fact_value>
        </:fact>
      </AdminComponents.card_fact_strip>
    </article>
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

  defp card_vital_label_class,
    do: "text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/35"

  defp operator_role_label("instance_owner"), do: "Instance owner"
  defp operator_role_label("instance_admin"), do: "Instance admin"
  defp operator_role_label(_role), do: "No role"

  defp operator_role_class(true),
    do: "truncate text-[9.5px] font-bold uppercase tracking-[0.07em] text-primary/70"

  defp operator_role_class(false),
    do: "truncate text-[9.5px] font-bold uppercase tracking-[0.07em] text-base-content/45"

  defp totp_value_label(%User{totp_status: "active"}), do: "Enabled"
  defp totp_value_label(_operator), do: "Not set up"

  defp totp_value_class(%User{totp_status: "active"}), do: "text-success"
  defp totp_value_class(_operator), do: "text-warning"

  defp password_policy_value_class(%User{password_change_required: true}), do: "text-warning"
  defp password_policy_value_class(_operator), do: "text-base-content/65"

  defp operator_status_value_tone("active"), do: "text-success"
  defp operator_status_value_tone(_status), do: "text-warning"

  defp pool_count_label(true = _owner?, _pool_names), do: "All Pools"
  defp pool_count_label(false = _owner?, [_single] = _pool_names), do: "1 Pool"
  defp pool_count_label(false = _owner?, pool_names), do: "#{length(pool_names)} Pools"

  defp pools_trigger_label(open?, owner?, pool_names) do
    action = if open?, do: "Hide", else: "Show"

    subject =
      if owner? do
        "Pool visibility"
      else
        "assigned Pools (#{pool_count_label(false, pool_names)})"
      end

    "#{action} #{subject} for this operator"
  end

  # Same panel and overlay contract as the upstream account card (§5.19 kept
  # them radio-free; §5.17 owns the interactive cell): hidden panels stay in
  # the DOM but collapsed, aria-hidden, and inert; the footer trigger reads as
  # the whole cell block with a ~4px breathing gap, and, being the last cell,
  # reaches past its box into the footer's own px-4.
  defp operator_panel_class(true) do
    "grid min-w-0 opacity-100 transition-opacity duration-150 ease-out motion-reduce:transition-none"
  end

  defp operator_panel_class(false) do
    "pointer-events-none grid min-w-0 max-h-0 overflow-hidden opacity-0 transition-opacity duration-150 ease-out motion-reduce:transition-none"
  end

  defp aria_bool(true), do: "true"
  defp aria_bool(false), do: "false"

  defp footer_panel_trigger_class(active?) do
    [
      "absolute -inset-y-1.5 left-1 -right-3 z-20 cursor-pointer rounded border transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
      if(active?,
        do: "border-primary/35 bg-primary/5",
        else: "border-transparent hover:border-primary/25 hover:bg-primary/5"
      )
    ]
  end

  defp footer_panel_label_tone(true), do: "text-primary/70"
  defp footer_panel_label_tone(false), do: "text-base-content/35 group-hover:text-primary/70"

  defp footer_panel_value_tone(true), do: "text-base-content/75"

  defp footer_panel_value_tone(false),
    do: "text-base-content/60 group-hover:text-base-content/75"
end
