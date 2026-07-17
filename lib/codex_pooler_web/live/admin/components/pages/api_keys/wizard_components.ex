defmodule CodexPoolerWeb.Admin.ApiKeyWizardComponents do
  @moduledoc """
  API-key wizard shell and step navigation helpers.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PolicyEditorComponents

  @steps [
    %{id: :basics, label: "Basics", description: "Name and state"},
    %{id: :models, label: "Models", description: "Model access"},
    %{id: :enforcement, label: "Enforcement", description: "Enforced request fields"},
    %{id: :limits, label: "Limits", description: "Policy caps"},
    %{id: :review, label: "Review", description: "Effective policy"}
  ]
  @step_ids Enum.map(@steps, &Atom.to_string(&1.id))
  @api_key_docs_url "https://docs.codex-pooler.com/operators/api-keys/#create-api-key"

  @spec steps() :: [map()]
  def steps, do: @steps

  @spec normalize_step(term()) :: String.t()
  def normalize_step(step) do
    step = to_string(step)
    if step in @step_ids, do: step, else: "basics"
  end

  @spec next_step(String.t()) :: String.t()
  def next_step(current_step), do: adjacent_step(current_step, 1)

  @spec previous_step(String.t()) :: String.t()
  def previous_step(current_step), do: adjacent_step(current_step, -1)

  attr :form, :any, required: true
  attr :pool_options, :list, required: true
  attr :disabled, :boolean, default: false

  def api_key_basics_step(assigns) do
    ~H"""
    <section id="api-key-step-basics-panel" class="grid min-w-0 gap-5">
      <div class="grid gap-1">
        <h3 class="text-lg font-semibold text-base-content">Name and availability</h3>
        <p class="text-sm leading-6 text-base-content/65">
          Set the operator label, owning Pool, current state, and optional expiry.
        </p>
      </div>
      <div class="grid gap-4 md:grid-cols-2">
        <.input
          field={@form[:display_name]}
          type="text"
          label="Display name"
          placeholder="Production gateway key"
          required
          disabled={@disabled}
        />
        <.input
          field={@form[:pool_id]}
          type="select"
          label="Pool"
          options={@pool_options}
          disabled={@disabled}
        />
        <.input
          field={@form[:status]}
          type="select"
          label="Status"
          options={status_options()}
          disabled={@disabled}
        />
        <.input
          field={@form[:expires_at]}
          type="datetime-local"
          label="Expires at"
          disabled={@disabled}
        />
      </div>
      <.input
        field={@form[:operator_notes]}
        type="textarea"
        label="Operator notes"
        rows="3"
        placeholder="Operator-only notes; no secrets"
        disabled={@disabled}
      />
    </section>
    """
  end

  attr :form, :any, required: true
  attr :selector_state, :map, required: true

  def api_key_models_step(assigns) do
    assigns =
      assign(
        assigns,
        :sorted_model_options,
        Enum.sort_by(assigns.selector_state.options, & &1.identifier, :desc)
      )

    ~H"""
    <section id="api-key-step-models-panel" class="grid min-w-0 gap-5">
      <div class="grid gap-1">
        <h3 class="text-lg font-semibold text-base-content">Model access</h3>
        <p class="text-sm leading-6 text-base-content/65">
          Choose which models this key may use.
        </p>
      </div>

      <div class="grid gap-3 md:grid-cols-3">
        <.policy_mode_card
          id="api-key-model-mode-all"
          field={@form[:model_mode]}
          value="all_models"
          label="All models"
          description="Allow current and future routable models."
        />
        <.policy_mode_card
          id="api-key-model-mode-selected"
          field={@form[:model_mode]}
          value="selected_models"
          label="Selected"
          description="Allow only checked or manual model IDs."
        />
        <.policy_mode_card
          id="api-key-model-mode-deny"
          field={@form[:model_mode]}
          value="deny_all_models"
          label="Deny all"
          description="Keep the key valid but block model use."
        />
      </div>

      <input type="hidden" name={field_array_name(@form[:allowed_model_identifiers])} value="" />
      <div
        id="api-key-model-selection"
        class={[
          "grid min-w-0 gap-5",
          field_string_value(@form[:model_mode]) != "selected_models" && "hidden"
        ]}
      >
        <div class="grid min-w-0 gap-3">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="grid gap-1">
              <h3 class="text-lg font-semibold text-base-content">Catalog models</h3>
              <p class="text-sm leading-6 text-base-content/65">
                Routable models from this Pool's catalog.
              </p>
            </div>
            <span class={AdminBadges.count_chip_class()}>
              {length(@selector_state.options)} options
            </span>
          </div>

          <p
            :if={catalog_attention_label(@selector_state.catalog)}
            id="api-key-catalog-status"
            class="text-sm font-medium text-warning"
          >
            {catalog_attention_label(@selector_state.catalog)}
          </p>

          <div id="api-key-model-options" class="grid max-h-[13rem] gap-2 overflow-y-auto">
            <label
              :for={option <- @sorted_model_options}
              id={"api-key-model-option-#{dom_token(option.identifier)}"}
              class="flex min-h-12 min-w-0 cursor-pointer items-center gap-3 rounded-box border border-base-300 bg-base-100 px-3 py-2 transition-colors hover:border-primary/50 hover:bg-primary/5"
            >
              <input
                type="checkbox"
                class="checkbox checkbox-primary checkbox-sm shrink-0"
                name={field_array_name(@form[:allowed_model_identifiers])}
                value={option.identifier}
                checked={selected_value?(@form[:allowed_model_identifiers].value, option.identifier)}
              />
              <span class="flex min-w-0 flex-1 flex-wrap items-center justify-between gap-x-3 gap-y-0.5">
                <span class="min-w-0 truncate text-sm font-medium text-base-content">
                  {option.display_name || option.identifier}
                </span>
                <span class="truncate font-mono text-xs text-base-content/50">
                  {option.identifier}
                </span>
              </span>
            </label>
            <p :if={@selector_state.options == []} class="text-sm text-base-content/60">
              No routable catalog models are available for this Pool.
            </p>
          </div>

          <div :if={@selector_state.selected_unavailable_chips != []} class="grid gap-2">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Saved unavailable models
            </p>
            <label
              :for={chip <- @selector_state.selected_unavailable_chips}
              id={"api-key-stale-model-#{dom_token(chip.identifier)}"}
              class="flex min-w-0 cursor-pointer items-start gap-3 rounded-box border border-warning/30 bg-warning/10 p-3 text-sm"
            >
              <input
                type="checkbox"
                class="checkbox checkbox-warning checkbox-sm mt-1"
                name={field_array_name(@form[:allowed_model_identifiers])}
                value={chip.identifier}
                checked={selected_value?(@form[:allowed_model_identifiers].value, chip.identifier)}
              />
              <span class="grid min-w-0 gap-1">
                <span class="break-all font-mono font-semibold text-base-content">{chip.label}</span>
                <span class="text-base-content/65">{chip.warning}</span>
              </span>
            </label>
          </div>
        </div>

        <.input
          field={@form[:manual_model_identifiers_text]}
          type="textarea"
          label="Manual model identifiers"
          rows="3"
          placeholder="custom/manual-test-model"
        />

        <div
          :if={@selector_state.manual_chips != []}
          id="api-key-manual-model-chips"
          class="flex flex-wrap gap-2"
        >
          <span
            :for={chip <- @selector_state.manual_chips}
            class={AdminBadges.metadata_chip_class(:primary)}
          >
            {chip.label}
          </span>
        </div>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :selector_state, :map, required: true
  attr :enforced_model_options, :list, required: true
  attr :reasoning_effort_options, :list, required: true
  attr :service_tier_options, :list, required: true

  def api_key_enforcement_step(assigns) do
    ~H"""
    <section id="api-key-step-enforcement-panel" class="grid min-w-0 gap-5">
      <div
        id="api-key-reasoning-policy"
        role="radiogroup"
        aria-describedby="api-key-reasoning-policy-help"
        class="grid min-w-0 gap-5"
      >
        <div class="grid gap-1">
          <h3 class="text-lg font-semibold text-base-content">Reasoning effort policy</h3>
          <p id="api-key-reasoning-policy-help" class="text-sm leading-6 text-base-content/65">
            Leave requests unchanged, set a ceiling, or always send one effort.
          </p>
        </div>
        <div class="grid gap-3 md:grid-cols-3">
          <.reasoning_policy_mode
            id="api_key_reasoning_policy_mode_unrestricted"
            field={@form[:reasoning_policy_mode]}
            value="unrestricted"
            label="Unrestricted"
            description="Keep request values unchanged."
          />
          <.reasoning_policy_mode
            id="api_key_reasoning_policy_mode_allow_up_to"
            field={@form[:reasoning_policy_mode]}
            value="allow_up_to"
            label="Allow up to"
            description="Permit request values through a selected ceiling."
          />
          <.reasoning_policy_mode
            id="api_key_reasoning_policy_mode_always_use"
            field={@form[:reasoning_policy_mode]}
            value="always_use"
            label="Always use"
            description="Replace every request value with one effort."
          />
        </div>
        <.input
          :if={field_string_value(@form[:reasoning_policy_mode]) == "allow_up_to"}
          field={@form[:maximum_reasoning_effort]}
          type="select"
          label="Maximum reasoning effort"
          options={@reasoning_effort_options}
        />
        <.input
          :if={field_string_value(@form[:reasoning_policy_mode]) == "always_use"}
          field={@form[:enforced_reasoning_effort]}
          type="select"
          label="Enforced reasoning effort"
          options={@reasoning_effort_options}
        />
        <p class="text-sm leading-6 text-base-content/60">
          Reasoning "None" is an enforced upstream value; it is different from leaving the field unset.
          Minimal is sent upstream as low, and Ultra is sent upstream as max for backend Codex
          compatibility; use Max or Ultra only when the target model/upstream supports them.
        </p>
      </div>

      <div class="grid gap-1 border-t border-base-300/60 pt-5">
        <h3 class="text-lg font-semibold text-base-content">Enforced request fields</h3>
        <p class="text-sm leading-6 text-base-content/65">
          Optionally pin the model and service tier sent upstream, regardless of request values.
        </p>
      </div>

      <div class="grid gap-4 md:grid-cols-2">
        <.input
          field={@form[:enforced_model_identifier]}
          type="select"
          label="Enforced model"
          options={@enforced_model_options}
        />
        <.input
          field={@form[:enforced_service_tier]}
          type="select"
          label="Enforced service tier"
          options={@service_tier_options}
        />
      </div>

      <p class="text-sm leading-6 text-base-content/60">
        Service tier is only enforced when selected. Auto lets the upstream choose, default requests
        standard capacity, flex opts into lower-priority flexible capacity, and priority asks for the
        highest available tier.
      </p>

      <div
        :if={@selector_state.enforced_unavailable_warning}
        id="api-key-enforced-model-warning"
        class="alert alert-warning items-start"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div class="grid gap-1">
          <p class="font-semibold">Enforced model unavailable</p>
          <p class="text-sm">{@selector_state.enforced_unavailable_warning.message}</p>
        </div>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :mode, :atom, required: true, values: [:create, :edit]
  attr :current_step, :string, required: true
  attr :review_errors, :list, required: true
  attr :disabled, :boolean, default: false
  slot :basics, required: true
  slot :models, required: true
  slot :enforcement, required: true
  slot :limits, required: true
  slot :review, required: true

  def api_key_wizard(assigns) do
    assigns =
      assigns
      |> assign(:steps, @steps)
      |> assign(:title, title(assigns.mode))
      |> assign(:description, description(assigns.mode))
      |> assign(:cancel_event, cancel_event(assigns.mode))
      |> assign(:cancel_id, cancel_id(assigns.mode))
      |> assign(:submit_label, submit_label(assigns.mode))
      |> assign(:api_key_docs_url, @api_key_docs_url)

    ~H"""
    <PolicyEditorComponents.policy_editor_dialog
      id="api-key"
      eyebrow="API key policy"
      title={@title}
      description={@description}
      steps={@steps}
      current_step={@current_step}
      sections_label="API key policy sections"
      step_event="api_key_wizard_step"
      backdrop_event={@cancel_event}
      docs_url={@api_key_docs_url}
    >
      <.form
        id="api-key-form"
        for={@form}
        phx-change="validate_api_key_wizard"
        phx-submit="save_api_key"
        autocomplete="off"
        class="grid min-w-0 gap-4"
      >
        <.input field={@form[:id]} type="hidden" />
        <div
          id="api-key-section-basics"
          role="tabpanel"
          aria-labelledby="api-key-tab-basics"
          class={step_panel_class(@current_step, "basics")}
        >
          {render_slot(@basics)}
        </div>
        <div
          id="api-key-section-models"
          role="tabpanel"
          aria-labelledby="api-key-tab-models"
          class={step_panel_class(@current_step, "models")}
        >
          {render_slot(@models)}
        </div>
        <div
          id="api-key-section-enforcement"
          role="tabpanel"
          aria-labelledby="api-key-tab-enforcement"
          class={step_panel_class(@current_step, "enforcement")}
        >
          {render_slot(@enforcement)}
        </div>
        <div
          id="api-key-section-limits"
          role="tabpanel"
          aria-labelledby="api-key-tab-limits"
          class={step_panel_class(@current_step, "limits")}
        >
          {render_slot(@limits)}
        </div>
        <div
          id="api-key-section-review"
          role="tabpanel"
          aria-labelledby="api-key-tab-review"
          class={step_panel_class(@current_step, "review")}
        >
          {render_slot(@review)}
        </div>
      </.form>

      <:actions>
        <AdminComponents.action_button
          id={@cancel_id}
          label="Cancel"
          variant={:ghost}
          phx-click={@cancel_event}
        />
        <AdminComponents.action_button
          id="api-key-submit"
          icon="hero-key"
          label={@submit_label}
          type="submit"
          form="api-key-form"
          variant={:primary}
          disabled={@disabled || @review_errors != []}
        />
      </:actions>
    </PolicyEditorComponents.policy_editor_dialog>
    """
  end

  defp adjacent_step(current_step, direction) do
    index = Enum.find_index(@step_ids, &(&1 == current_step)) || 0
    Enum.at(@step_ids, index + direction) || current_step
  end

  defp step_panel_class(current_step, step) do
    [
      "min-w-0",
      current_step == step && "block",
      current_step != step && "hidden"
    ]
  end

  defp title(:create), do: "Create API key"
  defp title(:edit), do: "Edit API key"

  defp description(:create),
    do:
      "Define Pool ownership, model access, enforced request fields, and limits before copying the generated secret once."

  defp description(:edit), do: "Update policy sections without exposing stored secret material."

  defp cancel_event(:create), do: "cancel_create"
  defp cancel_event(:edit), do: "cancel_edit"
  defp cancel_id(:create), do: "api-key-cancel-create"
  defp cancel_id(:edit), do: "api-key-cancel-edit"
  defp submit_label(:create), do: "Create API key"
  defp submit_label(:edit), do: "Save API key"

  attr :id, :string, required: true
  attr :field, :any, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true

  defp policy_mode_card(assigns) do
    ~H"""
    <label
      id={@id}
      class={[
        "grid cursor-pointer gap-2 rounded-box border p-3 transition-colors hover:bg-base-200",
        field_string_value(@field) == @value && "border-primary bg-primary/10",
        field_string_value(@field) != @value && "border-base-300 bg-base-100"
      ]}
    >
      <span class="flex items-start gap-3">
        <input
          type="radio"
          class="radio radio-primary radio-sm mt-1"
          name={@field.name}
          value={@value}
          checked={field_string_value(@field) == @value}
        />
        <span class="grid gap-1">
          <span class="font-semibold text-base-content">{@label}</span>
          <span class="text-sm leading-5 text-base-content/60">{@description}</span>
        </span>
      </span>
    </label>
    """
  end

  attr :id, :string, required: true
  attr :field, :any, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true

  defp reasoning_policy_mode(assigns) do
    ~H"""
    <label class={[
      "flex min-w-0 cursor-pointer items-start gap-3 rounded-box border p-3 transition-colors hover:bg-base-200",
      field_string_value(@field) == @value && "border-primary bg-primary/10",
      field_string_value(@field) != @value && "border-base-300 bg-base-100"
    ]}>
      <input
        id={@id}
        type="radio"
        class="radio radio-primary radio-sm mt-1"
        name={@field.name}
        value={@value}
        checked={field_string_value(@field) == @value}
      />
      <span class="grid gap-1">
        <span class="font-semibold text-base-content">{@label}</span>
        <span class="text-sm leading-5 text-base-content/60">{@description}</span>
      </span>
    </label>
    """
  end

  defp status_options do
    [{"Active", "active"}, {"Paused", "paused"}]
  end

  defp catalog_attention_label(%{status: status, message: message}) do
    cond do
      status in [:synced, nil] -> nil
      is_binary(message) and message != "" -> message
      true -> "Catalog #{status}"
    end
  end

  defp catalog_attention_label(_catalog), do: "Catalog unavailable"

  defp field_array_name(field), do: "#{field.name}[]"
  defp field_string_value(field), do: to_string(field.value || "")

  defp selected_value?(values, value), do: value in list_input_values(values)

  defp list_input_values(nil), do: []

  defp list_input_values(value) when is_binary(value) do
    value
    |> String.split(["\n", ","], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp list_input_values(values) when is_list(values) do
    values
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp list_input_values(_values), do: []

  defp dom_token(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: value
  end
end
