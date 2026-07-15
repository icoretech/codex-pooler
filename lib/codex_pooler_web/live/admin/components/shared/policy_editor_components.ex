defmodule CodexPoolerWeb.Admin.PolicyEditorComponents do
  @moduledoc """
  Shared policy editor dialog and wizard navigation components.
  """
  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :id, :string, required: true
  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :steps, :list, required: true
  attr :current_step, :any, required: true
  attr :sections_label, :string, default: "Policy sections"
  attr :step_event, :string, default: nil
  attr :backdrop_event, :string, default: nil
  attr :backdrop_label, :string, default: "close"
  attr :docs_url, :string, default: "https://docs.codex-pooler.com/operators/admin-ui/"
  attr :rest, :global

  slot :inner_block, required: true
  slot :actions, required: true

  def policy_editor_dialog(assigns) do
    steps = normalize_wizard_steps(assigns.steps)
    current_step_id = normalize_wizard_step_id(assigns.current_step)

    assigns =
      assigns
      |> assign(:wizard_steps, Enum.with_index(steps))
      |> assign(:current_step_id, current_step_id)

    ~H"""
    <dialog id={@id} class="modal modal-bottom overflow-x-hidden sm:modal-middle" open {@rest}>
      <div
        id={"#{@id}-panel"}
        class="modal-box flex max-h-[calc(100dvh-0.75rem)] w-full max-w-none flex-col overflow-hidden border border-base-300 bg-base-100 p-0 shadow-2xl sm:max-h-[calc(100dvh-1.5rem)] sm:w-[calc(100vw-1.5rem)] sm:max-w-4xl"
      >
        <header
          id={"#{@id}-header"}
          class="policy-editor-header min-w-0 shrink-0 border-b border-base-300"
        >
          <p :if={@eyebrow} class="text-xs font-semibold uppercase tracking-wide text-primary">
            {@eyebrow}
          </p>
          <div class="mt-1 grid gap-0.5 sm:gap-1">
            <h2 class="text-lg font-bold text-base-content sm:text-xl">{@title}</h2>
            <p :if={@description} class="text-sm leading-5 text-base-content/70 sm:leading-6">
              {@description}
            </p>
          </div>

          <div id={"#{@id}-sections"} class="policy-editor-sections min-w-0">
            <ol
              id={"#{@id}-tabs"}
              class="policy-editor-tabs grid min-w-0 gap-2 lg:flex lg:items-stretch"
              role="tablist"
              aria-label={@sections_label}
            >
              <li
                :for={{step, index} <- @wizard_steps}
                id={wizard_step_dom_id(@id, step.id)}
                class="min-w-0 lg:flex-1"
              >
                <button
                  :if={@step_event}
                  id={wizard_tab_dom_id(@id, step.id)}
                  type="button"
                  class={wizard_step_class(step.id, @current_step_id)}
                  aria-label={step.label}
                  aria-current={step.id == @current_step_id && "step"}
                  aria-selected={if(step.id == @current_step_id, do: "true", else: "false")}
                  aria-controls={wizard_section_dom_id(@id, step.id)}
                  role="tab"
                  phx-click={@step_event}
                  phx-value-step={step.id}
                >
                  <span
                    data-role="policy-editor-step-marker"
                    class={wizard_step_marker_class(step.id, @current_step_id)}
                  >
                    {index + 1}
                  </span>
                  <span class="grid min-w-0 gap-0.5">
                    <span class="truncate text-xs font-semibold uppercase tracking-wide">
                      {step.label}
                    </span>
                    <span
                      :if={step.description}
                      class="truncate text-[0.68rem] normal-case tracking-normal text-base-content/55"
                    >
                      {step.description}
                    </span>
                  </span>
                </button>
                <span
                  :if={!@step_event}
                  id={wizard_tab_dom_id(@id, step.id)}
                  class={wizard_step_class(step.id, @current_step_id)}
                  aria-label={step.label}
                  aria-current={step.id == @current_step_id && "step"}
                  aria-selected={if(step.id == @current_step_id, do: "true", else: "false")}
                  aria-controls={wizard_section_dom_id(@id, step.id)}
                  role="tab"
                >
                  <span
                    data-role="policy-editor-step-marker"
                    class={wizard_step_marker_class(step.id, @current_step_id)}
                  >
                    {index + 1}
                  </span>
                  <span class="grid min-w-0 gap-0.5">
                    <span class="truncate text-xs font-semibold uppercase tracking-wide">
                      {step.label}
                    </span>
                    <span
                      :if={step.description}
                      class="truncate text-[0.68rem] normal-case tracking-normal text-base-content/55"
                    >
                      {step.description}
                    </span>
                  </span>
                </span>
              </li>
            </ol>
          </div>
        </header>

        <section
          id={"#{@id}-body"}
          class="min-h-0 min-w-0 flex-1 overflow-x-hidden overflow-y-auto px-4 py-4 sm:px-5"
        >
          {render_slot(@inner_block)}
        </section>

        <AdminComponents.dialog_footer
          id={"#{@id}-footer"}
          class="modal-action sticky bottom-0 mt-0 w-full shrink-0 border-t border-base-300 bg-base-200/80 px-4 py-2.5 sm:px-5"
          docs_link_role="policy-editor-docs-link"
          docs_link_id={"#{@id}-docs-link"}
          docs_icon_role="policy-editor-docs-icon"
          docs_url={@docs_url}
        >
          <:actions>
            {render_slot(@actions)}
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form id={"#{@id}-backdrop"} method="dialog" class="modal-backdrop">
        <button type="button" phx-click={@backdrop_event}>{@backdrop_label}</button>
      </form>
    </dialog>
    """
  end

  defp normalize_wizard_steps(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map(fn {step, index} -> normalize_wizard_step(step, index) end)
  end

  defp normalize_wizard_step(%{} = step, index) do
    id = Map.get(step, :id) || Map.get(step, "id") || index
    label = Map.get(step, :label) || Map.get(step, "label") || "Step #{index}"
    description = Map.get(step, :description) || Map.get(step, "description")

    %{
      id: normalize_wizard_step_id(id),
      label: to_string(label),
      description: description && to_string(description)
    }
  end

  defp normalize_wizard_step({id, label}, index) do
    normalize_wizard_step(%{id: id, label: label}, index)
  end

  defp normalize_wizard_step(step, index) do
    normalize_wizard_step(%{id: step, label: "Step #{index}"}, index)
  end

  defp normalize_wizard_step_id(step_id) do
    step_id
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "step"
      normalized -> normalized
    end
  end

  defp wizard_step_dom_id(dialog_id, step_id), do: "#{dialog_id}-step-#{step_id}"
  defp wizard_tab_dom_id(dialog_id, step_id), do: "#{dialog_id}-tab-#{step_id}"
  defp wizard_section_dom_id(dialog_id, step_id), do: "#{dialog_id}-section-#{step_id}"

  defp wizard_step_class(step_id, current_step_id) do
    [
      "policy-editor-tab flex w-full min-w-0 items-center justify-start gap-2.5 border px-3 py-2 text-left transition-colors duration-200 lg:h-full lg:px-2.5 lg:py-2",
      step_id == current_step_id &&
        "is-current text-base-content",
      step_id != current_step_id &&
        "text-base-content/65 hover:bg-base-200/70"
    ]
  end

  defp wizard_step_marker_class(step_id, current_step_id) do
    [
      "grid size-5 shrink-0 place-items-center rounded-full border font-mono text-[0.6rem] font-bold leading-none",
      step_id == current_step_id && "border-primary bg-primary text-primary-content",
      step_id != current_step_id && "border-base-300 bg-base-200 text-base-content/60"
    ]
  end
end
