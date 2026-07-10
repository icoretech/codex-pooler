defmodule CodexPoolerWeb.Admin.ApiKeyWizardComponents.Review do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :review_sections, :list, required: true
  attr :review_errors, :list, required: true
  attr :warnings, :list, default: []

  def api_key_review_step(assigns) do
    ~H"""
    <section id="api-key-step-review-panel" class="grid min-w-0 gap-5">
      <div class="grid gap-1">
        <h3 class="text-lg font-semibold text-base-content">Review effective policy</h3>
        <p class="text-sm leading-6 text-base-content/65">
          Confirm the normalized policy before saving.
        </p>
      </div>

      <div
        :if={@review_errors != []}
        id="api-key-review-errors"
        class="alert alert-error items-start"
      >
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div class="grid gap-1">
          <p class="font-semibold">Policy needs attention</p>
          <ul class="list-disc pl-5 text-sm">
            <li :for={error <- @review_errors}>{error}</li>
          </ul>
        </div>
      </div>

      <div
        id="api-key-review-summary"
        class="overflow-hidden rounded-box border border-base-300 bg-base-100"
      >
        <.review_section :for={{title, rows} <- @review_sections} title={title} rows={rows} />
      </div>

      <div :if={@warnings != []} id="api-key-review-warnings" class="grid gap-2">
        <div :for={warning <- @warnings} class="alert alert-warning items-start">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>{warning.message}</span>
        </div>
      </div>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true

  defp review_section(assigns) do
    ~H"""
    <section class="grid gap-2 border-t border-base-300 px-4 py-3 first:border-t-0 sm:grid-cols-[9rem_minmax(0,1fr)] sm:gap-4">
      <h4 class="text-sm font-semibold text-base-content">{@title}</h4>
      <dl class="grid gap-2 text-sm">
        <div
          :for={{label, value} <- @rows}
          class="grid gap-1 sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-3"
        >
          <dt class="text-xs font-semibold uppercase tracking-wide text-base-content/50">{label}</dt>
          <dd class="break-words text-base-content/80">{value}</dd>
        </div>
      </dl>
    </section>
    """
  end
end
