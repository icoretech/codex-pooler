defmodule CodexPoolerWeb.Admin.RequestLogsLive do
  use CodexPoolerWeb, :live_view

  alias CodexPooler.Accounting
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.PoolFilterComponents
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
       page_title: "Request logs",
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
          <PoolFilterComponents.pool_filter_dropdown
            id="request-log-pool-filter"
            label="Pool"
            hidden_id="filters_pool_id"
            selected_value={@filter_values["pool_id"] || ""}
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
            <AdminComponents.cally_date_filter field={@filter_form[:date_from]} label="Date from" />
            <AdminComponents.cally_date_filter field={@filter_form[:date_to]} label="Date to" />
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
          class="min-w-0 grow text-xs font-normal"
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

  defp advanced_filters_open?(filter_values) do
    Enum.any?(
      ~w(request_id date_from date_to),
      &(filter_values[&1] not in [nil, ""])
    )
  end

  defp form_field_value(%{value: value}) when is_binary(value), do: value
  defp form_field_value(_field), do: ""

  defp load_request_logs(socket, params) do
    pools = Pools.list_log_filter_pools(socket.assigns.current_scope)

    visible_upstream_identities =
      Upstreams.list_visible_upstream_identities(socket.assigns.current_scope)

    {selected_pool, pool_error} = RequestLogFilterForm.select_pool(pools, params["pool_id"])

    upstream_filter_identities =
      upstream_filter_identities(visible_upstream_identities, selected_pool)

    visible_upstream_identity_ids =
      upstream_filter_identities
      |> Enum.map(& &1.id)
      |> MapSet.new()

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
      pool_filter_options: PoolFilterComponents.pool_filter_options(pools),
      model_filter_options: model_filter_options(model_filter_models, form_values["model"]),
      upstream_account_options: upstream_account_options(upstream_filter_identities)
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

  defp upstream_filter_identities(visible_upstream_identities, nil),
    do: visible_upstream_identities

  defp upstream_filter_identities(visible_upstream_identities, selected_pool) do
    selected_pool_identity_ids =
      selected_pool
      |> Upstreams.list_pool_assignments()
      |> Enum.reject(&(&1.status == "deleted"))
      |> Enum.map(& &1.upstream_identity_id)
      |> MapSet.new()

    Enum.filter(visible_upstream_identities, &MapSet.member?(selected_pool_identity_ids, &1.id))
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
