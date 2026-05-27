defmodule CodexPoolerWeb.Admin.RequestLogsLive do
  use CodexPoolerWeb, :live_view

  alias CodexPooler.Accounting
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.RequestLogFilterForm
  alias CodexPoolerWeb.Admin.RequestLogsDisplay

  import CodexPoolerWeb.Admin.RequestLogsPresentation

  import CodexPoolerWeb.Admin.RequestLogsPresentation.Filters,
    only: [request_log_filter_dropdown: 1]

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Admin request logs",
       pools: [],
       selected_pool: nil,
       request_logs: empty_request_logs(),
       current_params: %{},
       filter_form: to_form(%{}, as: :filters),
       filter_values: %{},
       filter_errors: [],
       pool_filter_options: [],
       model_filter_options: [],
       upstream_account_options: [],
       subscribed_pool_ids: MapSet.new()
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_request_logs(socket, params)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/admin/request-logs?#{RequestLogFilterForm.query_params(filter_params)}"
     )}
  end

  def handle_event("clear_request_id_filter", _params, socket) do
    params = Map.put(socket.assigns.filter_values, "request_id", "")

    {:noreply,
     push_patch(socket, to: ~p"/admin/request-logs?#{RequestLogFilterForm.query_params(params)}")}
  end

  def handle_event("select_pool_filter", %{"pool-id" => pool_id}, socket) do
    params = Map.put(socket.assigns.filter_values, "pool_id", pool_id)

    {:noreply,
     push_patch(socket, to: ~p"/admin/request-logs?#{RequestLogFilterForm.query_params(params)}")}
  end

  def handle_event("select_status_filter", %{"status" => status}, socket) do
    params = Map.put(socket.assigns.filter_values, "status", status)

    {:noreply,
     push_patch(socket, to: ~p"/admin/request-logs?#{RequestLogFilterForm.query_params(params)}")}
  end

  def handle_event("select_upstream_filter", %{"upstream-id" => upstream_id}, socket) do
    params = Map.put(socket.assigns.filter_values, "upstream_identity_id", upstream_id)

    {:noreply,
     push_patch(socket, to: ~p"/admin/request-logs?#{RequestLogFilterForm.query_params(params)}")}
  end

  def handle_event("select_model_filter", %{"model" => model}, socket) do
    params = Map.put(socket.assigns.filter_values, "model", model)

    {:noreply,
     push_patch(socket, to: ~p"/admin/request-logs?#{RequestLogFilterForm.query_params(params)}")}
  end

  @impl true
  def handle_info({Events, %{pool_id: pool_id, topics: topics}}, socket) do
    if "request_logs" in topics and request_log_event_in_scope?(socket, pool_id) do
      {:noreply, load_request_logs(socket, socket.assigns.current_params)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:request_logs}
    >
      <section id="admin-request-logs-live" class="grid gap-6">
        <AdminComponents.page_header
          id="request-log-page-header"
          title="Request logs"
          description="Audit recent gateway traffic, routing decisions, upstream outcomes, quota evidence, token usage, and cost settlement."
        />

        <AdminComponents.filter_form
          id="request-log-filter-form"
          for={@filter_form}
          phx-change="filter"
          phx-submit="filter"
          advanced_open={advanced_filters_open?(@filter_values)}
          mobile_single_column
        >
          <.request_log_filter_dropdown
            id="request-log-pool-filter"
            label="Pool"
            field_name="pool_id"
            hidden_id="filters_pool_id"
            role="pool-filter"
            event="select_pool_filter"
            value_attr={:pool_id}
            selected_value={@filter_values["pool_id"] || ""}
            selected={selected_pool_filter_option(@pool_filter_options, @filter_values["pool_id"])}
            options={@pool_filter_options}
          />
          <.request_log_filter_dropdown
            id="request-log-status-filter"
            label="Status"
            field_name="status"
            hidden_id="filters_status"
            role="status-filter"
            event="select_status_filter"
            value_attr={:status}
            selected_value={@filter_values["status"] || ""}
            selected={RequestLogsDisplay.selected_status_filter_option(@filter_values["status"])}
            options={RequestLogsDisplay.status_filter_options()}
          />
          <.request_log_filter_dropdown
            id="request-log-upstream-filter"
            label="Upstream account"
            field_name="upstream_identity_id"
            hidden_id="filters_upstream_identity_id"
            role="upstream-filter"
            event="select_upstream_filter"
            value_attr={:upstream_id}
            selected_value={@filter_values["upstream_identity_id"] || ""}
            selected={
              selected_upstream_filter_option(
                @upstream_account_options,
                @filter_values["upstream_identity_id"]
              )
            }
            options={@upstream_account_options}
          />
          <.request_log_filter_dropdown
            id="request-log-model-filter"
            label="Model"
            field_name="model"
            hidden_id="filters_model"
            role="model-filter"
            event="select_model_filter"
            value_attr={:model}
            selected_value={@filter_values["model"] || ""}
            selected={RequestLogsDisplay.selected_model_filter_option(@filter_values["model"])}
            options={@model_filter_options}
          />
          <:advanced>
            <.request_id_filter field={@filter_form[:request_id]} />
            <.cally_date_filter field={@filter_form[:date_from]} label="Date from" inline_label />
            <.cally_date_filter field={@filter_form[:date_to]} label="Date to" inline_label />
          </:advanced>
        </AdminComponents.filter_form>

        <div
          :if={@filter_errors != []}
          id="request-log-filter-errors"
          class="alert alert-warning items-start"
        >
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <div>
            <p class="font-semibold">Some filters were ignored</p>
            <ul class="mt-1 list-disc space-y-1 pl-5 text-sm">
              <li :for={error <- @filter_errors}>{error.message}</li>
            </ul>
          </div>
        </div>

        <.request_logs_table request_logs={@request_logs} />
      </section>
    </AdminComponents.admin_shell>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp request_id_filter(assigns) do
    assigns = assign(assigns, :value, form_field_value(assigns.field))

    ~H"""
    <div id="request-log-request-id-filter" class="fieldset mb-2">
      <div class="input input-sm flex w-full items-center gap-2">
        <input
          id={@field.id}
          name={@field.name}
          type="text"
          value={@value}
          placeholder="Correlation or row id"
          aria-label="Request ID"
          class="min-w-0 grow text-sm font-normal"
        />
        <button
          id="request-log-request-id-clear"
          type="button"
          class={[
            "grid size-6 shrink-0 place-items-center rounded-full text-base-content/50 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
            @value == "" && "hidden"
          ]}
          phx-click="clear_request_id_filter"
          aria-label="Clear request id filter"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :inline_label, :boolean, default: false

  defp cally_date_filter(assigns) do
    assigns =
      assigns
      |> assign(:id, assigns.field.id)
      |> assign(:name, assigns.field.name)
      |> assign(:value, assigns.field.value || "")
      |> assign(:anchor_name, "--#{String.replace(assigns.field.id, "_", "-")}-cally")

    ~H"""
    <div
      id={"#{@id}-picker"}
      class="fieldset mb-2"
      phx-hook="CallyDatePicker"
      data-placeholder="dd/mm/yyyy"
    >
      <input type="hidden" id={@id} name={@name} value={@value} />
      <label :if={!@inline_label} class="label mb-1" for={"#{@id}-button"}>{@label}</label>
      <button
        id={"#{@id}-button"}
        type="button"
        class="input input-sm flex w-full items-center justify-between gap-2 text-left"
        aria-label={@label}
        popovertarget={"#{@id}-popover"}
        style={"anchor-name: #{@anchor_name};"}
      >
        <span
          :if={@inline_label}
          class="label !mb-0 min-w-0 shrink truncate !px-2 !normal-case !tracking-normal leading-none text-base-content/60"
        >
          {@label}
        </span>
        <span class="min-w-0 flex-1 truncate leading-none" data-role="cally-date-label">
          {if @value == "", do: "dd/mm/yyyy", else: @value}
        </span>
        <.icon name="hero-calendar-days" class="size-4 shrink-0 opacity-65" />
      </button>
      <div
        id={"#{@id}-popover"}
        popover
        class="dropdown rounded-box border border-base-300 bg-base-100 p-3 text-base-content shadow-xl"
        style={"position-anchor: #{@anchor_name};"}
      >
        <calendar-date
          class="cally"
          value={@value}
          locale="en-GB"
          data-role="cally-calendar"
        >
          <svg
            aria-label="Previous"
            class="size-4 fill-current"
            slot="previous"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
          >
            <path d="M15.75 19.5 8.25 12l7.5-7.5"></path>
          </svg>
          <svg
            aria-label="Next"
            class="size-4 fill-current"
            slot="next"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
          >
            <path d="m8.25 4.5 7.5 7.5-7.5 7.5"></path>
          </svg>
          <calendar-month></calendar-month>
        </calendar-date>
        <div class="mt-3 grid grid-cols-2 gap-2 border-t border-base-300 pt-3">
          <button
            type="button"
            class="btn btn-secondary btn-sm"
            data-role="cally-clear"
          >
            Clear
          </button>
          <button
            type="button"
            class="btn btn-secondary btn-sm"
            data-role="cally-cancel"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp advanced_filters_open?(filter_values) do
    Enum.any?(
      ~w(request_id date_from date_to),
      &(filter_values[&1] not in [nil, ""])
    )
  end

  defp form_field_value(%{value: value}) when is_binary(value), do: value
  defp form_field_value(_field), do: ""

  defp load_request_logs(socket, params) do
    pools = Pools.list_visible_pools(socket.assigns.current_scope)

    visible_upstream_identities =
      Upstreams.list_visible_upstream_identities(socket.assigns.current_scope)

    visible_upstream_identity_ids =
      visible_upstream_identities
      |> Enum.map(& &1.id)
      |> MapSet.new()

    {selected_pool, pool_error} = RequestLogFilterForm.select_pool(pools, params["pool_id"])

    {filters, form_values, filter_errors} =
      RequestLogFilterForm.parse_filters(params, selected_pool, visible_upstream_identity_ids)

    filter_errors = Enum.reject([pool_error | filter_errors], &is_nil/1)

    request_logs =
      if selected_pool do
        Accounting.list_request_logs(selected_pool, limit: @page_size, filters: filters)
      else
        Accounting.list_request_logs_for_scope(
          socket.assigns.current_scope,
          limit: @page_size,
          filters: filters
        )
      end

    model_filter_models =
      if selected_pool do
        Accounting.list_request_log_models(selected_pool)
      else
        Accounting.list_request_log_models_for_scope(socket.assigns.current_scope)
      end

    socket = maybe_subscribe_pool_events(socket, pools, selected_pool)

    assign(socket,
      pools: pools,
      selected_pool: selected_pool,
      request_logs: request_logs,
      current_params: params,
      filter_form:
        to_form(form_values,
          as: :filters,
          errors: RequestLogFilterForm.form_errors(filter_errors)
        ),
      filter_values: form_values,
      filter_errors: filter_errors,
      pool_filter_options: pool_filter_options(pools),
      model_filter_options: model_filter_options(model_filter_models, form_values["model"]),
      upstream_account_options: upstream_account_options(visible_upstream_identities)
    )
  end

  defp maybe_subscribe_pool_events(socket, _pools, selected_pool)
       when not is_nil(selected_pool) do
    PoolEventSubscriptions.reconcile(socket, MapSet.new([selected_pool.id]))
    |> elem(0)
  end

  defp maybe_subscribe_pool_events(socket, pools, _selected_pool) do
    pools
    |> PoolEventSubscriptions.pool_id_set()
    |> then(fn target_pool_ids ->
      {socket, _stale_pool_ids} = PoolEventSubscriptions.reconcile(socket, target_pool_ids)
      socket
    end)
  end

  defp selected_pool_id(%{assigns: %{selected_pool: %{id: pool_id}}}), do: pool_id
  defp selected_pool_id(_socket), do: nil

  defp request_log_event_in_scope?(socket, pool_id) do
    case selected_pool_id(socket) do
      nil -> Enum.any?(socket.assigns.pools, &(&1.id == pool_id))
      selected_pool_id -> selected_pool_id == pool_id
    end
  end

  defp pool_filter_options(pools) do
    settings_by_pool_id = pools |> Enum.map(& &1.id) |> Pools.routing_settings_by_pool_ids()

    pool_options =
      pools
      |> Enum.sort_by(&String.downcase(&1.name))
      |> Enum.map(fn pool ->
        strategy = Map.fetch!(settings_by_pool_id, pool.id).routing_strategy

        %{
          label: pool.name,
          value: pool.id,
          icon: AdminBadges.routing_strategy_icon(strategy),
          strategy_label: AdminBadges.routing_strategy_label(strategy)
        }
      end)

    [all_pool_filter_option() | pool_options]
  end

  defp all_pool_filter_option do
    %{label: "All Pools", value: "", icon: "hero-server-stack", strategy_label: nil}
  end

  defp selected_pool_filter_option(options, pool_id) do
    Enum.find(options, &(&1.value == pool_id)) || all_pool_filter_option()
  end

  defp model_filter_options(models, selected_model) do
    models =
      models
      |> Enum.reject(&RequestLogFilterForm.blank?/1)
      |> Enum.uniq()
      |> Enum.sort_by(&String.downcase/1)

    selected_models =
      selected_model
      |> RequestLogFilterForm.blank_to_nil()
      |> List.wrap()

    [
      %{label: "Any model", value: "", icon: "hero-cpu-chip"}
      | Enum.map(Enum.uniq(selected_models ++ models), fn model ->
          %{label: model, value: model, icon: "hero-cpu-chip"}
        end)
    ]
  end

  defp upstream_account_options(visible_upstream_identities) do
    [
      any_upstream_filter_option()
      | Enum.map(visible_upstream_identities, &upstream_account_option/1)
    ]
  end

  defp any_upstream_filter_option do
    %{label: "Any account", value: "", icon: "hero-cloud-arrow-up"}
  end

  defp selected_upstream_filter_option(options, upstream_identity_id) do
    Enum.find(options, &(&1.value == upstream_identity_id)) || any_upstream_filter_option()
  end

  defp upstream_account_option(identity) do
    %{
      label: identity.account_label || identity.chatgpt_account_id || "upstream account",
      value: identity.id,
      icon: "hero-cloud-arrow-up"
    }
  end

  defp empty_request_logs, do: %{items: [], total: 0, limit: @page_size, offset: 0}
end
