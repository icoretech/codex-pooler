defmodule CodexPoolerWeb.Dev.ComponentShowcase do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer
  alias CodexPoolerWeb.DateTimeDisplay
  alias CodexPoolerWeb.Dev.{ComponentShowcaseAdmin, ComponentShowcaseObservatory}

  attr :theme, :string, required: true, values: ~w(light dark)
  attr :paused, :boolean, required: true

  attr :review_state, :string,
    required: true,
    values: ~w(catalog flash policy-dialog request-drawer)

  attr :variants, :map, required: true
  attr :observatory, :map, required: true

  def component_showcase(assigns) do
    assigns = assign(assigns, :datetime_preferences, DateTimeDisplay.preferences_for_user(nil))

    ~H"""
    <div
      id="component-showcase"
      data-theme={@theme}
      data-review-state={@review_state}
      class={[
        "drawer drawer-end min-h-svh bg-base-200 text-base-content",
        @review_state == "request-drawer" && "drawer-open"
      ]}
    >
      <input
        id="request-log-detail-drawer"
        type="checkbox"
        class="drawer-toggle"
        checked={@review_state == "request-drawer"}
      />

      <div class="drawer-content min-w-0">
        <div class="mx-auto grid w-full min-w-0 gap-6 p-4 sm:p-6 xl:p-8">
          <AdminComponents.page_header
            id="showcase-page-header"
            eyebrow="Development"
            title="Component showcase"
            description="Real shared components and Observatory primitives rendered with deterministic, metadata-only fixtures."
          >
            <:actions>
              <AdminComponents.action_button
                id="showcase-header-action"
                icon="hero-check-badge"
                label={String.capitalize(@theme) <> " theme"}
                variant={:primary}
              />
            </:actions>
          </AdminComponents.page_header>

          <ComponentShowcaseAdmin.admin_primitives
            variants={@variants}
            review_state={@review_state}
          />

          <ComponentShowcaseObservatory.observatory_primitives
            paused={@paused}
            observatory={@observatory}
          />
        </div>
      </div>

      <RequestLogDetailDrawer.request_log_detail_drawer datetime_preferences={@datetime_preferences} />
    </div>
    """
  end
end
