defmodule CodexPoolerWeb.Admin.UpstreamCockpitComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.UpstreamCockpitComponents.{Charts, Dialogs, Sections, Summary}
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AuthJsonDialog

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
  attr :refresh_data_message, :string, default: nil
  attr :uploads, :map, required: true
  attr :datetime_preferences, :map, required: true

  def cockpit_page(assigns) do
    ~H"""
    <section id="upstream-cockpit" class="grid gap-6">
      <Summary.cockpit_navigation />

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

      <Summary.identity_summary cockpit={@cockpit} />
      <Summary.status_summary cockpit={@cockpit} datetime_preferences={@datetime_preferences} />
      <Summary.oauth_flow_state cockpit={@cockpit} datetime_preferences={@datetime_preferences} />
      <Sections.assignments_section cockpit={@cockpit} />
      <Charts.quota_section cockpit={@cockpit} datetime_preferences={@datetime_preferences} />
      <Charts.request_section cockpit={@cockpit} />
      <Charts.pool_contribution_section cockpit={@cockpit} />
      <Sections.recent_events_section cockpit={@cockpit} datetime_preferences={@datetime_preferences} />
      <Sections.actions_section
        cockpit={@cockpit}
        saved_reset_policy_form={@saved_reset_policy_form}
        confirming_saved_reset_redemption={@confirming_saved_reset_redemption}
        datetime_preferences={@datetime_preferences}
      />
      <Sections.related_links_section cockpit={@cockpit} />
      <Sections.refresh_section cockpit={@cockpit} refresh_data_message={@refresh_data_message} />
    </section>
    """
  end
end
