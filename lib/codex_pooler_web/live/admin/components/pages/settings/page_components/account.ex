defmodule CodexPoolerWeb.Admin.SettingsPageComponents.Account do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :account_form, :any, required: true
  attr :datetime_format_options, :list, required: true
  attr :timezone_options, :list, required: true

  def profile_panel(assigns) do
    ~H"""
    <section
      id="settings-account-profile-panel"
      class="grid gap-4 rounded-box border border-base-300 bg-base-100 p-5 shadow-sm lg:grid-cols-[16rem_minmax(0,1fr)]"
    >
      <div class="border-base-300 lg:border-r lg:pr-5">
        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
          Identity
        </p>
        <h3 class="mt-1 text-xl font-semibold text-base-content">Operator profile</h3>
        <p class="mt-2 text-sm leading-6 text-base-content/65">
          Update the account details shown in this admin session.
        </p>
      </div>
      <.form
        id="settings-account-form"
        for={@account_form}
        phx-submit="save_account"
        autocomplete="off"
        class="grid min-w-0 gap-4"
      >
        <div class="grid gap-4 md:grid-cols-2">
          <.input
            id="settings-account-email"
            field={@account_form[:email]}
            type="email"
            label="Email"
            required
          />
          <.input
            id="settings-account-display-name"
            field={@account_form[:display_name]}
            type="text"
            label="Display name"
          />
        </div>
        <div class="grid gap-4 md:grid-cols-2">
          <.input
            id="settings-account-datetime-format"
            field={@account_form[:datetime_format]}
            type="select"
            label="Time format"
            options={@datetime_format_options}
            required
          />
          <.input
            id="settings-account-timezone"
            field={@account_form[:timezone]}
            type="select"
            label="Timezone"
            options={@timezone_options}
            required
          />
        </div>
        <div class="flex justify-end">
          <AdminComponents.action_button
            id="settings-account-submit"
            icon="hero-check"
            label="Save account"
            type="submit"
            variant={:primary}
          />
        </div>
      </.form>
    </section>
    """
  end
end
