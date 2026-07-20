defmodule CodexPoolerWeb.Admin.PoolModelServingComponents do
  @moduledoc """
  Edit-only Pool model serving controls and catalog state presentation.
  """

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  @mode_options [
    {:auto, "Auto", "Recommended. Follow the capability discovered from current upstreams."},
    {:lite, "Lite", "Always use the lighter Responses serving path for this model."},
    {:full, "Full", "Force ordinary Responses when the selected upstream supports it."}
  ]

  attr :projection, :any, default: nil

  attr :status, :atom,
    default: :idle,
    values: [:idle, :loading, :ready, :empty, :error, :stale]

  attr :dirty?, :boolean, default: false
  attr :sync_pending?, :boolean, default: false

  def model_serving_panel(assigns) do
    assigns =
      assigns
      |> assign(:html_form, to_form(%{}, as: :pool_model_serving))
      |> assign(:mode_options, @mode_options)

    ~H"""
    <section
      id="pool-model-serving-panel"
      data-state={@status}
      aria-busy={to_string(@status in [:idle, :loading])}
      class="grid min-w-0 gap-5"
    >
      <div class="flex min-w-0 flex-wrap items-start justify-between gap-3">
        <div class="grid min-w-0 gap-1">
          <h3 id="pool-model-serving-title" class="text-lg font-semibold text-base-content">
            Model serving modes
          </h3>
          <p class="text-sm leading-6 text-base-content/65">
            Choose the Responses serving path for each model currently known to this Pool.
          </p>
        </div>
        <div :if={@projection} class="flex shrink-0 flex-wrap items-center gap-2">
          <span
            :if={@dirty?}
            id="pool-model-serving-dirty-status"
            class={AdminBadges.metadata_chip_class(:warning)}
          >
            Unsaved changes
          </span>
          <span class={AdminBadges.count_chip_class()}>
            {length(@projection.rows)} models
          </span>
        </div>
      </div>

      <AdminComponents.extended_notice
        :if={@status in [:idle, :loading]}
        id="pool-model-serving-state-loading"
        icon="hero-arrow-path"
        title="Loading model modes"
        description="Reading the latest saved modes and routable model catalog."
      />

      <p
        :if={@status == :ready}
        id="pool-model-serving-state-ready"
        role="status"
        aria-live="polite"
        class="sr-only"
      >
        Model serving modes loaded.
      </p>

      <AdminComponents.extended_notice
        :if={@status == :error}
        id="pool-model-serving-state-error"
        icon="hero-exclamation-triangle"
        tone={:error}
        role="alert"
        title="Model catalog needs attention"
        description="The latest catalog state could not be confirmed. Saved choices remain available when present, and invalid changes are never applied."
      />

      <AdminComponents.extended_notice
        :if={@status == :stale}
        id="pool-model-serving-state-stale"
        icon="hero-exclamation-triangle"
        tone={:warning}
        role="status"
        title="Model catalog may be stale"
        description={stale_description(@sync_pending?)}
      />

      <AdminComponents.extended_notice
        :if={@status not in [:idle, :loading]}
        id="pool-model-serving-guidance"
        icon="hero-information-circle"
        tone={:info}
        role="note"
        title="Choose Auto unless an upstream requires an override"
        description="Auto is recommended. Full is an advanced provider-dependent override that uses ordinary Responses. Upstream compatibility can change or reject Full requests. Pooler never silently downgrades Full; switch the model back to Auto or Lite to change the configured mode."
      />

      <div
        :if={@status == :empty}
        id="pool-model-serving-state-empty-announcement"
        role="status"
        aria-live="polite"
      >
        <AdminComponents.empty_state
          id="pool-model-serving-state-empty"
          icon="hero-cube-transparent"
          title="No routable models"
          description="This Pool has no routable catalog models or retained model overrides yet. Run model sync after assigning an active upstream."
        />
      </div>

      <.form
        :if={@projection}
        id="pool-model-serving-form"
        for={@html_form}
        phx-change="validate_pool_model_serving"
        phx-submit="save_pool_model_serving"
        aria-labelledby="pool-model-serving-title"
        autocomplete="off"
        class="grid min-w-0 gap-3"
      >
        <input
          id="pool-model-serving-revision"
          type="hidden"
          name={@projection.revision_name}
          value={@projection.revision}
        />

        <fieldset
          :for={row <- @projection.rows}
          id={row.dom_id}
          data-role="pool-model-serving-row"
          data-availability={availability(row)}
          aria-describedby={row_described_by(row)}
          class="grid min-w-0 gap-3 rounded-box border border-base-300 bg-base-100 p-4"
        >
          <legend class="sr-only">{row.labels.fieldset} — {row.display_name}</legend>
          <input type="hidden" name={row.identifier_name} value={row.exposed_model_id} />

          <div class="flex min-w-0 flex-wrap items-start justify-between gap-3">
            <div class="grid min-w-0 gap-1">
              <p class="text-sm font-semibold text-base-content">{row.display_name}</p>
              <p class="break-all text-xs font-medium leading-5 text-base-content/55">
                {row.exposed_model_id}
              </p>
            </div>
            <span
              id={"#{row.dom_id}-effective"}
              data-role="pool-model-serving-effective"
              data-effective-mode={row.effective_badge.mode}
              class={effective_badge_class(row.effective_badge.mode)}
            >
              {effective_badge_label(row.effective_badge)}
            </span>
          </div>

          <div
            :if={row.warning}
            id={"#{row.dom_id}-availability-warning"}
            role="status"
            class="flex min-w-0 items-start gap-2 rounded-box border border-warning/25 bg-warning/10 px-3 py-2 text-xs leading-5 text-warning"
          >
            <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
            <span>
              <strong>{availability_warning_label(row)}</strong> {row.warning}.
            </span>
          </div>

          <div class="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-3">
            <label
              :for={{mode, label, description} <- @mode_options}
              class={mode_card_class(row, mode)}
            >
              <span class="flex min-w-0 items-start gap-3">
                <input
                  id={Map.fetch!(row.input_ids, mode)}
                  type="radio"
                  class="radio radio-primary radio-sm mt-0.5 shrink-0"
                  name={row.mode_name}
                  value={Atom.to_string(mode)}
                  checked={row.configured_mode == Atom.to_string(mode)}
                  aria-describedby={"#{Map.fetch!(row.input_ids, mode)}-help"}
                />
                <span class="grid min-w-0 gap-1">
                  <span class="text-sm font-semibold text-base-content">{label}</span>
                  <span
                    id={"#{Map.fetch!(row.input_ids, mode)}-help"}
                    class="text-xs leading-5 text-base-content/60"
                  >
                    {description}
                  </span>
                </span>
              </span>
            </label>
          </div>
        </fieldset>
      </.form>
    </section>
    """
  end

  defp availability(%{available?: true}), do: "available"
  defp availability(_row), do: "saved-unavailable"

  defp row_described_by(%{warning: nil, dom_id: dom_id}), do: "#{dom_id}-effective"

  defp row_described_by(%{dom_id: dom_id}),
    do: "#{dom_id}-effective #{dom_id}-availability-warning"

  defp effective_badge_class("lite"), do: AdminBadges.metadata_chip_class(:info)
  defp effective_badge_class(_mode), do: AdminBadges.metadata_chip_class(:neutral)

  defp availability_warning_label(%{configured_mode: "auto"}),
    do: "Will be removed on save."

  defp availability_warning_label(_row), do: "Saved setting retained."

  defp effective_badge_label(%{mode: "removed", label: label}), do: label

  defp effective_badge_label(%{mode: mode}),
    do: "Effective #{String.capitalize(mode)}"

  defp mode_card_class(row, mode) do
    selected? = row.configured_mode == Atom.to_string(mode)

    [
      "grid min-w-0 cursor-pointer gap-2 rounded-box border p-3 transition-colors hover:bg-base-200",
      selected? && "border-primary bg-primary/10",
      !selected? && "border-base-300 bg-base-100"
    ]
  end

  defp stale_description(true) do
    "The catalog or saved modes changed while you were editing. Your unsaved choices are preserved; retry Save model modes to apply them to the latest saved revision. Reopen after saving to include newly synced models."
  end

  defp stale_description(false) do
    "Catalog evidence is older than the expected refresh window. You can review and save existing choices; revision checks reject conflicting updates."
  end
end
