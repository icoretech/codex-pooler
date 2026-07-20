defmodule CodexPoolerWeb.Admin.PoolModelServingComponents do
  @moduledoc """
  Edit-only Pool model serving controls and catalog state presentation.
  """

  use CodexPoolerWeb, :html

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
      |> assign(:summary, assigns.projection && serving_summary(assigns.projection.rows))

    ~H"""
    <section
      id="pool-model-serving-panel"
      data-state={@status}
      aria-busy={to_string(@status in [:idle, :loading])}
      class="grid min-w-0 gap-4"
    >
      <h3 id="pool-model-serving-title" class="sr-only">Model serving modes</h3>

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

      <AdminComponents.guidance_notice
        :if={@status not in [:idle, :loading]}
        id="pool-model-serving-guidance"
        title="Choose Auto unless an upstream requires an override"
        description="Full is an advanced provider-dependent override using ordinary Responses; upstream compatibility can change or reject it. Pooler never silently downgrades Full — switch a model back to Auto or Lite to change its configured mode."
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
        phx-hook="ModelServingTools"
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

        <div
          id="pool-model-serving-summary"
          class="flex min-w-0 flex-wrap items-center justify-between gap-x-5 gap-y-2 rounded-box border border-base-300 bg-base-200/40 px-3 py-2"
        >
          <dl class="flex min-w-0 flex-wrap items-baseline gap-x-5 gap-y-1">
            <div class="flex items-baseline gap-1.5">
              <dt class="text-[0.6rem] font-bold uppercase tracking-wide text-base-content/50">
                Configured
              </dt>
              <dd class="text-xs font-medium tabular-nums text-base-content/80">
                {@summary.configured}
              </dd>
            </div>
            <div class="flex items-baseline gap-1.5">
              <dt class="text-[0.6rem] font-bold uppercase tracking-wide text-base-content/50">
                Catalog
              </dt>
              <dd class="text-xs font-medium tabular-nums text-base-content/80">
                {@summary.catalog}
              </dd>
            </div>
            <div class="flex items-baseline gap-1.5">
              <dt class="text-[0.6rem] font-bold uppercase tracking-wide text-base-content/50">
                Effective (available)
              </dt>
              <dd class="text-xs font-medium tabular-nums text-base-content/80">
                {@summary.effective}
              </dd>
            </div>
          </dl>
          <button
            id="pool-model-serving-set-all-auto"
            type="button"
            data-role="model-serving-set-all-auto"
            class="btn btn-outline btn-primary btn-xs"
          >
            Set all to Auto
          </button>
        </div>

        <div class="grid min-w-0 overflow-hidden rounded-box border border-base-300">
          <div class="hidden items-center gap-x-4 border-b border-base-300 bg-base-200/40 px-3 py-1.5 text-[0.6rem] font-bold uppercase tracking-wide text-base-content/50 sm:grid sm:grid-cols-[minmax(0,1fr)_11.5rem_8.75rem]">
            <span>Model</span>
            <span class="text-center">Configured mode</span>
            <span class="text-right">Effective</span>
          </div>

          <fieldset
            :for={row <- @projection.rows}
            id={row.dom_id}
            data-role="pool-model-serving-row"
            data-availability={availability(row)}
            aria-describedby={row_described_by(row)}
            class={row_class(row)}
          >
            <legend class="sr-only">{row.labels.fieldset} — {row.display_name}</legend>
            <input type="hidden" name={row.identifier_name} value={row.exposed_model_id} />

            <div class="min-w-0">
              <div class="flex min-w-0 flex-wrap items-center gap-2">
                <p class={[
                  "text-[13px] font-semibold leading-tight",
                  (row.available? && "text-base-content") || "text-base-content/60"
                ]}>
                  {row.display_name}
                </p>
                <span
                  :if={!row.available?}
                  class="rounded border border-warning/40 bg-warning/10 px-1 py-px text-[0.56rem] font-bold uppercase tracking-wide text-warning"
                >
                  unavailable
                </span>
              </div>
              <p class={[
                "break-all text-[10.5px] font-normal leading-[1.3] tracking-[0.015em] text-base-content/50",
                !row.available? && "line-through decoration-base-content/40"
              ]}>
                {row.exposed_model_id}
              </p>
            </div>

            <div class={[
              "grid grid-cols-3 overflow-hidden rounded-field border border-base-300 bg-base-100",
              !row.available? && "opacity-60"
            ]}>
              <label
                :for={{mode, label, description} <- @mode_options}
                title={description}
                class="cursor-pointer border-l border-base-300 px-2 py-1.5 text-center text-xs font-semibold text-base-content/70 transition-colors first:border-l-0 hover:bg-base-200 has-[:checked]:bg-primary has-[:checked]:text-primary-content has-[:focus-visible]:outline has-[:focus-visible]:outline-2 has-[:focus-visible]:-outline-offset-2 has-[:focus-visible]:outline-primary"
              >
                <input
                  id={Map.fetch!(row.input_ids, mode)}
                  type="radio"
                  class="sr-only"
                  name={row.mode_name}
                  value={Atom.to_string(mode)}
                  checked={row.configured_mode == Atom.to_string(mode)}
                />
                {label}
              </label>
            </div>

            <div class="flex min-w-0 justify-end">
              <span
                id={"#{row.dom_id}-effective"}
                data-role="pool-model-serving-effective"
                data-effective-mode={row.effective_badge.mode}
                class="inline-flex items-baseline gap-1 whitespace-nowrap"
              >
                <span class="text-[0.6rem] font-semibold uppercase tracking-wide text-base-content/45">
                  {effective_pill_prefix(row)}
                </span>
                <span class={effective_mode_class(row)}>{effective_pill_text(row)}</span>
              </span>
            </div>

            <div
              :if={row.warning}
              id={"#{row.dom_id}-availability-warning"}
              role="status"
              class="col-span-full flex min-w-0 items-start gap-1.5 text-xs leading-5 text-warning"
            >
              <.icon name="hero-exclamation-triangle" class="mt-0.5 size-3.5 shrink-0" />
              <span>
                <strong>{availability_warning_label(row)}</strong> {row.warning}.
              </span>
            </div>
          </fieldset>
        </div>
      </.form>
    </section>
    """
  end

  defp availability(%{available?: true}), do: "available"
  defp availability(_row), do: "saved-unavailable"

  defp row_described_by(%{warning: nil, dom_id: dom_id}), do: "#{dom_id}-effective"

  defp row_described_by(%{dom_id: dom_id}),
    do: "#{dom_id}-effective #{dom_id}-availability-warning"

  defp row_class(row) do
    [
      "grid min-w-0 grid-cols-1 items-center gap-x-4 gap-y-2 border-b border-base-300/70 px-3 py-2.5 last:border-b-0 sm:grid-cols-[minmax(0,1fr)_11.5rem_8.75rem]",
      !row.available? && "bg-base-content/3"
    ]
  end

  defp serving_summary(rows) do
    configured = Enum.frequencies_by(rows, & &1.configured_mode)
    available = Enum.count(rows, & &1.available?)
    unavailable = length(rows) - available

    effective =
      rows
      |> Enum.filter(& &1.available?)
      |> Enum.frequencies_by(& &1.effective_badge.mode)

    %{
      configured:
        "#{Map.get(configured, "auto", 0)} Auto · #{Map.get(configured, "lite", 0)} Lite · #{Map.get(configured, "full", 0)} Full",
      catalog: "#{available} available · #{unavailable} unavailable",
      effective: "#{Map.get(effective, "full", 0)} Full · #{Map.get(effective, "lite", 0)} Lite"
    }
  end

  defp effective_pill_prefix(%{available?: false, effective_badge: %{mode: "removed"}}),
    do: "removed"

  defp effective_pill_prefix(%{available?: false}), do: "retained"
  defp effective_pill_prefix(%{source: "override"}), do: "forced"
  defp effective_pill_prefix(_row), do: "resolves"

  defp effective_pill_text(%{effective_badge: %{mode: "removed"}}), do: "—"
  defp effective_pill_text(%{effective_badge: %{mode: mode}}), do: String.capitalize(mode)

  defp effective_mode_class(%{available?: false}), do: "text-xs font-bold text-base-content/45"

  defp effective_mode_class(%{effective_badge: %{mode: "lite"}}),
    do: "text-xs font-bold text-info"

  defp effective_mode_class(_row), do: "text-xs font-bold text-base-content/75"

  defp availability_warning_label(%{configured_mode: "auto"}),
    do: "Will be removed on save."

  defp availability_warning_label(_row), do: "Saved setting retained."

  defp stale_description(true) do
    "The catalog or saved modes changed while you were editing. Your unsaved choices are preserved; retry Save model modes to apply them to the latest saved revision. Reopen after saving to include newly synced models."
  end

  defp stale_description(false) do
    "Catalog evidence is older than the expected refresh window. You can review and save existing choices; revision checks reject conflicting updates."
  end
end
