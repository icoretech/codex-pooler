defmodule CodexPoolerWeb.Admin.ApiKeysLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.ApiKeyPageComponents
  alias CodexPoolerWeb.Admin.ApiKeyPageSupport, as: Support
  alias CodexPoolerWeb.Admin.ApiKeyPolicyForm
  alias CodexPoolerWeb.Admin.ApiKeysReadModel
  alias CodexPoolerWeb.Admin.ApiKeyWizardComponents
  alias CodexPoolerWeb.Admin.ApiKeyWizardComponents.{Limits, Review}
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.DateTimeDisplay

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "API keys",
       pools: [],
       pool_lookup: %{},
       api_keys: [],
       filter_values: %{"pool_id" => ""},
       selected_pool: nil,
       api_key_model_policy_summaries: %{},
       api_key_form: nil,
       api_key_params: %{},
       api_key_pool_groups: [],
       model_policy_filter: nil,
       unavailable_model_policy_count: 0,
       api_key_wizard_step: "basics",
       api_key_model_selector_state: ApiKeysReadModel.empty_model_selector_state(),
       api_key_review_errors: [],
       creating_api_key: false,
       editing_api_key: nil,
       deleting_api_key: nil,
       delete_form: nil,
       delete_form_version: 0,
       created_secret: nil,
       pool_options: [],
       data_load_warnings: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_api_keys(socket, params, reset_form: true, clear_secret: true)}
  end

  @impl true
  def handle_event("save_api_key", %{"api_key" => api_key_params}, socket) do
    api_key_params = ApiKeyPolicyForm.merge_params(socket.assigns.api_key_params, api_key_params)
    socket = assign_api_key_wizard_state(socket, api_key_params)

    case socket.assigns.api_key_review_errors do
      [] ->
        case Support.blank_to_nil(api_key_params["id"]) do
          nil -> create_api_key(socket, api_key_params)
          api_key_id -> update_api_key(socket, api_key_id, api_key_params)
        end

      _errors ->
        {:noreply,
         socket
         |> put_flash(:error, "Resolve the policy warnings before saving")
         |> assign(:api_key_wizard_step, "review")}
    end
  end

  def handle_event("validate_api_key_wizard", %{"api_key" => api_key_params}, socket) do
    api_key_params = ApiKeyPolicyForm.merge_params(socket.assigns.api_key_params, api_key_params)

    {:noreply, assign_api_key_wizard_state(socket, api_key_params)}
  end

  def handle_event("api_key_wizard_step", %{"step" => step}, socket) do
    {:noreply, assign_api_key_wizard_step(socket, ApiKeyWizardComponents.normalize_step(step))}
  end

  def handle_event("api_key_wizard_next", _params, socket) do
    next_step = ApiKeyWizardComponents.next_step(socket.assigns.api_key_wizard_step)

    {:noreply, assign_api_key_wizard_step(socket, next_step)}
  end

  def handle_event("api_key_wizard_back", _params, socket) do
    {:noreply,
     assign(
       socket,
       :api_key_wizard_step,
       ApiKeyWizardComponents.previous_step(socket.assigns.api_key_wizard_step)
     )}
  end

  def handle_event("open_create_api_key", _params, socket) do
    params = ApiKeyPolicyForm.empty_params(socket.assigns.pools)

    {:noreply,
     socket
     |> assign(
       creating_api_key: true,
       editing_api_key: nil,
       created_secret: nil,
       api_key_wizard_step: "basics"
     )
     |> assign_api_key_wizard_state(params)}
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, close_create_dialog(socket)}
  end

  def handle_event("edit_api_key", %{"id" => api_key_id}, socket) do
    case Access.get_api_key_with_policy(socket.assigns.current_scope, api_key_id) do
      {:ok, %{api_key: %APIKey{} = api_key, policy_bindings: policy_bindings}} ->
        params = ApiKeyPolicyForm.params_for(api_key, policy_bindings)

        {:noreply,
         socket
         |> assign(
           creating_api_key: false,
           editing_api_key: api_key,
           created_secret: nil,
           api_key_wizard_step: "basics"
         )
         |> assign_api_key_wizard_state(params)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    params = ApiKeyPolicyForm.empty_params(socket.assigns.pools)

    {:noreply,
     socket
     |> assign(
       creating_api_key: false,
       editing_api_key: nil,
       created_secret: nil,
       api_key_wizard_step: "basics"
     )
     |> assign_api_key_wizard_state(params)}
  end

  def handle_event("close_secret", _params, socket) do
    {:noreply, assign(socket, :created_secret, nil)}
  end

  def handle_event("disable_api_key", %{"id" => api_key_id}, socket) do
    key_action(socket, api_key_id, &Access.pause_api_key/2, "API key disabled")
  end

  def handle_event("enable_api_key", %{"id" => api_key_id}, socket) do
    key_action(socket, api_key_id, &Access.resume_api_key/2, "API key enabled")
  end

  def handle_event("revoke_api_key", %{"id" => api_key_id}, socket) do
    key_action(socket, api_key_id, &Access.revoke_api_key/2, "API key revoked")
  end

  def handle_event("delete_api_key", %{"id" => api_key_id}, socket) do
    case find_api_key(socket, api_key_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "API key was not found")}

      %{id: _id} = api_key ->
        {:noreply,
         socket
         |> assign(
           creating_api_key: false,
           editing_api_key: nil,
           deleting_api_key: api_key,
           created_secret: nil,
           api_key_wizard_step: "basics"
         )
         |> assign_api_key_wizard_state(ApiKeyPolicyForm.empty_params(socket.assigns.pools))
         |> assign(:delete_form, Support.api_key_delete_form(api_key))
         |> update(:delete_form_version, &(&1 + 1))}
    end
  end

  def handle_event("cancel_delete_api_key", _params, socket) do
    {:noreply, clear_deleting_api_key(socket)}
  end

  def handle_event("confirm_delete_api_key", %{"api_key_delete" => delete_params}, socket) do
    api_key_id = delete_params["id"]
    confirmation_prefix = Support.blank_to_nil(delete_params["confirmation_prefix"])

    with %{id: deleting_api_key_id, key_prefix: deleting_api_key_prefix} <-
           socket.assigns.deleting_api_key,
         true <- deleting_api_key_id == api_key_id,
         true <- deleting_api_key_prefix == confirmation_prefix,
         {:ok, _api_key} <- Access.delete_api_key(socket.assigns.current_scope, api_key_id) do
      {:noreply,
       socket
       |> put_flash(:info, "API key deleted")
       |> clear_deleting_api_key()
       |> load_api_keys(reset_form: true)}
    else
      false ->
        {:noreply,
         socket
         |> put_flash(:error, "Type the API key prefix to confirm deletion")
         |> reset_delete_form()}

      nil ->
        {:noreply, put_flash(socket, :error, "API key was not found")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> reset_delete_form()}
    end
  end

  def handle_event("rotate_api_key", %{"id" => api_key_id}, socket) do
    case Access.rotate_api_key(socket.assigns.current_scope, api_key_id) do
      {:ok, %{api_key: api_key, raw_key: raw_key}} ->
        {:noreply,
         socket
         |> put_flash(:info, "API key rotated")
         |> assign(:created_secret, Support.created_secret(api_key, raw_key))
         |> assign(:creating_api_key, false)
         |> assign(:editing_api_key, nil)
         |> load_api_keys(reset_form: true)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  @impl true
  def handle_info({Events, %{pool_id: pool_id, topics: topics}}, socket)
      when is_binary(pool_id) and is_list(topics) do
    if api_key_event_in_scope?(socket, pool_id, topics) do
      {:noreply, load_api_keys(socket, reset_form: false, clear_secret: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({Events, _event}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:policy_limit_fields, ApiKeyPolicyForm.limit_fields())
      |> assign(
        :datetime_preferences,
        DateTimeDisplay.preferences_for_user(assigns.current_scope.user)
      )

    ~H"""
    <AdminComponents.admin_shell
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:api_keys}
      alert_notification_center={@alert_notification_center}
    >
      <section id="admin-api-keys-live" class="grid min-w-0 gap-6">
        <AdminComponents.page_header
          id="api-key-page-header"
          title="API keys"
          description="Create and manage API keys for each Pool, including model access, usage limits, rotation, and status."
        >
          <:actions>
            <AdminComponents.action_button
              :if={@pools == [] && Pools.owner?(@current_scope)}
              id="api-key-page-create-action"
              icon="hero-server-stack"
              label="Create Pool"
              navigate={~p"/admin/pools"}
              size={:md}
              variant={:primary}
            />
            <AdminComponents.action_button
              :if={@pools != []}
              id="api-key-page-create-action"
              icon="hero-key"
              label="Create API key"
              phx-click="open_create_api_key"
              size={:md}
              variant={:primary}
            />
          </:actions>
        </AdminComponents.page_header>

        <div
          :for={warning <- @data_load_warnings}
          id={"api-key-data-load-warning-#{warning.id}"}
          class="alert alert-warning items-start"
        >
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <div class="grid gap-1">
            <p class="font-semibold">{warning.title}</p>
            <p class="text-sm">{warning.message}</p>
          </div>
        </div>

        <ApiKeyPageComponents.created_secret_dialog
          :if={@created_secret}
          created_secret={@created_secret}
        />

        <ApiKeyWizardComponents.api_key_wizard
          :if={@creating_api_key || @editing_api_key}
          form={@api_key_form}
          mode={if(@creating_api_key, do: :create, else: :edit)}
          current_step={@api_key_wizard_step}
          review_errors={@api_key_review_errors}
          disabled={@pools == []}
        >
          <:basics>
            <ApiKeyWizardComponents.api_key_basics_step
              form={@api_key_form}
              pool_options={@pool_options}
              disabled={@pools == []}
            />
          </:basics>
          <:models>
            <ApiKeyWizardComponents.api_key_models_step
              form={@api_key_form}
              selector_state={@api_key_model_selector_state}
            />
          </:models>
          <:enforcement>
            <ApiKeyWizardComponents.api_key_enforcement_step
              form={@api_key_form}
              selector_state={@api_key_model_selector_state}
              enforced_model_options={
                ApiKeyPolicyForm.enforced_model_options(
                  @api_key_model_selector_state,
                  @api_key_form
                )
              }
              reasoning_effort_options={ApiKeyPolicyForm.reasoning_effort_options()}
              service_tier_options={ApiKeyPolicyForm.service_tier_options()}
            />
          </:enforcement>
          <:limits>
            <Limits.api_key_limits_step
              form={@api_key_form}
              limit_fields={@policy_limit_fields}
            />
          </:limits>
          <:review>
            <Review.api_key_review_step
              review_sections={
                ApiKeyPolicyForm.review_sections(
                  @api_key_form,
                  @api_key_model_selector_state,
                  ApiKeysReadModel.selected_pool(@pools, @api_key_params["pool_id"])
                )
              }
              review_errors={@api_key_review_errors}
              warnings={@api_key_model_selector_state.warnings}
            />
          </:review>
        </ApiKeyWizardComponents.api_key_wizard>

        <ApiKeyPageComponents.delete_api_key_dialog
          :if={@deleting_api_key}
          api_key={@deleting_api_key}
          form={@delete_form}
          form_version={@delete_form_version}
        />

        <ApiKeyPageComponents.api_key_groups
          pools={@pools}
          groups={@api_key_pool_groups}
          model_policy_summaries={@api_key_model_policy_summaries}
          datetime_preferences={@datetime_preferences}
          selected_pool={@selected_pool}
          model_policy_filter={@model_policy_filter}
          unavailable_model_policy_count={@unavailable_model_policy_count}
          can_manage_pools?={Pools.can_manage_pools?(@current_scope)}
        />
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp create_api_key(socket, api_key_params) do
    pool = ApiKeysReadModel.selected_pool(socket.assigns.pools, api_key_params["pool_id"])

    case Access.create_api_key(
           socket.assigns.current_scope,
           pool,
           ApiKeyPolicyForm.attrs(api_key_params)
         ) do
      {:ok, %{api_key: api_key, raw_key: raw_key}} ->
        {:noreply,
         socket
         |> put_flash(:info, "API key created")
         |> assign(:created_secret, Support.created_secret(api_key, raw_key))
         |> assign(:creating_api_key, false)
         |> assign(:editing_api_key, nil)
         |> load_api_keys(reset_form: true)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(:api_key_wizard_step, "review")
         |> assign_api_key_wizard_state(api_key_params)}
    end
  end

  defp update_api_key(socket, api_key_id, api_key_params) do
    case Access.update_api_key_with_policy(
           socket.assigns.current_scope,
           api_key_id,
           ApiKeyPolicyForm.attrs(api_key_params)
         ) do
      {:ok, _api_key} ->
        {:noreply,
         socket
         |> put_flash(:info, "API key updated")
         |> assign(:created_secret, nil)
         |> assign(:creating_api_key, false)
         |> assign(:editing_api_key, nil)
         |> load_api_keys(reset_form: true)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(:api_key_wizard_step, "review")
         |> assign_api_key_wizard_state(api_key_params)}
    end
  end

  defp key_action(socket, api_key_id, operation, success_message) do
    case operation.(socket.assigns.current_scope, api_key_id) do
      {:ok, _api_key} ->
        {:noreply,
         socket
         |> put_flash(:info, success_message)
         |> assign(:created_secret, nil)
         |> assign(:creating_api_key, false)
         |> assign(:editing_api_key, nil)
         |> load_api_keys(reset_form: true)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp find_api_key(socket, api_key_id) do
    Enum.find(socket.assigns.api_keys, &(&1.id == api_key_id))
  end

  defp close_create_dialog(socket) do
    params = ApiKeyPolicyForm.empty_params(socket.assigns.pools)

    assign(socket,
      creating_api_key: false,
      created_secret: nil,
      api_key_wizard_step: "basics"
    )
    |> assign_api_key_wizard_state(params)
  end

  defp clear_deleting_api_key(socket) do
    assign(socket, deleting_api_key: nil, delete_form: nil)
  end

  defp reset_delete_form(%{assigns: %{deleting_api_key: %{id: _id} = api_key}} = socket) do
    socket
    |> assign(:delete_form, Support.api_key_delete_form(api_key))
    |> update(:delete_form_version, &(&1 + 1))
  end

  defp reset_delete_form(socket), do: clear_deleting_api_key(socket)

  defp load_api_keys(socket, opts) do
    load_api_keys(socket, socket.assigns.filter_values || %{}, opts)
  end

  defp load_api_keys(socket, params, opts) do
    read_model = ApiKeysReadModel.load(socket.assigns.current_scope, params)

    socket
    |> assign(read_model)
    |> maybe_subscribe_pool_events(read_model.pools)
    |> maybe_reset_form(opts, read_model.pools)
    |> assign_api_key_wizard_state()
    |> Support.maybe_clear_secret(opts)
  end

  defp maybe_subscribe_pool_events(socket, pools) do
    pools
    |> PoolEventSubscriptions.pool_id_set()
    |> then(fn target_pool_ids ->
      {socket, _stale_pool_ids} =
        PoolEventSubscriptions.reconcile(socket, target_pool_ids, ["pools"])

      socket
    end)
  end

  defp api_key_event_in_scope?(socket, pool_id, topics) do
    case Events.validate_topics(topics) do
      {:ok, topics} ->
        "pools" in topics and MapSet.member?(socket.assigns.subscribed_pool_ids, pool_id)

      {:error, :invalid_topics} ->
        false
    end
  end

  defp maybe_reset_form(socket, opts, pools) do
    if Keyword.get(opts, :reset_form, false) or is_nil(socket.assigns.api_key_form) do
      params = ApiKeyPolicyForm.empty_params(pools)

      assign(socket,
        api_key_params: params,
        api_key_form: ApiKeyPolicyForm.form(params),
        api_key_wizard_step: "basics"
      )
    else
      socket
    end
  end

  defp assign_api_key_wizard_state(socket) do
    assign_api_key_wizard_state(
      socket,
      socket.assigns.api_key_params || ApiKeyPolicyForm.empty_params(socket.assigns.pools)
    )
  end

  defp assign_api_key_wizard_state(socket, params) do
    params = ApiKeyPolicyForm.normalize_params(params, socket.assigns.pools)
    form = ApiKeyPolicyForm.form(params, errors: ApiKeyPolicyForm.input_errors(params))
    pool = ApiKeysReadModel.selected_pool(socket.assigns.pools, params["pool_id"])
    model_selector_state = ApiKeysReadModel.model_selector_state(pool, params)
    review_errors = ApiKeyPolicyForm.review_errors(params)

    assign(socket,
      api_key_params: params,
      api_key_form: form,
      api_key_model_selector_state: model_selector_state,
      api_key_review_errors: review_errors
    )
  end

  defp error_message(reason), do: Support.error_message(reason)

  defp assign_api_key_wizard_step(socket, "review") do
    if ApiKeyPolicyForm.expiry_errors(socket.assigns.api_key_params) == [] do
      assign(socket, :api_key_wizard_step, "review")
    else
      assign(socket, :api_key_wizard_step, "basics")
    end
  end

  defp assign_api_key_wizard_step(socket, step), do: assign(socket, :api_key_wizard_step, step)
end
