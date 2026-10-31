defmodule CodexPoolerWeb.Admin.UpstreamsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Events
  alias CodexPooler.Mailer
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.InviteCreationDialog
  alias CodexPoolerWeb.Admin.LiveUpdatesHooks
  alias CodexPoolerWeb.Admin.NotificationCenterHooks
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.PoolFilterComponents
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.PoolWizardComponents
  alias CodexPoolerWeb.Admin.ProviderCreditsWorkflow
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetOperationProjection
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonImport
  alias CodexPoolerWeb.Admin.UpstreamFilterForm
  alias CodexPoolerWeb.Admin.UpstreamPageComponents

  alias CodexPoolerWeb.Admin.UpstreamsLive.{
    AccountLifecycleWorkflow,
    AuthJsonWorkflow,
    InviteWorkflow,
    OAuthWorkflow,
    PoolEditorWorkflow,
    SavedResetWorkflow
  }

  alias CodexPoolerWeb.DateTimeDisplay

  @upstreams_reload_debounce_ms 1_000
  @saved_reset_status_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: gettext("Upstreams"),
        can_manage_pools?: false,
        pools: [],
        pool_options: [],
        dialog_pool_options: [],
        pool_filter_options: PoolFilterComponents.all_pool_filter_options(),
        filter_form: UpstreamFilterForm.filter_form(),
        filter_values: UpstreamFilterForm.filter_values(%{}, []),
        status_options: UpstreamFilterForm.status_options(),
        upstream_accounts: [],
        auth_json_form: UpstreamAuthJsonImport.empty_form(),
        auth_json_upload_limit_label: UpstreamAuthJsonImport.upload_limit_label(),
        importing_auth_json: false,
        oauth_linking: false,
        oauth_link_mode: :link,
        oauth_link_target_account: nil,
        oauth_link_form: OAuthWorkflow.form(),
        oauth_link_pool_id: "",
        oauth_link_flow: nil,
        oauth_link_authorization_url: nil,
        oauth_link_result: nil,
        oauth_link_error: nil,
        oauth_link_poll_timer: nil,
        renaming_account: nil,
        rename_account_form: nil,
        deleting_account: nil,
        delete_account_form: AccountLifecycleWorkflow.delete_form(nil),
        editing_saved_reset_policy: nil,
        saved_reset_policy_form: saved_reset_policy_form(%{}),
        saved_reset_policy_recovery: connected_saved_reset_policy_recovery(socket),
        confirming_saved_reset_redemption: nil,
        account_panel_views: %{},
        subscribed_pool_ids: MapSet.new(),
        upstreams_reload_timer: nil,
        upstreams_reload_generation: 0,
        upstreams_reload_running?: false,
        upstreams_reload_rerun?: false,
        upstreams_reload_dirty?: false,
        upstreams_loaded?: false,
        saved_reset_status_timer: nil,
        saved_reset_status_generation: 0,
        saved_reset_status_running: nil,
        saved_reset_status_rerun: nil,
        mailer_configured?: Mailer.configured?()
      )
      |> assign(PoolEditorWorkflow.initial_assigns())
      |> assign(InviteWorkflow.initial_assigns(socket.assigns.locale.tag))
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

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> close_account_workflow_dialogs()
     |> maybe_load_upstreams(params)
     |> restore_saved_reset_policy_draft()
     |> apply_pool_editor_params(params)
     |> apply_invite_params(params)
     |> canonicalize_upstreams_url(params)}
  end

  @impl true
  def handle_info({Events, %{topics: topics, reason: "upstream_account_provider_credits_policy_updated"}}, socket) do
    if "upstreams" in topics, do: {:noreply, reload_upstreams(socket)}, else: {:noreply, socket}
  end

  def handle_info({Events, %{topics: topics}}, socket) do
    if "upstreams" in topics do
      {:noreply, schedule_upstreams_reload(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:reload_upstreams_from_events, socket) do
    # The timer that sent this has fired; a hold must not leave the assign
    # naming it, or every later debounce coalesces onto nothing.
    socket
    |> assign(:upstreams_reload_timer, nil)
    |> LiveUpdatesHooks.unless_paused(&reload_upstreams_or_defer/1)
  end

  def handle_info(:live_updates_resumed, socket) do
    {:noreply, resume_upstreams_reload(socket)}
  end

  # A role change or a Pool granted or revoked changes which accounts, Pools
  # and management controls this page may show. It re-reads them at once, even
  # behind an open dialog (an ordinary reload waits for it to close), and
  # closes a dialog on an account the viewer can no longer see, the Pool editor
  # the viewer may no longer use, and a dialog that needs a Pool when none is
  # left (findings#206 row 206-329).
  def handle_info({NotificationCenterHooks, :viewer_visibility_changed}, socket) do
    {socket, closed?} = socket |> invalidate_saved_reset_status() |> reload_upstreams() |> close_lost_account_dialogs()

    # The Pool editor and the invite dialog live in the URL: closing them is a
    # patch to the page without their parameters.
    url_dialog_lost? = url_dialog_lost?(socket)
    socket = if url_dialog_lost?, do: push_patch(socket, to: upstreams_path(socket)), else: socket
    {:noreply, if(closed? or url_dialog_lost?, do: put_flash(socket, :info, gettext("Your Pool access changed")), else: socket)}
  end

  def handle_info(:refresh_saved_reset_status_tick, socket) do
    socket = assign(socket, :saved_reset_status_timer, nil)

    socket
    |> sync_saved_reset_status_timer()
    |> LiveUpdatesHooks.unless_paused(&request_saved_reset_status/1)
  end

  @impl true
  def handle_info({:poll_oauth_device, flow_id}, socket) do
    {:noreply, OAuthWorkflow.poll_device(socket, flow_id, &reload_upstreams/1)}
  end

  @impl true
  def handle_async({:upstreams_reload, generation}, {:ok, page_state}, socket) do
    socket = assign(socket, :upstreams_reload_running?, false)

    cond do
      generation != socket.assigns.upstreams_reload_generation ->
        {:noreply, maybe_run_upstreams_reload_rerun(socket)}

      LiveUpdatesHooks.paused?(socket) ->
        {:noreply, socket |> assign(:upstreams_reload_dirty?, true) |> LiveUpdatesHooks.hold()}

      upstream_dialog_open?(socket) ->
        {:noreply,
         assign(socket,
           upstreams_reload_dirty?: true,
           upstreams_reload_rerun?: false
         )}

      true ->
        {:noreply, apply_upstreams_page_state(socket, page_state)}
    end
  end

  def handle_async({:upstreams_reload, _generation}, {:exit, _reason}, socket) do
    socket = assign(socket, :upstreams_reload_running?, false)
    {:noreply, maybe_run_upstreams_reload_rerun(socket)}
  end

  def handle_async({:saved_reset_status, generation}, {:ok, result}, socket) do
    case socket.assigns.saved_reset_status_running do
      %{generation: ^generation} = running ->
        socket = assign(socket, :saved_reset_status_running, nil)

        socket =
          if generation == socket.assigns.saved_reset_status_generation and
               running.page_generation == socket.assigns.upstreams_reload_generation and
               (running.forced? or (not LiveUpdatesHooks.paused?(socket) and not unrelated_upstream_dialog_open?(socket))) do
            apply_saved_reset_status(socket, result, running)
          else
            socket
          end

        {:noreply, socket |> run_saved_reset_status_rerun() |> sync_saved_reset_status_timer()}

      _stale ->
        {:noreply, socket}
    end
  end

  def handle_async({:saved_reset_status, generation}, {:exit, _reason}, socket) do
    case socket.assigns.saved_reset_status_running do
      %{generation: ^generation} ->
        {:noreply, socket |> assign(:saved_reset_status_running, nil) |> run_saved_reset_status_rerun() |> sync_saved_reset_status_timer()}

      _stale ->
        {:noreply, socket}
    end
  end

  def handle_async({:pool_editor_model_serving, _load_token, _pool_id} = key, result, socket) do
    {:noreply, PoolEditorWorkflow.handle_model_async(key, result, socket)}
  end

  @impl true
  def terminate(_reason, socket) do
    cancel_saved_reset_status_timer(socket)
    :ok
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    filter_values = UpstreamFilterForm.filter_values(filter_params, socket.assigns.pools)

    if filter_values == socket.assigns.filter_values do
      {:noreply, socket}
    else
      {:noreply,
       push_patch(socket,
         to: upstreams_path(socket, filter_values, current_workflow_params(socket)),
         replace: true
       )}
    end
  end

  def handle_event("select_pool_filter", %{"pool-id" => pool_id}, socket) do
    filter_values =
      socket.assigns.filter_values
      |> Map.put("pool_id", pool_id)
      |> UpstreamFilterForm.filter_values(socket.assigns.pools)

    {:noreply,
     push_patch(socket,
       to: upstreams_path(socket, filter_values, current_workflow_params(socket))
     )}
  end

  def handle_event("clear_upstream_query_filter", _params, socket) do
    filter_values =
      socket.assigns.filter_values
      |> Map.put("query", "")
      |> UpstreamFilterForm.filter_values(socket.assigns.pools)

    {:noreply,
     push_patch(socket,
       to: upstreams_path(socket, filter_values, current_workflow_params(socket)),
       replace: true
     )}
  end

  def handle_event("select_status_filter", %{"status" => status}, socket) do
    filter_values =
      socket.assigns.filter_values
      |> Map.put("status", status)
      |> UpstreamFilterForm.filter_values(socket.assigns.pools)

    {:noreply,
     push_patch(socket,
       to: upstreams_path(socket, filter_values, current_workflow_params(socket))
     )}
  end

  def handle_event("pool_wizard_step", %{"step" => step}, socket) do
    case socket.assigns.editing_pool do
      %{id: pool_id} ->
        {:noreply,
         push_patch(socket,
           to: pool_editor_path(socket, pool_id, PoolWizardComponents.normalize_step(step, :edit))
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, push_patch(socket, to: upstreams_path(socket))}
  end

  def handle_event("save_pool", %{"wizard_step" => step, "pool_edit" => attrs}, socket) when is_map(attrs) do
    with %{id: pool_id} <- socket.assigns.editing_pool,
         {:ok, pool} <- PoolEditorWorkflow.find_editable_pool(socket.assigns.current_scope, pool_id) do
      form = PoolForm.edit_form(pool, Map.put(attrs, "id", pool_id))
      socket = assign(socket, :pool_edit_form, form)
      handle_event("pool_wizard_step", %{"step" => step}, socket)
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save_pool", %{"wizard_step" => _step}, socket), do: {:noreply, socket}

  def handle_event("save_pool", %{"pool_edit" => pool_params}, socket) do
    {:noreply,
     PoolEditorWorkflow.save(socket, pool_params, fn socket, pool ->
       socket
       |> assign(:editing_pool, pool)
       |> reload_upstreams()
     end)}
  end

  def handle_event(
        "validate_pool_model_serving",
        %{"pool_model_serving" => attrs},
        socket
      ) do
    {:noreply, PoolEditorWorkflow.validate_model_serving(socket, attrs)}
  end

  def handle_event("save_pool_model_serving", %{"pool_model_serving" => attrs}, socket) do
    {:noreply, PoolEditorWorkflow.save_model_serving(socket, attrs)}
  end

  def handle_event("cancel_create_invite", _params, socket) do
    {:noreply, push_patch(socket, to: upstreams_path(socket))}
  end

  def handle_event("validate_invite", %{"invite" => invite_params} = params, socket) do
    {:noreply, InviteWorkflow.validate(socket, invite_params, params["_target"])}
  end

  def handle_event("create_invite", %{"invite" => invite_params}, socket) do
    {:noreply,
     InviteWorkflow.create(socket, invite_params, fn token ->
       url(~p"/onboarding/invites/#{token}")
     end)}
  end

  @impl true
  def handle_event("import_auth_json", %{"auth_json" => auth_json_params}, socket) do
    pool = selected_pool(socket.assigns.pools, auth_json_params["pool_id"])

    {:noreply, AuthJsonWorkflow.import(socket, auth_json_params, pool, &reload_upstreams/1)}
  end

  def handle_event("open_import_auth_json", params, socket) do
    {:noreply,
     socket
     |> close_account_workflow_dialogs()
     |> assign(
       importing_auth_json: true,
       auth_json_form: AuthJsonWorkflow.form_for_open(socket.assigns.pools, params)
     )
     |> defer_upstreams_reload()}
  end

  def handle_event("cancel_import_auth_json", _params, socket) do
    {:noreply, socket |> AuthJsonWorkflow.close() |> flush_deferred_upstreams_reload()}
  end

  def handle_event("open_oauth_link", params, socket) do
    {:noreply,
     socket
     |> OAuthWorkflow.open_link(params, &close_account_workflow_dialogs/1)
     |> defer_upstreams_reload()}
  end

  def handle_event("open_oauth_relink", %{"id" => identity_id}, socket) do
    {:noreply,
     socket
     |> OAuthWorkflow.open_relink(identity_id, &close_account_workflow_dialogs/1)
     |> defer_upstreams_reload()}
  end

  def handle_event("validate_oauth_link_pool", %{"oauth_link" => oauth_params}, socket) do
    {:noreply, OAuthWorkflow.validate_pool(socket, oauth_params)}
  end

  def handle_event("start_oauth_browser", params, socket) do
    {:noreply, OAuthWorkflow.start_browser(socket, params)}
  end

  def handle_event("start_oauth_device", params, socket) do
    {:noreply, OAuthWorkflow.start_device(socket, params)}
  end

  def handle_event("submit_oauth_callback", %{"oauth_link" => oauth_params}, socket) do
    {:noreply, OAuthWorkflow.submit_callback(socket, oauth_params, &reload_upstreams/1)}
  end

  def handle_event("cancel_oauth_link", _params, socket) do
    {:noreply, socket |> OAuthWorkflow.cancel() |> flush_deferred_upstreams_reload()}
  end

  def handle_event("validate_auth_json_import", %{"auth_json" => auth_json_params}, socket) do
    {:noreply, AuthJsonWorkflow.validate(socket, auth_json_params)}
  end

  def handle_event("cancel_auth_json_upload", %{"ref" => ref}, socket) do
    {:noreply, AuthJsonWorkflow.cancel_upload_entry(socket, ref)}
  end

  def handle_event("open_rename_account", %{"id" => identity_id}, socket) do
    case find_account(socket.assigns.upstream_accounts, identity_id) do
      %{identity: %UpstreamIdentity{} = identity} = account ->
        {:noreply,
         socket
         |> close_saved_reset_policy_dialog()
         |> ProviderCreditsWorkflow.close()
         |> assign(
           renaming_account: account,
           rename_account_form: rename_account_form(identity)
         )
         |> defer_upstreams_reload()}

      nil ->
        {:noreply, put_flash(socket, :error, gettext("Upstream account was not found"))}
    end
  end

  def handle_event("cancel_rename_account", _params, socket) do
    {:noreply, socket |> close_rename_account_dialog() |> flush_deferred_upstreams_reload()}
  end

  def handle_event("open_delete_account", %{"id" => identity_id}, socket) do
    {:noreply,
     socket
     |> close_account_workflow_dialogs()
     |> AccountLifecycleWorkflow.open_delete(identity_id)
     |> defer_upstreams_reload()}
  end

  def handle_event("cancel_delete_account", _params, socket) do
    {:noreply,
     socket
     |> AccountLifecycleWorkflow.close_delete()
     |> flush_deferred_upstreams_reload()}
  end

  def handle_event("confirm_delete_account", %{"upstream_delete" => delete_params}, socket) do
    {:noreply, AccountLifecycleWorkflow.confirm_delete(socket, delete_params, &reload_upstreams/1)}
  end

  def handle_event("open_provider_credits_policy", %{"id" => identity_id}, socket) do
    socket = socket |> close_account_workflow_dialogs() |> reload_upstreams()
    {:noreply, ProviderCreditsWorkflow.open(socket, find_account(socket.assigns.upstream_accounts, identity_id))}
  end

  def handle_event("cancel_provider_credits_policy", _params, socket) do
    {:noreply, socket |> ProviderCreditsWorkflow.close() |> flush_deferred_upstreams_reload()}
  end

  def handle_event("validate_provider_credits_policy", params, socket) do
    {:noreply, ProviderCreditsWorkflow.validate(socket, Map.get(params, "provider_credits_policy"))}
  end

  def handle_event("save_provider_credits_policy", params, socket) do
    {:noreply, ProviderCreditsWorkflow.save(socket, Map.get(params, "provider_credits_policy"), &reload_upstreams/1)}
  end

  def handle_event("open_saved_reset_policy", %{"id" => identity_id}, socket) do
    case find_account(socket.assigns.upstream_accounts, identity_id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Upstream account was not found"))}

      account ->
        {:noreply,
         socket
         |> close_account_workflow_dialogs()
         |> assign(
           editing_saved_reset_policy: account,
           saved_reset_policy_form: saved_reset_policy_form(account.saved_reset_policy),
           confirming_saved_reset_redemption: nil
         )
         |> defer_upstreams_reload()
         |> sync_saved_reset_status_timer()}
    end
  end

  def handle_event("open_quota_observations", _params, socket) do
    {:noreply, socket |> assign(:quota_observations_open?, true) |> defer_upstreams_reload() |> sync_saved_reset_status_timer()}
  end

  def handle_event("close_quota_observations", _params, socket) do
    {:noreply, socket |> assign(:quota_observations_open?, false) |> flush_deferred_upstreams_reload() |> sync_saved_reset_status_timer()}
  end

  def handle_event("cancel_saved_reset_policy", _params, socket) do
    {:noreply,
     socket
     |> close_saved_reset_policy_dialog()
     |> flush_deferred_upstreams_reload()
     |> sync_saved_reset_status_timer()}
  end

  def handle_event("refresh_saved_reset_status", %{"id" => identity_id}, socket) do
    case find_account(socket.assigns.upstream_accounts, identity_id) do
      nil -> {:noreply, socket}
      _trusted_account -> {:noreply, request_saved_reset_status(socket, [identity_id], true)}
    end
  end

  def handle_event("validate_saved_reset_policy", %{"saved_reset_policy" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :saved_reset_policy_form,
       saved_reset_policy_form(current_saved_reset_policy(socket), params, :validate)
     )}
  end

  def handle_event(
        "open_saved_reset_redemption_confirmation",
        %{"id" => identity_id} = params,
        socket
      ) do
    {:noreply, SavedResetWorkflow.maybe_confirm_redemption(socket, identity_id, params)}
  end

  def handle_event("toggle_account_pools_panel", %{"id" => identity_id}, socket) do
    {:noreply, update(socket, :account_panel_views, &toggle_account_panel_view(&1, identity_id, :pools))}
  end

  def handle_event("toggle_account_tokens_panel", %{"id" => identity_id}, socket) do
    {:noreply, update(socket, :account_panel_views, &toggle_account_panel_view(&1, identity_id, :tokens))}
  end

  def handle_event("cancel_saved_reset_redemption", _params, socket) do
    {:noreply, assign(socket, :confirming_saved_reset_redemption, nil)}
  end

  def handle_event("redeem_saved_reset", %{"id" => identity_id}, socket) do
    {:noreply,
     SavedResetWorkflow.redeem(socket, identity_id,
       reload: &reload_upstreams/1,
       refresh_editing: &refresh_editing_saved_reset_policy/2
     )}
  end

  def handle_event("save_saved_reset_policy", %{"saved_reset_policy" => params}, socket) do
    case socket.assigns.editing_saved_reset_policy do
      %{identity: %UpstreamIdentity{id: identity_id}} ->
        changeset =
          saved_reset_policy_changeset(current_saved_reset_policy(socket), params, :validate)

        if changeset.valid? do
          {:noreply,
           SavedResetWorkflow.save_policy(socket, identity_id, changeset,
             close: &close_saved_reset_policy_dialog/1,
             reload: &reload_upstreams/1
           )}
        else
          {:noreply, SavedResetWorkflow.assign_form(socket, changeset)}
        end

      nil ->
        {:noreply, put_flash(socket, :error, gettext("Upstream account was not found"))}
    end
  end

  def handle_event("validate_rename_account", %{"rename" => rename_params}, socket) do
    {:noreply,
     assign(
       socket,
       :rename_account_form,
       rename_account_form(socket.assigns.renaming_account, rename_params, :validate)
     )}
  end

  def handle_event("rename_account", %{"rename" => rename_params}, socket) do
    case socket.assigns.renaming_account do
      %{identity: %UpstreamIdentity{} = identity} ->
        {:noreply,
         AccountLifecycleWorkflow.rename(
           socket,
           identity,
           rename_params,
           &close_rename_account_dialog/1,
           &reload_upstreams/1
         )}

      nil ->
        {:noreply, put_flash(socket, :error, gettext("Upstream account was not found"))}
    end
  end

  def handle_event("pause_account", %{"id" => identity_id}, socket) do
    {:noreply, AccountLifecycleWorkflow.pause(socket, identity_id, &reload_upstreams/1)}
  end

  def handle_event("reactivate_account", %{"id" => identity_id}, socket) do
    {:noreply, AccountLifecycleWorkflow.reactivate(socket, identity_id, &reload_upstreams/1)}
  end

  def handle_event("refresh_account", %{"id" => identity_id}, socket) do
    {:noreply, AccountLifecycleWorkflow.refresh(socket, identity_id, &reload_upstreams/1)}
  end

  defp refresh_editing_saved_reset_policy(socket, identity_id) do
    case find_account(socket.assigns.upstream_accounts, identity_id) do
      nil -> close_saved_reset_policy_dialog(socket)
      account -> assign(socket, :editing_saved_reset_policy, account)
    end
  end

  # Cancelling rather than only forgetting: on the resumed path a replayed event
  # has just armed a fresh debounce, and dropping the reference without killing
  # the timer leaves it to fire into a second reload.
  defp resume_upstreams_reload(socket) do
    socket = cancel_upstreams_reload_timer(socket)

    if saved_reset_status_targets(socket) == [] do
      reload_upstreams_or_defer(socket)
    else
      request_saved_reset_status(socket)
    end
  end

  @impl true
  def render(assigns) do
    assigns = saved_reset_view_assigns(assigns)

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
      <div
        :for={warning <- @pool_editor_warnings}
        id={"upstream-pool-editor-warning-#{warning.id}"}
        class="alert alert-warning mb-4 items-start"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div class="grid gap-1">
          <p class="font-semibold">{warning.title}</p>
          <p class="text-sm">{warning.message}</p>
        </div>
      </div>

      <PoolWizardComponents.pool_wizard
        :if={@editing_pool}
        mode={:edit}
        form={@pool_edit_form}
        current_step={@pool_editor_step}
        upstream_options={@pool_editor_upstream_options}
        api_key_options={@pool_editor_api_key_options}
        model_serving_form={@pool_model_serving_form}
        model_serving_status={@pool_model_serving_status}
        model_serving_dirty?={@pool_model_serving_dirty?}
        model_serving_sync_pending?={@pool_model_serving_sync_pending?}
      />

      <InviteCreationDialog.pool_invite_dialog
        creating_invite={@creating_invite}
        invite_form={@invite_form}
        invite_form_valid?={@invite_form_valid?}
        invite_locale_source={@invite_locale_source}
        last_invite={@last_invite}
        mailer_configured?={@mailer_configured?}
        pool_options={@dialog_pool_options}
      />

      <UpstreamPageComponents.upstreams_page
        pools={@pools}
        pool_options={@pool_options}
        dialog_pool_options={@dialog_pool_options}
        filter_form={@filter_form}
        filter_values={@filter_values}
        pool_filter_options={@pool_filter_options}
        status_options={@status_options}
        auth_json_form={@auth_json_form}
        auth_json_upload_limit_label={@auth_json_upload_limit_label}
        importing_auth_json={@importing_auth_json}
        oauth_linking={@oauth_linking}
        oauth_link_mode={@oauth_link_mode}
        oauth_link_target_account={@oauth_link_target_account}
        oauth_link_form={@oauth_link_form}
        oauth_link_flow={@oauth_link_flow}
        oauth_link_authorization_url={@oauth_link_authorization_url}
        oauth_link_result={@oauth_link_result}
        oauth_link_error={@oauth_link_error}
        renaming_account={@renaming_account}
        rename_account_form={@rename_account_form}
        deleting_account={@deleting_account}
        delete_account_form={@delete_account_form}
        editing_saved_reset_policy={@editing_saved_reset_policy}
        saved_reset_policy_form={@saved_reset_policy_form}
        editing_provider_credits_policy={@editing_provider_credits_policy}
        provider_credits_policy_form={@provider_credits_policy_form}
        confirming_saved_reset_redemption={@confirming_saved_reset_redemption}
        account_panel_views={@account_panel_views}
        upstream_accounts={@upstream_accounts}
        uploads={@uploads}
        datetime_preferences={@datetime_preferences}
        can_manage_pools?={@can_manage_pools?}
      />
    </AdminComponents.admin_shell>
    """
  end

  defp connected_saved_reset_policy_recovery(socket) do
    if connected?(socket), do: saved_reset_policy_recovery_params(get_connect_params(socket))
  end

  defp saved_reset_policy_recovery_params(%{"saved_reset_policy_recovery" => %{"id" => id, "policy" => policy}}) when is_binary(id) and is_map(policy) do
    policy = Map.take(policy, ~w(auto_redeem_enabled trigger_mode quota_threshold_percent min_blocked_minutes keep_credits))
    if Enum.all?(policy, fn {_key, value} -> is_binary(value) and byte_size(value) <= 256 end), do: %{id: id, policy: policy}
  end

  defp saved_reset_policy_recovery_params(_params), do: nil

  defp restore_saved_reset_policy_draft(socket) do
    recovery = socket.assigns.saved_reset_policy_recovery
    socket = assign(socket, :saved_reset_policy_recovery, nil)

    case recovery do
      %{id: identity_id, policy: policy} ->
        case find_account(socket.assigns.upstream_accounts, identity_id) do
          nil ->
            socket

          account ->
            socket
            |> assign(editing_saved_reset_policy: account, saved_reset_policy_form: saved_reset_policy_form(account.saved_reset_policy, policy, :validate))
            |> defer_upstreams_reload()
            |> sync_saved_reset_status_timer()
        end

      nil ->
        socket
    end
  end

  defp load_upstreams(socket, params) do
    generation = socket.assigns.upstreams_reload_generation + 1

    socket
    |> invalidate_saved_reset_status()
    |> assign(
      upstreams_reload_generation: generation,
      upstreams_reload_rerun?: false,
      upstreams_reload_dirty?: false
    )
    |> apply_upstreams_page_state(upstreams_page_state(socket.assigns.current_scope, params))
  end

  defp upstreams_page_state(scope, params) do
    pools = Pools.list_visible_pools(scope)
    filter_values = UpstreamFilterForm.filter_values(params, pools)
    filtered_pools = filtered_pools(pools, filter_values)

    datetime_preferences = DateTimeDisplay.preferences_for_user(scope.user)

    upstream_accounts =
      UpstreamAccountsReadModel.list_visible_accounts(
        scope,
        filtered_pools,
        filter_values,
        datetime_preferences
      )

    %{
      can_manage_pools?: Pools.can_manage_pools?(scope),
      pools: pools,
      filtered_pools: filtered_pools,
      filter_values: filter_values,
      upstream_accounts: upstream_accounts
    }
  end

  defp apply_upstreams_page_state(socket, page_state) do
    %{
      can_manage_pools?: can_manage_pools?,
      pools: pools,
      filtered_pools: filtered_pools,
      filter_values: filter_values,
      upstream_accounts: upstream_accounts
    } = page_state

    socket =
      socket
      |> cancel_upstreams_reload_timer()
      |> maybe_subscribe_pool_events(filtered_pools)

    assign(socket,
      can_manage_pools?: can_manage_pools?,
      pools: pools,
      pool_options: pool_options(pools),
      dialog_pool_options: dialog_pool_options(pools),
      pool_filter_options: PoolFilterComponents.pool_filter_options(pools),
      filter_values: filter_values,
      filter_form: UpstreamFilterForm.filter_form(filter_values),
      status_options: UpstreamFilterForm.status_options(),
      upstream_accounts: upstream_accounts,
      upstreams_reload_dirty?: false,
      upstreams_reload_rerun?: false,
      upstreams_loaded?: true,
      account_panel_views: prune_account_panel_views(socket.assigns.account_panel_views, upstream_accounts)
    )
    |> ProviderCreditsWorkflow.refresh(upstream_accounts)
    |> sync_saved_reset_status_timer()
  end

  defp request_upstreams_reload(socket) do
    generation = socket.assigns.upstreams_reload_generation + 1

    socket =
      assign(socket,
        upstreams_reload_generation: generation,
        upstreams_reload_dirty?: false
      )

    if socket.assigns.upstreams_reload_running? do
      assign(socket, :upstreams_reload_rerun?, true)
    else
      start_upstreams_reload(socket, generation)
    end
  end

  defp start_upstreams_reload(socket, generation) do
    scope = socket.assigns.current_scope
    params = socket.assigns.filter_values
    locale = Gettext.get_locale()

    socket
    |> assign(upstreams_reload_running?: true, upstreams_reload_rerun?: false)
    |> start_async({:upstreams_reload, generation}, fn ->
      Gettext.with_locale(locale, fn -> upstreams_page_state(scope, params) end)
    end)
  end

  defp maybe_run_upstreams_reload_rerun(socket) do
    cond do
      upstream_dialog_open?(socket) ->
        assign(socket,
          upstreams_reload_dirty?: true,
          upstreams_reload_rerun?: false
        )

      socket.assigns.upstreams_reload_rerun? ->
        start_upstreams_reload(socket, socket.assigns.upstreams_reload_generation)

      true ->
        socket
    end
  end

  defp reload_upstreams_or_defer(socket) do
    if upstream_dialog_open?(socket) do
      socket |> assign(:upstreams_reload_dirty?, true) |> request_saved_reset_status()
    else
      request_upstreams_reload(socket)
    end
  end

  defp defer_upstreams_reload(socket) do
    socket =
      if socket.assigns.upstreams_reload_running? or is_reference(socket.assigns.upstreams_reload_timer) do
        socket |> assign(:upstreams_reload_dirty?, true) |> cancel_upstreams_reload_timer()
      else
        socket
      end

    sync_saved_reset_status_timer(socket)
  end

  defp flush_deferred_upstreams_reload(socket) do
    socket =
      if socket.assigns.upstreams_reload_dirty? and not upstream_dialog_open?(socket) do
        request_upstreams_reload(socket)
      else
        socket
      end

    sync_saved_reset_status_timer(socket)
  end

  defp upstream_dialog_open?(socket) do
    socket.assigns[:quota_observations_open?] == true or socket.assigns.importing_auth_json or
      socket.assigns.oauth_linking or
      socket.assigns.creating_invite or
      not is_nil(socket.assigns.editing_pool) or
      not is_nil(socket.assigns.renaming_account) or
      not is_nil(socket.assigns.deleting_account) or
      not is_nil(socket.assigns.editing_saved_reset_policy)
  end

  defp reload_upstreams(socket), do: load_upstreams(socket, socket.assigns.filter_values)

  defp maybe_load_upstreams(socket, params) do
    filter_values = UpstreamFilterForm.filter_values(params, socket.assigns.pools)

    if socket.assigns.upstreams_loaded? and filter_values == socket.assigns.filter_values do
      socket
    else
      load_upstreams(socket, params)
    end
  end

  defp apply_pool_editor_params(socket, %{"edit_pool_id" => pool_id} = params) do
    step = Map.get(params, "step", "details")

    case PoolEditorWorkflow.find_editable_pool(socket.assigns.current_scope, pool_id) do
      {:ok, pool} ->
        socket
        |> InviteWorkflow.close()
        |> PoolEditorWorkflow.open(pool, step)
        |> defer_upstreams_reload()

      {:error, _reason} ->
        PoolEditorWorkflow.close(socket)
    end
  end

  defp apply_pool_editor_params(socket, _params) do
    if socket.assigns.editing_pool do
      socket
      |> PoolEditorWorkflow.close()
      |> flush_deferred_upstreams_reload()
    else
      socket
    end
  end

  defp apply_invite_params(socket, %{"create_invite" => "1"}) do
    if socket.assigns.pools == [] do
      socket
    else
      socket
      |> PoolEditorWorkflow.close()
      |> InviteWorkflow.open()
      |> defer_upstreams_reload()
    end
  end

  defp apply_invite_params(socket, _params) do
    if socket.assigns.creating_invite do
      socket
      |> InviteWorkflow.close()
      |> flush_deferred_upstreams_reload()
    else
      socket
    end
  end

  defp pool_editor_path(socket, pool_id, step) do
    upstreams_path(socket, %{"edit_pool_id" => pool_id, "step" => step})
  end

  defp upstreams_path(socket, extra_params \\ %{}) do
    upstreams_path(socket, socket.assigns.filter_values, extra_params)
  end

  defp upstreams_path(socket, filter_params, extra_params) do
    params =
      filter_params
      |> UpstreamFilterForm.filter_values(socket.assigns.pools)
      |> UpstreamFilterForm.query_params()
      |> Map.merge(extra_params)

    ~p"/admin/upstreams?#{params}"
  end

  defp canonicalize_upstreams_url(socket, params) do
    canonical_params =
      socket.assigns.filter_values
      |> UpstreamFilterForm.filter_values(socket.assigns.pools)
      |> UpstreamFilterForm.query_params()
      |> Map.merge(current_workflow_params(socket))

    if connected?(socket) and params != canonical_params do
      push_patch(socket, to: ~p"/admin/upstreams?#{canonical_params}", replace: true)
    else
      socket
    end
  end

  defp current_workflow_params(%{assigns: %{creating_invite: true}}),
    do: %{"create_invite" => "1"}

  defp current_workflow_params(%{
         assigns: %{editing_pool: %{id: pool_id}, pool_editor_step: step}
       }) do
    %{
      "edit_pool_id" => pool_id,
      "step" => PoolWizardComponents.normalize_step(step, :edit)
    }
  end

  defp current_workflow_params(_socket), do: %{}

  defp schedule_upstreams_reload(socket) do
    cond do
      upstream_dialog_open?(socket) ->
        socket
        |> assign(:upstreams_reload_dirty?, true)
        |> cancel_upstreams_reload_timer()
        |> request_saved_reset_status()

      is_reference(socket.assigns[:upstreams_reload_timer]) ->
        socket

      true ->
        timer =
          Process.send_after(
            self(),
            :reload_upstreams_from_events,
            @upstreams_reload_debounce_ms
          )

        assign(socket, :upstreams_reload_timer, timer)
    end
  end

  defp saved_reset_status_targets(socket) do
    editing_id = get_in(socket.assigns, [:editing_saved_reset_policy, :identity, Access.key(:id)])
    unrelated_dialog? = unrelated_upstream_dialog_open?(socket)

    socket.assigns.upstream_accounts
    |> Enum.filter(fn account ->
      account.deletion_state in [:in_progress, :failed] or
        (not unrelated_dialog? and
           (account.identity.id == editing_id or socket.assigns[:quota_observations_open?] == true or
              get_in(account, [:saved_reset_operation, :active?]) == true))
    end)
    |> Enum.map(& &1.identity.id)
  end

  defp unrelated_upstream_dialog_open?(socket) do
    socket.assigns.importing_auth_json or socket.assigns.oauth_linking or socket.assigns.creating_invite or
      not is_nil(socket.assigns.editing_pool) or not is_nil(socket.assigns.renaming_account) or
      not is_nil(socket.assigns.deleting_account) or not is_nil(socket.assigns.editing_provider_credits_policy)
  end

  defp request_saved_reset_status(socket), do: request_saved_reset_status(socket, saved_reset_status_targets(socket), false)

  defp request_saved_reset_status(socket, [], _forced?), do: sync_saved_reset_status_timer(socket)

  defp request_saved_reset_status(socket, identity_ids, forced?) do
    if connected?(socket) and (forced? or not LiveUpdatesHooks.paused?(socket)) do
      generation = socket.assigns.saved_reset_status_generation + 1
      socket = assign(socket, :saved_reset_status_generation, generation)

      if socket.assigns.saved_reset_status_running do
        previous = socket.assigns.saved_reset_status_rerun || %{identity_ids: [], forced?: false}
        assign(socket, :saved_reset_status_rerun, %{identity_ids: Enum.uniq(previous.identity_ids ++ identity_ids), forced?: previous.forced? or forced?})
      else
        start_saved_reset_status(socket, identity_ids, forced?, generation)
      end
    else
      LiveUpdatesHooks.hold(socket)
    end
  end

  defp start_saved_reset_status(socket, identity_ids, forced?, generation) do
    # A targeted read is newer than any whole-page read already in flight.
    # Advancing their shared ordering prevents the older page from restoring it.
    socket = assign(socket, :upstreams_reload_generation, socket.assigns.upstreams_reload_generation + 1)
    scope = socket.assigns.current_scope
    filters = Map.put(socket.assigns.filter_values, :identity_ids, identity_ids)
    preferences = DateTimeDisplay.preferences_for_user(scope.user)
    cursors = Map.new(socket.assigns.upstream_accounts, &{&1.identity.id, &1.saved_reset_refresh_cursor})
    running = %{generation: generation, page_generation: socket.assigns.upstreams_reload_generation, identity_ids: identity_ids, forced?: forced?, cursors: Map.take(cursors, identity_ids)}
    locale = Gettext.get_locale()

    socket
    |> assign(saved_reset_status_running: running, saved_reset_status_rerun: nil)
    |> start_async({:saved_reset_status, generation}, fn ->
      Gettext.with_locale(locale, fn ->
        pools = Pools.list_visible_pools(scope)
        UpstreamAccountsReadModel.list_visible_accounts(scope, filtered_pools(pools, filters), filters, preferences)
      end)
    end)
  end

  defp run_saved_reset_status_rerun(socket) do
    case socket.assigns.saved_reset_status_rerun do
      %{identity_ids: ids, forced?: forced?} ->
        visible_ids = MapSet.new(socket.assigns.upstream_accounts, & &1.identity.id)
        ids = Enum.filter(ids, &MapSet.member?(visible_ids, &1))
        socket |> assign(:saved_reset_status_rerun, nil) |> request_saved_reset_status(ids, forced?)

      nil ->
        socket
    end
  end

  defp apply_saved_reset_status(socket, accounts, running) do
    fresh = Map.new(accounts, &{&1.identity.id, &1})
    targets = MapSet.new(running.identity_ids)

    accounts =
      Enum.flat_map(socket.assigns.upstream_accounts, fn current ->
        id = current.identity.id

        cond do
          not MapSet.member?(targets, id) -> [current]
          current.saved_reset_refresh_cursor != running.cursors[id] -> [current]
          not Map.has_key?(fresh, id) -> []
          fresh[id].deletion_state != current.deletion_state -> [fresh[id]]
          UpstreamAccountsReadModel.newer_saved_reset_refresh_cursor?(fresh[id].saved_reset_refresh_cursor, current.saved_reset_refresh_cursor) -> [fresh[id]]
          true -> [current]
        end
      end)

    socket = assign(socket, :upstream_accounts, accounts)

    socket =
      case socket.assigns.editing_saved_reset_policy do
        %{identity: %{id: id}} -> refresh_editing_saved_reset_policy(socket, id)
        nil -> socket
      end

    {socket, _closed?} = close_lost_account_dialogs(socket)
    socket
  end

  defp sync_saved_reset_status_timer(socket) do
    if connected?(socket) and saved_reset_status_targets(socket) != [] do
      socket = LiveUpdatesHooks.hold(socket)

      if is_reference(socket.assigns.saved_reset_status_timer) do
        socket
      else
        assign(socket, :saved_reset_status_timer, Process.send_after(self(), :refresh_saved_reset_status_tick, @saved_reset_status_interval_ms))
      end
    else
      cancel_saved_reset_status_timer(socket)
    end
  end

  defp cancel_saved_reset_status_timer(socket) do
    if is_reference(socket.assigns[:saved_reset_status_timer]) do
      Process.cancel_timer(socket.assigns.saved_reset_status_timer, async: false, info: false)
    end

    assign(socket, :saved_reset_status_timer, nil)
  end

  defp invalidate_saved_reset_status(socket) do
    socket =
      case socket.assigns.saved_reset_status_running do
        %{generation: generation} -> cancel_async(socket, {:saved_reset_status, generation})
        nil -> socket
      end

    assign(socket, saved_reset_status_generation: socket.assigns.saved_reset_status_generation + 1, saved_reset_status_running: nil, saved_reset_status_rerun: nil)
  end

  defp saved_reset_view_assigns(assigns) do
    paused? = assigns[:live_updates_paused?] == true
    connected? = match?(%{transport_pid: pid} when is_pid(pid), assigns.socket)
    running = assigns.saved_reset_status_running

    decorate = fn account ->
      operation = SavedResetOperationProjection.observe(account.saved_reset_operation, paused?: paused?, connected?: connected?)

      account |> Map.put(:saved_reset_operation, operation) |> Map.put(:saved_reset_status_refreshing?, running != nil and account.identity.id in running.identity_ids) |> Map.put(:deletion_updates_paused?, paused?)
    end

    assigns
    |> assign(:upstream_accounts, Enum.map(assigns.upstream_accounts, decorate))
    |> assign(:editing_saved_reset_policy, if(assigns.editing_saved_reset_policy, do: decorate.(assigns.editing_saved_reset_policy)))
  end

  defp cancel_upstreams_reload_timer(socket) do
    if is_reference(socket.assigns[:upstreams_reload_timer]) do
      Process.cancel_timer(socket.assigns.upstreams_reload_timer, async: false, info: false)
    end

    assign(socket, :upstreams_reload_timer, nil)
  end

  defp filtered_pools(pools, %{"pool_id" => pool_id}) when is_binary(pool_id) and pool_id != "" do
    Enum.filter(pools, &(&1.id == pool_id))
  end

  defp filtered_pools(pools, _filter_values), do: pools

  defp maybe_subscribe_pool_events(socket, pools) do
    pools
    |> PoolEventSubscriptions.pool_id_set()
    |> then(fn target_pool_ids ->
      {socket, _stale_pool_ids} = PoolEventSubscriptions.reconcile(socket, target_pool_ids)
      socket
    end)
  end

  defp selected_pool(pools, pool_id) when is_binary(pool_id),
    do: Enum.find(pools, &(&1.id == pool_id))

  defp selected_pool(_pools, _pool_id), do: nil

  defp find_account(accounts, identity_id) do
    Enum.find(accounts, &(&1.identity.id == identity_id))
  end

  @type account_panel_view :: :tokens | :pools

  @spec toggle_account_panel_view(map(), String.t(), account_panel_view()) :: map()
  defp toggle_account_panel_view(panel_views, identity_id, target_view)
       when is_map(panel_views) and is_binary(identity_id) do
    case Map.get(panel_views, identity_id, :usage) do
      ^target_view -> Map.delete(panel_views, identity_id)
      _view -> Map.put(panel_views, identity_id, target_view)
    end
  end

  @spec prune_account_panel_views(map(), [UpstreamAccountsReadModel.account_snapshot()]) :: map()
  defp prune_account_panel_views(panel_views, accounts)
       when is_map(panel_views) and is_list(accounts) do
    visible_account_ids = MapSet.new(accounts, & &1.identity.id)

    Map.filter(panel_views, fn {identity_id, view} ->
      MapSet.member?(visible_account_ids, identity_id) and view in [:tokens, :pools]
    end)
  end

  defp pool_options(pools) do
    pools
    |> Enum.map(&{pool_name(&1), &1.id})
    |> case do
      [] -> [{gettext("No active Pools available"), ""}]
      options -> options
    end
  end

  defp pool_name(nil), do: gettext("Unknown Pool")
  defp pool_name(pool), do: pool.name

  defp dialog_pool_options(pools) do
    pools
    |> Enum.map(&{pool_name(&1), &1.id})
    |> case do
      [] -> [{gettext("No active Pools available"), ""}]
      options -> options
    end
  end

  defp close_account_workflow_dialogs(socket) do
    socket
    |> AuthJsonWorkflow.close()
    |> close_rename_account_dialog()
    |> AccountLifecycleWorkflow.close_delete()
    |> OAuthWorkflow.close()
    |> close_saved_reset_policy_dialog()
    |> ProviderCreditsWorkflow.close()
  end

  defp close_lost_account_dialogs(socket) do
    visible_account_ids = MapSet.new(socket.assigns.upstream_accounts, & &1.identity.id)
    lost? = &(match?(%{identity: %{id: _id}}, &1) and not MapSet.member?(visible_account_ids, &1.identity.id))
    no_pools? = socket.assigns.pools == []

    {socket, false}
    |> close_if(lost?.(socket.assigns.renaming_account), &close_rename_account_dialog/1)
    |> close_if(lost?.(socket.assigns.deleting_account), &AccountLifecycleWorkflow.close_delete/1)
    |> close_if(provider_credits_control_lost?(socket), &ProviderCreditsWorkflow.close/1)
    |> close_if(lost?.(socket.assigns.editing_saved_reset_policy), &close_saved_reset_policy_dialog/1)
    |> close_if(lost?.(socket.assigns.confirming_saved_reset_redemption), &assign(&1, :confirming_saved_reset_redemption, nil))
    |> close_if(socket.assigns.oauth_linking and (lost?.(socket.assigns.oauth_link_target_account) or no_pools?), &OAuthWorkflow.close/1)
    |> close_if(socket.assigns.importing_auth_json and no_pools?, &AuthJsonWorkflow.close/1)
  end

  defp provider_credits_control_lost?(socket) do
    case socket.assigns.editing_provider_credits_policy do
      %{identity: %{id: identity_id}} ->
        not Enum.any?(socket.assigns.upstream_accounts, &(&1.identity.id == identity_id and &1.can_manage_provider_credits?))

      nil ->
        false
    end
  end

  defp url_dialog_lost?(%{assigns: %{editing_pool: %{id: pool_id}, current_scope: scope}}),
    do: match?({:error, _reason}, PoolEditorWorkflow.find_editable_pool(scope, pool_id))

  defp url_dialog_lost?(%{assigns: %{creating_invite: true, pools: []}}), do: true
  defp url_dialog_lost?(_socket), do: false

  defp close_if({socket, _closed?}, true, close), do: {close.(socket), true}
  defp close_if({socket, closed?}, false, _close), do: {socket, closed?}

  defp close_rename_account_dialog(socket) do
    assign(socket,
      renaming_account: nil,
      rename_account_form: nil
    )
  end

  @spec close_saved_reset_policy_dialog(Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  defp close_saved_reset_policy_dialog(socket) do
    assign(socket,
      editing_saved_reset_policy: nil,
      saved_reset_policy_form: saved_reset_policy_form(%{}),
      confirming_saved_reset_redemption: nil
    )
  end

  defp rename_account_form(account_or_identity, attrs \\ %{}, action \\ nil)

  defp rename_account_form(%{identity: %UpstreamIdentity{} = identity}, attrs, action),
    do: rename_account_form(identity, attrs, action)

  defp rename_account_form(%UpstreamIdentity{} = identity, attrs, action) do
    identity
    |> UpstreamIdentity.changeset(attrs)
    |> Map.put(:action, action)
    |> Phoenix.Component.to_form(as: :rename)
  end

  defp rename_account_form(nil, _attrs, _action), do: nil

  @spec saved_reset_policy_form(map(), map(), atom() | nil) :: Phoenix.HTML.Form.t()
  defp saved_reset_policy_form(policy, attrs \\ %{}, action \\ nil) do
    policy
    |> saved_reset_policy_changeset(attrs, action)
    |> Phoenix.Component.to_form(as: :saved_reset_policy)
  end

  @spec saved_reset_policy_changeset(map(), map(), atom() | nil) :: Ecto.Changeset.t()
  defp saved_reset_policy_changeset(policy, attrs, action) do
    data = %{
      auto_redeem_enabled: Map.get(policy, :enabled?, false),
      trigger_mode: Map.get(policy, :trigger_mode, "blocked"),
      quota_threshold_percent: Map.get(policy, :quota_threshold_percent, 95),
      min_blocked_minutes: Map.get(policy, :min_blocked_minutes, 60),
      keep_credits: Map.get(policy, :keep_credits, 0)
    }

    {data,
     %{
       auto_redeem_enabled: :boolean,
       trigger_mode: :string,
       quota_threshold_percent: :integer,
       min_blocked_minutes: :integer,
       keep_credits: :integer
     }}
    |> Ecto.Changeset.cast(attrs, [
      :auto_redeem_enabled,
      :trigger_mode,
      :quota_threshold_percent,
      :min_blocked_minutes,
      :keep_credits
    ])
    |> Ecto.Changeset.validate_inclusion(:trigger_mode, ["blocked", "threshold"])
    |> Ecto.Changeset.validate_number(:quota_threshold_percent,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> Ecto.Changeset.validate_number(:min_blocked_minutes, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:keep_credits, greater_than_or_equal_to: 0)
    |> Map.put(:action, action)
  end

  @spec current_saved_reset_policy(Phoenix.LiveView.Socket.t()) :: map()
  defp current_saved_reset_policy(socket) do
    case socket.assigns.editing_saved_reset_policy do
      %{saved_reset_policy: policy} when is_map(policy) -> policy
      _account -> %{}
    end
  end
end
