defmodule CodexPoolerWeb.Dev.ComponentShowcaseAdminForms do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.CoreComponents
  alias CodexPoolerWeb.Layouts

  def form_primitives(assigns) do
    assigns = assign(assigns, :filter_form, to_form(%{"from" => ""}, as: :showcase_filter))

    ~H"""
    <AdminComponents.admin_surface id="showcase-form-surface" title="Filters and inputs">
      <div class="grid gap-4 p-4">
        <AdminComponents.filter_form id="showcase-filter-form" for={@filter_form} advanced_open>
          <AdminComponents.cally_date_filter field={@filter_form[:from]} label="From" />
          <:advanced>
            <CoreComponents.input
              id="showcase-input-select"
              name="showcase[status]"
              label="Status"
              type="select"
              options={[{"Any", "any"}, {"Succeeded", "succeeded"}]}
              value="any"
            />
          </:advanced>
          <:actions>
            <AdminComponents.action_button id="showcase-filter-apply" label="Apply" />
          </:actions>
        </AdminComponents.filter_form>
        <div class="grid gap-3 md:grid-cols-2">
          <CoreComponents.input
            id="showcase-input-text"
            name="showcase[label]"
            label="Label"
            value="Sample"
          />
          <CoreComponents.input
            id="showcase-input-textarea"
            name="showcase[notes]"
            label="Notes"
            type="textarea"
            value="Metadata only"
          />
          <CoreComponents.input
            id="showcase-input-checkbox"
            name="showcase[enabled]"
            label="Enabled"
            type="checkbox"
            value="true"
          />
          <CoreComponents.input
            id="showcase-input-error"
            name="showcase[invalid]"
            label="Invalid sample"
            value=""
            errors={["must be selected"]}
          />
          <CoreComponents.otp_input
            id="showcase-input-otp"
            name="showcase[otp]"
            label="One-time code"
            value="123456"
          />
          <Layouts.theme_toggle
            id="showcase-theme-toggle"
            class="card relative flex h-10 w-40 flex-row items-center rounded-full border-2 border-base-300 bg-base-300 md:justify-self-end"
          />
        </div>
      </div>
    </AdminComponents.admin_surface>
    """
  end
end
