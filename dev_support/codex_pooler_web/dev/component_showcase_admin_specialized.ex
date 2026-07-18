defmodule CodexPoolerWeb.Dev.ComponentShowcaseAdminSpecialized do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PolicyEditorComponents
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.QuotaLimitRow
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.SavedResetMeter
  alias CodexPoolerWeb.Dev.ComponentShowcaseData

  attr :review_state, :string,
    required: true,
    values: ~w(catalog flash policy-dialog request-drawer)

  def specialized_primitives(assigns) do
    assigns =
      assigns
      |> assign(:account, ComponentShowcaseData.account_card())
      |> assign(:quota_limits, ComponentShowcaseData.quota_limits())
      |> assign(:saved_resets, ComponentShowcaseData.saved_resets())
      |> assign(:active_policy, ComponentShowcaseData.saved_reset_policy(true))
      |> assign(:inactive_policy, ComponentShowcaseData.saved_reset_policy(false))

    ~H"""
    <section id="showcase-specialized-primitives" class="grid min-w-0 gap-4">
      <h3 class="text-lg font-bold">Domain compositions</h3>

      <div id="showcase-account-card">
        <AccountCard.account_card account={@account} account_index={0} />
      </div>

      <div class="grid min-w-0 gap-4 lg:grid-cols-2">
        <AdminComponents.admin_surface id="showcase-quota-surface" title="Quota progress states">
          <div class="grid gap-4 p-4">
            <QuotaLimitRow.quota_limit_row
              :for={limit <- @quota_limits}
              id={"showcase-quota-#{limit.id}"}
              limit={limit}
            />
          </div>
        </AdminComponents.admin_surface>

        <AdminComponents.admin_surface id="showcase-reset-surface" title="Saved reset states">
          <div class="grid gap-4 p-4">
            <div class="flex flex-wrap items-center gap-2">
              <SavedResetMeter.saved_reset_count_badge
                id="showcase-reset-badge-active"
                identity_id="00000000-0000-4000-8000-000000000042"
                saved_resets={@saved_resets}
                saved_reset_policy={@active_policy}
              />
              <SavedResetMeter.saved_reset_count_badge
                id="showcase-reset-badge-inactive"
                identity_id="00000000-0000-4000-8000-000000000043"
                saved_resets={@saved_resets}
                saved_reset_policy={@inactive_policy}
              />
            </div>
            <SavedResetMeter.saved_reset_meter
              id="showcase-reset-meter-active"
              saved_resets={@saved_resets}
              saved_reset_policy={@active_policy}
            />
            <SavedResetMeter.saved_reset_meter
              id="showcase-reset-meter-inactive"
              saved_resets={@saved_resets}
              saved_reset_policy={@inactive_policy}
            />
          </div>
        </AdminComponents.admin_surface>
      </div>

      <div class="grid min-w-0 gap-4 lg:grid-cols-2">
        <AdminComponents.object_inspector
          id="showcase-object-inspector"
          title="Sanitized request"
          subtitle="Metadata-only fixture"
          status="succeeded"
        >
          <p class="text-sm text-base-content/70">
            The inspector shell is real; private definition rows stay owned by the request drawer.
          </p>
        </AdminComponents.object_inspector>

        <AdminComponents.admin_surface id="showcase-policy-launcher" title="Policy editor">
          <div class="grid gap-2 p-4">
            <p class="text-sm text-base-content/65">
              Open each overlay state through its real shared composition and stable interaction.
            </p>
            <div class="flex flex-wrap gap-2">
              <AdminComponents.action_button
                id="showcase-show-flash"
                icon="hero-information-circle"
                label="Show toast"
                phx-click="showcase-show-flash"
              />
              <AdminComponents.action_button
                id="showcase-open-request-drawer"
                icon="hero-document-magnifying-glass"
                label="Open request drawer"
                phx-click="showcase-open-request-drawer"
              />
              <AdminComponents.action_button
                id="showcase-open-policy-editor"
                icon="hero-adjustments-horizontal"
                label="Open policy editor"
                phx-click="showcase-open-policy-editor"
              />
            </div>
          </div>
        </AdminComponents.admin_surface>
      </div>

      <PolicyEditorComponents.policy_editor_dialog
        :if={@review_state == "policy-dialog"}
        id="showcase-policy-editor"
        eyebrow="Deterministic policy"
        title="Policy editor anatomy"
        description="Real shared dialog with synthetic metadata-only content."
        steps={[
          %{id: "scope", label: "Scope", description: "Select access"},
          %{id: "review", label: "Review", description: "Confirm policy"}
        ]}
        current_step="scope"
        sections_label="Showcase policy sections"
        backdrop_event="showcase-close-policy-editor"
      >
        <section id="showcase-policy-section" class="grid gap-3" role="tabpanel">
          <p class="text-sm text-base-content/70">No domain record is created by this preview.</p>
        </section>
        <:actions>
          <AdminComponents.action_button
            id="showcase-close-policy-editor"
            label="Close"
            phx-click="showcase-close-policy-editor"
          />
        </:actions>
      </PolicyEditorComponents.policy_editor_dialog>
    </section>
    """
  end
end
