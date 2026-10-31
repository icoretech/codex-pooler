defmodule CodexPoolerWeb.Admin.UpstreamCockpitLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Accounting
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams.OAuth, as: UpstreamOAuth
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.LiveUpdatesHooks
  alias CodexPoolerWeb.Admin.NotificationCenterHooks
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.ProviderCreditsWorkflow
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetOperationProjection
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonImport
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents
  alias CodexPoolerWeb.Admin.UpstreamCockpitLive.AccountLifecycleWorkflow
  alias CodexPoolerWeb.Admin.UpstreamCockpitLive.AuthJsonImportWorkflow
  alias CodexPoolerWeb.Admin.UpstreamCockpitLive.OAuthRelinkWorkflow
  alias CodexPoolerWeb.Admin.UpstreamCockpitLive.SavedResetWorkflow
  alias CodexPoolerWeb.Admin.UpstreamCockpitReadModel
  alias CodexPoolerWeb.Admin.UpstreamsLive.WorkflowError
  alias CodexPoolerWeb.DateTimeDisplay

  @saved_reset_status_interval_ms 5_000

  @type cockpit :: UpstreamCockpitReadModel.t()

  @impl true
  def mount(%{"id" => identity_id}, _session, socket) do
    socket =
      socket
      |> assign(
        cockpit: nil,
        page_title: gettext("Upstream health"),
        refresh_data_message: nil,
        auth_json_form: UpstreamAuthJsonImport.empty_form(),
        auth_json_upload_limit_label: UpstreamAuthJsonImport.upload_limit_label(),
        dialog_pool_options: [],
        importing_auth_json: false,
        oauth_relinking: false,
        oauth_relink_form: OAuthRelinkWorkflow.form(),
        oauth_relink_flow: nil,
        oauth_relink_authorization_url: nil,
        oauth_relink_result: nil,
        oauth_relink_error: nil,
        oauth_relink_poll_timer: nil,
        renaming_account: nil,
        rename_account_form: nil,
        deleting_account: nil,
        delete_account_form: AccountLifecycleWorkflow.delete_form(nil),
        saved_reset_policy_form: SavedResetWorkflow.policy_form(%{}),
        saved_reset_policy_dirty?: false,
        confirming_saved_reset_redemption: nil,
        selected_request_log: nil,
        subscribed_pool_ids: MapSet.new(),
        cockpit_metrics_generation: 0,
        cockpit_metrics_loaded?: false,
        cockpit_metrics_loading?: true,
        cockpit_metrics_running?: false,
        cockpit_metrics_rerun?: false,
        saved_reset_status_generation: 0,
        saved_reset_status_running: nil,
        saved_reset_status_rerun?: false,
        saved_reset_status_force?: false,
        saved_reset_status_timer: nil,
        saved_reset_status_timer_token: nil
      )
      |> assign(ProviderCreditsWorkflow.initial_assigns())
      |> allow_upload(:auth_json,
        accept: ~w(.json),
        max_entries: 1,
        max_file_size: UpstreamAuthJsonImport.upload_limit_bytes(),
        chunk_size: 16_000,
        chunk_timeout: 5_000,
        auto_upload: true
      )
      |> NotificationCenterHooks.follow_viewer_visibility()

    case UpstreamCockpitReadModel.load_visible_without_request_metrics(
           socket.assigns.current_scope,
           identity_id
         ) do
      {:ok, cockpit} ->
        {:ok, socket |> assign_cockpit(cockpit) |> request_cockpit_metrics()}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Upstream account was not found"))
         |> redirect(to: ~p"/admin/upstreams")}
    end
  end

  @impl true
  def handle_info({Events, %{topics: topics, reason: "upstream_account_provider_credits_policy_updated", payload: payload}}, socket) do
    if "upstreams" in topics and upstream_event_in_scope?(socket, payload), do: {:noreply, request_saved_reset_status(socket)}, else: {:noreply, socket}
  end

  def handle_info({Events, %{topics: topics, payload: payload} = event}, socket) do
    if "upstreams" in topics and upstream_event_in_scope?(socket, payload) do
      {:noreply, refresh_for_upstream_event(socket, event)}
    else
      {:noreply, socket}
    end
  end

  # The pause gate collapses held events by pool and topics, which is coarser
  # than the identity check above: a sibling identity's event in the same pool
  # can overwrite this one's. The gate says so instead of guessing, and the only
  # honest answer from here is to reload.
  def handle_info(:live_updates_resumed, socket) do
    {:noreply, request_saved_reset_status(socket)}
  end

  # A role change or a Pool granted or revoked changes which of this account's
  # Pool assignments, request data and dialog Pools the viewer may see. The
  # page re-reads them at once, even behind the quota observations, closes an
  # auth.json or OAuth relink dialog that offered a Pool the viewer lost and a
  # request it can no longer see, and leaves for the account list when the
  # account itself is no longer visible (findings#206 row 206-410).
  def handle_info({NotificationCenterHooks, :viewer_visibility_changed}, %{assigns: %{cockpit: nil}} = socket), do: {:noreply, socket}

  def handle_info({NotificationCenterHooks, :viewer_visibility_changed}, socket) do
    socket = invalidate_saved_reset_status(socket)
    scope = socket.assigns.current_scope

    case UpstreamCockpitReadModel.load_visible_without_request_metrics(scope, socket.assigns.cockpit.identity.id) do
      {:ok, cockpit} ->
        {socket, closed?} = close_lost_dialogs(socket, scope)

        socket =
          socket
          |> assign_cockpit(preserve_request_metrics(socket, cockpit))
          |> request_cockpit_metrics()

        {:noreply, if(closed?, do: put_flash(socket, :info, gettext("Your Pool access changed")), else: socket)}

      :error ->
        {:noreply,
         socket
         |> clear_inaccessible_cockpit()
         |> put_flash(:info, gettext("Your Pool access changed"))
         |> push_navigate(to: ~p"/admin/upstreams")}
    end
  end

  def handle_info({:saved_reset_status_tick, token}, socket) do
    if token == socket.assigns.saved_reset_status_timer_token do
      socket = assign(socket, saved_reset_status_timer: nil, saved_reset_status_timer_token: nil)
      {:noreply, socket |> request_saved_reset_status() |> schedule_saved_reset_status()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:poll_oauth_relink_device, flow_id}, socket) do
    {:noreply, OAuthRelinkWorkflow.poll_device(socket, flow_id, &refresh_oauth_flow_state/1)}
  end

  @impl true
  def handle_event("open_quota_observations", _params, socket),
    do: {:noreply, socket |> assign(:quota_observations_open?, true) |> schedule_saved_reset_status()}

  def handle_event("close_quota_observations", _params, socket),
    do: {:noreply, socket |> assign(:quota_observations_open?, false) |> schedule_saved_reset_status()}

  def handle_event("refresh_saved_reset_status", %{"id" => identity_id}, socket) do
    if socket.assigns.cockpit && identity_id == socket.assigns.cockpit.identity.id do
      {:noreply, request_saved_reset_status(socket, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("refresh_saved_reset_status", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_request_log", %{"request-id" => request_id}, socket) do
    {:noreply, assign(socket, :selected_request_log, load_request_log(socket, request_id))}
  end

  def handle_event("close_request_log", _params, socket) do
    {:noreply, assign(socket, :selected_request_log, nil)}
  end

  def handle_event("refresh_data", _params, socket) do
    {:noreply,
     socket
     |> load_cockpit()
     |> assign(:refresh_data_message, gettext("Account data refreshed"))}
  end

  @impl true
  def handle_event("open_rename_account", %{"id" => identity_id}, socket) do
    {:noreply, socket |> ProviderCreditsWorkflow.close() |> AccountLifecycleWorkflow.open_rename(identity_id)}
  end

  def handle_event("cancel_rename_account", _params, socket) do
    {:noreply, AccountLifecycleWorkflow.close_rename(socket)}
  end

  def handle_event("validate_rename_account", %{"rename" => rename_params}, socket) do
    {:noreply, AccountLifecycleWorkflow.validate_rename(socket, rename_params)}
  end

  def handle_event("rename_account", %{"rename" => rename_params}, socket) do
    {:noreply, AccountLifecycleWorkflow.rename(socket, rename_params, &load_cockpit/1)}
  end

  def handle_event("pause_account", %{"id" => identity_id}, socket) do
    {:noreply, AccountLifecycleWorkflow.pause(socket, identity_id, &load_cockpit/1)}
  end

  def handle_event("reactivate_account", %{"id" => identity_id}, socket) do
    {:noreply, AccountLifecycleWorkflow.reactivate(socket, identity_id, &load_cockpit/1)}
  end

  def handle_event("refresh_account", %{"id" => identity_id}, socket) do
    {:noreply, AccountLifecycleWorkflow.refresh(socket, identity_id, &load_cockpit/1)}
  end

  def handle_event("open_import_auth_json", params, socket) do
    identity_id = Map.get(params, "id", socket.assigns.cockpit.identity.id)

    if action_available?(socket, :replace_auth_json, identity_id) do
      pool_id =
        Map.get(params, "pool-id") || Map.get(params, "pool_id") ||
          default_pool_id(socket.assigns.cockpit)

      {:noreply, socket |> ProviderCreditsWorkflow.close() |> AuthJsonImportWorkflow.open(pool_id)}
    else
      {:noreply, put_unavailable_action_error(socket, :replace_auth_json)}
    end
  end

  def handle_event("cancel_import_auth_json", _params, socket) do
    {:noreply, AuthJsonImportWorkflow.close(socket)}
  end

  def handle_event("open_oauth_relink", %{"id" => identity_id}, socket) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        {:noreply, put_flash(socket, :error, gettext("Upstream account was not found"))}

      action_available?(socket, :oauth_relink, identity_id) ->
        {:noreply,
         socket
         |> AuthJsonImportWorkflow.close()
         |> AccountLifecycleWorkflow.close_rename()
         |> AccountLifecycleWorkflow.close_delete()
         |> OAuthRelinkWorkflow.close()
         |> SavedResetWorkflow.close_redemption_confirmation()
         |> ProviderCreditsWorkflow.close()
         |> OAuthRelinkWorkflow.open()}

      true ->
        {:noreply, put_unavailable_action_error(socket, :oauth_relink)}
    end
  end

  def handle_event("start_oauth_relink_browser", _params, socket) do
    {:noreply,
     OAuthRelinkWorkflow.start_browser(
       socket,
       default_relink_pool(socket),
       &refresh_oauth_flow_state/1
     )}
  end

  def handle_event("start_oauth_relink_device", _params, socket) do
    {:noreply,
     OAuthRelinkWorkflow.start_device(
       socket,
       default_relink_pool(socket),
       &refresh_oauth_flow_state/1
     )}
  end

  def handle_event("submit_oauth_relink_callback", %{"oauth_relink" => oauth_params}, socket) do
    {:noreply, OAuthRelinkWorkflow.submit_callback(socket, oauth_params, &load_cockpit/1)}
  end

  def handle_event("cancel_oauth_relink", _params, socket) do
    {:noreply, OAuthRelinkWorkflow.cancel(socket, &refresh_oauth_flow_state/1)}
  end

  # Cancels a pending flow discovered from the DB (the relink card), unlike
  # the dialog's cancel which only knows the flow this session started.
  def handle_event("cancel_pending_oauth_flow", %{"id" => flow_id}, socket) do
    if pending_cockpit_flow?(socket, flow_id) do
      case UpstreamOAuth.cancel_oauth_flow(socket.assigns.current_scope, flow_id) do
        {:ok, _flow} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("OAuth relink flow cancelled"))
           |> load_cockpit()}

        {:error, reason} when is_map(reason) ->
          {:noreply, put_flash(socket, :error, gettext("Could not cancel OAuth flow: %{reason}", reason: WorkflowError.message(reason)))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("OAuth flow was not found"))}
    end
  end

  def handle_event("validate_auth_json_import", %{"auth_json" => auth_json_params}, socket) do
    {:noreply, AuthJsonImportWorkflow.validate(socket, auth_json_params)}
  end

  def handle_event("cancel_auth_json_upload", %{"ref" => ref}, socket) do
    {:noreply, AuthJsonImportWorkflow.cancel_upload_entry(socket, ref)}
  end

  def handle_event("import_auth_json", %{"auth_json" => auth_json_params}, socket) do
    pool = selected_pool(socket.assigns.current_scope, auth_json_params["pool_id"])

    {:noreply, AuthJsonImportWorkflow.import(socket, auth_json_params, pool, &load_cockpit/1)}
  end

  def handle_event("open_delete_account", %{"id" => identity_id}, socket) do
    {:noreply, socket |> ProviderCreditsWorkflow.close() |> AccountLifecycleWorkflow.open_delete(identity_id)}
  end

  def handle_event("cancel_delete_account", _params, socket) do
    {:noreply, AccountLifecycleWorkflow.close_delete(socket)}
  end

  def handle_event("confirm_delete_account", %{"upstream_delete" => delete_params}, socket) do
    {:noreply,
     AccountLifecycleWorkflow.confirm_delete(socket, delete_params, fn socket ->
       redirect(socket, to: ~p"/admin/upstreams")
     end)}
  end

  def handle_event("open_provider_credits_policy", _params, socket) do
    socket = socket |> AuthJsonImportWorkflow.close() |> OAuthRelinkWorkflow.close() |> AccountLifecycleWorkflow.close_rename() |> AccountLifecycleWorkflow.close_delete() |> SavedResetWorkflow.close_redemption_confirmation() |> load_cockpit()
    {:noreply, ProviderCreditsWorkflow.open(socket, socket.assigns.cockpit)}
  end

  def handle_event("cancel_provider_credits_policy", _params, socket), do: {:noreply, ProviderCreditsWorkflow.close(socket)}

  def handle_event("validate_provider_credits_policy", params, socket) do
    {:noreply, ProviderCreditsWorkflow.validate(socket, Map.get(params, "provider_credits_policy"))}
  end

  def handle_event("save_provider_credits_policy", params, socket) do
    {:noreply, ProviderCreditsWorkflow.save(socket, Map.get(params, "provider_credits_policy"), &load_cockpit/1)}
  end

  def handle_event("validate_saved_reset_policy", %{"saved_reset_policy" => params}, socket) do
    {:noreply,
     assign(socket,
       saved_reset_policy_form: Phoenix.Component.to_form(params, as: :saved_reset_policy),
       saved_reset_policy_dirty?: true
     )}
  end

  def handle_event("save_saved_reset_policy", %{"saved_reset_policy" => params}, socket) do
    {:noreply,
     socket
     |> assign(:saved_reset_policy_dirty?, false)
     |> SavedResetWorkflow.save_policy(params, &load_cockpit/1)}
  end

  def handle_event(
        "open_saved_reset_redemption_confirmation",
        %{"id" => identity_id} = params,
        socket
      ) do
    pool_id = Map.get(params, "pool-id") || Map.get(params, "pool_id")

    {:noreply, SavedResetWorkflow.open_redemption_confirmation(socket, identity_id, pool_id)}
  end

  def handle_event("cancel_saved_reset_redemption", _params, socket) do
    {:noreply, SavedResetWorkflow.close_redemption_confirmation(socket)}
  end

  def handle_event("redeem_saved_reset", %{"id" => identity_id} = params, socket) do
    pool_id = Map.get(params, "pool-id") || Map.get(params, "pool_id")

    {:noreply, SavedResetWorkflow.redeem(socket, identity_id, pool_id, &load_cockpit/1)}
  end

  @impl true
  def handle_async({:saved_reset_status, token}, {:ok, result}, socket) do
    if socket.assigns.saved_reset_status_running == token do
      current? = status_token_current?(socket, token)
      socket = assign(socket, :saved_reset_status_running, nil)
      socket = if current?, do: apply_saved_reset_status(socket, result, token), else: socket
      {:noreply, finish_saved_reset_status(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:saved_reset_status, token}, {:exit, _reason}, socket) do
    if socket.assigns.saved_reset_status_running == token do
      socket = assign(socket, :saved_reset_status_running, nil)
      {:noreply, finish_saved_reset_status(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:cockpit_metrics, generation}, {:ok, metrics}, socket) do
    socket = assign(socket, cockpit_metrics_running?: false)

    if is_nil(socket.assigns.cockpit) do
      {:noreply, socket}
    else
      if generation == socket.assigns.cockpit_metrics_generation do
        {:noreply,
         socket
         |> assign(cockpit_metrics_loaded?: true, cockpit_metrics_loading?: false)
         |> merge_cockpit_deferred_data(metrics)
         |> maybe_restart_cockpit_metrics()}
      else
        {:noreply, start_cockpit_metrics_task(socket, socket.assigns.cockpit_metrics_generation)}
      end
    end
  end

  def handle_async({:cockpit_metrics, generation}, {:exit, _reason}, socket) do
    socket = assign(socket, cockpit_metrics_running?: false)

    if is_nil(socket.assigns.cockpit) do
      {:noreply, socket}
    else
      if generation == socket.assigns.cockpit_metrics_generation do
        {:noreply,
         socket
         |> assign(:cockpit_metrics_loading?, false)
         |> put_flash(:error, gettext("Could not refresh request metrics"))
         |> maybe_restart_cockpit_metrics()}
      else
        {:noreply, start_cockpit_metrics_task(socket, socket.assigns.cockpit_metrics_generation)}
      end
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if is_reference(socket.assigns[:saved_reset_status_timer]), do: Process.cancel_timer(socket.assigns.saved_reset_status_timer)
    :ok
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
      locale={@locale}
      locale_preference={@locale_preference}
      active_nav={:upstreams}
      alert_notification_center={@alert_notification_center}
      openai_status_aggregate={@openai_status_aggregate}
    >
      <UpstreamCockpitComponents.cockpit_page
        :if={@cockpit}
        cockpit={present_saved_reset_status(assigns)}
        auth_json_form={@auth_json_form}
        auth_json_upload_limit_label={@auth_json_upload_limit_label}
        dialog_pool_options={@dialog_pool_options}
        importing_auth_json={@importing_auth_json}
        oauth_relinking={@oauth_relinking}
        oauth_relink_form={@oauth_relink_form}
        oauth_relink_flow={@oauth_relink_flow}
        oauth_relink_authorization_url={@oauth_relink_authorization_url}
        oauth_relink_result={@oauth_relink_result}
        oauth_relink_error={@oauth_relink_error}
        renaming_account={@renaming_account}
        rename_account_form={@rename_account_form}
        deleting_account={@deleting_account}
        delete_account_form={@delete_account_form}
        saved_reset_policy_form={@saved_reset_policy_form}
        editing_provider_credits_policy={@editing_provider_credits_policy}
        provider_credits_policy_form={@provider_credits_policy_form}
        confirming_saved_reset_redemption={@confirming_saved_reset_redemption}
        selected_request_log={@selected_request_log}
        refresh_data_message={@refresh_data_message}
        request_metrics_loaded?={@cockpit_metrics_loaded?}
        request_metrics_loading?={@cockpit_metrics_loading?}
        request_metrics_running?={@cockpit_metrics_running?}
        uploads={@uploads}
        datetime_preferences={@datetime_preferences}
      />
    </AdminComponents.admin_shell>
    """
  end

  # Same scope-checked loader the request logs page uses for its drawer; the
  # admin surface includes the debug projection.
  defp load_request_log(socket, request_id) do
    Accounting.get_request_log_for_scope(socket.assigns.current_scope, request_id, surface: :admin)
  end

  defp default_relink_pool(socket) do
    selected_pool(socket.assigns.current_scope, default_pool_id(socket.assigns.cockpit))
  end

  defp load_cockpit(socket) do
    socket = invalidate_saved_reset_status(socket)

    case UpstreamCockpitReadModel.load_visible_without_request_metrics(
           socket.assigns.current_scope,
           socket.assigns.cockpit.identity.id
         ) do
      {:ok, cockpit} ->
        socket
        |> assign_cockpit(preserve_request_metrics(socket, cockpit))
        |> request_cockpit_metrics()

      :error ->
        socket
        |> clear_inaccessible_cockpit()
        |> put_flash(:error, gettext("Upstream account was not found"))
        |> redirect(to: ~p"/admin/upstreams")
    end
  end

  # Status reads never request traffic metrics or contact the provider. Pool
  # events are the fast path; a single connected timer covers missed events.
  defp refresh_for_upstream_event(socket, event) do
    if event.reason == "request_metrics_updated", do: load_cockpit(socket), else: request_saved_reset_status(socket)
  end

  defp request_saved_reset_status(socket, force? \\ false) do
    cond do
      is_nil(socket.assigns.cockpit) or not connected?(socket) ->
        socket

      not force? and LiveUpdatesHooks.paused?(socket) ->
        LiveUpdatesHooks.hold(socket)

      socket.assigns.saved_reset_status_running != nil ->
        queue_saved_reset_status(socket, force?)

      true ->
        start_saved_reset_status(socket, force?)
    end
  end

  defp queue_saved_reset_status(socket, force?) do
    if force? and socket.assigns.saved_reset_status_running.force? do
      socket
    else
      assign(socket,
        saved_reset_status_generation: socket.assigns.saved_reset_status_generation + 1,
        saved_reset_status_rerun?: true,
        saved_reset_status_force?: socket.assigns.saved_reset_status_force? or force?
      )
    end
  end

  defp start_saved_reset_status(socket, force?) do
    scope = socket.assigns.current_scope
    identity_id = socket.assigns.cockpit.identity.id
    deletion_state = socket.assigns.cockpit.deletion_state
    locale = Gettext.get_locale()

    token = %{
      generation: socket.assigns.saved_reset_status_generation + 1,
      scope: scope_signature(scope),
      cursor: socket.assigns.cockpit.saved_reset_refresh_cursor,
      force?: force?
    }

    socket
    |> assign(saved_reset_status_generation: token.generation, saved_reset_status_running: token, saved_reset_status_rerun?: false, saved_reset_status_force?: false)
    |> start_async({:saved_reset_status, token}, fn ->
      Gettext.with_locale(locale, fn -> UpstreamCockpitReadModel.refresh_visible_status(scope, identity_id, deletion_state) end)
    end)
  end

  defp status_token_current?(socket, token) do
    socket.assigns.cockpit != nil and
      token.generation == socket.assigns.saved_reset_status_generation and
      token.scope == scope_signature(socket.assigns.current_scope) and
      token.cursor == socket.assigns.cockpit.saved_reset_refresh_cursor and
      (token.force? or not LiveUpdatesHooks.paused?(socket))
  end

  defp scope_signature(scope), do: {scope.user.id, scope.roles, scope.assigned_pool_ids}

  defp apply_saved_reset_status(socket, {:ok, cockpit}, token) do
    if cockpit.deletion_state != socket.assigns.cockpit.deletion_state or UpstreamAccountsReadModel.newer_saved_reset_refresh_cursor?(cockpit.saved_reset_refresh_cursor, token.cursor) do
      assign_cockpit(socket, preserve_request_metrics(socket, cockpit))
    else
      socket
    end
  end

  defp apply_saved_reset_status(socket, :deleted, _token) do
    socket
    |> clear_inaccessible_cockpit()
    |> put_flash(:info, gettext("Upstream account permanently deleted"))
    |> push_navigate(to: ~p"/admin/upstreams")
  end

  defp apply_saved_reset_status(socket, :error, _token) do
    message = if socket.assigns.cockpit.deletion_state in [:in_progress, :failed], do: gettext("Upstream account is no longer available"), else: gettext("Your Pool access changed")

    socket
    |> clear_inaccessible_cockpit()
    |> put_flash(:info, message)
    |> push_navigate(to: ~p"/admin/upstreams")
  end

  defp finish_saved_reset_status(socket) do
    socket = if socket.assigns.saved_reset_status_rerun?, do: request_saved_reset_status(socket, socket.assigns.saved_reset_status_force?), else: socket
    schedule_saved_reset_status(socket)
  end

  defp invalidate_saved_reset_status(socket) do
    assign(socket, saved_reset_status_generation: socket.assigns.saved_reset_status_generation + 1, saved_reset_status_rerun?: false, saved_reset_status_force?: false)
  end

  defp clear_inaccessible_cockpit(socket) do
    socket
    |> invalidate_saved_reset_status()
    |> assign(cockpit: nil, confirming_saved_reset_redemption: nil, quota_observations_open?: false, selected_request_log: nil, saved_reset_policy_dirty?: false)
    |> ProviderCreditsWorkflow.close()
    |> cancel_saved_reset_status_timer()
  end

  defp schedule_saved_reset_status(socket) do
    socket = if connected?(socket), do: LiveUpdatesHooks.hold(socket), else: socket

    if connected?(socket) and monitor_saved_reset_status?(socket) do
      socket = LiveUpdatesHooks.hold(socket)

      if socket.assigns.saved_reset_status_timer do
        socket
      else
        token = make_ref()
        timer = Process.send_after(self(), {:saved_reset_status_tick, token}, @saved_reset_status_interval_ms)
        assign(socket, saved_reset_status_timer: timer, saved_reset_status_timer_token: token)
      end
    else
      cancel_saved_reset_status_timer(socket)
    end
  end

  defp monitor_saved_reset_status?(socket) do
    cockpit = socket.assigns.cockpit
    operation = cockpit && cockpit.saved_reset_operation

    cockpit != nil and
      (cockpit.deletion_state in [:in_progress, :failed] or socket.assigns[:quota_observations_open?] == true or
         (is_map(operation) and (operation.active? or operation.request.state in [:queued, :processing])))
  end

  defp cancel_saved_reset_status_timer(socket) do
    if socket.assigns.saved_reset_status_timer, do: Process.cancel_timer(socket.assigns.saved_reset_status_timer)
    assign(socket, saved_reset_status_timer: nil, saved_reset_status_timer_token: nil)
  end

  defp present_saved_reset_status(assigns) do
    cockpit = assigns.cockpit
    operation = cockpit.saved_reset_operation

    operation =
      if is_map(operation) and assigns[:live_updates_paused?] == true,
        do: SavedResetOperationProjection.observe(operation, paused?: true),
        else: operation

    cockpit |> Map.delete(:saved_reset_refresh_cursor) |> Map.put(:saved_reset_status_refreshing?, assigns.saved_reset_status_running != nil) |> Map.put(:saved_reset_operation, operation) |> Map.put(:deletion_updates_paused?, assigns[:live_updates_paused?] == true)
  end

  defp request_cockpit_metrics(socket) do
    if connected?(socket) do
      generation = socket.assigns.cockpit_metrics_generation + 1

      socket =
        assign(socket,
          cockpit_metrics_generation: generation,
          cockpit_metrics_loading?: not socket.assigns.cockpit_metrics_loaded?,
          cockpit_metrics_rerun?: socket.assigns.cockpit_metrics_running?
        )

      if socket.assigns.cockpit_metrics_running? do
        socket
      else
        start_cockpit_metrics_task(socket, generation)
      end
    else
      socket
    end
  end

  defp start_cockpit_metrics_task(socket, generation) do
    scope = socket.assigns.current_scope
    cockpit = socket.assigns.cockpit
    locale = Gettext.get_locale()

    socket
    |> assign(
      cockpit_metrics_loading?: not socket.assigns.cockpit_metrics_loaded?,
      cockpit_metrics_running?: true,
      cockpit_metrics_rerun?: false
    )
    |> start_async({:cockpit_metrics, generation}, fn ->
      Gettext.with_locale(locale, fn -> UpstreamCockpitReadModel.deferred_request_data(scope, cockpit) end)
    end)
  end

  defp maybe_restart_cockpit_metrics(socket) do
    if socket.assigns.cockpit_metrics_rerun? do
      start_cockpit_metrics_task(socket, socket.assigns.cockpit_metrics_generation)
    else
      socket
    end
  end

  defp merge_cockpit_deferred_data(socket, data) do
    assign(
      socket,
      :cockpit,
      UpstreamCockpitReadModel.merge_deferred_request_data(socket.assigns.cockpit, data)
    )
  end

  defp preserve_request_metrics(socket, cockpit) do
    UpstreamCockpitReadModel.preserve_request_data(cockpit, socket.assigns.cockpit)
  end

  # Event-driven cockpit reloads must not clobber policy edits in progress:
  # the form assign is rebuilt from the persisted policy only while the
  # operator hasn't touched it (dirty resets on save).
  defp preserve_policy_edits(socket, cockpit) do
    if socket.assigns[:saved_reset_policy_dirty?] do
      socket.assigns.saved_reset_policy_form
    else
      SavedResetWorkflow.policy_form(cockpit.saved_reset_policy)
    end
  end

  defp assign_cockpit(socket, cockpit) do
    socket
    |> maybe_subscribe_pool_events(cockpit)
    |> assign(
      cockpit: cockpit,
      dialog_pool_options: preserve_dialog_pool_options(socket),
      saved_reset_policy_form: preserve_policy_edits(socket, cockpit)
    )
    |> ProviderCreditsWorkflow.refresh([cockpit])
    |> schedule_saved_reset_status()
  end

  # Event-driven reloads must not rebuild the pool options feeding the
  # auth-json and OAuth relink dialog selects while one of those dialogs is
  # open: a changed option list re-renders the select and reverts the
  # operator's un-submitted choice. The next reload after close refreshes.
  defp preserve_dialog_pool_options(socket) do
    if socket.assigns[:importing_auth_json] or socket.assigns[:oauth_relinking] do
      socket.assigns.dialog_pool_options
    else
      dialog_pool_options(socket.assigns.current_scope)
    end
  end

  defp refresh_oauth_flow_state(%{assigns: %{cockpit: nil}} = socket), do: socket

  defp refresh_oauth_flow_state(socket) do
    cockpit = socket.assigns.cockpit

    oauth_flows =
      UpstreamAccountsReadModel.oauth_flow_state(
        socket.assigns.current_scope,
        Enum.map(cockpit.assignments.items, &%{id: &1.pool_id}),
        DateTimeDisplay.preferences_for_user(socket.assigns.current_scope.user),
        upstream_identity_ids: [cockpit.identity.id]
      )

    assign(socket, :cockpit, %{cockpit | oauth_flows: oauth_flows})
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

  defp pending_cockpit_flow?(socket, flow_id) do
    case socket.assigns.cockpit do
      %{oauth_flows: %{items: items}} when is_list(items) ->
        Enum.any?(items, &(&1.id == flow_id and &1.status == "pending"))

      _cockpit ->
        false
    end
  end

  defp upstream_event_in_scope?(%{assigns: %{cockpit: %{identity: %{id: identity_id}}}}, payload), do: payload_upstream_identity_id(payload) == identity_id
  defp upstream_event_in_scope?(_socket, _payload), do: false

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
    reason = action.reason || gettext("action is unavailable")
    put_flash(socket, :error, gettext("%{action} is not available: %{reason}", action: action_label(action_key), reason: reason))
  end

  defp action_label(:replace_auth_json), do: gettext("Replace auth.json")
  defp action_label(:oauth_relink), do: gettext("OAuth relink")

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
      [] -> [{gettext("No active Pools available"), ""}]
      options -> options
    end
  end

  # A dialog that offered a Pool the viewer can no longer see closes; one that
  # only gained a Pool keeps its options, so an unsubmitted choice stays. A
  # finished relink keeps its result on screen.
  defp close_lost_dialogs(socket, scope) do
    visible_pool_ids = scope |> Pools.list_visible_pools() |> MapSet.new(& &1.id)

    offered_pool_lost? =
      MapSet.size(visible_pool_ids) == 0 or
        Enum.any?(socket.assigns.dialog_pool_options, fn {_name, pool_id} -> pool_id != "" and not MapSet.member?(visible_pool_ids, pool_id) end)

    confirmation_pool = socket.assigns.confirming_saved_reset_redemption && socket.assigns.confirming_saved_reset_redemption.pool_id
    confirmation_lost? = is_binary(confirmation_pool) and not MapSet.member?(visible_pool_ids, confirmation_pool)

    request_lost? = match?(%{id: _id}, socket.assigns.selected_request_log) and is_nil(load_request_log(socket, socket.assigns.selected_request_log.id))

    {socket, false}
    |> close_if(socket.assigns.importing_auth_json and offered_pool_lost?, &AuthJsonImportWorkflow.close/1)
    |> close_if(socket.assigns.oauth_relinking and is_nil(socket.assigns.oauth_relink_result) and offered_pool_lost?, &OAuthRelinkWorkflow.close/1)
    |> close_if(confirmation_lost?, &SavedResetWorkflow.close_redemption_confirmation/1)
    |> close_if(request_lost?, &assign(&1, :selected_request_log, nil))
  end

  defp close_if({socket, _closed?}, true, close), do: {close.(socket), true}
  defp close_if({socket, closed?}, false, _close), do: {socket, closed?}

  defp default_pool_id(%{assignments: %{items: [%{pool_id: pool_id} | _items]}}), do: pool_id
  defp default_pool_id(_cockpit), do: nil
end
