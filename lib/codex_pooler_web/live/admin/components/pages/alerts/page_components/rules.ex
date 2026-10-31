defmodule CodexPoolerWeb.Admin.AlertsPageComponents.Rules do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPoolerWeb.Admin.AlertRuleForm
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :selected_tab, :string, required: true
  attr :manageable_pools, :list, required: true
  attr :rules, :list, required: true
  attr :pool_lookup, :map, required: true
  attr :rule_form_mode, :atom, required: true
  attr :rule_form, :any, required: true

  @spec rules_section(map()) :: Phoenix.LiveView.Rendered.t()
  def rules_section(assigns) do
    ~H"""
    <AdminComponents.extended_notice
      :if={@selected_tab == "rules" and @manageable_pools == []}
      id="alerts-no-manageable-pools-notice"
      icon="hero-server-stack"
      title={gettext("No manageable Pools")}
      description={gettext("Ask an instance owner to assign an active Pool before creating alert rules.")}
      tone={:info}
    />

    <div
      :if={@selected_tab == "rules"}
      id="alerts-rules-section"
      class="grid min-w-0 gap-4 xl:grid-cols-[minmax(0,1fr)_24rem] xl:items-start"
    >
      <AdminComponents.admin_surface
        id="alerts-rules-list"
        title={gettext("Rules")}
        description={gettext("Pool-first alert definitions evaluated from persisted metadata only.")}
        count={rule_count_label(@rules)}
        overflow={:visible}
      >
        <AdminComponents.empty_state
          :if={@rules == []}
          id="alerts-rules-empty-state"
          title={gettext("No alert rules")}
          description={gettext("Create a rule for an active Pool to start tracking serving risk and quota evidence.")}
          icon="hero-bell-alert"
        />

        <div :if={@rules != []} id="alerts-rule-table-scroll-region" class="overflow-x-auto">
          <table id="alerts-rule-table" class="table min-w-[52rem]">
            <thead>
              <tr>
                <th>{gettext("Rule")}</th>
                <th>{gettext("Pool")}</th>
                <th class="text-center">{gettext("State")}</th>
                <th>{gettext("Route class")}</th>
                <th>{gettext("Threshold")}</th>
                <th class="text-center">{gettext("Cooldown")}</th>
                <th class="text-right">{gettext("Actions")}</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={rule <- @rules}
                id={"alert-rule-row-#{rule.id}"}
                class="text-sm transition-colors hover:bg-base-200/80"
              >
                <td class="min-w-56">
                  <div class="grid min-w-0 gap-1">
                    <span class="truncate font-semibold text-base-content">
                      {rule.display_name}
                    </span>
                    <span
                      id={"alert-rule-row-#{rule.id}-kind"}
                      class="text-xs text-base-content/60"
                    >
                      {AlertRuleForm.rule_kind_label(rule.rule_kind)}
                    </span>
                  </div>
                </td>
                <td class="min-w-44">
                  <div class="grid min-w-0 gap-0.5">
                    <span id={"alert-rule-row-#{rule.id}-pool"} class="truncate font-medium">
                      {pool_name_for(@pool_lookup, rule.pool_id)}
                    </span>
                    <span class="truncate font-mono text-xs text-base-content/45">
                      {pool_slug_for(@pool_lookup, rule.pool_id)}
                    </span>
                  </div>
                </td>
                <td class="text-center">
                  <span
                    id={"alert-rule-row-#{rule.id}-state"}
                    class={AdminBadges.status_chip_class(rule.state)}
                  >
                    {AlertRuleForm.state_label(rule.state)}
                  </span>
                </td>
                <td
                  id={"alert-rule-row-#{rule.id}-route-class"}
                  class="font-mono text-xs text-base-content/70"
                >
                  {rule.route_class || gettext("any")}
                </td>
                <td
                  id={"alert-rule-row-#{rule.id}-threshold"}
                  class="min-w-40 text-xs text-base-content/70"
                >
                  {threshold_summary(rule)}
                </td>
                <td
                  id={"alert-rule-row-#{rule.id}-cooldown"}
                  class="text-center font-mono text-xs tabular-nums text-base-content/70"
                >
                  {ngettext("%{count} min", "%{count} min", rule.cooldown_minutes)}
                </td>
                <td class="text-right">
                  <div class="flex justify-end gap-2">
                    <AdminComponents.action_button
                      id={"alert-rule-edit-#{rule.id}"}
                      icon="hero-pencil-square"
                      label={gettext("Edit")}
                      phx-click="open_edit_rule"
                      phx-value-id={rule.id}
                    />
                    <AdminComponents.action_button
                      :if={rule.state == AlertRule.active_state()}
                      id={"alert-rule-disable-#{rule.id}"}
                      icon="hero-pause"
                      label={gettext("Disable")}
                      phx-click="disable_rule"
                      phx-value-id={rule.id}
                    />
                    <AdminComponents.action_button
                      id={"alert-rule-delete-#{rule.id}"}
                      icon="hero-trash"
                      label={gettext("Delete")}
                      phx-click="open_delete_rule"
                      phx-value-id={rule.id}
                      variant={:danger}
                    />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </AdminComponents.admin_surface>

      <AdminComponents.admin_surface
        id="alerts-rule-form-panel"
        title={rule_form_title(@rule_form_mode)}
        description={gettext("The rule form is always available on this tab. Edit an existing row or save the inline values below.")}
        overflow={:visible}
      >
        <.form
          id="alerts-rule-form"
          for={@rule_form}
          phx-change="change_rule_form"
          phx-submit="save_rule"
          autocomplete="off"
          class="grid gap-4 p-4"
        >
          <.input field={@rule_form[:scope_type]} type="hidden" />
          <div class="grid gap-4">
            <.input
              id="alert-rule-pool-id"
              field={@rule_form[:pool_id]}
              type="select"
              label={gettext("Pool")}
              options={AlertRuleForm.pool_options(@manageable_pools)}
              prompt={gettext("Choose Pool")}
              required
              disabled={@manageable_pools == []}
            />
            <.input
              id="alert-rule-display-name"
              field={@rule_form[:display_name]}
              type="text"
              label={gettext("Rule name")}
              placeholder={gettext("Primary Pool serving risk")}
              required
            />
            <.input
              id="alert-rule-kind"
              field={@rule_form[:rule_kind]}
              type="select"
              label={gettext("Condition")}
              options={AlertRuleForm.rule_kind_options()}
              required
            />
          </div>

          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-1">
            <.input
              id="alert-rule-severity"
              field={@rule_form[:severity]}
              type="select"
              label={gettext("Severity")}
              options={AlertRuleForm.severity_options()}
            />
            <.input
              id="alert-rule-state"
              field={@rule_form[:state]}
              type="select"
              label={gettext("Rule state")}
              options={AlertRuleForm.state_options()}
            />
            <.input
              id="alert-rule-cooldown-minutes"
              field={@rule_form[:cooldown_minutes]}
              type="number"
              label={gettext("Cooldown minutes")}
              min={AlertRule.cooldown_minimum_minutes()}
              max={AlertRule.cooldown_maximum_minutes()}
              required
            />
            <div
              :if={
                model_scope_visible?(
                  AlertRuleForm.value(@rule_form[:rule_kind]),
                  AlertRuleForm.value(@rule_form[:model])
                )
              }
              id="alert-rule-model-scope-field"
              class="grid gap-1"
            >
              <.input
                id="alert-rule-model"
                field={@rule_form[:model]}
                type="text"
                label={gettext("Model scope")}
                placeholder={gettext("All models")}
                autocomplete="off"
              />
              <p id="alert-rule-model-scope-help" class="px-1 text-xs leading-5 text-base-content/55">
                {model_scope_help(AlertRuleForm.value(@rule_form[:rule_kind]))}
              </p>
            </div>
            <div
              :if={AlertRuleForm.value(@rule_form[:rule_kind]) in AlertRule.route_class_rule_kinds()}
              id="alert-rule-route-class-field"
              class="grid gap-1"
            >
              <.input
                id="alert-rule-route-class"
                field={@rule_form[:route_class]}
                type="select"
                label={gettext("Route class")}
                options={AlertRuleForm.route_class_options()}
                prompt={gettext("All route classes")}
              />
              <p
                id="alert-rule-route-class-help"
                class="px-1 text-xs leading-5 text-base-content/55"
              >
                {gettext("Leave blank for all route classes. This uses worst-wins evaluation across every class.")}
              </p>
            </div>
          </div>

          <div
            id="alert-rule-kind-fields"
            class="grid gap-4 rounded-box border border-base-300 bg-base-200 p-4"
          >
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
              {gettext("Rule-specific fields")}
            </p>

            <.input
              :if={AlertRuleForm.value(@rule_form[:rule_kind]) == "pool_low_usable_assignments"}
              id="alert-rule-min-usable-assignments"
              field={@rule_form[:min_usable_assignments]}
              type="number"
              label={gettext("Minimum usable assignments")}
              min="1"
            />

            <.input
              :if={
                AlertRuleForm.value(@rule_form[:rule_kind]) == "pool_all_assignments_in_state" ||
                  AlertRuleForm.value(@rule_form[:rule_kind]) == "upstream_auth_state"
              }
              id="alert-rule-target-state"
              field={@rule_form[:target_state]}
              type="select"
              label={gettext("Target state")}
              options={AlertRuleForm.target_state_options(AlertRuleForm.value(@rule_form[:rule_kind]))}
            />

            <.input
              :if={AlertRuleForm.value(@rule_form[:rule_kind]) == "upstream_quota_threshold"}
              id="alert-rule-window-selector"
              field={@rule_form[:window_selector]}
              type="select"
              label={gettext("Quota window")}
              options={AlertRuleForm.window_selector_options()}
            />

            <.input
              :if={AlertRuleForm.value(@rule_form[:rule_kind]) == "upstream_quota_threshold"}
              id="alert-rule-threshold-used-percent"
              field={@rule_form[:threshold_used_percent]}
              type="number"
              label={gettext("Used threshold percent")}
              min="0"
              max="100"
              step="0.1"
            />

            <p
              :if={AlertRuleForm.value(@rule_form[:rule_kind]) == "pool_no_usable_assignments"}
              id="alert-rule-no-extra-fields"
              class="text-sm leading-6 text-base-content/65"
            >
              {gettext("This rule fires when the selected Pool has no usable upstream assignments for the optional model scope.")}
            </p>
            <p
              :if={
                AlertRuleForm.value(@rule_form[:rule_kind]) ==
                  "upstream_saved_reset_banked_first_seen"
              }
              id="alert-rule-no-extra-fields"
              class="text-sm leading-6 text-base-content/65"
            >
              {gettext("This rule fires when persisted saved-reset metadata first shows a banked saved reset for an assigned upstream account.")}
            </p>
          </div>

          <div class="flex flex-wrap justify-end gap-2">
            <AdminComponents.action_button
              id="alert-rule-cancel"
              label={gettext("Cancel")}
              phx-click="cancel_rule_form"
            />
            <AdminComponents.action_button
              id="alert-rule-submit"
              icon="hero-check"
              label={rule_form_submit_label(@rule_form_mode)}
              type="submit"
              variant={:primary}
              disabled={@manageable_pools == []}
            />
          </div>
        </.form>
      </AdminComponents.admin_surface>
    </div>
    """
  end

  defp model_scope_visible?(rule_kind, model) do
    model_scope_supported?(rule_kind) or present_string?(model)
  end

  defp model_scope_supported?(rule_kind)
       when rule_kind in [
              "pool_no_usable_assignments",
              "pool_low_usable_assignments",
              "pool_all_assignments_in_state",
              "upstream_quota_threshold"
            ],
       do: true

  defp model_scope_supported?(_rule_kind), do: false

  defp model_scope_help(rule_kind) do
    if model_scope_supported?(rule_kind) do
      gettext("Optional. Leave blank to evaluate all models for this Pool; set a model id to scope assignment coverage or quota evidence.")
    else
      gettext("This condition does not use model scope. Clear the stored value and save if this rule was created before the form was simplified.")
    end
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
  defp rule_form_title(:edit), do: gettext("Edit rule")
  defp rule_form_title(_mode), do: gettext("Create rule")

  defp rule_form_submit_label(:edit), do: gettext("Save rule")
  defp rule_form_submit_label(_mode), do: gettext("Create rule")

  defp rule_count_label(rules) do
    ngettext("%{count} rule", "%{count} rules", length(rules))
  end

  defp pool_name_for(pool_lookup, pool_id),
    do: pool_lookup |> Map.fetch!(pool_id) |> Map.fetch!(:name)

  defp pool_slug_for(pool_lookup, pool_id),
    do: pool_lookup |> Map.fetch!(pool_id) |> Map.fetch!(:slug)

  defp threshold_summary(%AlertRule{rule_kind: "pool_low_usable_assignments"} = rule),
    do: ngettext("Minimum %{count} usable assignments", "Minimum %{count} usable assignments", rule.min_usable_assignments || 1)

  defp threshold_summary(%AlertRule{rule_kind: "pool_all_assignments_in_state"} = rule),
    do: gettext("All assignments %{state}", state: AlertRuleForm.target_state_label(rule.target_state))

  defp threshold_summary(%AlertRule{rule_kind: "upstream_quota_threshold"} = rule),
    do: gettext("%{window} at %{threshold}", window: AlertRuleForm.window_selector_label(rule.window_selector), threshold: AlertRuleForm.threshold_label(rule.threshold_used_percent))

  defp threshold_summary(%AlertRule{rule_kind: "upstream_auth_state"} = rule),
    do: gettext("Assigned upstream %{state}", state: AlertRuleForm.target_state_label(rule.target_state))

  defp threshold_summary(%AlertRule{rule_kind: "upstream_saved_reset_banked_first_seen"}),
    do: gettext("First banked reset observed")

  defp threshold_summary(_rule), do: gettext("No usable assignments")
end
