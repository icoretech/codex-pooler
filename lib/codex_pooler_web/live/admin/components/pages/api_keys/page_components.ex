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
    <dialog
      id="api-key-created-secret-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            API key
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Copy this key before closing</h2>
          <p id="api-key-created-secret" class="mt-2 text-sm leading-6 text-base-content/70">
            It is shown once. Afterwards only the fingerprint
            <span class="font-semibold text-base-content">{@created_secret.key_prefix}</span>
            identifies it.
          </p>
        </div>

        <div class="grid gap-5 p-5 sm:p-6">
          <AdminComponents.one_time_secret
            value={@created_secret.raw_key}
            value_id="api-key-created-secret-value"
            copy_id="api-key-copy-created-secret"
            copy_label="Copy key"
            copy_aria_label="Copy API key"
          />
        </div>

        <AdminComponents.dialog_footer
          id="api-key-created-secret-dialog-footer"
          docs_url={@api_key_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="api-key-secret-dialog-close"
              icon="hero-check"
              label="Done"
              phx-click="close_secret"
              variant={:primary}
            />
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
    <dialog
      id="api-key-delete-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-error">API key</p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">
            Delete {@api_key.display_name}?
          </h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            It stops working immediately, and its request history goes with it. This cannot be undone.
          </p>
        </div>

        <.form
          id="api-key-delete-form"
          for={@form}
          phx-submit="confirm_delete_api_key"
          autocomplete="off"
          class="grid gap-5 p-5 sm:p-6"
        >
          <.input field={@form[:id]} type="hidden" />
          <.input
            field={@form[:confirmation_prefix]}
            id={"api_key_delete_confirmation_prefix_#{@form_version}"}
            type="text"
            label={"Type #{@api_key.key_prefix} to confirm"}
            placeholder={@api_key.key_prefix}
            pattern={@api_key.key_prefix}
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
              label="Cancel"
              variant={:ghost}
              phx-click="cancel_delete_api_key"
            />
            <AdminComponents.action_button
              id="api-key-delete-submit"
              icon="hero-trash"
              label="Delete"
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
        <header class="flex min-w-0 flex-wrap content-start items-center justify-between gap-3 rounded-t-[calc(var(--radius-box)-1px)] border-b border-base-300 bg-primary/5 p-4 xl:rounded-l-[calc(var(--radius-box)-1px)] xl:rounded-tr-none xl:border-r xl:border-b-0">
          <span class="grid size-9 shrink-0 place-items-center rounded-field border border-primary/30 bg-primary/15 text-primary">
            <.icon name="hero-server-stack" class="size-4" />
          </span>
          <%!-- Beside the icon wherever it fits, on its own line where it does
          not. On a phone the icon and the count leave it around 78px, and a
          Pool called "Production Europe West Failover Cluster" came out broken
          mid-word — "Productio / n Europe" — so there it drops below them. At
          `xl` the header is a 13rem column and it drops below again. --%>
          <div class="min-w-0 order-last basis-full sm:order-none sm:flex-1 sm:basis-auto xl:order-last xl:flex-none xl:basis-full">
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
            class="relative grid min-w-0 grid-cols-1 items-start gap-x-3 p-4 transition-colors last:rounded-b-[calc(var(--radius-box)-1px)] hover:bg-base-200/60 focus-within:z-30 xl:grid-cols-[minmax(12rem,0.9fr)_minmax(12rem,0.85fr)_minmax(14rem,1fr)_auto] xl:gap-4 xl:last:rounded-bl-none"
          >
            <div class="grid min-w-0 gap-2 xl:contents">
              <div id={"api-key-row-#{api_key.id}-key"} class="grid min-w-0 gap-1.5 xl:content-start">
                <%!-- Only this line makes room for the chip and the menu, which
                sit over it below `xl`. The status vocabulary is closed and
                validated — active, paused, revoked — so the widest of them plus
                the gap and the menu is what `pr-24` reserves. --%>
                <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 pr-24 xl:pr-0">
                  <span class="truncate font-semibold text-base-content">
                    {api_key.display_name}
                  </span>
                </div>
                <div
                  :if={api_key.dashboard_access or ApiKeysReadModel.api_key_operator_notes(api_key)}
                  class="flex flex-wrap items-center gap-x-3 gap-y-1 xl:flex-col xl:items-start xl:gap-x-0 xl:gap-y-1"
                >
                  <.link
                    :if={api_key.dashboard_access}
                    id={"api-key-row-#{api_key.id}-observatory"}
                    href={~p"/observatory/login"}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex w-fit items-center gap-1 text-xs font-medium text-primary transition-colors hover:text-primary/80 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
                  >
                    <.icon name="hero-sparkles" class="size-3.5" />
                    <span>Observatory</span>
                  </.link>
                  <.api_key_notes_popover
                    :if={ApiKeysReadModel.api_key_operator_notes(api_key)}
                    id={"api-key-row-#{api_key.id}-notes"}
                    notes={ApiKeysReadModel.api_key_operator_notes(api_key)}
                  />
                </div>
              </div>
              <%!-- Two by two below `xl`, on the vitals block the operator
              cards already use: a label over its value never shares a line with
              it, so it stops wrapping in a column this narrow. --%>
              <div class="grid min-w-0 grid-cols-2 gap-x-3 gap-y-2.5 text-xs leading-5 text-base-content/65 xl:contents">
                <dl class="contents xl:grid xl:content-start xl:gap-2">
                  <div
                    id={"api-key-row-#{api_key.id}-last-used"}
                    class="min-w-0 xl:grid xl:gap-0.5"
                  >
                    <dt class={card_vital_label_class()}>Last used</dt>
                    <dd class="truncate tabular-nums">
                      {last_used_label(api_key.last_used_at, @datetime_preferences)}
                    </dd>
                  </div>
                  <div class="min-w-0 xl:grid xl:gap-0.5">
                    <dt class={card_vital_label_class()}>Prefix</dt>
                    <dd class="flex min-w-0 items-center gap-1">
                      <span class="min-w-0 truncate">{api_key.key_prefix}</span>
                      <button
                        id={"api-key-row-#{api_key.id}-prefix-copy"}
                        type="button"
                        phx-hook="ClipboardCopy"
                        data-copy-text={api_key.key_prefix}
                        class="inline-grid size-5 shrink-0 place-items-center rounded text-base-content/40 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-primary"
                        aria-label="Copy key prefix"
                      >
                        <.icon name="hero-clipboard-document" class="copy-icon size-3.5" />
                      </button>
                    </dd>
                  </div>
                </dl>
                <div class="contents xl:grid xl:content-start xl:gap-2">
                  <div
                    id={"api-key-row-#{api_key.id}-expires"}
                    class="min-w-0 xl:grid xl:gap-0.5"
                  >
                    <span class={["block", card_vital_label_class()]}>Expires</span>
                    <span class={[
                      "block truncate tabular-nums",
                      expiry_label_class(api_key.expires_at)
                    ]}>
                      {expiry_label(api_key.expires_at, @datetime_preferences)}
                    </span>
                  </div>
                  <div class="min-w-0 xl:grid xl:gap-1">
                    <span class={["block", card_vital_label_class()]}>Model access</span>
                    <div
                      id={"api-key-row-#{api_key.id}-models"}
                      class="flex min-w-0 flex-wrap items-center gap-1"
                    >
                      <.model_access_badges models={api_key.allowed_model_identifiers} />
                    </div>
                  </div>
                  <span
                    :if={
                      ApiKeysReadModel.model_policy_warning_label(
                        Map.get(@model_policy_summaries, api_key.id)
                      )
                    }
                    id={"api-key-row-#{api_key.id}-model-policy-warning"}
                    class="col-span-2 inline-flex basis-full items-start gap-1.5 text-xs font-medium leading-5 text-warning xl:col-span-1 xl:basis-auto"
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
            </div>
            <%!-- Out of flow below `xl`, where it was a full-height column
            reserving a third of the card's width for a chip and a menu that
            occupy one line of it. The name row reserves the width instead. --%>
            <div
              data-role="api-key-actions"
              class="absolute right-4 top-4 z-10 flex h-6 items-center gap-2 xl:relative xl:inset-auto xl:h-auto xl:justify-self-end"
            >
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
    <div
      data-role="api-key-actions-menu"
      class="dropdown dropdown-end relative inline-block focus-within:z-50"
    >
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
        data-role="api-key-action-menu"
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

  # The same label the operator cards name a vital with, from the same
  # definition — these rows sit two clicks apart and used to disagree about what
  # a fact label is.
  defp card_vital_label_class,
    do: [AdminComponents.card_fact_label_class(), "text-base-content/35"]

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
    <details
      id={@id}
      class="dropdown inline-flex"
      phx-click-away={JS.remove_attribute("open", to: "##{@id}")}
    >
      <summary
        id={"#{@id}-button"}
        class="inline-flex w-fit cursor-pointer list-none items-center gap-1 text-xs font-medium text-base-content/55 transition-colors hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary [&::-webkit-details-marker]:hidden"
        aria-label="Show API key notes"
      >
        <.icon name="hero-document-text" class="size-3.5" />
        <span>Notes</span>
      </summary>
      <div
        id={"#{@id}-content"}
        class="dropdown-content z-50 mt-2 w-72 overflow-hidden rounded-box border border-base-300 bg-base-100 p-3 text-left shadow-2xl"
      >
        <p class="font-mono text-[0.62rem] font-semibold uppercase tracking-[0.18em] text-primary">
          Operator notes
        </p>
        <p class="mt-2 text-xs font-normal leading-5 text-base-content/70">{@notes}</p>
      </div>
    </details>
    """
  end

  attr :models, :any, required: true

  defp model_access_badges(%{models: nil} = assigns) do
    ~H"""
    <span class="min-w-0 truncate">All models</span>
    """
  end

  defp model_access_badges(%{models: []} = assigns) do
    ~H"""
    <span class="min-w-0 truncate text-warning">No models</span>
    """
  end

  defp model_access_badges(assigns) do
    ~H"""
    <span :for={model <- @models} class={model_chip_class()} title={model}>{model}</span>
    """
  end

  defp model_chip_class,
    do:
      "inline-flex max-w-full items-center truncate rounded-full border border-base-300 bg-base-200 px-2 py-0.5 text-[0.7rem] font-medium leading-4 text-base-content/70"
end
