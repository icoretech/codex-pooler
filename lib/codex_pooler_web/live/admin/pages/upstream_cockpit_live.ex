defmodule CodexPoolerWeb.Admin.UpstreamCockpitLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonImport
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents
  alias CodexPoolerWeb.Admin.UpstreamCockpitLive.AccountLifecycleWorkflow
  alias CodexPoolerWeb.Admin.UpstreamCockpitLive.AuthJsonImportWorkflow
  alias CodexPoolerWeb.Admin.UpstreamCockpitLive.OAuthRelinkWorkflow
  alias CodexPoolerWeb.Admin.UpstreamCockpitLive.SavedResetWorkflow
  alias CodexPoolerWeb.Admin.UpstreamCockpitReadModel
  alias CodexPoolerWeb.DateTimeDisplay

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
        confirming_saved_reset_redemption: nil,
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
  def handle_info({:poll_oauth_relink_device, flow_id}, socket) do
    {:noreply, OAuthRelinkWorkflow.poll_device(socket, flow_id, &refresh_oauth_flow_state/1)}
  end

  @impl true
  def handle_event("refresh_data", _params, socket) do
    {:noreply,
     socket |> load_cockpit() |> assign(:refresh_data_message, "Cockpit data refreshed")}
  end

  @impl true
  def handle_event("open_rename_account", %{"id" => identity_id}, socket) do
    {:noreply, AccountLifecycleWorkflow.open_rename(socket, identity_id)}
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

      {:noreply, AuthJsonImportWorkflow.open(socket, pool_id)}
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
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}

      action_available?(socket, :oauth_relink, identity_id) ->
        {:noreply,
         socket
         |> AuthJsonImportWorkflow.close()
         |> AccountLifecycleWorkflow.close_rename()
         |> AccountLifecycleWorkflow.close_delete()
         |> OAuthRelinkWorkflow.close()
         |> SavedResetWorkflow.close_redemption_confirmation()
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
    {:noreply, AccountLifecycleWorkflow.open_delete(socket, identity_id)}
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

  def handle_event("save_saved_reset_policy", %{"saved_reset_policy" => params}, socket) do
    {:noreply, SavedResetWorkflow.save_policy(socket, params, &load_cockpit/1)}
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
      active_nav={:upstreams}
      alert_notification_center={@alert_notification_center}
    >
      <UpstreamCockpitComponents.cockpit_page
        cockpit={@cockpit}
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
        confirming_saved_reset_redemption={@confirming_saved_reset_redemption}
        refresh_data_message={@refresh_data_message}
        uploads={@uploads}
        datetime_preferences={@datetime_preferences}
      />
    </AdminComponents.admin_shell>
    """
  end

  defp default_relink_pool(socket) do
    selected_pool(socket.assigns.current_scope, default_pool_id(socket.assigns.cockpit))
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
      dialog_pool_options: dialog_pool_options(socket.assigns.current_scope),
      saved_reset_policy_form: SavedResetWorkflow.policy_form(cockpit.saved_reset_policy)
    )
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
  defp action_label(:oauth_relink), do: "OAuth relink"

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
end
