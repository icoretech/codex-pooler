defmodule CodexPoolerWeb.Admin.ApiKeyPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.ApiKeysReadModel
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.DateTimeDisplay

  @api_key_docs_url "https://docs.codex-pooler.com/operators/api-keys/"

  attr :created_secret, :map, required: true

  def created_secret_dialog(assigns) do
    assigns = assign(assigns, :api_key_docs_url, @api_key_docs_url)

    ~H"""
    <dialog id="api-key-created-secret-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            API key secret
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Copy this API key now</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            This raw key is shown once. Future views only show fingerprint {@created_secret.key_prefix}.
          </p>
        </div>

        <div class="grid gap-5 p-6">
          <div id="api-key-created-secret" class="alert alert-success items-start">
            <.icon name="hero-key" class="size-5" />
            <div class="grid gap-1">
              <p class="font-semibold">Copy this API key before closing the dialog.</p>
              <p class="text-sm">It will not be shown again.</p>
            </div>
          </div>

          <div class="grid gap-2 rounded-box border border-base-300 bg-base-200 p-4">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              one-time api key
            </p>
            <div class="join w-full">
              <code
                id="api-key-created-secret-value"
                class="join-item min-h-10 flex-1 break-all border border-base-300 bg-base-100 px-3 py-2.5 font-mono text-sm text-base-content"
              >
                {@created_secret.raw_key}
              </code>
              <button
                id="api-key-copy-created-secret"
                type="button"
                class="btn btn-neutral join-item min-h-10"
                phx-hook="ClipboardCopy"
                phx-update="ignore"
                data-copy-text={@created_secret.raw_key}
                data-copy-label="Copy"
                data-copied-label="Copied"
                aria-label="Copy API key"
              >
                <.icon name="hero-clipboard-document" class="copy-icon size-4" />
                <span data-copy-label>Copy</span>
              </button>
            </div>
          </div>
        </div>

        <AdminComponents.dialog_footer
          id="api-key-created-secret-dialog-footer"
          docs_url={@api_key_docs_url}
        >
          <:actions>
            <button
              id="api-key-secret-dialog-close"
              type="button"
              class="btn btn-primary btn-sm"
              phx-click="close_secret"
            >
              Close
            </button>
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_secret">close</button>
      </form>
    </dialog>
    """
  end

  attr :api_key, :any, required: true
  attr :form, :any, required: true
  attr :form_version, :integer, required: true

  def delete_api_key_dialog(assigns) do
    assigns = assign(assigns, :api_key_docs_url, @api_key_docs_url)

    ~H"""
    <dialog id="api-key-delete-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">Hard delete</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Delete API key</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            This permanently removes the API key and its related request history from this instance.
          </p>
        </div>

        <.form
          id="api-key-delete-form"
          for={@form}
          phx-submit="confirm_delete_api_key"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input field={@form[:id]} type="hidden" />
          <div class="alert alert-warning items-start">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <div class="grid gap-1">
              <p class="font-semibold">
                This removes {@api_key.display_name} permanently.
              </p>
              <p class="text-sm">
                Type <span class="break-all font-semibold">{@api_key.key_prefix}</span> to confirm.
              </p>
            </div>
          </div>
          <.input
            field={@form[:confirmation_prefix]}
            id={"api_key_delete_confirmation_prefix_#{@form_version}"}
            type="text"
            label="Confirm prefix"
            placeholder={@api_key.key_prefix}
            required
          />
        </.form>

        <AdminComponents.dialog_footer
          id="api-key-delete-dialog-footer"
          docs_url={@api_key_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="api-key-delete-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_delete_api_key"
            />
            <AdminComponents.action_button
              id="api-key-delete-submit"
              icon="hero-trash"
              label="Delete API key"
              type="submit"
              form="api-key-delete-form"
              variant={:danger}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_delete_api_key">close</button>
      </form>
    </dialog>
    """
  end

  attr :pools, :list, required: true
  attr :groups, :list, required: true
  attr :model_policy_summaries, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :selected_pool, :any, default: nil
  attr :model_policy_filter, :string, default: nil
  attr :unavailable_model_policy_count, :integer, required: true
  attr :can_manage_pools?, :boolean, required: true

  def api_key_groups(assigns) do
    ~H"""
    <div id="admin-api-keys" class="grid min-w-0 gap-4">
      <div
        :if={@selected_pool}
        id="api-key-active-pool-filter"
        class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 pb-3 text-sm"
      >
        <span class="inline-flex min-w-0 items-center gap-2 text-base-content/70">
          <.icon name="hero-funnel" class="size-4 shrink-0 text-primary" /> Showing
          <span class="font-semibold text-base-content">{@selected_pool.name}</span>
        </span>
        <.link
          id="api-key-clear-pool-filter"
          patch={api_key_filter_path(nil, @model_policy_filter)}
          class="btn btn-ghost btn-xs"
        >
          Show all Pools
        </.link>
      </div>

      <div
        :if={@model_policy_filter == "unavailable"}
        id="api-key-active-model-policy-filter"
        class="flex flex-wrap items-center justify-between gap-3 border-b border-warning/30 pb-3 text-sm text-warning"
      >
        <span class="inline-flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          Unavailable model references: {ApiKeysReadModel.unavailable_model_policy_count_label(
            @unavailable_model_policy_count
          )}
        </span>
        <.link
          id="api-key-clear-model-policy-filter"
          patch={api_key_filter_path(@selected_pool, nil)}
          class="btn btn-ghost btn-xs"
        >
          Clear filter
        </.link>
      </div>

      <div
        :if={@model_policy_filter != "unavailable" and @unavailable_model_policy_count > 0}
        id="api-key-model-policy-attention"
        class="flex flex-wrap items-center justify-between gap-3 border-b border-warning/30 pb-3 text-sm"
      >
        <span class="inline-flex items-center gap-2 text-warning">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          Model policy attention: {ApiKeysReadModel.unavailable_model_policy_count_label(
            @unavailable_model_policy_count
          )}
        </span>
        <.link
          id="api-key-filter-unavailable-model-policies"
          patch={api_key_filter_path(@selected_pool, "unavailable")}
          class="btn btn-warning btn-outline btn-xs"
        >
          Show affected keys
        </.link>
      </div>

      <AdminComponents.empty_state
        :if={@groups == []}
        id="api-key-empty-state"
        title="No API keys"
        description={
          cond do
            @pools == [] -> "Create a Pool before adding API keys."
            @selected_pool -> "Create the first API key for this Pool."
            true -> "Create the first API key for an active Pool."
          end
        }
        icon="hero-key"
      >
        <:actions>
          <AdminComponents.action_button
            :if={@pools == [] && @can_manage_pools?}
            id="api-key-empty-create-action"
            icon="hero-server-stack"
            label="Create Pool"
            navigate={~p"/admin/pools"}
            variant={:primary}
          />
          <AdminComponents.action_button
            :if={@pools != []}
            id="api-key-empty-create-action"
            icon="hero-key"
            label="Create API key"
            phx-click="open_create_api_key"
            variant={:primary}
          />
        </:actions>
      </AdminComponents.empty_state>

      <section
        :for={group <- @groups}
        id={"api-key-pool-group-#{group.dom_id}"}
        class="grid min-w-0 overflow-visible rounded-box border border-base-300 bg-base-100 xl:grid-cols-[13rem_minmax(0,1fr)]"
      >
        <header class="flex min-w-0 flex-wrap content-start items-center gap-3 rounded-t-[calc(var(--radius-box)-1px)] border-b border-base-300 bg-primary/5 p-4 xl:justify-between xl:rounded-l-[calc(var(--radius-box)-1px)] xl:rounded-tr-none xl:border-r xl:border-b-0">
          <span class="grid size-9 shrink-0 place-items-center rounded-field border border-primary/30 bg-primary/15 text-primary">
            <.icon name="hero-server-stack" class="size-4" />
          </span>
          <div class="min-w-0 flex-1 xl:order-last xl:basis-full">
            <p class="text-xs font-medium text-base-content/55">Pool</p>
            <h2 class="break-words text-lg font-bold leading-6 text-base-content">{group.name}</h2>
          </div>
          <span
            id={"api-key-pool-group-#{group.dom_id}-count"}
            class={[AdminBadges.count_chip_class(), "shrink-0"]}
          >
            {group.count_label}
          </span>
        </header>

        <div
          id={"api-key-pool-group-#{group.dom_id}-table-scroll-region"}
          class="min-w-0 divide-y divide-base-300"
        >
          <article
            :for={api_key <- group.api_keys}
            id={"api-key-row-#{api_key.id}"}
            class="relative grid min-w-0 grid-cols-[minmax(0,1fr)_auto] items-start gap-x-3 p-4 transition-colors last:rounded-b-[calc(var(--radius-box)-1px)] hover:bg-base-200/60 focus-within:z-30 xl:grid-cols-[minmax(12rem,0.9fr)_minmax(12rem,0.85fr)_minmax(14rem,1fr)_auto] xl:gap-4 xl:last:rounded-bl-none"
          >
            <div class="grid min-w-0 gap-2 xl:contents">
              <div id={"api-key-row-#{api_key.id}-key"} class="grid min-w-0 gap-1.5 xl:content-start">
                <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
                  <span class="truncate font-semibold text-base-content">
                    {api_key.display_name}
                  </span>
                  <.api_key_notes_popover
                    :if={ApiKeysReadModel.api_key_operator_notes(api_key)}
                    id={"api-key-row-#{api_key.id}-notes"}
                    notes={ApiKeysReadModel.api_key_operator_notes(api_key)}
                  />
                </div>
              </div>
              <dl class="flex flex-wrap items-baseline gap-x-6 gap-y-1 text-sm text-base-content/70 xl:grid xl:content-start xl:gap-2">
                <div
                  id={"api-key-row-#{api_key.id}-last-used"}
                  class="flex items-baseline gap-1.5 xl:grid xl:gap-0.5"
                >
                  <dt class="text-xs font-medium text-base-content/50">Last used</dt>
                  <dd>{last_used_label(api_key.last_used_at, @datetime_preferences)}</dd>
                </div>
                <div class="flex min-w-0 items-baseline gap-1.5 xl:grid xl:gap-0.5">
                  <dt class="text-xs font-medium text-base-content/50">Prefix</dt>
                  <dd class="min-w-0 truncate">
                    {api_key.key_prefix}
                  </dd>
                </div>
              </dl>
              <div class="grid min-w-0 gap-1 text-sm text-base-content/70 xl:content-start xl:gap-2">
                <div
                  id={"api-key-row-#{api_key.id}-expires"}
                  class="flex items-baseline gap-1.5 xl:grid xl:gap-0.5"
                >
                  <span class="text-xs font-medium text-base-content/50">Expires</span>
                  <span class={expiry_label_class(api_key.expires_at)}>
                    {expiry_label(api_key.expires_at, @datetime_preferences)}
                  </span>
                </div>
                <div class="flex min-w-0 items-baseline gap-1.5 xl:grid xl:gap-0.5">
                  <span class="text-xs font-medium text-base-content/50">Model access</span>
                  <span
                    id={"api-key-row-#{api_key.id}-models"}
                    class="min-w-0 truncate xl:whitespace-normal"
                  >
                    {ApiKeysReadModel.model_policy_label(api_key.allowed_model_identifiers)}
                  </span>
                </div>
                <span
                  :if={
                    ApiKeysReadModel.model_policy_warning_label(
                      Map.get(@model_policy_summaries, api_key.id)
                    )
                  }
                  id={"api-key-row-#{api_key.id}-model-policy-warning"}
                  class="inline-flex items-start gap-1.5 text-xs font-medium leading-5 text-warning"
                >
                  <.icon name="hero-exclamation-triangle" class="mt-0.5 size-3.5 shrink-0" />
                  <span>
                    {ApiKeysReadModel.model_policy_warning_label(
                      Map.get(@model_policy_summaries, api_key.id)
                    )}
                  </span>
                </span>
              </div>
            </div>
            <div class="relative z-10 flex items-center gap-2 justify-self-end">
              <span
                id={"api-key-row-#{api_key.id}-status"}
                class={[AdminBadges.lifecycle_chip_class(api_key.status), "shrink-0"]}
              >
                {api_key.status}
              </span>
              <.api_key_actions_menu api_key={api_key} />
            </div>
          </article>
        </div>
      </section>
    </div>
    """
  end

  defp api_key_filter_path(selected_pool, model_policy_filter) do
    params =
      %{}
      |> maybe_put_pool_filter(selected_pool)
      |> maybe_put_model_policy_filter(model_policy_filter)

    if map_size(params) == 0 do
      ~p"/admin/api-keys"
    else
      ~p"/admin/api-keys?#{params}"
    end
  end

  defp maybe_put_pool_filter(params, %{id: pool_id}) when is_binary(pool_id),
    do: Map.put(params, "pool_id", pool_id)

  defp maybe_put_pool_filter(params, _selected_pool), do: params

  defp maybe_put_model_policy_filter(params, "unavailable"),
    do: Map.put(params, "model_policy", "unavailable")

  defp maybe_put_model_policy_filter(params, _model_policy_filter), do: params

  attr :api_key, :any, required: true

  defp api_key_actions_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end relative inline-block focus-within:z-50">
      <button
        id={"api-key-actions-menu-#{@api_key.id}"}
        type="button"
        class="btn btn-ghost btn-sm btn-square"
        tabindex="0"
        aria-label={"Actions for #{@api_key.display_name}"}
      >
        <.icon name="hero-ellipsis-vertical" class="size-5" />
      </button>
      <ul
        tabindex="0"
        class="menu dropdown-content z-50 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
      >
        <li>
          <AdminComponents.dropdown_action_item
            id={"edit-api-key-#{@api_key.id}"}
            icon="hero-pencil-square"
            label="Edit"
            phx-click="edit_api_key"
            phx-value-id={@api_key.id}
            disabled={@api_key.status == "revoked"}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"disable-api-key-#{@api_key.id}"}
            icon="hero-pause"
            label="Pause"
            variant={:warning}
            phx-click="disable_api_key"
            phx-value-id={@api_key.id}
            disabled={@api_key.status != "active"}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"enable-api-key-#{@api_key.id}"}
            icon="hero-play"
            label="Resume"
            variant={:positive}
            phx-click="enable_api_key"
            phx-value-id={@api_key.id}
            disabled={@api_key.status != "paused"}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"rotate-api-key-#{@api_key.id}"}
            icon="hero-arrow-path"
            label="Rotate"
            phx-click="rotate_api_key"
            phx-value-id={@api_key.id}
            disabled={@api_key.status == "revoked"}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"revoke-api-key-#{@api_key.id}"}
            icon="hero-no-symbol"
            label="Revoke"
            variant={:danger}
            phx-click="revoke_api_key"
            phx-value-id={@api_key.id}
            disabled={@api_key.status == "revoked"}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"delete-api-key-#{@api_key.id}"}
            icon="hero-trash"
            label="Delete"
            variant={:danger}
            phx-click="delete_api_key"
            phx-value-id={@api_key.id}
          />
        </li>
      </ul>
    </div>
    """
  end

  defp last_used_label(nil, _datetime_preferences), do: "Never used"

  defp last_used_label(%DateTime{} = last_used_at, datetime_preferences),
    do: DateTimeDisplay.format_datetime(last_used_at, datetime_preferences)

  defp last_used_label(_last_used_at, _datetime_preferences), do: "Never used"

  defp expiry_label(nil, _datetime_preferences), do: "No expiry"

  defp expiry_label(%DateTime{} = expires_at, datetime_preferences) do
    formatted = DateTimeDisplay.format_datetime(expires_at, datetime_preferences)

    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt,
      do: "Expired · #{formatted}",
      else: formatted
  end

  defp expiry_label(_expires_at, _datetime_preferences), do: "No expiry"

  defp expiry_label_class(%DateTime{} = expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt,
      do: "font-medium text-error",
      else: nil
  end

  defp expiry_label_class(_expires_at), do: nil

  attr :id, :string, required: true
  attr :notes, :string, required: true

  defp api_key_notes_popover(assigns) do
    ~H"""
    <span id={@id} class="dropdown dropdown-hover dropdown-right inline-flex">
      <button
        id={"#{@id}-button"}
        type="button"
        class="btn btn-ghost btn-xs btn-circle text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
        tabindex="0"
        aria-label="Show API key notes"
      >
        <.icon name="hero-information-circle" class="size-4" />
      </button>
      <span
        id={"#{@id}-content"}
        tabindex="0"
        class="dropdown-content z-20 ml-2 block w-72 rounded-box border border-base-300 bg-base-100 p-3 text-left text-xs font-normal leading-5 text-base-content/70 shadow-xl"
      >
        {@notes}
      </span>
    </span>
    """
  end
end
