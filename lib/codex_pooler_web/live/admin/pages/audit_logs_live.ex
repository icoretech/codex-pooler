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
  @snapshot_param "as_of"
  @snapshot_id_param "as_of_id"

  # A page number is address-bar input on its way to becoming an SQL OFFSET.
  # Unclamped it exceeds int64, raises inside handle_params, and the
  # reconnecting client retries the same URL.
  @max_page 10_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Audit logs",
       pools: [],
       selected_pool: nil,
       audit_logs: empty_audit_logs(),
       current_params: %{},
       audit_log_pin_at: nil,
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
              datetime_preferences={@datetime_preferences}
              previous_path={page_path(@current_params, @audit_logs, @audit_log_pin_at, -1)}
              next_path={page_path(@current_params, @audit_logs, @audit_log_pin_at, +1)}
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
    filter_errors = Enum.reject([pool_error | filter_errors], &is_nil/1)
    offset = page_offset(params)
    cursor = snapshot_at(params)
    audit_logs = audit_events(socket, selected_pool, pin(filters, cursor), offset)

    socket
    |> assign(
      pools: pools,
      selected_pool: selected_pool,
      audit_logs: audit_logs,
      current_params: params,
      audit_log_pin_at: cursor || newest_cursor(audit_logs),
      selected_audit_event:
        selected_audit_event(socket.assigns.selected_audit_event, audit_logs.items),
      filter_form: to_form(form_values, as: :filters, errors: form_errors(filter_errors)),
      filter_values: form_values,
      filter_errors: filter_errors,
      pool_filter_options: PoolFilterComponents.pool_filter_options(pools)
    )
    |> normalize_audit_log_window(params, audit_logs, cursor)
  end

  defp audit_events(_socket, selected_pool, filters, offset) when not is_nil(selected_pool) do
    Audit.list_events(selected_pool, limit: @page_size, offset: offset, filters: filters)
  end

  defp audit_events(socket, _selected_pool, filters, offset) do
    Audit.list_events_for_scope(socket.assigns.current_scope,
      limit: @page_size,
      offset: offset,
      filters: filters
    )
  end

  # The pin is its own filter rather than a tighter date_to, so it intersects
  # with whatever range the operator set instead of overriding it.
  defp pin(filters, nil), do: filters
  defp pin(filters, cursor), do: Keyword.put(filters, :at_or_before, cursor)

  # Audit events are appended, not streamed, so a page only moves when someone
  # acts while it is being read — but the same two invariants apply, for the
  # same reason: a page past the end has no way back, and an unpinned page
  # behind the first is an address that stops naming the same records.
  defp normalize_audit_log_window(socket, params, audit_logs, cursor) do
    %{total: total, limit: limit, offset: offset} = audit_logs
    page = div(offset, limit) + 1
    last_page = LogPagination.last_page(audit_logs)
    pin_at = newest_cursor(audit_logs)

    cond do
      total == 0 and page > 1 ->
        patch_window(socket, params, 1, nil)

      page > last_page ->
        patch_window(socket, params, last_page, cursor)

      page > 1 and is_nil(cursor) and not is_nil(pin_at) ->
        patch_window(socket, params, page, pin_at)

      true ->
        socket
    end
  end

  defp patch_window(socket, params, page, cursor) do
    push_patch(socket, to: ~p"/admin/audit-logs?#{window_params(params, page, cursor)}")
  end

  # Paging carries the filters forward and pins the window it was read at.
  # Stepping back onto page one drops the pin: the first page is the live
  # reading, and there is nothing behind it to hold still.
  defp page_path(params, audit_logs, cursor, step) do
    page = div(audit_logs.offset, max(audit_logs.limit, 1)) + 1 + step

    if page >= 1 do
      ~p"/admin/audit-logs?#{window_params(params, page, cursor)}"
    end
  end

  defp window_params(params, page, cursor) do
    {at, id} = cursor_params(page > 1 && cursor)

    params
    |> query_params()
    |> put_window("page", page > 1 && Integer.to_string(page))
    |> put_window(@snapshot_param, at)
    |> put_window(@snapshot_id_param, id)
  end

  defp put_window(params, _key, falsy) when falsy in [nil, false], do: params
  defp put_window(params, key, value), do: Map.put(params, key, value)

  defp cursor_params({%DateTime{} = at, id}), do: {DateTime.to_iso8601(at), id}
  defp cursor_params(_cursor), do: {nil, nil}

  defp newest_cursor(%{items: [%{occurred_at: %DateTime{} = at, id: id} | _rest]}), do: {at, id}
  defp newest_cursor(_audit_logs), do: nil

  defp page_offset(params), do: (page_number(params) - 1) * @page_size

  defp page_number(params) do
    with value when is_binary(value) <- Map.get(params, "page"),
         {page, ""} <- Integer.parse(String.trim(value)),
         true <- page > 1 do
      min(page, @max_page)
    else
      _other -> 1
    end
  end

  defp snapshot_at(params) do
    with value when is_binary(value) <- Map.get(params, @snapshot_param),
         id when is_binary(id) <- Map.get(params, @snapshot_id_param),
         {:ok, at, _offset} <- DateTime.from_iso8601(String.trim(value)),
         {:ok, id} <- Ecto.UUID.cast(String.trim(id)) do
      {at, id}
    else
      _other -> nil
    end
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
