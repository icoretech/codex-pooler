defmodule CodexPoolerWeb.Admin.RequestLogsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Accounting
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments, as: UpstreamAssignments
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.LiveUpdatesHooks
  alias CodexPoolerWeb.Admin.LogPagination
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.PoolFilterComponents
  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer
  alias CodexPoolerWeb.Admin.RequestLogFilterForm
  alias CodexPoolerWeb.Admin.RequestLogsDisplay
  alias CodexPoolerWeb.DateTimeDisplay

  import CodexPoolerWeb.Admin.RequestLogsPresentation

  import CodexPoolerWeb.Admin.RequestLogsPresentation.Filters,
    only: [request_log_filter_dropdown: 1]

  @page_size 50
  @request_logs_reload_debounce_ms 250
  @reload_telemetry_event [:codex_pooler, :admin, :request_logs, :reload]
  @selected_request_id_param "selected_request_id"
  @snapshot_param "as_of"
  @snapshot_id_param "as_of_id"

  # A page number arrives from the address bar, so it is attacker-shaped input,
  # not a bounded control: it becomes an OFFSET, and an OFFSET past int64 makes
  # the query raise inside handle_params, which kills the LiveView, which the
  # client answers by reconnecting to the same URL — a crash loop from one link.
  # The cap keeps the SQL legal and the scan bounded; a page past the real end
  # is then corrected against the total, so the cap is a backstop, not the
  # mechanism.
  @max_page 100_000

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
       datetime_preferences:
         DateTimeDisplay.preferences_for_user(socket.assigns.current_scope.user),
       pool_filter_options: [],
       model_filter_options: [],
       upstream_account_options: [],
       subscribed_pool_ids: MapSet.new(),
       request_logs_reload_timer: nil,
       request_logs_loaded?: false,
       request_logs_loading?: true,
       request_logs_generation: 0,
       request_logs_running?: false,
       request_logs_rerun?: false,
       request_logs_preparation: nil,
       visible_pool_ids: [],
       request_log_filters: %{},
       request_log_snapshot_at: nil,
       request_log_pin_at: nil,
       request_log_newer_count: 0,
       selected_request_log: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Opening or closing the detail drawer only changes the selection param;
    # the list, filter options, and counts are unaffected and must not be
    # rebuilt (each rebuild costs several queries over large tables).
    if socket.assigns[:request_logs_loaded?] &&
         same_list_params?(params, socket.assigns[:current_params]) do
      {:noreply,
       socket
       |> assign(:current_params, params)
       |> assign_selected_request_log(params)
       |> maybe_clear_missing_selected_request_log()}
    else
      {:noreply, request_request_logs(socket, params, :filter_patch)}
    end
  end

  defp same_list_params?(params, current_params) do
    Map.drop(params || %{}, [@selected_request_id_param]) ==
      Map.drop(current_params || %{}, [@selected_request_id_param])
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

  def handle_event("open_request_log", %{"request-id" => request_id}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/admin/request-logs?#{open_request_log_query_params(socket.assigns.current_params, request_id)}"
     )}
  end

  def handle_event("close_request_log", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/admin/request-logs?#{close_request_log_query_params(socket.assigns.current_params)}"
     )}
  end

  # Pausing is handled in front of this by LiveUpdatesHooks: a held event never
  # arrives here, and on resume it arrives exactly as it would have.
  @impl true
  def handle_info({Events, %{pool_id: pool_id, topics: topics}}, socket) do
    if "request_logs" in topics and request_log_event_in_scope?(socket, pool_id) do
      {:noreply, schedule_request_logs_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  # The debounce timer has fired by the time this arrives, so the assign must
  # stop naming it before anything else. Holding it while it still answers
  # `is_reference/1` makes every later `schedule_request_logs_refresh/1`
  # coalesce onto a timer that will never send.
  def handle_info(:refresh_request_logs_from_events, socket) do
    socket
    |> assign(:request_logs_reload_timer, nil)
    |> LiveUpdatesHooks.unless_paused(&request_request_logs_refresh/1)
  end

  def handle_info(:live_updates_resumed, socket) do
    {:noreply, request_request_logs_refresh(socket)}
  end

  @impl true
  def handle_async({:request_logs, generation}, {:ok, result}, socket) do
    socket = assign(socket, :request_logs_running?, false)

    if generation == socket.assigns.request_logs_generation do
      {:noreply, apply_request_logs_result(socket, result)}
    else
      {:noreply, maybe_start_pending_request_logs(socket)}
    end
  end

  def handle_async({:request_logs, generation}, {:exit, _reason}, socket) do
    socket = assign(socket, :request_logs_running?, false)

    if generation == socket.assigns.request_logs_generation do
      {:noreply,
       socket
       |> assign(request_logs_loading?: false, request_logs_rerun?: false)
       |> put_flash(:error, "request logs could not be loaded")}
    else
      {:noreply, maybe_start_pending_request_logs(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:request_logs}
      alert_notification_center={@alert_notification_center}
    >
      <div id="request-log-detail-drawer-root" class="drawer drawer-end">
        <input
          id="request-log-detail-drawer"
          type="checkbox"
          class="drawer-toggle"
          checked={@selected_request_log != nil}
        />

        <div class="drawer-content min-w-0">
          <section
            id="admin-request-logs-live"
            class="grid gap-6"
            aria-busy={to_string(@request_logs_loading?)}
          >
            <AdminComponents.page_header
              id="request-log-page-header"
              title="Request logs"
              description="Every request through the gateway: where it routed, how it ended, and what it cost."
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
                <AdminComponents.cally_date_filter
                  field={@filter_form[:date_from]}
                  label="Date from"
                />
                <AdminComponents.cally_date_filter
                  field={@filter_form[:date_to]}
                  label="Date to"
                />
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

            <.request_logs_table
              request_logs={@request_logs}
              loading?={@request_logs_loading?}
              loaded?={@request_logs_loaded?}
              datetime_preferences={@datetime_preferences}
              current_params={@current_params}
              pin_at={@request_log_pin_at}
              frozen?={@request_log_snapshot_at != nil}
              newer_count={@request_log_newer_count}
            />
          </section>
        </div>

        <RequestLogDetailDrawer.request_log_detail_drawer
          selected_request_log={@selected_request_log}
          datetime_preferences={@datetime_preferences}
        />
      </div>
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

  defp request_request_logs(socket, params, requested_stage) do
    stage =
      if socket.assigns.request_logs_loaded?, do: requested_stage, else: :initial_load

    generation = socket.assigns.request_logs_generation + 1
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
    visible_pool_ids = pool_ids(pools)
    snapshot_at = snapshot_at(params)

    preparation = %{
      selected_pool: selected_pool,
      filters: filters,
      visible_pool_ids: visible_pool_ids,
      snapshot_at: snapshot_at,
      offset: page_offset(params),
      params: params,
      stage: stage,
      current_request_logs: socket.assigns.request_logs,
      current_pin_at: socket.assigns.request_log_pin_at,
      scope: socket.assigns.current_scope,
      selected_request_id: selected_request_id(params),
      started_at: System.monotonic_time()
    }

    socket
    |> cancel_request_logs_reload_timer()
    |> maybe_subscribe_pool_events(pools, selected_pool)
    |> assign(
      pools: pools,
      selected_pool: selected_pool,
      current_params: params,
      filter_form:
        to_form(form_values,
          as: :filters,
          errors: RequestLogFilterForm.form_errors(filter_errors)
        ),
      filter_values: form_values,
      filter_errors: filter_errors,
      pool_filter_options: PoolFilterComponents.pool_filter_options(pools),
      upstream_account_options: upstream_account_options(upstream_filter_identities),
      visible_pool_ids: visible_pool_ids,
      request_log_filters: filters,
      request_log_snapshot_at: snapshot_at,
      request_logs_loading?: true,
      request_logs_generation: generation,
      request_logs_preparation: preparation
    )
    |> maybe_start_request_logs(generation)
  end

  defp request_request_logs_refresh(socket) do
    preparation = %{
      selected_pool: socket.assigns.selected_pool,
      filters: socket.assigns.request_log_filters,
      visible_pool_ids: socket.assigns.visible_pool_ids,
      snapshot_at: socket.assigns.request_log_snapshot_at,
      offset: 0,
      params: socket.assigns.current_params,
      stage: :event_refresh,
      current_request_logs: socket.assigns.request_logs,
      current_pin_at: socket.assigns.request_log_pin_at,
      scope: socket.assigns.current_scope,
      selected_request_id: selected_request_id(socket.assigns.current_params),
      started_at: System.monotonic_time()
    }

    generation = socket.assigns.request_logs_generation + 1

    socket
    |> cancel_request_logs_reload_timer()
    |> assign(
      request_logs_loading?: true,
      request_logs_generation: generation,
      request_logs_preparation: preparation
    )
    |> maybe_start_request_logs(generation)
  end

  defp maybe_start_request_logs(socket, generation) do
    if connected?(socket) and not socket.assigns.request_logs_running? do
      preparation = socket.assigns.request_logs_preparation

      socket
      |> assign(request_logs_running?: true, request_logs_rerun?: false)
      |> start_async({:request_logs, generation}, fn ->
        build_request_logs_result(preparation)
      end)
    else
      assign(socket, :request_logs_rerun?, connected?(socket))
    end
  end

  defp maybe_start_pending_request_logs(socket) do
    if socket.assigns.request_logs_rerun? do
      maybe_start_request_logs(socket, socket.assigns.request_logs_generation)
    else
      socket
    end
  end

  defp build_request_logs_result(preparation) do
    request_logs =
      case preparation do
        %{stage: :event_refresh, snapshot_at: %DateTime{}} ->
          preparation.current_request_logs

        _preparation ->
          request_logs(
            preparation.selected_pool,
            snapshot_filters(preparation.filters, preparation.snapshot_at),
            preparation.visible_pool_ids,
            preparation.offset
          )
      end

    pin_at =
      if preparation.stage == :event_refresh and not is_nil(preparation.snapshot_at) do
        preparation.current_pin_at
      else
        preparation.snapshot_at || newest_cursor(request_logs)
      end

    %{
      preparation: preparation,
      request_logs: request_logs,
      pin_at: pin_at,
      newer_count:
        newer_request_log_count(
          preparation.selected_pool,
          preparation.filters,
          preparation.visible_pool_ids,
          preparation.snapshot_at
        ),
      model_filter_models:
        request_log_models(preparation.selected_pool, preparation.visible_pool_ids),
      selected_request_log:
        selected_request_log(preparation.scope, preparation.selected_request_id)
    }
  end

  defp apply_request_logs_result(socket, result) do
    preparation = result.preparation
    current_selected_request_id = selected_request_id(socket.assigns.current_params)

    socket =
      socket
      |> assign(
        request_logs: result.request_logs,
        request_log_pin_at: result.pin_at,
        request_log_newer_count: result.newer_count,
        model_filter_options:
          model_filter_options(result.model_filter_models, socket.assigns.filter_values["model"]),
        request_logs_loading?: false,
        request_logs_loaded?: true,
        request_logs_rerun?: false
      )
      |> maybe_assign_async_selected_request_log(
        preparation.selected_request_id,
        current_selected_request_id,
        result.selected_request_log
      )
      |> notify_request_logs_reload(preparation.stage, preparation.started_at)
      |> normalize_request_log_window(
        preparation.params,
        result.request_logs,
        preparation.snapshot_at
      )

    if preparation.selected_request_id == current_selected_request_id do
      maybe_clear_missing_selected_request_log(socket)
    else
      socket
    end
  end

  defp maybe_assign_async_selected_request_log(socket, selected_id, selected_id, log),
    do: assign(socket, :selected_request_log, log)

  defp maybe_assign_async_selected_request_log(socket, _result_id, _current_id, _log), do: socket

  # Two invariants keep a paged window honest. Both are repaired by patching to
  # the URL that satisfies them, because the alternative is rendering a state
  # that cannot explain itself: a page past the end shows the "no request logs"
  # empty state while thousands match, and hides the pager that would let the
  # operator back out.
  #
  #   * a page past the end lands on the last page that has rows;
  #   * every page but the first is pinned, so no page behind the live one can
  #     shift while it is being read.
  #
  # The second is why the live refresh may rebuild from offset zero: past this
  # point, an unpinned window is always page one.
  defp normalize_request_log_window(socket, params, request_logs, snapshot_at) do
    %{total: total, limit: limit, offset: offset} = request_logs
    page = div(offset, limit) + 1
    last_page = LogPagination.last_page(request_logs)

    cond do
      # A pin names a window counted from a row. With no rows there is no such
      # window, and the way back is inside the pager, which an empty list does
      # not render — so a pinned empty result would be a frozen page with no
      # exit. Unpinning is the only state that can recover itself.
      total == 0 and (page > 1 or not is_nil(snapshot_at)) ->
        patch_request_log_window(socket, params, 1, nil)

      # A page number is an offset into a window. Without the cursor that window
      # was counted from it names nothing, and it cannot be repaired by pinning
      # here: the only cursor available is the head of the page just loaded, and
      # bounding the list there and then applying the same offset again lands
      # past where the operator asked, skipping every row in between. So a page
      # that arrives unpinned — a bookmark, a hand-edited URL — goes to the live
      # first page. Paging from page one always carries its pin, so this is the
      # stale-address case, not the ordinary one.
      page > 1 and is_nil(snapshot_at) ->
        patch_request_log_window(socket, params, 1, nil)

      page > last_page ->
        patch_request_log_window(socket, params, last_page, snapshot_at)

      true ->
        socket
    end
  end

  defp patch_request_log_window(socket, params, page, pin_at) do
    push_patch(socket,
      to: ~p"/admin/request-logs?#{request_log_window_params(params, page, pin_at)}"
    )
  end

  defp request_log_window_params(params, page, cursor) do
    {at, id} = cursor_params(page > 1 && cursor)

    params
    |> Map.drop(["page", @snapshot_param, @snapshot_id_param])
    |> put_window_param("page", page > 1 && Integer.to_string(page))
    |> put_window_param(@snapshot_param, at)
    |> put_window_param(@snapshot_id_param, id)
    |> normalize_request_log_query_params()
  end

  defp put_window_param(params, _key, falsy) when falsy in [nil, false], do: params
  defp put_window_param(params, key, value), do: Map.put(params, key, value)

  defp cursor_params({%DateTime{} = at, id}), do: {DateTime.to_iso8601(at), id}
  defp cursor_params(_cursor), do: {nil, nil}

  defp assign_selected_request_log(socket, params) do
    case selected_request_id(params) do
      nil ->
        assign(socket, :selected_request_log, nil)

      request_id ->
        assign(
          socket,
          :selected_request_log,
          Accounting.get_request_log_for_scope(socket.assigns.current_scope, request_id,
            surface: :admin
          )
        )
    end
  end

  defp selected_request_log(_scope, nil), do: nil

  defp selected_request_log(scope, request_id) do
    Accounting.get_request_log_for_scope(scope, request_id, surface: :admin)
  end

  defp maybe_clear_missing_selected_request_log(socket) do
    if selected_request_id(socket.assigns.current_params) &&
         is_nil(socket.assigns.selected_request_log) do
      push_patch(socket,
        to:
          ~p"/admin/request-logs?#{close_request_log_query_params(socket.assigns.current_params)}"
      )
    else
      socket
    end
  end

  defp selected_request_id(params) do
    params
    |> Map.get(@selected_request_id_param)
    |> case do
      value when is_binary(value) ->
        value = String.trim(value)
        if Ecto.UUID.cast(value) == {:ok, value}, do: value

      _value ->
        nil
    end
  end

  defp open_request_log_query_params(params, request_id) do
    params
    |> Map.put(@selected_request_id_param, request_id)
    |> normalize_request_log_query_params()
  end

  defp close_request_log_query_params(params) do
    params
    |> Map.delete(@selected_request_id_param)
    |> normalize_request_log_query_params()
  end

  defp normalize_request_log_query_params(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp request_logs(selected_pool, filters, visible_pool_ids, offset) do
    request_log_page(selected_pool, filters, visible_pool_ids,
      offset: offset,
      limit: @page_size
    )
  end

  defp request_log_page(selected_pool, filters, _visible_pool_ids, opts)
       when not is_nil(selected_pool) do
    Accounting.list_request_logs(selected_pool, [{:filters, filters} | opts])
  end

  defp request_log_page(_selected_pool, filters, visible_pool_ids, opts) do
    Accounting.list_request_logs(
      nil,
      [{:filters, filters}, {:visible_pool_ids, visible_pool_ids} | opts]
    )
  end

  # The pin is a cursor in the list's sort key, not a time: it is its own filter
  # and composes with the operator's date range by intersection, so nothing the
  # operator set has to be merged or overridden.
  defp snapshot_filters(filters, nil), do: filters
  defp snapshot_filters(filters, cursor), do: Keyword.put(filters, :at_or_before, cursor)

  # Counting arrivals uses the operator's own filters plus a lower bound at the
  # freeze, never the frozen upper bound — the two together select nothing.
  defp newer_request_log_count(_selected_pool, _filters, _visible_pool_ids, nil), do: 0

  defp newer_request_log_count(selected_pool, filters, visible_pool_ids, cursor) do
    # The complement of the pinned window, expressed in the same key, so the
    # count and the page cannot disagree about which side of the pin a row is
    # on. The operator's own filters are carried through untouched.
    filters = Keyword.put(filters, :after, cursor)

    # Only the total is wanted. The list query still costs its count, but asking
    # for one row instead of fifty keeps the join and the debug projection off
    # the debounce path; a count-only query in the facade is the real fix.
    %{total: total} =
      request_log_page(selected_pool, filters, visible_pool_ids, offset: 0, limit: 1)

    total
  end

  # The head of the page, as a cursor: the row itself, not the moment it landed.
  defp newest_cursor(%{items: [%{admitted_at: %DateTime{} = admitted_at, id: id} | _rest]}),
    do: {admitted_at, id}

  defp newest_cursor(_request_logs), do: nil

  defp snapshot_at(params) do
    with value when is_binary(value) <- Map.get(params, @snapshot_param),
         id when is_binary(id) <- Map.get(params, @snapshot_id_param),
         {:ok, snapshot_at, _offset} <- DateTime.from_iso8601(String.trim(value)),
         {:ok, id} <- Ecto.UUID.cast(String.trim(id)) do
      {snapshot_at, id}
    else
      _other -> nil
    end
  end

  # Pages are 1-based in the URL and become an offset here. Anything that is not
  # a positive integer reads as page 1 rather than as an error: a paging param
  # is navigation state, not a filter the operator typed.
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

  defp request_log_models(selected_pool, _visible_pool_ids) when not is_nil(selected_pool) do
    Accounting.list_request_log_models(selected_pool)
  end

  defp request_log_models(_selected_pool, visible_pool_ids) do
    Accounting.list_request_log_models(nil, visible_pool_ids: visible_pool_ids)
  end

  defp pool_ids(pools), do: Enum.map(pools, & &1.id)

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

  defp schedule_request_logs_refresh(socket) do
    if is_reference(socket.assigns[:request_logs_reload_timer]) do
      socket
    else
      timer =
        Process.send_after(
          self(),
          :refresh_request_logs_from_events,
          @request_logs_reload_debounce_ms
        )

      assign(socket, :request_logs_reload_timer, timer)
    end
  end

  defp cancel_request_logs_reload_timer(socket) do
    if is_reference(socket.assigns[:request_logs_reload_timer]) do
      Process.cancel_timer(socket.assigns.request_logs_reload_timer, async: false, info: false)
    end

    assign(socket, :request_logs_reload_timer, nil)
  end

  defp notify_request_logs_reload(socket, stage, started_at) do
    if connected?(socket) do
      :telemetry.execute(
        @reload_telemetry_event,
        %{count: 1, duration: System.monotonic_time() - started_at},
        %{stage: stage, scope: telemetry_scope(socket.assigns.selected_pool)}
      )
    end

    socket
  end

  defp telemetry_scope(nil), do: :all_pools
  defp telemetry_scope(_selected_pool), do: :selected_pool

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
      |> UpstreamAssignments.list_pool_assignments()
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
