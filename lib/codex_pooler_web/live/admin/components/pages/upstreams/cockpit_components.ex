defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer
  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.{Charts, Dialogs, Sections, Summary}
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AuthJsonDialog
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.ReconciliationStatus

  attr :cockpit, :map, required: true
  attr :auth_json_form, :any, required: true
  attr :auth_json_upload_limit_label, :string, required: true
  attr :dialog_pool_options, :list, required: true
  attr :importing_auth_json, :boolean, required: true
  attr :oauth_relinking, :boolean, required: true
  attr :oauth_relink_form, :any, required: true
  attr :oauth_relink_flow, :map, default: nil
  attr :oauth_relink_authorization_url, :string, default: nil
  attr :oauth_relink_result, :map, default: nil
  attr :oauth_relink_error, :map, default: nil
  attr :renaming_account, :map, default: nil
  attr :rename_account_form, :any, default: nil
  attr :deleting_account, :map, default: nil
  attr :delete_account_form, :any, required: true
  attr :saved_reset_policy_form, :any, required: true
  attr :confirming_saved_reset_redemption, :map, default: nil
  attr :selected_request_log, :map, default: nil
  attr :refresh_data_message, :string, default: nil
  attr :uploads, :map, required: true
  attr :datetime_preferences, :map, required: true

  def cockpit_page(assigns) do
    ~H"""
    <div id="request-log-detail-drawer-root" class="drawer drawer-end">
      <input
        id="request-log-detail-drawer"
        type="checkbox"
        class="drawer-toggle"
        checked={@selected_request_log != nil}
      />

      <div class="drawer-content min-w-0">
        <section id="upstream-cockpit" class="grid gap-4">
          <AuthJsonDialog.auth_json_import_dialog
            auth_json_form={@auth_json_form}
            importing_auth_json={@importing_auth_json}
            pool_options={@dialog_pool_options}
            upload={@uploads.auth_json}
            upload_limit_label={@auth_json_upload_limit_label}
          />

          <Dialogs.oauth_relink_dialog
            oauth_relinking={@oauth_relinking}
            oauth_relink_form={@oauth_relink_form}
            oauth_relink_flow={@oauth_relink_flow}
            oauth_relink_authorization_url={@oauth_relink_authorization_url}
            oauth_relink_result={@oauth_relink_result}
            oauth_relink_error={@oauth_relink_error}
          />

          <Dialogs.rename_account_dialog account={@renaming_account} form={@rename_account_form} />
          <Dialogs.delete_account_dialog account={@deleting_account} form={@delete_account_form} />

          <ReconciliationStatus.reconciliation_status
            id_prefix="upstream-cockpit"
            identity_observability={@cockpit.header.identity_observability}
            reauth_required?={@cockpit.flags.reauth_required?}
          />

          <div class="grid items-start gap-4 xl:grid-cols-[minmax(0,4fr)_minmax(0,8fr)]">
            <div class="grid gap-4 xl:sticky xl:top-4">
              <Summary.credential_card cockpit={@cockpit} />
              <Summary.vitals_card cockpit={@cockpit} />
              <Summary.relink_card cockpit={@cockpit} datetime_preferences={@datetime_preferences} />
              <Sections.actions_rail
                cockpit={@cockpit}
                confirming_saved_reset_redemption={@confirming_saved_reset_redemption}
              />
            </div>

            <div class="grid min-w-0 gap-4">
              <Sections.readiness_section
                cockpit={@cockpit}
                datetime_preferences={@datetime_preferences}
              />
              <Charts.quota_section
                cockpit={@cockpit}
                saved_reset_policy_form={@saved_reset_policy_form}
                datetime_preferences={@datetime_preferences}
              />
              <Charts.request_section cockpit={@cockpit} refresh_data_message={@refresh_data_message} />
              <Sections.recent_events_section
                cockpit={@cockpit}
                datetime_preferences={@datetime_preferences}
              />
            </div>
          </div>
        </section>
      </div>

      <RequestLogDetailDrawer.request_log_detail_drawer
        selected_request_log={@selected_request_log}
        datetime_preferences={@datetime_preferences}
      />
    </div>
    """
  end
end
