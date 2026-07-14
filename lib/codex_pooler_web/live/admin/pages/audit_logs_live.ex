defmodule CodexPoolerWeb.Admin.AuditLogsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Audit
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.LogPagination
  alias CodexPoolerWeb.Admin.PoolFilterComponents
  alias CodexPoolerWeb.DateTimeDisplay

  import CodexPoolerWeb.Admin.AuditLogsComponents,
    only: [audit_event_drawer: 1, audit_log_filters: 1, audit_logs_table: 1]

  @page_size 50
  @outcome_options ~w(success failure)
  @actor_type_options ~w(user system)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Audit logs",
       pools: [],
       selected_pool: nil,
       audit_logs: empty_audit_logs(),
       current_params: %{},
       selected_audit_event: nil,
       filter_form: to_form(%{}, as: :filters),
       filter_values: %{},
       filter_errors: [],
       pool_filter_options: [],
       datetime_preferences:
         DateTimeDisplay.preferences_for_user(socket.assigns.current_scope.user)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_audit_logs(socket, params)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/audit-logs?#{query_params(filter_params)}")}
  end

  def handle_event("select_action_filter", %{"action" => action}, socket) do
    params = Map.put(socket.assigns.filter_values, "action", action)

    {:noreply, push_patch(socket, to: ~p"/admin/audit-logs?#{query_params(params)}")}
  end

  def handle_event("select_pool_filter", %{"pool-id" => pool_id}, socket) do
    params = Map.put(socket.assigns.filter_values, "pool_id", pool_id)

    {:noreply, push_patch(socket, to: ~p"/admin/audit-logs?#{query_params(params)}")}
  end

  def handle_event("select_outcome_filter", %{"outcome" => outcome}, socket) do
    params = Map.put(socket.assigns.filter_values, "outcome", outcome)

    {:noreply, push_patch(socket, to: ~p"/admin/audit-logs?#{query_params(params)}")}
  end

  @impl true
  def handle_event("show_audit_event", %{"id" => id}, socket) do
    selected_event = Enum.find(socket.assigns.audit_logs.items, &(&1.id == id))

    {:noreply, assign(socket, selected_audit_event: selected_event)}
  end

  @impl true
  def handle_event("close_audit_event", _params, socket) do
    {:noreply, assign(socket, selected_audit_event: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:audit_logs}
      alert_notification_center={@alert_notification_center}
    >
      <div id="audit-event-details-drawer-root" class="drawer drawer-end">
        <input
          id="audit-event-details-drawer"
          type="checkbox"
          class="drawer-toggle"
          checked={@selected_audit_event != nil}
        />

        <div class="drawer-content min-w-0">
          <section id="admin-audit-logs-live" class="grid min-w-0 gap-6">
            <AdminComponents.page_header
              id="audit-log-page-header"
              title="Audit logs"
              description="Review sign-ins, operator changes, and other operator account activity with sensitive values redacted."
            />

            <.audit_log_filters
              filter_form={@filter_form}
              filter_values={@filter_values}
              filter_errors={@filter_errors}
              pool_filter_options={@pool_filter_options}
            />

            <.audit_logs_table
              audit_logs={@audit_logs}
              current_params={@current_params}
              datetime_preferences={@datetime_preferences}
            />
          </section>
        </div>

        <.audit_event_drawer
          selected_audit_event={@selected_audit_event}
          datetime_preferences={@datetime_preferences}
        />
      </div>
    </AdminComponents.admin_shell>
    """
  end

  defp load_audit_logs(socket, params) do
    pools = Pools.list_log_filter_pools(socket.assigns.current_scope)
    {selected_pool, pool_error} = select_pool(pools, params["pool_id"])
    {filters, form_values, filter_errors} = parse_filters(params, selected_pool)
    {page, page_error} = LogPagination.parse_page(params)
    filter_errors = Enum.reject([pool_error, page_error | filter_errors], &is_nil/1)
    offset = LogPagination.offset(page, @page_size)

    audit_logs =
      if selected_pool do
        Audit.list_events(selected_pool, limit: @page_size, offset: offset, filters: filters)
      else
        Audit.list_events_for_scope(socket.assigns.current_scope,
          limit: @page_size,
          offset: offset,
          filters: filters
        )
      end

    case LogPagination.clamp_page(page, audit_logs) do
      ^page ->
        assign(socket,
          pools: pools,
          selected_pool: selected_pool,
          audit_logs: audit_logs,
          current_params:
            params
            |> normalize_query_params()
            |> LogPagination.put_page(page),
          selected_audit_event:
            selected_audit_event(socket.assigns.selected_audit_event, audit_logs.items),
          filter_form: to_form(form_values, as: :filters, errors: form_errors(filter_errors)),
          filter_values: form_values,
          filter_errors: filter_errors,
          pool_filter_options: PoolFilterComponents.pool_filter_options(pools)
        )

      clamped_page ->
        push_patch(socket,
          to:
            LogPagination.path(
              "/admin/audit-logs",
              normalize_query_params(params),
              clamped_page
            )
        )
    end
  end

  defp normalize_query_params(params) do
    params
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(~w(pool_id outcome actor_type actor action target date_from date_to page))
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp parse_filters(params, selected_pool) do
    form_values = %{
      "pool_id" => (selected_pool && selected_pool.id) || string_param(params, "pool_id") || "",
      "outcome" => string_param(params, "outcome"),
      "actor_type" => string_param(params, "actor_type"),
      "actor" => string_param(params, "actor"),
      "action" => string_param(params, "action"),
      "target" => string_param(params, "target"),
      "date_from" => string_param(params, "date_from"),
      "date_to" => string_param(params, "date_to")
    }

    {outcome, outcome_error} =
      parse_member(
        form_values["outcome"],
        @outcome_options,
        :outcome,
        "Outcome filter is not supported"
      )

    {actor_type, actor_type_error} =
      parse_member(
        form_values["actor_type"],
        @actor_type_options,
        :actor_type,
        "Actor type filter is not supported"
      )

    {action, action_error} =
      parse_member(
        form_values["action"],
        Audit.supported_actions(),
        :action,
        "Action filter is not supported"
      )

    {date_from, date_from_error} = parse_date(form_values["date_from"], :date_from)
    {date_to, date_to_error} = parse_date(form_values["date_to"], :date_to)

    filters =
      [
        outcome: outcome,
        actor_type: actor_type,
        actor: blank_to_nil(form_values["actor"]),
        action: action,
        target: blank_to_nil(form_values["target"]),
        date_from: date_from,
        date_to: date_to
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    errors =
      Enum.reject(
        [outcome_error, actor_type_error, action_error, date_from_error, date_to_error],
        &is_nil/1
      )

    {filters, form_values, errors}
  end

  defp query_params(filter_params) do
    filter_params
    |> Map.take(~w(pool_id outcome actor_type actor action target date_from date_to))
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp select_pool(pools, pool_id) do
    cond do
      blank?(pool_id) ->
        {nil, nil}

      pool = Enum.find(pools, &(&1.id == pool_id)) ->
        {pool, nil}

      true ->
        {nil, %{field: :pool_id, message: "Pool filter did not match an available Pool"}}
    end
  end

  defp parse_member(nil, _allowed, _field, _message), do: {nil, nil}

  defp parse_member(value, allowed, field, message) do
    if value in allowed do
      {value, nil}
    else
      {nil, %{field: field, message: message}}
    end
  end

  defp parse_date(nil, _field), do: {nil, nil}

  defp parse_date(value, field) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {date_boundary(date, field), nil}

      {:error, _reason} ->
        {nil, %{field: field, message: "#{date_label(field)} must be a valid date"}}
    end
  end

  defp date_boundary(date, :date_to), do: DateTime.new!(date, ~T[23:59:59.999999], "Etc/UTC")
  defp date_boundary(date, _field), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp form_errors(errors), do: Enum.map(errors, &{&1.field, {&1.message, []}})

  defp empty_audit_logs, do: %{items: [], total: 0, limit: @page_size, offset: 0}

  defp selected_audit_event(nil, _events), do: nil

  defp selected_audit_event(%{id: selected_id}, events),
    do: Enum.find(events, &(&1.id == selected_id))

  defp date_label(:date_from), do: "Date from"
  defp date_label(:date_to), do: "Date to"

  defp string_param(params, key), do: params |> Map.get(key) |> blank_to_nil()
  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: String.trim(to_string(value)))
  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
end
