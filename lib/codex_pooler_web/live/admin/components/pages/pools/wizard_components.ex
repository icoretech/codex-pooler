defmodule CodexPoolerWeb.Admin.PoolWizardComponents do
  @moduledoc """
  Pool create/edit wizard presentation components.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PolicyEditorComponents
  alias CodexPoolerWeb.Admin.PoolForm
  alias CodexPoolerWeb.Admin.PoolModelServingComponents

  @pool_wizard_steps [
    %{id: :details, label: "Details", description: "Name and lifecycle"},
    %{id: :routing, label: "Routing", description: "Strategy"},
    %{id: :upstreams, label: "Upstreams", description: "Linked accounts"},
    %{id: "api-keys", label: "API keys", description: "Linked keys"},
    %{id: :models, label: "Models", description: "Serving mode"}
  ]

  @pool_docs_url "https://docs.codex-pooler.com/operators/pools/"

  @pool_wizard_step_ids Enum.map(@pool_wizard_steps, &to_string(&1.id))

  @pool_wizard_modes %{
    create: %{
      id: "pool-create-dialog",
      title: "Create Pool",
      description:
        "Create the operational boundary used by API keys, upstream assignments, routing policy, and audit filters.",
      form_id: "pool-create-form",
      form_submit: "create_pool",
      cancel_event: "cancel_create",
      cancel_id: "pool-create-cancel",
      submit_id: "pool-create-submit",
      submit_label: "Create Pool",
      submit_icon: "hero-plus",
      routing_controls_id: "pool-create-routing-controls",
      upstream_field: :upstream_identity_ids,
      upstream_options_id: "pool-create-upstream-identity-options",
      upstream_count_id: "pool-create-upstream-identity-count",
      upstream_empty_label: "No active upstream accounts are available yet.",
      access_options_id: "pool-create-api-key-options",
      access_count_id: "pool-create-api-key-count"
    },
    edit: %{
      id: "pool-edit-dialog",
      title: "Edit Pool",
      description:
        "Update lifecycle details, routing, upstream assignments, and related API key context.",
      form_id: "pool-edit-form",
      form_submit: "save_pool",
      cancel_event: "cancel_edit",
      cancel_id: "pool-edit-cancel",
      submit_id: "pool-edit-submit",
      submit_label: "Save Pool",
      submit_icon: "hero-check",
      routing_controls_id: "pool-edit-routing-controls",
      upstream_field: :upstream_identity_ids,
      upstream_options_id: "pool-edit-upstream-assignment-options",
      upstream_count_id: "pool-edit-upstream-assignment-count",
      upstream_empty_label: "No active upstream accounts are available yet.",
      access_options_id: "pool-edit-api-key-options",
      access_count_id: "pool-edit-api-key-count"
    }
  }

  @pool_status_choices [
    %{
      value: "active",
      label: "Active",
      dot: "bg-success",
      description:
        "Receives new runtime work when an active API key and eligible upstreams are assigned."
    },
    %{
      value: "disabled",
      label: "Disabled",
      dot: "bg-warning",
      description: "Stays configured and visible for operations; does not admit new runtime work."
    },
    %{
      value: "archived",
      label: "Archived",
      dot: "bg-base-content/40",
      description: "Kept for historical reporting and cleanup."
    }
  ]

  @pool_step_headings %{
    "details" => %{
      title: "Pool details",
      description: "Set the operator-facing name and lifecycle state for this Pool."
    },
    "routing" => %{
      title: "Routing strategy",
      description: "Choose how this Pool selects upstream accounts for runtime requests."
    },
    "upstreams" => %{
      title: "Pool upstream assignments",
      description: "Select the upstream accounts available to this Pool."
    },
    "api-keys" => %{
      title: "API Keys",
      description: "Select the API keys assigned to this Pool."
    },
    "models" => %{
      title: "Model serving modes",
      description:
        "Choose the Responses serving path for each model currently known to this Pool."
    }
  }

  def normalize_step(step) when step in @pool_wizard_step_ids, do: step
  def normalize_step(_step), do: "details"

  def normalize_step("models", :create), do: "details"
  def normalize_step(step, mode) when mode in [:create, :edit], do: normalize_step(step)

  attr :mode, :atom, required: true, values: [:create, :edit]
  attr :form, :any, required: true
  attr :current_step, :string, required: true
  attr :upstream_options, :list, required: true
  attr :api_key_options, :list, required: true
  attr :model_serving_form, :any, default: nil
  attr :model_serving_status, :atom, default: :idle
  attr :model_serving_dirty?, :boolean, default: false
  attr :model_serving_sync_pending?, :boolean, default: false

  def pool_wizard(assigns) do
    assigns =
      assigns
      |> assign(pool_wizard_config(assigns.mode))
      |> assign(:docs_url, @pool_docs_url)
      |> assign(:steps, pool_wizard_steps(assigns.mode))
      |> assign(:step_heading, pool_step_heading(assigns.current_step))
      |> assign(:status_choices, @pool_status_choices)

    ~H"""
    <div
      id={"#{@id}-responsive-shell"}
      class="contents sm:[&_.policy-editor-tabs]:grid-cols-2!"
    >
      <PolicyEditorComponents.policy_editor_dialog
        id={@id}
        eyebrow={@title}
        title={@step_heading.title}
        description={@step_heading.description}
        steps={@steps}
        current_step={@current_step}
        sections_label="Pool sections"
        step_event="pool_wizard_step"
        backdrop_event={@cancel_event}
        docs_url={@docs_url}
      >
        <.form
          id={@form_id}
          for={@form}
          phx-submit={@form_submit}
          autocomplete="off"
          class="grid min-w-0 gap-4"
        >
          <.input :if={@mode == :edit} field={@form[:id]} type="hidden" />

          <div
            id={"#{@id}-section-details"}
            role="tabpanel"
            aria-labelledby={"#{@id}-tab-details"}
            class={step_panel_class(@current_step, "details")}
          >
            <section id={"#{@id}-step-details-panel"} class="grid min-w-0 gap-5">
              <div class="grid min-w-0 gap-1">
                <div class="max-w-md">
                  <.input
                    field={@form[:name]}
                    type="text"
                    label="Name"
                    placeholder="Production Pool"
                    required
                  />
                </div>
                <p class="text-xs leading-4 text-base-content/55">
                  Operator-facing — shown across the admin, alerts, and audit history.
                </p>
              </div>

              <fieldset :if={@mode == :edit} class="grid min-w-0 gap-2">
                <legend class="label mb-1">Status</legend>
                <div
                  id="pool_edit_status"
                  role="radiogroup"
                  aria-label="Pool status"
                  class="grid min-w-0 gap-2 md:grid-cols-3"
                >
                  <label
                    :for={choice <- @status_choices}
                    class="flex min-w-0 cursor-pointer items-start gap-2.5 rounded-box border border-base-300 bg-base-100 p-2.5 transition-colors hover:border-primary/50 has-[:checked]:border-primary/60 has-[:checked]:bg-primary/5"
                  >
                    <input
                      id={"pool_edit_status_#{choice.value}"}
                      type="radio"
                      class="radio radio-primary radio-xs mt-0.5 shrink-0"
                      name="pool_edit[status]"
                      value={choice.value}
                      checked={to_string(@form[:status].value) == choice.value}
                    />
                    <span class="grid min-w-0 gap-0.5">
                      <span class="flex items-center gap-1.5 text-[13px] font-semibold leading-tight text-base-content">
                        <span class={["size-1.5 rounded-full", choice.dot]}></span>
                        {choice.label}
                      </span>
                      <span class="text-xs leading-4 text-base-content/60">
                        {choice.description}
                      </span>
                    </span>
                  </label>
                </div>
                <p class="flex items-center gap-1.5 text-xs text-base-content/55">
                  <.icon name="hero-information-circle" class="size-4 shrink-0" />
                  Hard deletion is available only after a Pool is archived.
                </p>
              </fieldset>

              <p
                :if={@mode == :create}
                class="flex items-center gap-1.5 text-xs text-base-content/55"
              >
                <.icon name="hero-information-circle" class="size-4 shrink-0" />
                Lifecycle status becomes editable after the Pool is created.
              </p>

              <div
                :if={@mode == :edit}
                class="flex min-w-0 flex-wrap items-center gap-3 rounded-box border border-dashed border-base-content/20 px-3 py-2"
              >
                <span class="text-[0.6rem] font-bold uppercase tracking-wide text-base-content/50">
                  Pool ID
                </span>
                <span class="break-all text-[10.5px] font-normal tracking-[0.015em] text-base-content/55">
                  {@form[:id].value}
                </span>
                <button
                  id="pool-edit-pool-id-copy"
                  type="button"
                  phx-hook="ClipboardCopy"
                  data-copy-text={@form[:id].value}
                  data-copy-label="Copy"
                  data-copied-label="Copied"
                  class="btn btn-ghost btn-xs ml-auto gap-1.5 text-base-content/60 hover:text-base-content"
                >
                  <.icon name="hero-clipboard-document" class="copy-icon size-3.5" />
                  <span data-copy-label>Copy</span>
                </button>
              </div>
            </section>
          </div>

          <div
            id={"#{@id}-section-routing"}
            role="tabpanel"
            aria-labelledby={"#{@id}-tab-routing"}
            class={step_panel_class(@current_step, "routing")}
          >
            <section id={"#{@id}-step-routing-panel"} class="grid min-w-0 gap-5">
              <div id={@routing_controls_id} class="pool-routing-policy-form grid">
                <div class="pool-routing-policy-row">
                  <div class="min-w-0">
                    <p class="text-sm font-semibold text-base-content">Selection policy</p>
                    <p class="text-xs leading-5 text-base-content/55">
                      Strategy and fan-out size used for runtime requests.
                    </p>
                  </div>
                  <div class="grid min-w-0 gap-3 sm:grid-cols-[minmax(0,1fr)_9rem]">
                    <.input
                      field={@form[:routing_strategy]}
                      type="select"
                      label="Routing strategy"
                      class="select select-bordered w-full"
                      options={PoolForm.routing_strategy_options()}
                    />
                    <.input
                      field={@form[:bridge_ring_size]}
                      type="number"
                      label="Ring size"
                      class="input input-bordered w-full"
                      min="1"
                    />
                  </div>
                </div>

                <div class="routing-matrix">
                  <div class="routing-matrix-section">
                    <div class="min-w-0">
                      <p class="text-sm font-semibold text-base-content">Continuity</p>
                      <p class="text-xs leading-5 text-base-content/55">
                        Identity-aware routing behavior.
                      </p>
                    </div>
                    <div class="routing-matrix-options">
                      <div class="routing-matrix-option">
                        <.input
                          field={@form[:sticky_websocket_sessions]}
                          type="checkbox"
                          label="Sticky websocket sessions"
                        />
                        <p class="routing-option-help">
                          Same upstream for websocket sessions with continuity identity.
                        </p>
                      </div>
                      <div class="routing-matrix-option">
                        <.input
                          field={@form[:sticky_http_sessions]}
                          type="checkbox"
                          label="HTTP affinity"
                        />
                        <p class="routing-option-help">
                          Same upstream preference for related HTTP requests.
                        </p>
                      </div>
                      <div class="routing-matrix-option">
                        <.input
                          field={@form[:prompt_cache_affinity_enabled]}
                          type="checkbox"
                          label="Prompt cache affinity"
                        />
                        <p class="routing-option-help">
                          Keep related prompt-cache-key requests near the same upstream for routing locality only.
                          Codex Pooler does not store prompts or responses for this control.
                        </p>
                      </div>
                    </div>
                  </div>

                  <div class="routing-matrix-section">
                    <div class="min-w-0">
                      <p class="text-sm font-semibold text-base-content">Compatibility</p>
                      <p class="text-xs leading-5 text-base-content/55">
                        Optional client surfaces.
                      </p>
                    </div>
                    <div class="routing-matrix-options">
                      <div class="routing-matrix-option">
                        <.input
                          field={@form[:v1_compatibility_enabled]}
                          type="checkbox"
                          label="Allow /v1 compatibility"
                        />
                        <p class="routing-option-help">
                          OpenAI-style `/v1` compatibility routes.
                        </p>
                      </div>
                      <div class="routing-matrix-option">
                        <.input
                          field={@form[:request_compression_enabled]}
                          type="checkbox"
                          label="Request compression"
                        />
                        <p class="routing-option-help">
                          Shrinks eligible Responses tool outputs before upstream dispatch.
                        </p>
                      </div>
                      <div class="routing-matrix-option">
                        <.input
                          field={@form[:allow_image_generation]}
                          type="checkbox"
                          label="Allow Image Generation"
                        />
                        <p class="routing-option-help">
                          Permits image generation and edits for requests using this Pool.
                        </p>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </section>
          </div>

          <div
            id={"#{@id}-section-upstreams"}
            role="tabpanel"
            aria-labelledby={"#{@id}-tab-upstreams"}
            class={step_panel_class(@current_step, "upstreams")}
          >
            <section id={"#{@id}-step-upstreams-panel"} class="grid min-w-0 gap-5">
              <.assignment_checkbox_cards
                id={@upstream_options_id}
                field={@form[@upstream_field]}
                options={@upstream_options}
                empty_label={@upstream_empty_label}
                filter_placeholder="Filter accounts…"
                count_id={@upstream_count_id}
              />
            </section>
          </div>

          <div
            id={"#{@id}-section-api-keys"}
            role="tabpanel"
            aria-labelledby={"#{@id}-tab-api-keys"}
            class={step_panel_class(@current_step, "api-keys")}
          >
            <section id={"#{@id}-step-api-keys-panel"} class="grid min-w-0 gap-5">
              <.assignment_checkbox_cards
                id={@access_options_id}
                field={@form[:api_key_ids]}
                options={@api_key_options}
                empty_label="No API keys are available yet."
                filter_placeholder="Filter keys…"
                count_id={@access_count_id}
              />
            </section>
          </div>
        </.form>

        <div
          :if={@mode == :edit}
          id={"#{@id}-section-models"}
          class={step_panel_class(@current_step, "models")}
          role="tabpanel"
          aria-labelledby={"#{@id}-tab-models"}
        >
          <PoolModelServingComponents.model_serving_panel
            projection={@model_serving_form}
            status={@model_serving_status}
            dirty?={@model_serving_dirty?}
            sync_pending?={@model_serving_sync_pending?}
          />
        </div>

        <:actions>
          <span
            :if={@mode == :edit && @current_step == "models" && @model_serving_dirty?}
            id="pool-model-serving-dirty-status"
            class={[AdminBadges.metadata_chip_class(:warning), "self-center"]}
          >
            Unsaved changes
          </span>
          <AdminComponents.action_button
            id={@cancel_id}
            label="Cancel"
            variant={:ghost}
            phx-click={@cancel_event}
          />
          <AdminComponents.action_button
            :if={
              @mode == :edit && @current_step == "models" && @model_serving_form &&
                @model_serving_form.rows != []
            }
            id="pool-model-serving-submit"
            icon="hero-check"
            label="Save model modes"
            type="submit"
            form="pool-model-serving-form"
            variant={:primary}
          />
          <AdminComponents.action_button
            :if={@current_step != "models"}
            id={@submit_id}
            icon={@submit_icon}
            label={@submit_label}
            type="submit"
            form={@form_id}
            variant={:primary}
          />
        </:actions>
      </PolicyEditorComponents.policy_editor_dialog>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true
  attr :empty_label, :string, required: true
  attr :filter_placeholder, :string, default: "Filter…"
  attr :count_id, :string, required: true

  defp assignment_checkbox_cards(assigns) do
    assigns = assign(assigns, :options, sort_selected_first(assigns.options, assigns.field))

    ~H"""
    <section id={@id} class="grid gap-2" phx-hook="AssignmentTools">
      <input type="hidden" name={PoolForm.field_array_name(@field)} value="" />
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <input
          :if={@options != []}
          id={"#{@id}-filter"}
          type="text"
          data-role="assignment-filter"
          placeholder={@filter_placeholder}
          aria-label={@filter_placeholder}
          autocomplete="off"
          class="input input-sm w-52 max-w-full"
        />
        <span id={@count_id} class="text-xs font-semibold tabular-nums text-base-content/60">
          {length(@options)} available
        </span>
        <div :if={@options != []} class="ml-auto flex items-center gap-1">
          <button
            id={"#{@id}-select-all"}
            type="button"
            data-assignment-action="select-all"
            class="btn btn-ghost btn-xs text-base-content/60 hover:text-base-content"
          >
            Select all
          </button>
          <button
            id={"#{@id}-clear"}
            type="button"
            data-assignment-action="clear"
            class="btn btn-ghost btn-xs text-base-content/60 hover:text-base-content"
          >
            Clear
          </button>
        </div>
      </div>
      <div
        class="grid max-h-[max(8.5rem,calc(100dvh-23rem))] content-start gap-2 overflow-y-auto sm:grid-cols-2"
        data-assignment-scroll="true"
      >
        <label
          :for={option <- @options}
          id={"#{@id}-card-#{PoolForm.dom_token(PoolForm.option_value(option))}"}
          class="flex min-h-10 min-w-0 cursor-pointer items-center gap-3 rounded-box border border-base-300 bg-base-100 px-3 py-1.5 transition-colors hover:border-primary/50 hover:bg-primary/5 has-[:checked]:border-primary/40 has-[:checked]:bg-primary/5"
        >
          <input
            type="checkbox"
            class="checkbox checkbox-primary checkbox-sm shrink-0"
            name={PoolForm.field_array_name(@field)}
            value={PoolForm.option_value(option)}
            checked={PoolForm.selected_value?(@field.value, PoolForm.option_value(option))}
          />
          <span class="flex min-w-0 flex-1 flex-wrap items-center justify-between gap-2">
            <span class="truncate text-sm font-medium text-base-content">
              {PoolForm.option_label(option)}
            </span>
            <span class="flex shrink-0 flex-wrap items-center gap-2">
              <AdminBadges.plan_badge
                :if={PoolForm.option_badge_kind(option) == :plan}
                id={"#{@id}-plan-badge-#{PoolForm.dom_token(PoolForm.option_value(option))}"}
                data-role="plan-badge"
                label={PoolForm.option_plan_label(option)}
                family={PoolForm.option_plan_family(option)}
              />
              <span
                :if={PoolForm.option_badge_kind(option) != :plan}
                class={AdminBadges.count_chip_class()}
              >
                {PoolForm.option_plan_label(option)}
              </span>
              <span class={AdminBadges.lifecycle_chip_class(PoolForm.option_status(option))}>
                {PoolForm.option_status(option)}
              </span>
            </span>
          </span>
        </label>
        <p :if={@options == []} class="text-sm text-base-content/60">{@empty_label}</p>
      </div>
    </section>
    """
  end

  defp step_panel_class(current_step, step) do
    [
      "min-w-0",
      current_step == step && "block",
      current_step != step && "hidden"
    ]
  end

  defp pool_wizard_config(mode), do: Map.fetch!(@pool_wizard_modes, mode)

  defp pool_step_heading(step), do: Map.fetch!(@pool_step_headings, normalize_step(step))

  defp sort_selected_first(options, field) do
    Enum.sort_by(options, fn option ->
      selected? = PoolForm.selected_value?(field.value, PoolForm.option_value(option))
      {!selected?, String.downcase(to_string(PoolForm.option_label(option)))}
    end)
  end

  defp pool_wizard_steps(:edit), do: @pool_wizard_steps
  defp pool_wizard_steps(:create), do: Enum.reject(@pool_wizard_steps, &(&1.id == :models))
end
