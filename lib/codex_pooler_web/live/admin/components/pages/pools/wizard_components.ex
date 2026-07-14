defmodule CodexPoolerWeb.Admin.PoolWizardComponents do
  @moduledoc """
  Pool create/edit wizard presentation components.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PolicyEditorComponents
  alias CodexPoolerWeb.Admin.PoolForm

  @pool_wizard_steps [
    %{id: :details, label: "Details", description: "Name and lifecycle"},
    %{id: :routing, label: "Routing", description: "Strategy"},
    %{id: :upstreams, label: "Upstreams", description: "Linked accounts"},
    %{id: "api-keys", label: "API keys", description: "Linked keys"}
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

  def normalize_step(step) when step in @pool_wizard_step_ids, do: step
  def normalize_step(_step), do: "details"

  attr :mode, :atom, required: true, values: [:create, :edit]
  attr :form, :any, required: true
  attr :current_step, :string, required: true
  attr :upstream_options, :list, required: true
  attr :api_key_options, :list, required: true

  def pool_wizard(assigns) do
    assigns =
      assigns
      |> assign(pool_wizard_config(assigns.mode))
      |> assign(:docs_url, @pool_docs_url)
      |> assign(:steps, @pool_wizard_steps)

    ~H"""
    <PolicyEditorComponents.policy_editor_dialog
      id={@id}
      eyebrow="Pool configuration"
      title={@title}
      description={@description}
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
            <div class="grid gap-1">
              <h3 class="text-lg font-semibold text-base-content">Pool details</h3>
              <p class="text-sm leading-6 text-base-content/65">
                Set the operator-facing name and lifecycle state for this Pool.
              </p>
            </div>
            <div class={[
              @mode == :edit && "grid gap-4 md:grid-cols-2",
              @mode == :create && "grid gap-4"
            ]}>
              <.input
                field={@form[:name]}
                type="text"
                label="Name"
                placeholder="Production Pool"
                required
              />
              <.input
                :if={@mode == :edit}
                field={@form[:status]}
                type="select"
                label="Status"
                options={PoolForm.status_options()}
              />
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
            <div class="grid gap-1">
              <h3 class="text-lg font-semibold text-base-content">Routing strategy</h3>
              <p class="text-sm leading-6 text-base-content/65">
                Choose how this Pool selects upstream accounts for runtime requests.
              </p>
            </div>
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
                        field={@form[:upstream_websocket_bridge_enabled]}
                        type="checkbox"
                        label="Upstream websocket bridge"
                      />
                      <p class="routing-option-help">
                        Carries public streaming turns upstream over the session's
                        Codex websocket to reuse the provider prompt cache.
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
            <div
              id={"#{@id}-step-upstreams-panel-header"}
              class="flex flex-wrap items-start justify-between gap-3"
            >
              <div class="grid gap-1">
                <h3 class="text-lg font-semibold text-base-content">Pool upstream assignments</h3>
                <p class="text-sm leading-6 text-base-content/65">
                  Select the upstream accounts available to this Pool.
                </p>
              </div>
              <span
                id={@upstream_count_id}
                class={AdminBadges.count_chip_class()}
              >
                {length(@upstream_options)} available
              </span>
            </div>
            <.assignment_checkbox_cards
              id={@upstream_options_id}
              field={@form[@upstream_field]}
              options={@upstream_options}
              empty_label={@upstream_empty_label}
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
            <div
              id={"#{@id}-step-api-keys-panel-header"}
              class="flex flex-wrap items-start justify-between gap-3"
            >
              <div class="grid gap-1">
                <h3 class="text-lg font-semibold text-base-content">API Keys</h3>
                <p class="text-sm leading-6 text-base-content/65">
                  Select the API keys assigned to this Pool.
                </p>
              </div>
              <span
                id={@access_count_id}
                class={AdminBadges.count_chip_class()}
              >
                {length(@api_key_options)} available
              </span>
            </div>
            <.assignment_checkbox_cards
              id={@access_options_id}
              field={@form[:api_key_ids]}
              options={@api_key_options}
              empty_label="No API keys are available yet."
            />
          </section>
        </div>
      </.form>

      <:actions>
        <AdminComponents.action_button
          id={@cancel_id}
          icon="hero-x-mark"
          label="Cancel"
          phx-click={@cancel_event}
        />
        <AdminComponents.action_button
          id={@submit_id}
          icon={@submit_icon}
          label={@submit_label}
          type="submit"
          form={@form_id}
          variant={:primary}
        />
      </:actions>
    </PolicyEditorComponents.policy_editor_dialog>
    """
  end

  attr :id, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :options, :list, required: true
  attr :empty_label, :string, required: true

  defp assignment_checkbox_cards(assigns) do
    ~H"""
    <section id={@id} class="grid gap-2">
      <input type="hidden" name={PoolForm.field_array_name(@field)} value="" />
      <div class="grid max-h-[8.5rem] gap-2 overflow-y-auto" data-assignment-scroll="true">
        <label
          :for={option <- @options}
          id={"#{@id}-card-#{PoolForm.dom_token(PoolForm.option_value(option))}"}
          class="flex min-h-12 min-w-0 cursor-pointer items-center gap-3 rounded-box border border-base-300 bg-base-100 px-3 py-2 transition-colors hover:border-primary/50 hover:bg-primary/5"
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
                variant={:metadata}
              />
              <span
                :if={PoolForm.option_badge_kind(option) != :plan}
                class="inline-flex items-center rounded-box bg-base-200 px-2 py-1 text-xs font-semibold text-base-content/70"
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
end
