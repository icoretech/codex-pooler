defmodule CodexPoolerWeb.Admin.InvitesLive do
  use CodexPoolerWeb, :live_view

  alias CodexPooler.Access
  alias CodexPooler.Events
  alias CodexPooler.Mailer
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.InviteCreationDialog
  alias CodexPoolerWeb.Admin.InvitesPageComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.PoolFilterComponents
  alias CodexPoolerWeb.Admin.PoolInviteForm

  @page_size 50
  @status_options [
    %{label: "Any status", value: "", icon: "hero-envelope", tone: :neutral},
    %{label: "Active", value: "active", icon: "hero-paper-airplane", tone: :primary},
    %{label: "Accepted", value: "accepted", icon: "hero-check-circle", tone: :success},
    %{label: "Expired", value: "expired", icon: "hero-clock", tone: :warning},
    %{label: "Revoked", value: "revoked", icon: "hero-no-symbol", tone: :error}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Invites",
       pools: [],
       invites: empty_invites(),
       filter_form: to_form(%{}, as: :filters),
       filter_values: %{},
       pool_filter_options: [],
       status_options: @status_options,
       subscribed_pool_ids: MapSet.new(),
       creating_invite: false,
       invite_form: PoolInviteForm.empty_form(),
       invite_form_valid?: false,
       last_invite: nil,
       mailer_configured?: Mailer.configured?(),
       revoking_invite: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> load_invites(filter_params(params))
     |> maybe_prefill_invite_dialog(params)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/invites?#{query_params(filter_params)}")}
  end

  def handle_event("select_pool_filter", %{"pool-id" => pool_id}, socket) do
    params = Map.put(socket.assigns.filter_values, "pool_id", pool_id)

    {:noreply, push_patch(socket, to: ~p"/admin/invites?#{query_params(params)}")}
  end

  def handle_event("select_status_filter", %{"status" => status}, socket) do
    params = Map.put(socket.assigns.filter_values, "status", status)

    {:noreply, push_patch(socket, to: ~p"/admin/invites?#{query_params(params)}")}
  end

  def handle_event("reissue_invite", %{"id" => invite_id}, socket) do
    if socket.assigns.mailer_configured? do
      socket.assigns.current_scope
      |> Access.reissue_invite(invite_id)
      |> deliver_reissued_invite(socket)
    else
      {:noreply, put_flash(socket, :error, "SMTP is not configured for invite email.")}
    end
  end

  def handle_event("open_create_invite", _params, socket) do
    {:noreply,
     assign(socket,
       creating_invite: true,
       invite_form: PoolInviteForm.empty_form(),
       invite_form_valid?: false,
       last_invite: nil,
       revoking_invite: nil
     )}
  end

  def handle_event("cancel_create_invite", _params, socket) do
    {:noreply, close_invite_dialog(socket)}
  end

  def handle_event("validate_invite", %{"invite" => invite_params}, socket) do
    pool = selected_pool(socket.assigns.pools, invite_params["pool_id"])
    changeset = PoolInviteForm.changeset(invite_params, pool)

    {:noreply,
     socket
     |> assign(:invite_form, PoolInviteForm.form_for_changeset(changeset))
     |> assign(:invite_form_valid?, changeset.valid?)
     |> assign(:last_invite, nil)}
  end

  def handle_event("create_invite", %{"invite" => invite_params}, socket) do
    pool = selected_pool(socket.assigns.pools, invite_params["pool_id"])
    send_email? = PoolInviteForm.send_email?(invite_params, socket.assigns.mailer_configured?)
    changeset = PoolInviteForm.changeset(invite_params, pool)

    if changeset.valid? do
      case create_invite(socket, pool, invite_params, send_email?) do
        {:noreply, socket} -> {:noreply, assign(socket, :invite_form_valid?, false)}
      end
    else
      message =
        if pool,
          do: "Pool invite could not be created",
          else: "Select an active Pool before creating an invite"

      {:noreply,
       socket
       |> put_flash(:error, message)
       |> assign(:invite_form, PoolInviteForm.form_for_changeset(changeset))
       |> assign(:invite_form_valid?, false)
       |> assign(:creating_invite, true)
       |> assign(:last_invite, nil)}
    end
  end

  def handle_event("open_revoke_invite", %{"id" => invite_id}, socket) do
    {:noreply,
     assign(socket,
       revoking_invite: find_invite_row(socket, invite_id),
       creating_invite: false,
       last_invite: nil
     )}
  end

  def handle_event("cancel_revoke_invite", _params, socket) do
    {:noreply, assign(socket, revoking_invite: nil)}
  end

  def handle_event("confirm_revoke_invite", %{"id" => invite_id}, socket) do
    case Access.revoke_invite(socket.assigns.current_scope, invite_id) do
      {:ok, _invite} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pool invite revoked")
         |> assign(revoking_invite: nil)
         |> load_invites(socket.assigns.filter_values)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, invite_error_message(reason))}
    end
  end

  @impl true
  def handle_info({:email, _email}, socket) do
    {:noreply, socket}
  end

  def handle_info({Events, %{pool_id: pool_id, topics: topics}}, socket) do
    if "upstreams" in topics and invite_event_in_scope?(socket, pool_id) do
      {:noreply, load_invites(socket, socket.assigns.filter_values)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <AdminComponents.admin_shell flash={@flash} current_scope={@current_scope} active_nav={:invites}>
      <section id="admin-invites-live" class="grid gap-6">
        <AdminComponents.page_header
          id="invite-page-header"
          title="Invites"
          description="Review Pool invites, delivery status, and onboarding outcomes."
        >
          <:actions>
            <AdminComponents.action_button
              :if={@pools == []}
              id="invite-page-create-pool"
              icon="hero-server-stack"
              label="Create Pool"
              navigate={~p"/admin/pools"}
              size={:md}
              variant={:primary}
            />
            <AdminComponents.action_button
              :if={@pools != []}
              id="invite-page-create-action"
              icon="hero-user-plus"
              label="Create Pool invite"
              phx-click="open_create_invite"
              size={:md}
              variant={:primary}
            />
          </:actions>
        </AdminComponents.page_header>

        <InviteCreationDialog.pool_invite_dialog
          creating_invite={@creating_invite}
          invite_form={@invite_form}
          invite_form_valid?={@invite_form_valid?}
          last_invite={@last_invite}
          mailer_configured?={@mailer_configured?}
          pool_options={dialog_pool_options(@pools)}
        />

        <AdminComponents.filter_form
          id="invite-filter-form"
          for={@filter_form}
          phx-change="filter"
          phx-submit="filter"
          compact
        >
          <PoolFilterComponents.pool_filter_dropdown
            id="invite-pool-filter"
            label="Pool"
            hidden_id="filters_pool_id"
            selected_value={@filter_values["pool_id"] || ""}
            options={@pool_filter_options}
          />
          <InvitesPageComponents.invite_filter_dropdown
            id="invite-status-filter"
            label="Status"
            field_name="status"
            hidden_id="filters_status"
            role="status-filter"
            event="select_status_filter"
            value_attr={:status}
            selected_value={@filter_values["status"] || ""}
            options={@status_options}
          />
        </AdminComponents.filter_form>

        <InvitesPageComponents.invites_table
          invites={@invites}
          mailer_configured?={@mailer_configured?}
        />
        <InvitesPageComponents.invite_revoke_dialog invite={@revoking_invite} />
      </section>
    </AdminComponents.admin_shell>
    """
  end

  defp load_invites(socket, params) do
    pools = Pools.list_visible_pools(socket.assigns.current_scope)
    form_values = filter_values(params, pools)
    filters = parsed_filters(form_values)

    invites =
      Access.list_invites(socket.assigns.current_scope, limit: @page_size, filters: filters)

    socket = maybe_subscribe_pool_events(socket, pools, form_values["pool_id"])

    assign(socket,
      pools: pools,
      invites: invites,
      filter_form: to_form(form_values, as: :filters),
      filter_values: form_values,
      pool_filter_options: PoolFilterComponents.pool_filter_options(pools)
    )
  end

  defp filter_params(%{"create" => "1"} = params),
    do: Map.drop(params, ["create", "pool_id", "invited_email", "send_email"])

  defp filter_params(params), do: Map.drop(params, ["create", "invited_email", "send_email"])

  defp maybe_prefill_invite_dialog(socket, %{"create" => "1"} = params) do
    pool_id = selected_pool_id(Map.get(params, "pool_id", ""), socket.assigns.pools)

    invite_params = %{
      "pool_id" => pool_id,
      "invited_email" => string_param(params, "invited_email"),
      "send_email" => send_email_param(params)
    }

    socket
    |> assign(
      creating_invite: true,
      last_invite: nil,
      revoking_invite: nil
    )
    |> prefill_invite_form(params, invite_params, pool_id)
  end

  defp maybe_prefill_invite_dialog(socket, _params), do: socket

  defp prefill_invite_form(socket, params, invite_params, pool_id) do
    if validate_invite_prefill?(params) do
      changeset =
        PoolInviteForm.changeset(invite_params, selected_pool(socket.assigns.pools, pool_id))

      assign(socket,
        invite_form: PoolInviteForm.form_for_changeset(changeset),
        invite_form_valid?: changeset.valid?
      )
    else
      assign(socket,
        invite_form: PoolInviteForm.form_for_params(invite_params),
        invite_form_valid?: false
      )
    end
  end

  defp validate_invite_prefill?(params) do
    explicit_param?(params, "invited_email") or explicit_param?(params, "send_email")
  end

  defp explicit_param?(params, key) do
    match?(value when is_binary(value) and value != "", Map.get(params, key))
  end

  defp string_param(params, key) do
    case Map.get(params, key, "") do
      value when is_binary(value) -> value
      _value -> ""
    end
  end

  defp send_email_param(params) do
    case Map.get(params, "send_email") do
      value when value in ["true", "false"] -> value
      _value -> "false"
    end
  end

  defp create_invite(socket, pool, invite_params, send_email?) do
    case pool && Access.create_invite(socket.assigns.current_scope, pool, invite_params) do
      {:ok, %{invite: invite, token: token} = result} ->
        invite_url = url(~p"/onboarding/invites/#{token}")

        result =
          Access.maybe_deliver_pool_invite_email(
            result,
            send_email?,
            invite_url,
            pool,
            socket.assigns.current_scope
          )

        {:noreply,
         socket
         |> put_flash(:info, PoolInviteForm.created_flash(result))
         |> load_invites(socket.assigns.filter_values)
         |> assign(:invite_form, PoolInviteForm.empty_form())
         |> assign(:invite_form_valid?, false)
         |> assign(:creating_invite, true)
         |> assign(:last_invite, PoolInviteForm.receipt(pool, invite, invite_url, result))}

      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Select an active Pool before creating an invite")
         |> assign(:invite_form, PoolInviteForm.form_for_params(invite_params))
         |> assign(:invite_form_valid?, false)
         |> assign(:creating_invite, true)
         |> assign(:last_invite, nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Pool invite could not be created")
         |> assign(:invite_form, PoolInviteForm.form_for_changeset(changeset))
         |> assign(:invite_form_valid?, false)
         |> assign(:creating_invite, true)
         |> assign(:last_invite, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, invite_error_message(reason))
         |> assign(:invite_form, PoolInviteForm.form_for_params(invite_params))
         |> assign(:invite_form_valid?, false)
         |> assign(:creating_invite, true)
         |> assign(:last_invite, nil)}
    end
  end

  defp filter_values(params, pools) do
    pool_id =
      params
      |> Map.get("pool_id", "")
      |> selected_pool_id(pools)

    %{
      "pool_id" => pool_id,
      "status" => selected_status(Map.get(params, "status", ""))
    }
  end

  defp parsed_filters(values) do
    []
    |> maybe_put_filter(:pool_id, values["pool_id"])
    |> maybe_put_filter(:status, values["status"])
    |> maybe_put_filter(:email, values["email"])
  end

  defp query_params(params) do
    %{
      "pool_id" => Map.get(params, "pool_id", ""),
      "status" => selected_status(Map.get(params, "status", ""))
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp maybe_put_filter(filters, _key, value) when value in [nil, ""], do: filters
  defp maybe_put_filter(filters, key, value), do: Keyword.put(filters, key, value)

  defp dialog_pool_options(pools) do
    pools
    |> Enum.map(&{pool_name(&1), &1.id})
    |> case do
      [] -> [{"No active Pools available", ""}]
      options -> options
    end
  end

  defp pool_name(nil), do: "Unknown Pool"
  defp pool_name(pool), do: pool.name

  defp selected_pool(pools, pool_id) when is_binary(pool_id),
    do: Enum.find(pools, &(&1.id == pool_id))

  defp selected_pool(_pools, _pool_id), do: nil

  defp selected_pool_id(pool_id, pools) when is_binary(pool_id) do
    if Enum.any?(pools, &(&1.id == pool_id)), do: pool_id, else: ""
  end

  defp selected_pool_id(_pool_id, _pools), do: ""

  defp selected_status(status) when status in ~w(active accepted expired revoked), do: status
  defp selected_status(_status), do: ""

  defp deliver_reissued_invite({:ok, %{token: token, pool: pool} = result}, socket) do
    invite_url = url(~p"/onboarding/invites/#{token}")

    result
    |> Access.maybe_deliver_pool_invite_email(
      true,
      invite_url,
      pool,
      socket.assigns.current_scope
    )
    |> case do
      %{email_error?: true} ->
        {:noreply,
         socket
         |> put_flash(:error, "Pool invite reissued, but email delivery failed")
         |> load_invites(socket.assigns.filter_values)}

      %{email_error?: false} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pool invite reissued and emailed")
         |> load_invites(socket.assigns.filter_values)}
    end
  end

  defp deliver_reissued_invite({:error, reason}, socket),
    do: {:noreply, put_flash(socket, :error, invite_error_message(reason))}

  defp find_invite_row(socket, invite_id) do
    Enum.find(socket.assigns.invites.items, &(&1.id == invite_id))
  end

  defp close_invite_dialog(socket) do
    assign(socket,
      creating_invite: false,
      invite_form: PoolInviteForm.empty_form(),
      invite_form_valid?: false,
      last_invite: nil
    )
  end

  defp maybe_subscribe_pool_events(socket, _pools, selected_pool_id)
       when is_binary(selected_pool_id) and selected_pool_id != "" do
    PoolEventSubscriptions.reconcile(socket, MapSet.new([selected_pool_id]))
    |> elem(0)
  end

  defp maybe_subscribe_pool_events(socket, pools, _selected_pool_id) do
    pools
    |> PoolEventSubscriptions.pool_id_set()
    |> then(fn target_pool_ids ->
      {socket, _stale_pool_ids} = PoolEventSubscriptions.reconcile(socket, target_pool_ids)
      socket
    end)
  end

  defp invite_event_in_scope?(socket, pool_id) do
    case socket.assigns.filter_values["pool_id"] do
      selected_pool_id when is_binary(selected_pool_id) and selected_pool_id != "" ->
        selected_pool_id == pool_id

      _any_pool ->
        Enum.any?(socket.assigns.pools, &(&1.id == pool_id))
    end
  end

  defp empty_invites, do: %{items: [], total: 0, limit: @page_size}

  defp invite_error_message(%{message: message}), do: message
  defp invite_error_message(_reason), do: "Pool invite could not be updated"
end
