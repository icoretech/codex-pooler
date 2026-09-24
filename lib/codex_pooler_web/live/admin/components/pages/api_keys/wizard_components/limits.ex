defmodule CodexPoolerWeb.Admin.ApiKeyWizardComponents.Limits do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.ApiKeyPolicyForm

  attr :form, :any, required: true
  attr :limit_fields, :list, required: true
  attr :budget_usage, :map, default: nil
  attr :budget_usage_loading?, :boolean, default: false

  def api_key_limits_step(assigns) do
    assigns = assign(assigns, :retained_model_policies, ApiKeyPolicyForm.retained_model_policies(assigns.form.params))

    ~H"""
    <section id="api-key-step-limits-panel" class="grid min-w-0 gap-3">
      <section
        id="api-key-key-wide-limits"
        aria-labelledby="api-key-key-wide-title"
        class="grid min-w-0 gap-3 rounded-box bg-base-200/50 p-3 sm:grid-cols-2 sm:items-center"
      >
        <div class="grid gap-1">
          <h3 id="api-key-key-wide-title" class="text-sm font-semibold text-base-content">
            Key-wide limits
          </h3>
          <p id="api-key-active-requests-hint" class="text-xs leading-5 text-base-content/65">
            Across all models. Blank disables the cap. Counts active executions, not idle sockets.
            Lowering the cap lets current requests finish. This is not a hard token ceiling.
          </p>
        </div>
        <.input
          field={@form[:max_active_requests]}
          type="number"
          label="Maximum active requests"
          min="1"
          max="2147483647"
          step="1"
          placeholder="Disabled"
          aria-describedby="api-key-active-requests-hint"
          aria-invalid={@form[:max_active_requests].errors != []}
        />
      </section>

      <section
        aria-labelledby="api-key-default-limits-title"
        class="grid min-w-0 gap-2 rounded-box border border-base-300 p-3"
      >
        <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
          <h3 id="api-key-default-limits-title" class="text-sm font-semibold text-base-content">
            Default policy
          </h3>
          <p class="text-xs text-base-content/60">Blank fields have no saved cap.</p>
        </div>
        <.policy_grid
          id="api-key-default-limits-grid"
          form={@form}
          fields={@limit_fields}
          prefix="default"
        />
      </section>

      <section
        id="api-key-model-limits"
        aria-labelledby="api-key-model-limits-title"
        class="grid min-w-0 gap-2 border-t border-base-300 px-3 pt-3"
      >
        <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
          <h3 id="api-key-model-limits-title" class="text-sm font-semibold text-base-content">
            Model override
          </h3>
          <p class="text-xs text-base-content/60">
            Optional limits for one model; key-wide limits still apply.
          </p>
        </div>
        <.policy_grid
          id="api-key-model-limits-grid"
          form={@form}
          fields={@limit_fields}
          prefix="model"
        />
      </section>

      <section
        :if={@retained_model_policies != []}
        id="api-key-retained-model-limits"
        aria-labelledby="api-key-retained-model-limits-title"
        class="grid min-w-0 gap-2 border-t border-base-300 px-3 pt-3"
      >
        <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
          <h3 id="api-key-retained-model-limits-title" class="text-sm font-semibold text-base-content">
            Other model overrides
          </h3>
          <p class="text-xs text-base-content/60">Kept as saved when this key is updated.</p>
        </div>
        <ul class="grid gap-1 text-xs">
          <li
            :for={{policy, index} <- Enum.with_index(@retained_model_policies)}
            id={"api-key-retained-model-limit-#{index}"}
            class="flex min-w-0 flex-wrap gap-x-3 gap-y-1"
          >
            <span class="font-mono text-base-content">{policy["model_identifier"]}</span>
            <span class="text-base-content/65">{retained_limit_summary(policy, @limit_fields)}</span>
          </li>
        </ul>
      </section>

      <p id="api-key-admission-estimate-hint" class="px-3 text-xs leading-5 text-base-content/60">
        Output estimate floors are 512 tokens for ordinary requests and 2,048 tokens for opaque-context requests.
        Output limits are admission checks, not guaranteed provider output caps.
      </p>
      <div
        :if={@budget_usage_loading?}
        id="api-key-budget-loading"
        class="flex items-center gap-2 px-3 text-xs text-base-content/60"
        role="status"
      >
        <.icon name="hero-arrow-path" class="admin-loading-icon size-4" />
        <span>Loading current usage</span>
      </div>
      <.budget_breakdown :if={@budget_usage} usage={@budget_usage} />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :form, :any, required: true
  attr :fields, :list, required: true
  attr :prefix, :string, required: true

  defp policy_grid(assigns) do
    ~H"""
    <div
      id={@id}
      class="grid min-w-0 gap-x-3 gap-y-3 sm:grid-cols-3 [&_.fieldset]:mb-0 [&_.fieldset]:py-0"
    >
      <.input
        :if={@prefix == "model"}
        field={@form[:model_policy_model_identifier]}
        type="text"
        label="Model identifier"
        placeholder="Model identifier"
      />
      <.limit_input :for={field <- @fields} form={@form} field={field} prefix={@prefix} />
    </div>
    """
  end

  attr :form, :any, required: true
  attr :field, :string, required: true
  attr :prefix, :string, required: true

  def limit_input(assigns) do
    assigns = assign(assigns, :field_atom, String.to_atom("#{assigns.prefix}_#{assigns.field}"))

    ~H"""
    <.input
      field={@form[@field_atom]}
      type="number"
      label={limit_field_label(@field)}
      min="1"
      step="1"
    />
    """
  end

  defp retained_limit_summary(policy, fields) do
    fields
    |> Enum.flat_map(fn field ->
      case policy[field] do
        value when is_integer(value) -> ["#{limit_field_label(field)} #{format_tokens(value)}"]
        _blank -> []
      end
    end)
    |> case do
      [] -> "No caps"
      limits -> Enum.join(limits, " · ")
    end
  end

  def limit_field_label("max_requests_per_minute"), do: "Requests per minute"
  def limit_field_label("max_tokens_per_day"), do: "Tokens per day"
  def limit_field_label("max_tokens_per_week"), do: "Tokens per week"
  def limit_field_label("max_input_tokens_per_request"), do: "Input tokens per request"
  def limit_field_label("max_output_tokens_per_request"), do: "Output tokens per request"

  attr :usage, :map, required: true

  defp budget_breakdown(assigns) do
    ~H"""
    <section
      id="api-key-budget-breakdown"
      aria-labelledby="api-key-budget-title"
      class="grid min-w-0 gap-2 border-t border-base-300 px-3 pt-3"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <h3 id="api-key-budget-title" class="text-sm font-semibold text-base-content">
          Budget usage
        </h3>
        <p class="text-xs text-base-content/60">Snapshot when editor opened</p>
      </div>
      <div
        :for={{window, label} <- [{:daily, "Today (UTC)"}, {:weekly, "Last 7 days"}]}
        id={"api-key-budget-#{window}"}
        class="grid min-w-0 gap-2 text-xs sm:grid-cols-[7rem_minmax(0,1fr)]"
      >
        <h4 class="text-base-content/65">{label}</h4>
        <dl class="grid grid-cols-2 gap-2 sm:grid-cols-4">
          <div :for={
            {field, name, suffix} <- [
              {:known_total_tokens, "Known", "known"},
              {:provisional_total_tokens, "Provisional", "provisional"},
              {:pending_total_tokens, "Pending", "pending"},
              {:effective_total_tokens, "Effective", "effective"}
            ]
          }>
            <dt class="text-base-content/60">{name}</dt>
            <dd
              id={"api-key-budget-#{window}-#{suffix}"}
              class="font-mono tabular-nums text-base-content"
            >
              {format_tokens(@usage[window][field])}
            </dd>
          </div>
        </dl>
      </div>
      <p class="text-xs leading-5 text-base-content/60">
        Effective = known usage + provisional usage without a final count + pending reservations. Estimates do not change measured token burn.
      </p>
    </section>
    """
  end

  defp format_tokens(value),
    do:
      value
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()
end
