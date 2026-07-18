defmodule CodexPoolerWeb.Dev.ComponentShowcaseAdmin do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.RequestLogsPresentation

  alias CodexPoolerWeb.Dev.{
    ComponentShowcaseAdminForms,
    ComponentShowcaseAdminSpecialized,
    ComponentShowcaseData
  }

  attr :variants, :map, required: true

  attr :review_state, :string,
    required: true,
    values: ~w(catalog flash policy-dialog request-drawer)

  def admin_primitives(assigns) do
    assigns = assign(assigns, :protocols, ComponentShowcaseData.protocols())

    ~H"""
    <section id="showcase-admin-primitives" class="grid min-w-0 gap-4">
      <h2 class="text-xl font-bold">Shared admin primitives</h2>

      <AdminComponents.metric_strip id="showcase-metric-strip" compact_mobile>
        <AdminComponents.metric_card
          :for={metric <- @variants.metrics}
          id={"showcase-metric-#{metric.id}"}
          icon={metric.icon}
          label={metric.label}
          value={metric.value}
          description="Deterministic sample"
          tone={metric.tone}
          compact_mobile
        />
        <AdminComponents.metric_card
          id="showcase-metric-breakdown"
          icon="hero-calculator"
          label="Tokens"
          value="18.4k"
          description="Breakdown slot"
          compact_mobile
        >
          <:breakdown>
            <span class="font-mono text-xs tabular-nums">12k input · 4k cached</span>
          </:breakdown>
        </AdminComponents.metric_card>
      </AdminComponents.metric_strip>

      <AdminComponents.admin_surface
        id="showcase-admin-surface"
        title="Surface anatomy"
        description="Header, count, toolbar, body and footer slots"
      >
        <:header_actions>
          <span id="showcase-count-chip" class={AdminBadges.count_chip_class()}>5 items</span>
        </:header_actions>
        <:toolbar>
          <div class="flex flex-wrap gap-2">
            <span
              :for={status <- @variants.statuses}
              id={"showcase-status-#{status.id}"}
              class={AdminBadges.status_chip_class(status.value)}
            >
              {status.label}
            </span>
          </div>
        </:toolbar>
        <div class="grid gap-4 p-4 lg:grid-cols-2">
          <div id="showcase-plan-badges" class="flex flex-wrap items-center gap-2">
            <AdminBadges.plan_badge
              :for={plan <- @variants.plans}
              id={"showcase-plan-#{plan.id}"}
              label={plan.label}
            />
          </div>
          <div id="showcase-redacted-badges" class="flex flex-wrap items-center gap-2">
            <AdminComponents.redacted_status_badge
              :for={item <- @variants.redacted}
              id={"showcase-redacted-#{item.id}"}
              label="Evidence"
              status={item.status}
            />
          </div>
        </div>
        <:footer>Stable ids keep every rendered variant independently addressable.</:footer>
      </AdminComponents.admin_surface>

      <div class="grid min-w-0 gap-4 lg:grid-cols-2">
        <AdminComponents.admin_surface id="showcase-chip-families" title="Chip families">
          <div class="grid gap-3 p-4">
            <div class="flex flex-wrap gap-2">
              <span
                :for={tone <- ~w(neutral primary success warning error)}
                id={"showcase-metadata-#{tone}"}
                class={AdminBadges.metadata_chip_class(String.to_existing_atom(tone))}
              >
                {tone}
              </span>
            </div>
            <div class="flex flex-wrap gap-2">
              <span
                :for={severity <- ~w(critical warning info unknown)}
                id={"showcase-severity-#{severity}"}
                class={AdminBadges.alert_severity_chip_class(severity)}
              >
                {severity}
              </span>
            </div>
            <div class="flex flex-wrap gap-2">
              <span :for={protocol <- @protocols} id={"showcase-protocol-#{protocol.id}"}>
                <RequestLogsPresentation.request_log_protocol_badge
                  request_log={protocol.request_log}
                  prefix="showcase-transport"
                />
              </span>
            </div>
          </div>
        </AdminComponents.admin_surface>

        <AdminComponents.admin_surface id="showcase-actions" title="Actions and menu items">
          <div class="flex flex-wrap gap-2 p-4">
            <AdminComponents.action_button
              :for={button <- @variants.buttons}
              id={"showcase-button-#{button.id}"}
              icon={button.icon}
              label={button.label}
              variant={button.variant}
            />
            <AdminComponents.action_button
              id="showcase-button-disabled"
              icon="hero-lock-closed"
              label="Disabled"
              disabled
            />
            <AdminComponents.action_button
              id="showcase-button-link"
              icon="hero-arrow-right"
              label="Link"
              href="#showcase-admin-primitives"
            />
            <AdminComponents.diagnostic_popover
              id="showcase-diagnostic-popover"
              label="Explain unavailable state"
              title="Unavailable"
              description="The reason remains visible without inventing a successful state."
              placement={:end}
            />
          </div>
          <ul id="showcase-dropdown-items" class="grid gap-1 border-t border-base-300 p-2">
            <li :for={item <- @variants.dropdown_items}>
              <AdminComponents.dropdown_action_item
                id={"showcase-dropdown-#{item.id}"}
                icon={item.icon}
                label={item.label}
                variant={item.variant}
              />
            </li>
            <li>
              <AdminComponents.dropdown_action_item
                id="showcase-dropdown-disabled"
                icon="hero-lock-closed"
                label="Disabled"
                disabled
              />
            </li>
            <li>
              <AdminComponents.dropdown_action_item
                id="showcase-dropdown-link"
                icon="hero-arrow-right"
                label="Link"
                href="#showcase-admin-primitives"
              />
            </li>
            <li>
              <AdminComponents.dropdown_action_item
                id="showcase-dropdown-copy"
                icon="hero-clipboard"
                label="Copy"
                copy_feedback?
                phx-hook="ClipboardCopy"
                data-copy-text="sanitized-sample"
                data-copy-label="Copy"
                data-copied-label="Copied"
              />
            </li>
          </ul>
        </AdminComponents.admin_surface>
      </div>

      <div class="grid min-w-0 gap-4 lg:grid-cols-2">
        <AdminComponents.empty_state
          id="showcase-empty-state"
          icon="hero-inbox"
          title="Nothing to inspect"
          description="The canonical empty-state component."
        />
        <div id="showcase-notices" class="grid gap-3">
          <AdminComponents.extended_notice
            :for={notice <- @variants.notices}
            id={"showcase-notice-#{notice.id}"}
            title={notice.title}
            description="Synthetic metadata-only state."
            tone={notice.tone}
          />
        </div>
      </div>

      <ComponentShowcaseAdminForms.form_primitives />

      <ComponentShowcaseAdminSpecialized.specialized_primitives review_state={@review_state} />
    </section>
    """
  end
end
