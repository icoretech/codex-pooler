defmodule CodexPoolerWeb.Admin.UpstreamsLive do
  use CodexPoolerWeb, :admin_live_view

  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PoolEventSubscriptions
  alias CodexPoolerWeb.Admin.PoolFilterComponents
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamAuthJsonImport
  alias CodexPoolerWeb.Admin.UpstreamFilterForm
  alias CodexPoolerWeb.Admin.UpstreamPageComponents
  alias CodexPoolerWeb.DateTimeDisplay

  @upstreams_reload_debounce_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Upstreams",
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
        renaming_account: nil,
        rename_account_form: nil,
        subscribed_pool_ids: MapSet.new(),
        upstreams_reload_timer: nil
      )
      |> allow_upload(:auth_json,
        accept: ~w(.json),
        max_entries: 1,
        max_file_size: UpstreamAuthJsonImport.upload_limit_bytes(),
        chunk_size: 16_000,
        chunk_timeout: 5_000,
        auto_upload: true
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket |> close_auth_json_dialog() |> close_rename_account_dialog() |> load_upstreams(params)}
  end

  @impl true
  def handle_info({Events, %{topics: topics}}, socket) do
    if "upstreams" in topics do
      {:noreply, schedule_upstreams_reload(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:reload_upstreams_from_events, socket) do
    {:noreply,
     socket
     |> assign(:upstreams_reload_timer, nil)
     |> reload_upstreams()}
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/admin/upstreams?#{UpstreamFilterForm.query_params(filter_params)}"
     )}
  end

  def handle_event("select_pool_filter", %{"pool-id" => pool_id}, socket) do
    params = Map.put(socket.assigns.filter_values, "pool_id", pool_id)

    {:noreply,
     push_patch(socket, to: ~p"/admin/upstreams?#{UpstreamFilterForm.query_params(params)}")}
  end

  def handle_event("clear_upstream_query_filter", _params, socket) do
    params = Map.put(socket.assigns.filter_values, "query", "")

    {:noreply,
     push_patch(socket, to: ~p"/admin/upstreams?#{UpstreamFilterForm.query_params(params)}")}
  end

  def handle_event("select_status_filter", %{"status" => status}, socket) do
    params = Map.put(socket.assigns.filter_values, "status", status)

    {:noreply,
     push_patch(socket, to: ~p"/admin/upstreams?#{UpstreamFilterForm.query_params(params)}")}
  end

  @impl true
  def handle_event("import_auth_json", %{"auth_json" => auth_json_params}, socket) do
    pool = selected_pool(socket.assigns.pools, auth_json_params["pool_id"])

    case import_auth_json_content(socket, auth_json_params) do
      {:ok, content, socket} ->
        do_import_auth_json(socket, pool, auth_json_params, content)

      {:error, message, socket} ->
        {:noreply,
         socket
         |> put_flash(:error, "Codex auth.json could not be imported")
         |> assign(
           :auth_json_form,
           UpstreamAuthJsonImport.form_with_error(auth_json_params["pool_id"], :content, message)
         )
         |> assign(:importing_auth_json, true)}
    end
  end

  def handle_event("open_import_auth_json", params, socket) do
    {:noreply,
     socket
     |> cancel_auth_json_upload_entries()
     |> assign(
       importing_auth_json: true,
       auth_json_form: auth_json_form_for_open(socket.assigns.pools, params)
     )}
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
         UpstreamAuthJsonImport.form_for_pool(auth_json_params["pool_id"])
       )}
    end
  end

  def handle_event("cancel_auth_json_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :auth_json, ref)}
  end

  def handle_event("open_rename_account", %{"id" => identity_id}, socket) do
    case find_account(socket.assigns.upstream_accounts, identity_id) do
      %{identity: %UpstreamIdentity{} = identity} = account ->
        {:noreply,
         assign(socket,
           renaming_account: account,
           rename_account_form: rename_account_form(identity)
         )}

      nil ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}
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
       rename_account_form(socket.assigns.renaming_account, rename_params, :validate)
     )}
  end

  def handle_event("rename_account", %{"rename" => rename_params}, socket) do
    case socket.assigns.renaming_account do
      %{identity: %UpstreamIdentity{} = identity} ->
        do_rename_account(socket, identity, rename_params)

      nil ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}
    end
  end

  def handle_event("pause_account", %{"id" => identity_id}, socket) do
    lifecycle_action(
      socket,
      identity_id,
      &Upstreams.pause_account_for_scope/3,
      "Upstream account paused"
    )
  end

  def handle_event("reactivate_account", %{"id" => identity_id}, socket) do
    lifecycle_action(
      socket,
      identity_id,
      &Upstreams.reactivate_account_for_scope/3,
      "Upstream account reactivated"
    )
  end

  def handle_event("delete_account", %{"id" => identity_id}, socket) do
    lifecycle_action(
      socket,
      identity_id,
      &Upstreams.soft_delete_account_for_scope/3,
      "Upstream account deleted"
    )
  end

  def handle_event("refresh_account", %{"id" => identity_id}, socket) do
    case Upstreams.enqueue_token_refresh_for_scope(socket.assigns.current_scope, identity_id,
           trigger_kind: "admin_upstreams_live"
         ) do
      {:ok, %{job: job}} ->
        message =
          if job.conflict?, do: "Token refresh is already queued", else: "Token refresh queued"

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> reload_upstreams()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp do_rename_account(socket, %UpstreamIdentity{} = identity, rename_params) do
    case Upstreams.rename_account_for_scope(
           socket.assigns.current_scope,
           identity.id,
           rename_params
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Upstream account renamed")
         |> close_rename_account_dialog()
         |> reload_upstreams()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           rename_account_form: Phoenix.Component.to_form(changeset, as: :rename),
           renaming_account: socket.assigns.renaming_account
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp do_import_auth_json(socket, pool, auth_json_params, content) do
    case Upstreams.import_codex_auth_json(socket.assigns.current_scope, pool, content) do
      {:ok, %{status: :created}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Codex auth.json imported")
         |> assign(:auth_json_form, UpstreamAuthJsonImport.empty_form())
         |> assign(:importing_auth_json, false)
         |> reload_upstreams()}

      {:ok, %{status: :existing}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Codex auth.json matched an existing account; tokens updated")
         |> assign(:auth_json_form, UpstreamAuthJsonImport.empty_form())
         |> assign(:importing_auth_json, false)
         |> reload_upstreams()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Codex auth.json could not be imported")
         |> assign(:importing_auth_json, true)
         |> assign(:auth_json_form, Phoenix.Component.to_form(changeset, as: :auth_json))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(:importing_auth_json, true)
         |> assign(
           :auth_json_form,
           UpstreamAuthJsonImport.form_for_pool(auth_json_params["pool_id"])
         )}
    end
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
        renaming_account={@renaming_account}
        rename_account_form={@rename_account_form}
        upstream_accounts={@upstream_accounts}
        uploads={@uploads}
        datetime_preferences={@datetime_preferences}
      />
    </AdminComponents.admin_shell>
    """
  end

  defp lifecycle_action(socket, identity_id, operation, success_message) do
    case operation.(socket.assigns.current_scope, identity_id, %{reason: "admin_upstreams_live"}) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, success_message)
         |> reload_upstreams()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  defp load_upstreams(socket, params) do
    pools = Pools.list_visible_pools(socket.assigns.current_scope)
    filter_values = UpstreamFilterForm.filter_values(params, pools)
    filtered_pools = filtered_pools(pools, filter_values)

    upstream_accounts =
      UpstreamAccountsReadModel.list_visible_accounts(
        socket.assigns.current_scope,
        filtered_pools,
        filter_values,
        DateTimeDisplay.preferences_for_user(socket.assigns.current_scope.user)
      )

    socket =
      socket
      |> cancel_upstreams_reload_timer()
      |> maybe_subscribe_pool_events(filtered_pools)

    assign(socket,
      pools: pools,
      pool_options: pool_options(pools),
      dialog_pool_options: dialog_pool_options(pools),
      pool_filter_options: PoolFilterComponents.pool_filter_options(pools),
      filter_values: filter_values,
      filter_form: UpstreamFilterForm.filter_form(filter_values),
      status_options: UpstreamFilterForm.status_options(),
      upstream_accounts: upstream_accounts
    )
  end

  defp reload_upstreams(socket), do: load_upstreams(socket, socket.assigns.filter_values)

  defp schedule_upstreams_reload(socket) do
    if is_reference(socket.assigns[:upstreams_reload_timer]) do
      socket
    else
      timer =
        Process.send_after(
          self(),
          :reload_upstreams_from_events,
          @upstreams_reload_debounce_ms
        )

      assign(socket, :upstreams_reload_timer, timer)
    end
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

  defp auth_json_form_for_open(pools, %{"pool-id" => pool_id}) do
    case selected_pool(pools, pool_id) do
      nil -> UpstreamAuthJsonImport.empty_form()
      _pool -> UpstreamAuthJsonImport.form_for_pool(pool_id)
    end
  end

  defp auth_json_form_for_open(_pools, _params), do: UpstreamAuthJsonImport.empty_form()

  defp find_account(accounts, identity_id) do
    Enum.find(accounts, &(&1.identity.id == identity_id))
  end

  defp pool_options(pools) do
    pools
    |> Enum.map(&{pool_name(&1), &1.id})
    |> case do
      [] -> [{"No active Pools available", ""}]
      options -> options
    end
  end

  defp pool_name(nil), do: "Unknown Pool"
  defp pool_name(pool), do: pool.name

  defp dialog_pool_options(pools) do
    pools
    |> Enum.map(&{pool_name(&1), &1.id})
    |> case do
      [] -> [{"No active Pools available", ""}]
      options -> options
    end
  end

  defp close_auth_json_dialog(socket) do
    socket
    |> cancel_auth_json_upload_entries()
    |> assign(
      importing_auth_json: false,
      auth_json_form: UpstreamAuthJsonImport.empty_form()
    )
  end

  defp close_rename_account_dialog(socket) do
    assign(socket,
      renaming_account: nil,
      rename_account_form: nil
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

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_reason), do: "Operation failed"
end
