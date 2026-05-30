defmodule CodexPoolerWeb.Admin.UpstreamCockpitLive do
  use CodexPoolerWeb, :live_view

  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonDialog
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonImport
  alias CodexPoolerWeb.Admin.UpstreamCockpitReadModel

  @type cockpit :: UpstreamCockpitReadModel.t()

  @impl true
  def mount(%{"id" => identity_id}, _session, socket) do
    socket =
      socket
      |> assign(
        cockpit: nil,
        page_title: "Upstream cockpit",
        refresh_data_message: nil,
        auth_json_form: UpstreamAuthJsonImport.empty_form(),
        auth_json_upload_limit_label: UpstreamAuthJsonImport.upload_limit_label(),
        dialog_pool_options: [],
        importing_auth_json: false,
        renaming_account: nil,
        rename_account_form: nil,
        deleting_account: nil,
        delete_account_form: delete_account_form(nil),
        subscribed_pool_ids: MapSet.new()
      )
      |> allow_upload(:auth_json,
        accept: ~w(.json),
        max_entries: 1,
        max_file_size: UpstreamAuthJsonImport.upload_limit_bytes(),
        chunk_size: 16_000,
        chunk_timeout: 5_000,
        auto_upload: true
      )

    case UpstreamCockpitReadModel.load_visible(socket.assigns.current_scope, identity_id) do
      {:ok, cockpit} ->
        {:ok, assign_cockpit(socket, cockpit)}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Upstream account was not found")
         |> redirect(to: ~p"/admin/upstreams")}
    end
  end

  @impl true
  def handle_info({Events, %{topics: topics, payload: payload}}, socket) do
    if "upstreams" in topics and upstream_event_in_scope?(socket, payload) do
      {:noreply, load_cockpit(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh_data", _params, socket) do
    {:noreply,
     socket |> load_cockpit() |> assign(:refresh_data_message, "Cockpit data refreshed")}
  end

  @impl true
  def handle_event("open_rename_account", %{"id" => identity_id}, socket) do
    if action_available?(socket, :rename, identity_id) do
      {:noreply,
       assign(socket,
         renaming_account: %{id: identity_id, label: socket.assigns.cockpit.header.title},
         rename_account_form: rename_account_form(socket.assigns.cockpit.header.title)
       )}
    else
      {:noreply, put_unavailable_action_error(socket, :rename)}
    end
  end

  def handle_event("cancel_rename_account", _params, socket) do
    {:noreply, close_rename_account_dialog(socket)}
  end

  def handle_event("validate_rename_account", %{"rename" => rename_params}, socket) do
    {:noreply,
     assign(
       socket,
       :rename_account_form,
       rename_account_form(current_label(socket), rename_params, :validate)
     )}
  end

  def handle_event("rename_account", %{"rename" => rename_params}, socket) do
    identity_id = socket.assigns.cockpit.identity.id

    case Upstreams.rename_account_for_scope(
           socket.assigns.current_scope,
           identity_id,
           rename_params
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Upstream account renamed")
         |> close_rename_account_dialog()
         |> load_cockpit()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :rename_account_form, Phoenix.Component.to_form(changeset, as: :rename))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("pause_account", %{"id" => identity_id}, socket) do
    lifecycle_action(
      socket,
      identity_id,
      :pause,
      &Upstreams.pause_account_for_scope/3,
      "Upstream account paused"
    )
  end

  def handle_event("reactivate_account", %{"id" => identity_id}, socket) do
    lifecycle_action(
      socket,
      identity_id,
      :reactivate,
      &Upstreams.reactivate_account_for_scope/3,
      "Upstream account reactivated"
    )
  end

  def handle_event("refresh_account", %{"id" => identity_id}, socket) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      action_available?(socket, :refresh_token, identity_id) ->
        enqueue_token_refresh(socket, identity_id)

      true ->
        {:noreply, put_unavailable_action_error(socket, :refresh_token)}
    end
  end

  def handle_event("open_import_auth_json", params, socket) do
    identity_id = Map.get(params, "id", socket.assigns.cockpit.identity.id)

    if action_available?(socket, :replace_auth_json, identity_id) do
      pool_id =
        Map.get(params, "pool-id") || Map.get(params, "pool_id") ||
          default_pool_id(socket.assigns.cockpit)

      {:noreply,
       socket
       |> cancel_auth_json_upload_entries()
       |> assign(
         importing_auth_json: true,
         auth_json_form: auth_json_form_for_pool(socket, pool_id)
       )}
    else
      {:noreply, put_unavailable_action_error(socket, :replace_auth_json)}
    end
  end

  def handle_event("cancel_import_auth_json", _params, socket) do
    {:noreply, close_auth_json_dialog(socket)}
  end

  def handle_event("validate_auth_json_import", %{"auth_json" => auth_json_params}, socket) do
    if UpstreamAuthJsonImport.content_present?(auth_json_params) do
      {:noreply, socket}
    else
      {:noreply,
       assign(
         socket,
         :auth_json_form,
         auth_json_form_for_pool(socket, auth_json_params["pool_id"])
       )}
    end
  end

  def handle_event("cancel_auth_json_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :auth_json, ref)}
  end

  def handle_event("import_auth_json", %{"auth_json" => auth_json_params}, socket) do
    pool = selected_pool(socket.assigns.current_scope, auth_json_params["pool_id"])

    case import_auth_json_content(socket, auth_json_params) do
      {:ok, content, socket} ->
        do_import_auth_json(socket, pool, auth_json_params, content)

      {:error, message, socket} ->
        {:noreply,
         socket
         |> put_flash(:error, "Codex auth.json could not be imported")
         |> assign(
           auth_json_form:
             UpstreamAuthJsonImport.form_with_error(
               auth_json_params["pool_id"],
               :content,
               message
             ),
           importing_auth_json: true
         )}
    end
  end

  def handle_event("open_delete_account", %{"id" => identity_id}, socket) do
    if action_available?(socket, :delete, identity_id) do
      account = %{id: identity_id, label: socket.assigns.cockpit.header.title}

      {:noreply,
       assign(socket,
         deleting_account: account,
         delete_account_form: delete_account_form(account)
       )}
    else
      {:noreply, put_unavailable_action_error(socket, :delete)}
    end
  end

  def handle_event("cancel_delete_account", _params, socket) do
    {:noreply, close_delete_account_dialog(socket)}
  end

  def handle_event("confirm_delete_account", %{"upstream_delete" => delete_params}, socket) do
    case validate_delete_confirmation(socket.assigns.deleting_account, delete_params) do
      :ok ->
        identity_id = socket.assigns.cockpit.identity.id

        case Upstreams.soft_delete_account_for_scope(socket.assigns.current_scope, identity_id, %{
               reason: "admin_upstream_cockpit_live"
             }) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> put_flash(:info, "Upstream account deleted")
             |> close_delete_account_dialog()
             |> redirect(to: ~p"/admin/upstreams")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end

      {:error, form} ->
        {:noreply, assign(socket, :delete_account_form, form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell flash={@flash} current_scope={@current_scope} active_nav={:upstreams}>
      <section id="upstream-cockpit" class="grid gap-6">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <.link
            id="upstream-cockpit-back-link"
            navigate={~p"/admin/upstreams"}
            class="btn btn-ghost btn-sm gap-2"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            <span>Upstreams</span>
          </.link>
        </div>

        <UpstreamAuthJsonDialog.auth_json_import_dialog
          auth_json_form={@auth_json_form}
          importing_auth_json={@importing_auth_json}
          pool_options={@dialog_pool_options}
          upload={@uploads.auth_json}
          upload_limit_label={@auth_json_upload_limit_label}
        />

        <.rename_account_dialog account={@renaming_account} form={@rename_account_form} />
        <.delete_account_dialog account={@deleting_account} form={@delete_account_form} />

        <AdminComponents.page_header
          id="upstream-cockpit-header"
          eyebrow="Upstream cockpit"
          title={@cockpit.header.title}
          description="Identity-scoped operational cockpit with redacted account state, assignment posture, chart placeholders, recent event summary, and safe cross-links."
        >
          <:actions>
            <span
              id="upstream-cockpit-safe-account-id"
              class="badge badge-outline max-w-full break-all font-mono"
            >
              {@cockpit.header.safe_account_id_label}
            </span>
            <span class={status_badge_class(@cockpit.header.status)}>
              {@cockpit.header.status_label}
            </span>
            <span :if={@cockpit.header.plan_reported?} class="badge badge-outline">
              {@cockpit.header.plan_label}
            </span>
          </:actions>
        </AdminComponents.page_header>

        <AdminComponents.metric_strip id="upstream-status-summary" compact_mobile={true}>
          <AdminComponents.metric_card
            id="upstream-status-summary-identity"
            icon="hero-signal"
            label="Identity state"
            value={identity_state_label(@cockpit)}
            description={@cockpit.header.safe_account_id_label}
            tone={identity_state_tone(@cockpit)}
            compact_mobile={true}
          />
          <AdminComponents.metric_card
            id="upstream-status-summary-quota"
            icon="hero-chart-bar-square"
            label="Quota posture"
            value={quota_summary_label(@cockpit.charts.quota_health)}
            description={quota_summary_description(@cockpit.charts.quota_health)}
            tone={quota_summary_tone(@cockpit.charts.quota_health)}
            compact_mobile={true}
          />
          <AdminComponents.metric_card
            id="upstream-status-summary-requests"
            icon="hero-arrow-path-rounded-square"
            label="Request posture"
            value={request_summary_label(@cockpit.charts.request_health)}
            description={request_summary_description(@cockpit.charts.request_health)}
            tone={request_summary_tone(@cockpit.charts.request_health)}
            compact_mobile={true}
          />
          <div
            id="upstream-status-summary-details"
            class="col-span-full flex min-w-0 flex-wrap gap-2 rounded-box border border-base-300 bg-base-100 p-3"
          >
            <span
              :for={detail <- status_summary_details(@cockpit)}
              id={detail.id}
              class={detail.class}
            >
              {detail.label}
            </span>
          </div>
        </AdminComponents.metric_strip>

        <AdminComponents.admin_surface
          id="upstream-assignments"
          title="Pool assignments"
          description="Pools currently linked to this upstream account."
          count={pluralize_count(@cockpit.assignments.count, "assignment", "assignments")}
        >
          <div :if={@cockpit.assignments.empty?} class="p-4">
            <AdminComponents.empty_state
              id="upstream-assignments-empty"
              title="No Pool assignments"
              description="This upstream account is visible but is not assigned to a Pool yet."
              icon="hero-link-slash"
            />
          </div>
          <div :if={!@cockpit.assignments.empty?} class="divide-y divide-base-300/70">
            <article
              :for={assignment <- @cockpit.assignments.items}
              id={"upstream-assignment-#{assignment.id}"}
              class="grid gap-3 p-4 md:grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)_auto] md:items-center"
            >
              <div class="grid min-w-0 gap-1">
                <h3 class="break-words text-sm font-semibold text-base-content">
                  {assignment.assignment_label}
                </h3>
                <.link
                  id={"upstream-assignment-#{assignment.id}-pool-link"}
                  navigate={~p"/admin/pools"}
                  class="break-words text-sm font-medium text-primary hover:underline"
                >
                  {assignment.pool_label}
                </.link>
              </div>
              <div class="flex flex-wrap gap-2">
                <span class={assignment_status_class(assignment.status)}>
                  {status_label("Assignment", assignment.status)}
                </span>
                <span class={assignment_status_class(assignment.health_status)}>
                  {status_label("Health", assignment.health_status)}
                </span>
                <span class={assignment_status_class(assignment.eligibility_status)}>
                  {status_label("Routing", assignment.eligibility_status)}
                </span>
                <span class={assignment_status_class(assignment.quota_priming_status)}>
                  {assignment.quota_priming_label}
                </span>
                <span
                  :if={quota_item = quota_item_for(@cockpit, assignment)}
                  class={assignment_status_class(quota_item.state)}
                >
                  {quota_assignment_label(quota_item)}
                </span>
                <span
                  :if={contribution_item = pool_contribution_item_for(@cockpit, assignment)}
                  class={assignment_status_class(contribution_item.assignment_state)}
                >
                  {contribution_item.assignment_state_label}
                </span>
              </div>
              <span class="text-xs font-semibold uppercase tracking-wide text-base-content/55">
                {assignment.quota_priming_label}
              </span>
            </article>
          </div>
        </AdminComponents.admin_surface>

        <AdminComponents.admin_surface
          id="quota-health-chart"
          title="Quota health"
          description="Assignment-scoped quota evidence rendered as deterministic bars."
          count={quota_chart_count(@cockpit.charts.quota_health)}
        >
          <.quota_health_chart chart={@cockpit.charts.quota_health} />
        </AdminComponents.admin_surface>

        <AdminComponents.admin_surface
          id="request-health-chart"
          title="Request health"
          description="Target-upstream request outcomes over the last seven days."
          count={request_chart_count(@cockpit.charts.request_health)}
        >
          <.request_health_chart chart={@cockpit.charts.request_health} />
        </AdminComponents.admin_surface>

        <AdminComponents.admin_surface
          id="pool-contribution-chart"
          title="Pool contribution"
          description="Successful request share across assigned Pools."
          count={pool_contribution_count(@cockpit.charts.pool_contribution)}
        >
          <.pool_contribution_chart chart={@cockpit.charts.pool_contribution} />
        </AdminComponents.admin_surface>

        <AdminComponents.admin_surface
          id="upstream-event-summary"
          title="Recent events"
          description="Metadata-only summary of recent request and audit activity for this upstream."
          count={pluralize_count(@cockpit.recent_events.count, "event", "events")}
        >
          <div class="grid gap-4 p-4">
            <p class="text-sm leading-6 text-base-content/70">
              {recent_events_description(@cockpit.recent_events)}
            </p>

            <div
              :if={@cockpit.recent_events.items != []}
              id="upstream-event-summary-rows"
              class="grid gap-3"
              role="list"
            >
              <article
                :for={event_row <- recent_event_rows(@cockpit.recent_events.items)}
                id={event_row.id}
                data-role="recent-event-row"
                class="grid gap-3 rounded-box border border-base-300 bg-base-200/45 p-3 md:grid-cols-[auto_minmax(0,1fr)_auto] md:items-center"
                role="listitem"
              >
                <div class="flex items-start md:justify-center">
                  <span
                    data-role="recent-event-source"
                    class={event_source_badge_class(event_row.event.source)}
                  >
                    {event_source_label(event_row.event.source)}
                  </span>
                </div>
                <div class="grid min-w-0 gap-1">
                  <h3
                    data-role="recent-event-title"
                    class="break-words text-sm font-semibold text-base-content"
                  >
                    {event_row.event.title}
                  </h3>
                  <p
                    data-role="recent-event-subtitle"
                    class="break-words text-xs leading-5 text-base-content/65"
                  >
                    {event_row.event.subtitle}
                  </p>
                  <time
                    data-role="recent-event-timestamp"
                    datetime={DateTime.to_iso8601(event_row.event.timestamp)}
                    class="text-xs font-medium text-base-content/55"
                  >
                    {format_event_timestamp(event_row.event.timestamp)}
                  </time>
                </div>
                <.link
                  data-role="recent-event-link"
                  href={event_row.event.link}
                  class="btn btn-ghost btn-xs justify-self-start gap-2 md:justify-self-end"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
                  <span>Open evidence</span>
                </.link>
              </article>
            </div>

            <AdminComponents.empty_state
              :if={@cockpit.recent_events.items == []}
              id="upstream-event-summary-empty"
              title="No recent upstream events"
              description="Request and audit activity for this upstream account will appear here when the read model projects compact metadata events."
              icon="hero-clipboard-document-list"
            />
          </div>
          <:footer>
            <div class="flex flex-col gap-3 text-sm text-base-content/65 md:flex-row md:items-center md:justify-between">
              <p>
                For manual audit filtering, use upstream identity id <span class="font-mono">{@cockpit.identity.id}</span>.
              </p>
              <div class="flex flex-wrap gap-2">
                <.link
                  id="upstream-event-summary-request-logs-link"
                  href={request_logs_path(@cockpit)}
                  class="btn btn-secondary btn-xs gap-2"
                >
                  <.icon name="hero-document-magnifying-glass" class="size-3.5" />
                  <span>Filtered request logs</span>
                </.link>
                <.link
                  id="upstream-event-summary-audit-logs-link"
                  href={audit_logs_path(@cockpit)}
                  class="btn btn-secondary btn-xs gap-2"
                >
                  <.icon name="hero-clipboard-document-list" class="size-3.5" />
                  <span>Audit logs</span>
                </.link>
              </div>
            </div>
          </:footer>
        </AdminComponents.admin_surface>

        <AdminComponents.admin_surface
          id="upstream-actions"
          title="Available actions"
          description="Bounded operator actions reuse the upstream account workflows and refresh this cockpit after successful mutations."
        >
          <div class="grid gap-3 p-4 sm:grid-cols-2 xl:grid-cols-3">
            <.cockpit_action_button
              id={"cockpit-rename-upstream-account-#{@cockpit.identity.id}"}
              label="Rename"
              icon="hero-pencil-square"
              action={@cockpit.actions.rename}
              phx-click="open_rename_account"
              phx-value-id={@cockpit.identity.id}
            />
            <.cockpit_action_button
              id={"cockpit-pause-upstream-account-#{@cockpit.identity.id}"}
              label="Pause"
              icon="hero-pause"
              action={@cockpit.actions.pause}
              variant={:warning}
              phx-click="pause_account"
              phx-value-id={@cockpit.identity.id}
            />
            <.cockpit_action_button
              id={"cockpit-reactivate-upstream-account-#{@cockpit.identity.id}"}
              label="Reactivate"
              icon="hero-play"
              action={@cockpit.actions.reactivate}
              variant={:positive}
              phx-click="reactivate_account"
              phx-value-id={@cockpit.identity.id}
            />
            <.cockpit_action_button
              id={"cockpit-refresh-upstream-account-#{@cockpit.identity.id}"}
              label="Refresh token"
              icon="hero-arrow-path"
              action={@cockpit.actions.refresh_token}
              phx-click="refresh_account"
              phx-value-id={@cockpit.identity.id}
            />
            <.cockpit_action_button
              id={"cockpit-replace-auth-json-upstream-account-#{@cockpit.identity.id}"}
              label="Replace auth.json"
              icon="hero-document-arrow-up"
              action={@cockpit.actions.replace_auth_json}
              phx-click="open_import_auth_json"
              phx-value-id={@cockpit.identity.id}
              phx-value-pool-id={default_pool_id(@cockpit)}
            />
            <.cockpit_reinvite_link cockpit={@cockpit} />
            <.cockpit_action_button
              id={"cockpit-delete-upstream-account-#{@cockpit.identity.id}"}
              label="Delete"
              icon="hero-trash"
              action={@cockpit.actions.delete}
              variant={:danger}
              phx-click="open_delete_account"
              phx-value-id={@cockpit.identity.id}
            />
          </div>
          <:footer>
            <p class="text-sm text-base-content/65">
              Assignment and Pool changes stay on linked admin pages; this cockpit only mutates the upstream identity lifecycle and credentials.
            </p>
          </:footer>
        </AdminComponents.admin_surface>

        <AdminComponents.admin_surface
          id="upstream-related-links"
          title="Related admin pages"
          description="Use linked admin pages for full request and audit evidence."
        >
          <div class="flex flex-wrap gap-2 p-4">
            <.link
              href={request_logs_path(@cockpit)}
              class="btn btn-secondary btn-sm gap-2"
            >
              <.icon name="hero-document-magnifying-glass" class="size-4" />
              <span>Request logs</span>
            </.link>
            <.link
              href={audit_logs_path(@cockpit)}
              class="btn btn-secondary btn-sm gap-2"
            >
              <.icon name="hero-clipboard-document-list" class="size-4" />
              <span>Audit logs</span>
            </.link>
          </div>
        </AdminComponents.admin_surface>

        <section
          id="upstream-refresh-data"
          class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p class="text-xs font-semibold uppercase tracking-wide text-primary">Refresh data</p>
              <h2 class="mt-1 text-lg font-semibold text-base-content">Refresh cockpit data</h2>
              <p class="mt-2 max-w-3xl text-sm leading-6 text-base-content/65">
                Quota and upstream lifecycle changes refresh automatically when scoped broadcasts are available. Request health, recent events, and contribution metrics refresh only when this cockpit is reloaded.
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <span class="badge badge-outline">refresh {@cockpit.header.refresh_status}</span>
              <AdminComponents.action_button
                id="upstream-refresh-data-button"
                icon="hero-arrow-path"
                label="Refresh cockpit data"
                phx-click="refresh_data"
                variant={:primary}
              />
            </div>
          </div>
          <p
            :if={@refresh_data_message}
            id="upstream-refresh-data-message"
            class="mt-3 rounded-box border border-success/30 bg-success/10 px-3 py-2 text-sm font-medium text-success"
          >
            {@refresh_data_message}
          </p>
          <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-2">
            <div>
              <dt class="text-xs font-semibold uppercase text-base-content/45">Auth imported</dt>
              <dd class="mt-1 text-base-content">{@cockpit.header.auth_fresh_label}</dd>
            </div>
            <div>
              <dt class="text-xs font-semibold uppercase text-base-content/45">Token refresh</dt>
              <dd class="mt-1 text-base-content">{@cockpit.header.token_refresh_label}</dd>
            </div>
          </dl>
        </section>
      </section>
    </AdminComponents.admin_shell>
    """
  end

  attr :account, :map, default: nil
  attr :form, :any, default: nil

  defp rename_account_dialog(assigns) do
    ~H"""
    <dialog :if={@account && @form} id="cockpit-rename-upstream-account-dialog" class="modal" open>
      <div class="modal-box max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">Upstream account</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Rename upstream account</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Update the operator label shown in this cockpit and on the upstream account list.
          </p>
        </div>
        <.form
          id="cockpit-rename-upstream-account-form"
          for={@form}
          phx-change="validate_rename_account"
          phx-submit="rename_account"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input field={@form[:account_label]} type="text" label="Label" required />
          <div class="modal-action mt-0">
            <AdminComponents.action_button
              id="cockpit-rename-upstream-account-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_rename_account"
            />
            <AdminComponents.action_button
              id="cockpit-rename-upstream-account-submit"
              icon="hero-pencil-square"
              label="Rename"
              type="submit"
              variant={:primary}
            />
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_rename_account">close</button>
      </form>
    </dialog>
    """
  end

  attr :account, :map, default: nil
  attr :form, :any, required: true

  defp delete_account_dialog(assigns) do
    ~H"""
    <dialog :if={@account} id="cockpit-delete-upstream-account-dialog" class="modal" open>
      <div class="modal-box max-w-xl border border-error/30 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-error/20 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">
            Delete upstream account
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Confirm upstream account deletion</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Type the account label exactly to remove this upstream account from operator routing surfaces.
          </p>
        </div>
        <.form
          id="cockpit-delete-upstream-account-form"
          for={@form}
          phx-submit="confirm_delete_account"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input field={@form[:id]} type="hidden" />
          <p class="rounded-box border border-base-300 bg-base-200/60 p-3 text-sm text-base-content/70">
            Confirmation label: <span class="font-semibold text-base-content">{@account.label}</span>
          </p>
          <.input
            field={@form[:confirmation_label]}
            type="text"
            label="Account label confirmation"
            placeholder={@account.label}
            required
          />
          <div class="modal-action mt-0">
            <AdminComponents.action_button
              id="cockpit-delete-upstream-account-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_delete_account"
            />
            <AdminComponents.action_button
              id="cockpit-delete-upstream-account-submit"
              icon="hero-trash"
              label="Delete"
              type="submit"
              variant={:danger}
            />
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_delete_account">close</button>
      </form>
    </dialog>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :action, :map, required: true
  attr :variant, :atom, default: :neutral
  attr :rest, :global, include: ~w(phx-click phx-value-id phx-value-pool-id)

  defp cockpit_action_button(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200/60 p-3">
      <div class="flex items-center justify-between gap-2">
        <AdminComponents.action_button
          id={@id}
          icon={@icon}
          label={@label}
          variant={@variant}
          disabled={!@action.available?}
          title={@action.reason}
          {@rest}
        />
        <span class={action_state_class(@action)}>{action_state_label(@action)}</span>
      </div>
      <p :if={!@action.available? && @action.reason} class="mt-2 text-xs text-base-content/60">
        {@action.reason}
      </p>
    </div>
    """
  end

  attr :cockpit, :map, required: true

  defp cockpit_reinvite_link(assigns) do
    assigns = assign(assigns, :path, reinvite_path(assigns.cockpit))

    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200/60 p-3">
      <div class="flex items-center justify-between gap-2">
        <AdminComponents.action_button
          :if={@path}
          id={"cockpit-reinvite-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-user-plus"
          label="Reinvite account"
          navigate={@path}
          disabled={!@cockpit.actions.reinvite.available?}
          title={@cockpit.actions.reinvite.reason}
        />
        <AdminComponents.action_button
          :if={!@path}
          id={"cockpit-reinvite-upstream-account-#{@cockpit.identity.id}"}
          icon="hero-user-plus"
          label="Reinvite account"
          disabled
          title={@cockpit.actions.reinvite.reason}
        />
        <span class={action_state_class(@cockpit.actions.reinvite)}>
          {action_state_label(@cockpit.actions.reinvite)}
        </span>
      </div>
      <p
        :if={!@cockpit.actions.reinvite.available? && @cockpit.actions.reinvite.reason}
        class="mt-2 text-xs text-base-content/60"
      >
        {@cockpit.actions.reinvite.reason}
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp kpi_value(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-200/60 p-3">
      <p class="text-xs font-semibold uppercase tracking-wide text-base-content/55">{@label}</p>
      <p class="mt-1 font-mono text-xl font-semibold tabular-nums text-base-content">{@value}</p>
    </div>
    """
  end

  attr :chart, :map, required: true

  defp quota_health_chart(assigns) do
    assigns = assign(assigns, :model, quota_health_chart_model(assigns.chart))

    ~H"""
    <div class="grid gap-4 p-4">
      <p class="text-sm leading-6 text-base-content/70">
        {quota_chart_description(@chart)}
      </p>
      <p id="quota-health-chart-summary" class="sr-only" data-role="chart-sr-summary">
        {@model.summary}
      </p>
      <div class="grid gap-2 sm:grid-cols-3">
        <.kpi_value label="Routing usable" value={@chart.kpis.routing_usable_count} />
        <.kpi_value label="Stale or missing" value={@chart.kpis.stale_or_missing_count} />
        <.kpi_value label="Exhausted" value={@chart.kpis.exhausted_count} />
      </div>
      <div
        id="quota-health-chart-bars"
        data-chart="quota-health"
        data-chart-state={@chart.state}
        data-chart-total={@chart.kpis.assignment_count}
        data-chart-routing-usable={@chart.kpis.routing_usable_count}
        data-chart-degraded={@chart.degraded?}
        data-chart-colors={@model.colors}
        class="grid gap-3"
        role="list"
        aria-describedby="quota-health-chart-summary"
      >
        <article
          :for={item <- @model.items}
          id={"quota-health-chart-item-#{item.assignment_id}"}
          data-role="chart-bar-row"
          data-chart-value={item.bar_value}
          data-chart-state={item.state}
          class="grid gap-2 rounded-box border border-base-300 bg-base-200/45 p-3"
          role="listitem"
        >
          <div class="flex flex-wrap items-start justify-between gap-2">
            <div class="min-w-0">
              <h3 class="break-words text-sm font-semibold text-base-content">
                {item.assignment_label}
              </h3>
              <p class="break-words text-xs leading-5 text-base-content/60">{item.pool_label}</p>
            </div>
            <span class={assignment_status_class(item.state)}>{item.state_label}</span>
          </div>
          <progress
            id={"quota-health-chart-item-#{item.assignment_id}-bar"}
            class={quota_chart_progress_class(item.state)}
            value={item.bar_value}
            max="100"
            aria-label={item.aria_label}
          >
            {item.bar_label}
          </progress>
          <p class="text-xs leading-5 text-base-content/65">{item.supporting_label}</p>
        </article>
        <p :if={@model.items == []} class="text-sm leading-6 text-base-content/65">
          No Pool assignments are available for quota charting.
        </p>
      </div>
    </div>
    """
  end

  attr :chart, :map, required: true

  defp request_health_chart(assigns) do
    assigns = assign(assigns, :model, request_health_chart_model(assigns.chart))

    ~H"""
    <div class="grid gap-4 p-4">
      <p class="text-sm leading-6 text-base-content/70">
        {request_chart_description(@chart)}
      </p>
      <div class="grid gap-2 sm:grid-cols-4">
        <.kpi_value label="24h requests" value={@chart.kpis.total_requests_24h} />
        <.kpi_value label="24h failed" value={@chart.kpis.failed_requests_24h} />
        <.kpi_value label="Failure rate" value={@model.failure_rate_label} />
        <.kpi_value label="7d requests" value={@chart.kpis.total_requests_7d} />
      </div>
      <div
        id="request-health-chart-plot"
        class="admin-apex-bar-chart min-h-56 w-full"
        phx-hook="ApexTimeSeriesChart"
        phx-update="ignore"
        role="img"
        aria-labelledby="request-health-chart-title request-health-chart-summary"
        data-chart="request-health"
        data-chart-state={@chart.state}
        data-chart-total={@chart.kpis.total_requests_7d}
        data-chart-categories={@model.categories}
        data-chart-series={@model.series}
        data-chart-unit="requests"
        data-chart-units={@model.units}
        data-chart-yaxis={@model.yaxis}
        data-chart-height="220"
        data-chart-colors={@model.colors}
        data-chart-labels="true"
      >
      </div>
      <p id="request-health-chart-title" class="sr-only">Request health</p>
      <p id="request-health-chart-summary" class="sr-only" data-role="chart-sr-summary">
        {@model.summary}
      </p>
      <ul class="sr-only">
        <li :for={point <- @model.points}>
          {point.label}: {point.success_count} succeeded, {point.failure_count} failed, {point.total_count} total requests
        </li>
      </ul>
      <p class="text-xs leading-5 text-base-content/60">
        Failure rate {@model.failure_rate_label} across the last 24h; seven-day total {@model.total_label}.
      </p>
      <p class="text-xs leading-5 text-base-content/60">
        Request health, recent events, and contribution metrics refresh only when this cockpit is reloaded.
      </p>
    </div>
    """
  end

  attr :chart, :map, required: true

  defp pool_contribution_chart(assigns) do
    assigns = assign(assigns, :model, pool_contribution_chart_model(assigns.chart))

    ~H"""
    <div class="grid gap-4 p-4">
      <p class="text-sm leading-6 text-base-content/70">
        {pool_contribution_description(@chart)}
      </p>
      <p id="pool-contribution-chart-summary" class="sr-only" data-role="chart-sr-summary">
        {@model.summary}
      </p>
      <div class="grid gap-2 sm:grid-cols-4">
        <.kpi_value label="Assignments" value={@chart.kpis.assignment_count} />
        <.kpi_value label="Active" value={@chart.kpis.active_assignment_count} />
        <.kpi_value label="Disabled" value={@chart.kpis.disabled_assignment_count} />
        <.kpi_value label="7d successes" value={@chart.kpis.successful_requests_7d} />
      </div>
      <div
        id="pool-contribution-chart-bars"
        data-chart="pool-contribution"
        data-chart-state={@chart.state}
        data-chart-total={@chart.kpis.successful_requests_7d}
        data-chart-active={@chart.kpis.active_assignment_count}
        data-chart-disabled={@chart.kpis.disabled_assignment_count}
        data-chart-colors={@model.colors}
        class="grid gap-3"
        role="list"
        aria-describedby="pool-contribution-chart-summary"
      >
        <article
          :for={item <- @model.items}
          id={"pool-contribution-chart-item-#{item.assignment_id}"}
          data-role="chart-bar-row"
          data-chart-value={item.bar_value}
          data-chart-state={item.assignment_state}
          class="grid gap-2 rounded-box border border-base-300 bg-base-200/45 p-3"
          role="listitem"
        >
          <div class="flex flex-wrap items-start justify-between gap-2">
            <div class="min-w-0">
              <h3 class="break-words text-sm font-semibold text-base-content">{item.pool_label}</h3>
              <p class="break-words text-xs leading-5 text-base-content/60">
                {item.assignment_label}
              </p>
            </div>
            <span class={assignment_status_class(item.assignment_state)}>
              {item.assignment_state_label}
            </span>
          </div>
          <progress
            id={"pool-contribution-chart-item-#{item.assignment_id}-bar"}
            class={pool_contribution_progress_class(item.assignment_state)}
            value={item.bar_value}
            max="100"
            aria-label={item.aria_label}
          >
            {item.share_label}
          </progress>
          <p class="text-xs leading-5 text-base-content/65">{item.supporting_label}</p>
        </article>
        <p :if={@model.items == []} class="text-sm leading-6 text-base-content/65">
          No Pool assignments are available for contribution charting.
        </p>
      </div>
    </div>
    """
  end

  defp enqueue_token_refresh(socket, identity_id) do
    case Upstreams.enqueue_token_refresh_for_scope(socket.assigns.current_scope, identity_id,
           trigger_kind: "admin_upstream_cockpit_live"
         ) do
      {:ok, %{job: job}} ->
        message =
          if job.conflict?, do: "Token refresh is already queued", else: "Token refresh queued"

        {:noreply, socket |> put_flash(:info, message) |> load_cockpit()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp lifecycle_action(socket, identity_id, action_key, operation, success_message) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      action_available?(socket, action_key, identity_id) ->
        case operation.(socket.assigns.current_scope, identity_id, %{
               reason: "admin_upstream_cockpit_live"
             }) do
          {:ok, _result} ->
            {:noreply, socket |> put_flash(:info, success_message) |> load_cockpit()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, error_message(reason))}
        end

      true ->
        {:noreply, put_unavailable_action_error(socket, action_key)}
    end
  end

  defp load_cockpit(socket) do
    case UpstreamCockpitReadModel.load_visible(
           socket.assigns.current_scope,
           socket.assigns.cockpit.identity.id
         ) do
      {:ok, cockpit} ->
        assign_cockpit(socket, cockpit)

      :error ->
        socket
        |> put_flash(:error, "Upstream account was not found")
        |> redirect(to: ~p"/admin/upstreams")
    end
  end

  defp assign_cockpit(socket, cockpit) do
    socket
    |> maybe_subscribe_pool_events(cockpit)
    |> assign(
      cockpit: cockpit,
      dialog_pool_options: dialog_pool_options(socket.assigns.current_scope)
    )
  end

  defp maybe_subscribe_pool_events(socket, cockpit) do
    cockpit.assignments.items
    |> Enum.map(&%{id: &1.pool_id})
    |> PoolEventSubscriptions.pool_id_set()
    |> then(fn target_pool_ids ->
      {socket, _stale_pool_ids} = PoolEventSubscriptions.reconcile(socket, target_pool_ids)
      socket
    end)
  end

  defp upstream_event_in_scope?(socket, payload) do
    payload_upstream_identity_id(payload) == socket.assigns.cockpit.identity.id
  end

  defp payload_upstream_identity_id(%{"upstream_identity_id" => identity_id})
       when is_binary(identity_id),
       do: identity_id

  defp payload_upstream_identity_id(%{upstream_identity_id: identity_id})
       when is_binary(identity_id),
       do: identity_id

  defp payload_upstream_identity_id(_payload), do: nil

  defp action_available?(socket, action_key, identity_id) do
    cockpit = socket.assigns.cockpit

    identity_id == cockpit.identity.id and
      cockpit.actions |> Map.fetch!(action_key) |> Map.fetch!(:available?)
  end

  defp put_unavailable_action_error(socket, action_key) do
    action = Map.fetch!(socket.assigns.cockpit.actions, action_key)
    reason = action.reason || "action is unavailable"
    put_flash(socket, :error, "#{action_label(action_key)} is not available: #{reason}")
  end

  defp action_label(:replace_auth_json), do: "Replace auth.json"
  defp action_label(:refresh_token), do: "Refresh token"

  defp action_label(action_key),
    do: action_key |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp current_label(socket), do: socket.assigns.cockpit.header.title

  defp rename_account_form(label, attrs \\ %{}, action \\ nil) do
    data = %{account_label: label}

    {%{}, %{account_label: :string}}
    |> Ecto.Changeset.cast(Map.merge(data, attrs), [:account_label])
    |> Ecto.Changeset.validate_required([:account_label])
    |> Map.put(:action, action)
    |> Phoenix.Component.to_form(as: :rename)
  end

  defp close_rename_account_dialog(socket) do
    assign(socket, renaming_account: nil, rename_account_form: nil)
  end

  defp close_delete_account_dialog(socket) do
    assign(socket, deleting_account: nil, delete_account_form: delete_account_form(nil))
  end

  defp delete_account_form(nil) do
    Phoenix.Component.to_form(%{"id" => "", "confirmation_label" => ""}, as: :upstream_delete)
  end

  defp delete_account_form(%{id: id}) do
    Phoenix.Component.to_form(%{"id" => id, "confirmation_label" => ""}, as: :upstream_delete)
  end

  defp validate_delete_confirmation(%{id: id, label: label}, %{
         "id" => id,
         "confirmation_label" => confirmation
       }) do
    if String.trim(to_string(confirmation)) == label do
      :ok
    else
      {:error, delete_account_error_form(id, "type the account label exactly")}
    end
  end

  defp validate_delete_confirmation(%{id: id}, _params),
    do: {:error, delete_account_error_form(id, "type the account label exactly")}

  defp validate_delete_confirmation(nil, _params),
    do: {:error, delete_account_error_form("", "account was not selected")}

  defp delete_account_error_form(id, message) do
    data = %{id: id || "", confirmation_label: ""}

    {%{}, %{id: :string, confirmation_label: :string}}
    |> Ecto.Changeset.cast(data, [:id, :confirmation_label])
    |> Ecto.Changeset.add_error(:confirmation_label, message)
    |> Map.put(:action, :validate)
    |> Phoenix.Component.to_form(as: :upstream_delete)
  end

  defp auth_json_form_for_pool(socket, pool_id) do
    pool_id =
      if selected_pool(socket.assigns.current_scope, pool_id),
        do: pool_id,
        else: default_pool_id(socket.assigns.cockpit)

    UpstreamAuthJsonImport.form_for_pool(pool_id)
  end

  defp selected_pool(scope, pool_id) when is_binary(pool_id) do
    scope
    |> Pools.list_visible_pools()
    |> Enum.find(&(&1.id == pool_id))
  end

  defp selected_pool(_scope, _pool_id), do: nil

  defp dialog_pool_options(scope) do
    scope
    |> Pools.list_visible_pools()
    |> Enum.map(&{&1.name, &1.id})
    |> case do
      [] -> [{"No active Pools available", ""}]
      options -> options
    end
  end

  defp default_pool_id(%{assignments: %{items: [%{pool_id: pool_id} | _items]}}), do: pool_id
  defp default_pool_id(_cockpit), do: nil

  defp reinvite_path(cockpit) do
    pool_id = default_pool_id(cockpit)

    if cockpit.actions.reinvite.available? and is_binary(pool_id) do
      ~p"/admin/invites?#{%{create: "1", pool_id: pool_id}}"
    end
  end

  defp import_auth_json_content(socket, auth_json_params) do
    {completed_upload_entries, in_progress_upload_entries} = uploaded_entries(socket, :auth_json)
    upload_errors = UpstreamAuthJsonImport.upload_error_messages(socket.assigns.uploads.auth_json)

    case UpstreamAuthJsonImport.content_source(
           auth_json_params,
           completed_upload_entries,
           in_progress_upload_entries,
           upload_errors
         ) do
      {:ok, {:paste, content}} ->
        {:ok, content, socket}

      {:ok, :upload} ->
        consume_auth_json_upload(socket)

      {:error, message, :cancel_uploads} ->
        {:error, message, cancel_auth_json_upload_entries(socket)}

      {:error, message, :keep_uploads} ->
        {:error, message, socket}
    end
  end

  defp consume_auth_json_upload(socket) do
    case consume_uploaded_entries(socket, :auth_json, fn %{path: path}, _entry ->
           UpstreamAuthJsonImport.read_upload(path)
         end) do
      [content] when is_binary(content) ->
        if byte_size(content) <= UpstreamAuthJsonImport.upload_limit_bytes() do
          {:ok, content, socket}
        else
          {:error, "File must be #{UpstreamAuthJsonImport.upload_limit_label()} or smaller",
           socket}
        end

      [] ->
        {:error, "Paste auth.json or upload one .json file", socket}

      _entries ->
        {:error, "Uploaded auth.json could not be read", socket}
    end
  end

  defp cancel_auth_json_upload_entries(socket) do
    Enum.reduce(socket.assigns.uploads.auth_json.entries, socket, fn entry, socket ->
      cancel_upload(socket, :auth_json, entry.ref)
    end)
  end

  defp close_auth_json_dialog(socket) do
    socket
    |> cancel_auth_json_upload_entries()
    |> assign(importing_auth_json: false, auth_json_form: UpstreamAuthJsonImport.empty_form())
  end

  defp do_import_auth_json(socket, pool, auth_json_params, content) do
    case Upstreams.import_codex_auth_json(socket.assigns.current_scope, pool, content) do
      {:ok, %{status: :created}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Codex auth.json imported")
         |> close_auth_json_dialog()
         |> load_cockpit()}

      {:ok, %{status: :existing}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Codex auth.json matched an existing account; tokens updated")
         |> close_auth_json_dialog()
         |> load_cockpit()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Codex auth.json could not be imported")
         |> assign(
           importing_auth_json: true,
           auth_json_form: Phoenix.Component.to_form(changeset, as: :auth_json)
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(
           importing_auth_json: true,
           auth_json_form: UpstreamAuthJsonImport.form_for_pool(auth_json_params["pool_id"])
         )}
    end
  end

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_reason), do: "Operation failed"

  defp identity_state_label(%{flags: %{disabled_identity?: true}}), do: "Identity disabled"
  defp identity_state_label(%{flags: %{reauth_required?: true}}), do: "Reauth required"
  defp identity_state_label(%{header: %{status: "active"}}), do: "Identity active"
  defp identity_state_label(%{header: %{status: status}}), do: status_label("Identity", status)

  defp identity_state_tone(%{flags: %{disabled_identity?: true}}), do: :warning
  defp identity_state_tone(%{flags: %{reauth_required?: true}}), do: :error
  defp identity_state_tone(%{header: %{status: status}}) when status in ["active"], do: :success
  defp identity_state_tone(_cockpit), do: :warning

  defp status_summary_details(cockpit) do
    [
      detail("identity-detail", identity_state_label(cockpit), cockpit.header.status),
      optional_detail("plan", plan_status_label(cockpit), "active"),
      detail(
        "auth-verified",
        auth_verified_summary_label(cockpit.header.auth_verified_label),
        "active"
      ),
      detail("access-token", cockpit.header.access_token_label, token_detail_status(cockpit)),
      detail("token-refresh", cockpit.header.token_refresh_label, cockpit.header.refresh_status),
      detail("quota-refresh", "Quota refresh #{cockpit.header.quota_refresh_status}", "active"),
      detail(
        "quota-state-detail",
        quota_status_detail_label(cockpit.charts.quota_health),
        cockpit.charts.quota_health.state
      ),
      optional_detail("reauth-code", cockpit.header.reauth_reason_code, "reauth_required"),
      optional_detail("reauth-message", cockpit.header.reauth_reason_message, "reauth_required")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp detail(id, label, status) do
    %{id: "upstream-status-summary-#{id}", label: label, class: assignment_status_class(status)}
  end

  defp optional_detail(_id, nil, _status), do: nil
  defp optional_detail(_id, "", _status), do: nil
  defp optional_detail(id, label, status), do: detail(id, label, status)

  defp plan_status_label(%{header: %{plan_reported?: true, plan_label: plan_label}}),
    do: "Plan #{plan_label}"

  defp plan_status_label(_cockpit), do: nil

  defp token_detail_status(%{header: %{access_token_label: label}}) do
    if String.contains?(label, "expired"), do: "expired", else: "active"
  end

  defp quota_status_detail_label(%{state: "missing_evidence"}), do: "Quota missing"
  defp quota_status_detail_label(%{state: "stale"}), do: "Quota refresh needed"
  defp quota_status_detail_label(%{state: state}), do: status_label("Quota", state)

  defp quota_summary_label(%{state: "missing_evidence"}), do: "Quota evidence is missing"
  defp quota_summary_label(%{state: "weekly_only"}), do: "Weekly-only quota"
  defp quota_summary_label(%{state: state}), do: humanize_state(state)

  defp quota_summary_description(%{kpis: kpis}) do
    "#{kpis.routing_usable_count} routing usable, #{kpis.stale_or_missing_count} stale or missing"
  end

  defp quota_summary_tone(%{missing?: true}), do: :warning
  defp quota_summary_tone(%{degraded?: true}), do: :warning
  defp quota_summary_tone(_quota), do: :success

  defp request_summary_label(%{state: "empty"}), do: "No request traffic"
  defp request_summary_label(%{state: state}), do: humanize_state(state)

  defp request_summary_description(%{kpis: kpis}) do
    "#{kpis.total_requests_24h} requests and #{kpis.failed_requests_24h} failures in 24h"
  end

  defp request_summary_tone(%{state: "failed"}), do: :error
  defp request_summary_tone(%{degraded?: true}), do: :warning
  defp request_summary_tone(_request_health), do: :success

  defp quota_chart_count(%{kpis: kpis}),
    do: pluralize_count(kpis.assignment_count, "assignment", "assignments")

  defp quota_chart_description(%{state: "missing_evidence"}) do
    "Quota evidence is missing for this upstream assignment."
  end

  defp quota_chart_description(%{state: state, kpis: kpis}) do
    "Quota projection is #{humanize_state(state)} across #{pluralize_count(kpis.assignment_count, "assignment", "assignments")}."
  end

  defp request_chart_count(%{kpis: kpis}),
    do: pluralize_count(kpis.total_requests_7d, "request", "requests")

  defp request_chart_description(%{state: "empty"}) do
    "No request traffic has reached this upstream in the last 7 days."
  end

  defp request_chart_description(%{state: state, kpis: kpis}) do
    "Request posture is #{humanize_state(state)} with #{pluralize_count(kpis.total_requests_7d, "request", "requests")} in the last 7 days."
  end

  defp pool_contribution_count(%{kpis: kpis}),
    do: pluralize_count(kpis.assignment_count, "Pool", "Pools")

  defp pool_contribution_description(%{state: "no_successful_requests"}) do
    "No successful request contribution is recorded for assigned Pools in the last 7 days."
  end

  defp pool_contribution_description(%{state: state, kpis: kpis}) do
    "Pool contribution is #{humanize_state(state)} with #{pluralize_count(kpis.successful_requests_7d, "successful request", "successful requests")} in the last 7 days."
  end

  defp quota_health_chart_model(chart) do
    items = Enum.map(chart.items, &quota_health_chart_item/1)

    %{
      items: items,
      colors:
        Jason.encode!(["var(--color-success)", "var(--color-warning)", "var(--color-error)"]),
      summary:
        "#{pluralize_count(chart.kpis.assignment_count, "assignment", "assignments")}; #{chart.kpis.routing_usable_count} routing usable; #{chart.kpis.stale_or_missing_count} stale or missing; #{chart.kpis.exhausted_count} exhausted."
    }
  end

  defp quota_health_chart_item(item) do
    bar_value = chart_value(item.bar_value)

    item
    |> Map.put(:bar_value, chart_value_label(bar_value))
    |> Map.put(:bar_label, percent_label(bar_value))
    |> Map.put(:aria_label, quota_item_aria_label(item, bar_value))
    |> Map.put(:supporting_label, quota_item_supporting_label(item))
  end

  defp quota_item_aria_label(item, bar_value) do
    "#{item.assignment_label}: #{item.state_label}, #{percent_label(bar_value)} available"
  end

  defp quota_item_supporting_label(%{state: "missing_evidence"}), do: "No current quota evidence"

  defp quota_item_supporting_label(%{reset_at: %DateTime{} = reset_at} = item) do
    [
      item.remaining_percent_value && "#{percent_label(item.remaining_percent_value)} remaining",
      item.used_percent_value && "#{percent_label(item.used_percent_value)} used",
      "resets #{format_reset_at(reset_at)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp quota_item_supporting_label(item) do
    item.reason_codes
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "Quota pressure unknown"
      reason_codes -> "Reasons: #{Enum.join(reason_codes, ", ")}"
    end
  end

  defp request_health_chart_model(chart) do
    points = Enum.map(chart.items, &request_health_point/1)
    success_values = Enum.map(points, & &1.success_count)
    failure_values = Enum.map(points, & &1.failure_count)

    %{
      points: points,
      categories: Jason.encode!(Enum.map(points, & &1.label)),
      series:
        Jason.encode!([
          %{name: "Succeeded", type: "column", data: success_values},
          %{name: "Failed", type: "column", data: failure_values}
        ]),
      units: Jason.encode!(["requests", "failures"]),
      yaxis: Jason.encode!([%{seriesName: "Succeeded", title: "requests"}]),
      colors: Jason.encode!(["var(--color-success)", "var(--color-error)"]),
      failure_rate_label: rate_percent_label(chart.kpis.failure_rate_24h),
      total_label: pluralize_count(chart.kpis.total_requests_7d, "request", "requests"),
      summary:
        "#{pluralize_count(chart.kpis.total_requests_7d, "request", "requests")} over seven days; #{chart.kpis.total_requests_7d} total requests; #{chart.kpis.failed_requests_24h} failed in the last 24h; failure rate #{rate_percent_label(chart.kpis.failure_rate_24h)}."
    }
  end

  defp request_health_point(item) do
    %{
      label: chart_date_label(item.date),
      success_count: item.success_count,
      failure_count: item.failure_count,
      total_count: item.total_count
    }
  end

  defp pool_contribution_chart_model(chart) do
    items = Enum.map(chart.items, &pool_contribution_chart_item/1)

    %{
      items: items,
      colors: Jason.encode!(["var(--color-primary)", "var(--color-base-300)"]),
      summary:
        "#{pluralize_count(chart.kpis.successful_requests_7d, "successful request", "successful requests")} over seven days across #{pluralize_count(chart.kpis.assignment_count, "assignment", "assignments")}."
    }
  end

  defp pool_contribution_chart_item(item) do
    bar_value = chart_value(item.bar_value)
    success_count = item.successful_request_count_7d

    item
    |> Map.put(:bar_value, chart_value_label(bar_value))
    |> Map.put(:share_label, percent_label(bar_value))
    |> Map.put(
      :supporting_label,
      "#{pluralize_count(success_count, "success", "successes")} · #{percent_label(bar_value)} of target-upstream successes"
    )
    |> Map.put(
      :aria_label,
      "#{item.pool_label}: #{pluralize_count(success_count, "success", "successes")}, #{percent_label(bar_value)} share"
    )
  end

  defp quota_chart_progress_class("fresh"),
    do: "progress progress-success w-full admin-live-progress"

  defp quota_chart_progress_class("weekly_only"),
    do: "progress progress-info w-full admin-live-progress"

  defp quota_chart_progress_class("exhausted"),
    do: "progress progress-error w-full admin-live-progress"

  defp quota_chart_progress_class(_state),
    do: "progress progress-warning w-full admin-live-progress"

  defp pool_contribution_progress_class("active"),
    do: "progress progress-primary w-full admin-live-progress"

  defp pool_contribution_progress_class(_state),
    do: "progress w-full admin-live-progress"

  defp chart_value(nil), do: 0.0
  defp chart_value(value) when is_integer(value), do: chart_value(value * 1.0)
  defp chart_value(value) when is_float(value), do: value |> max(0.0) |> min(100.0)

  defp chart_value_label(value), do: value |> compact_float() |> String.replace_suffix(".0", "")

  defp rate_percent_label(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 1) <> "%"

  defp rate_percent_label(value) when is_integer(value), do: rate_percent_label(value * 1.0)

  defp percent_label(nil), do: "0%"
  defp percent_label(value) when is_integer(value), do: percent_label(value * 1.0)
  defp percent_label(value) when is_float(value), do: "#{compact_float(value)}%"

  defp chart_date_label(
         <<_year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>>
       ),
       do: month <> "-" <> day

  defp chart_date_label(date), do: to_string(date)

  defp format_reset_at(%DateTime{} = reset_at),
    do: Calendar.strftime(reset_at, "%b %-d, %H:%M UTC")

  defp compact_float(value) when is_float(value) do
    decimals = if value < 10 and value != Float.round(value, 0), do: 2, else: 1

    value
    |> Float.round(decimals)
    |> :erlang.float_to_binary(decimals: decimals)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""

  defp recent_events_description(%{empty?: true}), do: "No recent upstream events"

  defp recent_events_description(%{count: count, degraded?: true}) do
    "#{pluralize_count(count, "recent event", "recent events")} need operator review."
  end

  defp recent_events_description(%{count: count}) do
    "#{pluralize_count(count, "recent event", "recent events")} are available on linked evidence pages."
  end

  defp recent_event_rows(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} ->
      %{id: "upstream-event-summary-row-#{index}", event: event}
    end)
  end

  defp event_source_label("request_log"), do: "request log"
  defp event_source_label("audit_log"), do: "audit log"
  defp event_source_label(source), do: source |> status_text() |> String.downcase()

  defp event_source_badge_class("request_log"), do: "badge badge-info badge-sm"
  defp event_source_badge_class("audit_log"), do: "badge badge-primary badge-sm"
  defp event_source_badge_class(_source), do: "badge badge-neutral badge-sm"

  defp format_event_timestamp(%DateTime{} = timestamp),
    do: Calendar.strftime(timestamp, "%Y-%m-%d %H:%M UTC")

  defp request_logs_path(cockpit),
    do: ~p"/admin/request-logs?upstream_identity_id=#{cockpit.identity.id}"

  defp audit_logs_path(cockpit), do: ~p"/admin/audit-logs?target=#{cockpit.identity.id}"

  defp assignment_status_class(status), do: AdminBadges.status_chip_class(status)

  defp status_label(prefix, status) do
    "#{prefix} #{status_text(status)}"
  end

  defp status_text(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
  end

  defp auth_verified_summary_label("auth verified not reported"), do: "Never verified"
  defp auth_verified_summary_label(label), do: sentence_label(label)

  defp sentence_label(label) when is_binary(label) do
    case String.split_at(label, 1) do
      {first, rest} -> String.upcase(first) <> rest
    end
  end

  defp sentence_label(label), do: label

  defp quota_item_for(cockpit, assignment) do
    Enum.find(cockpit.charts.quota_health.items, &(&1.assignment_id == assignment.id))
  end

  defp pool_contribution_item_for(cockpit, assignment) do
    Enum.find(cockpit.charts.pool_contribution.items, &(&1.assignment_id == assignment.id))
  end

  defp quota_assignment_label(%{state: "missing_evidence"}), do: "Quota missing"
  defp quota_assignment_label(%{state: "stale"}), do: "Quota refresh needed"
  defp quota_assignment_label(%{state: state}), do: status_label("Quota", state)

  defp status_badge_class("active"), do: "badge badge-success"
  defp status_badge_class("disabled"), do: "badge badge-warning"
  defp status_badge_class("reauth_required"), do: "badge badge-error"
  defp status_badge_class(_status), do: "badge badge-neutral"

  defp action_state_label(%{available?: true}), do: "available"
  defp action_state_label(_action), do: "not available"

  defp action_state_class(%{available?: true}), do: "badge badge-success"
  defp action_state_class(_action), do: "badge badge-neutral"

  defp humanize_state(state) do
    state
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp pluralize_count(1, singular, _plural), do: "1 #{singular}"
  defp pluralize_count(count, _singular, plural), do: "#{count || 0} #{plural}"
end
