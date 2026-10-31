defmodule CodexPoolerWeb.Admin.AuditLogsComponents.Presentation do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Audit
  alias CodexPoolerWeb.DateTimeDisplay

  @outcome_options ~w(success failure)

  @spec outcome_options() :: [{String.t(), String.t()}]
  def outcome_options,
    do: [{gettext("Any outcome"), ""} | Enum.map(@outcome_options, &{outcome_label(&1), &1})]

  @spec outcome_filter_label(String.t() | nil) :: String.t()
  def outcome_filter_label(outcome) do
    outcome
    |> blank_to_nil()
    |> case do
      nil -> gettext("Any outcome")
      outcome -> outcome_label(outcome)
    end
  end

  def outcome_filter_icon("success"), do: "hero-check-circle"
  def outcome_filter_icon("failure"), do: "hero-x-circle"
  def outcome_filter_icon(_outcome), do: "hero-squares-2x2"

  def outcome_filter_icon_class("success"), do: "text-success"
  def outcome_filter_icon_class("failure"), do: "text-error"
  def outcome_filter_icon_class(_outcome), do: "text-base-content/60"

  @spec actor_type_options() :: [{String.t(), String.t()}]
  def actor_type_options, do: [{gettext("Any actor"), ""}, {gettext("User"), "user"}, {gettext("System"), "system"}]

  @spec action_options() :: [{String.t(), String.t()}]
  def action_options, do: [{gettext("Any event"), ""} | Enum.map(Audit.supported_actions(), &{action_label(&1), &1})]

  @spec action_filter_label(String.t() | nil) :: String.t()
  def action_filter_label(action) do
    action
    |> blank_to_nil()
    |> case do
      nil -> gettext("Any event")
      action -> action_label(action) || fallback_event_title(action)
    end
  end

  def action_filter_icon(action), do: audit_action_icon(action)
  def action_filter_icon_class(action), do: audit_action_icon_class(action)

  def event_icon(%{action: action}), do: audit_action_icon(action)
  def event_icon(_event), do: "hero-clipboard-document-list"

  def audit_action_icon("auth." <> _suffix), do: "hero-shield-check"
  def audit_action_icon("operator." <> _suffix), do: "hero-user-circle"
  def audit_action_icon("pool." <> _suffix), do: "hero-server-stack"
  def audit_action_icon("invite." <> _suffix), do: "hero-envelope"
  def audit_action_icon("upstream_account." <> _suffix), do: "hero-cloud-arrow-up"
  def audit_action_icon("api_key." <> _suffix), do: "hero-key"
  def audit_action_icon("mcp." <> _suffix), do: "hero-command-line"
  def audit_action_icon("alert_" <> _suffix), do: "hero-bell-alert"
  def audit_action_icon("instance_settings." <> _suffix), do: "hero-cog-6-tooth"
  def audit_action_icon(action) when action in [nil, ""], do: "hero-squares-2x2"
  def audit_action_icon(_action), do: "hero-clipboard-document-list"

  def audit_action_icon_class("auth." <> _suffix), do: "text-success"
  def audit_action_icon_class("operator." <> _suffix), do: "text-info"
  def audit_action_icon_class("pool." <> _suffix), do: "text-primary"
  def audit_action_icon_class("invite." <> _suffix), do: "text-primary"
  def audit_action_icon_class("upstream_account." <> _suffix), do: "text-primary"
  def audit_action_icon_class("api_key." <> _suffix), do: "text-warning"
  def audit_action_icon_class("mcp." <> _suffix), do: "text-info"
  def audit_action_icon_class("alert_" <> _suffix), do: "text-warning"
  def audit_action_icon_class(_action), do: "text-base-content/60"

  def event_icon_class("success"), do: "mx-auto size-5 text-success"
  def event_icon_class("failure"), do: "mx-auto size-5 text-error"
  def event_icon_class(_outcome), do: "mx-auto size-5 text-base-content/60"

  @spec event_title(map()) :: String.t()
  def event_title(%{action: action}) when is_binary(action) do
    action_label(action) || fallback_event_title(action)
  end

  def event_title(%{action: action}) do
    fallback_event_title(action)
  end

  def fallback_event_title(action) do
    action
    |> to_string()
    |> String.replace([".", "_"], " ")
    |> String.capitalize()
  end

  @spec target_label(map()) :: String.t()
  def target_label(%{target_type: "user"} = event),
    do: detail_value(event, "email") || gettext("Operator account")

  def target_label(%{target_type: "session"}), do: gettext("Browser session")
  def target_label(%{target_type: "recovery_code"}), do: gettext("Recovery code")
  def target_label(%{target_type: "request"} = event), do: request_label(event)
  def target_label(%{target_type: type}), do: type |> to_string() |> humanize_key()

  def target_link(%{target_type: "user"}), do: ~p"/admin/operators"
  def target_link(%{target_type: "request"} = event), do: request_log_link(event)
  def target_link(_event), do: nil

  def actor_link(%{actor_type: "user", actor_user_id: actor_user_id})
      when is_binary(actor_user_id),
      do: ~p"/admin/operators"

  def actor_link(_event), do: nil

  def request_log_link(%{pool_id: pool_id} = event) when is_binary(pool_id) do
    case request_identifier(event) do
      nil -> nil
      request_id -> ~p"/admin/request-logs?pool_id=#{pool_id}&request_id=#{request_id}"
    end
  end

  def request_log_link(_event), do: nil

  @spec request_label(map()) :: String.t()
  def request_label(event) do
    case request_identifier(event) do
      nil -> gettext("request")
      request_id -> gettext("request %{id}", id: short_identifier(request_id))
    end
  end

  def request_identifier(%{request_id: request_id}) when is_binary(request_id), do: request_id
  def request_identifier(%{target_id: target_id}) when is_binary(target_id), do: target_id
  def request_identifier(_event), do: nil

  @spec event_summary_rows(map()) :: [{String.t(), term()}]
  def event_summary_rows(event) do
    [
      {gettext("Outcome"), outcome_label(event.outcome)},
      {gettext("Actor"), format_actor(event)},
      {gettext("Target"), target_label(event)},
      {gettext("Request"), request_identifier(event)},
      {gettext("Correlation"), event.correlation_id},
      {gettext("IP address"), event.ip_address},
      {gettext("Action"), event.action},
      {gettext("Event id"), event.id}
    ]
    |> Enum.reject(fn {_label, value} -> blank?(value) end)
  end

  def detail_rows(details) when is_map(details) do
    details
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {humanize_key(key), useful_string(value)} end)
    |> Enum.reject(fn {_label, value} -> blank?(value) end)
  end

  def detail_rows(_details), do: []

  @spec outcome_label(String.t() | nil) :: String.t()
  def outcome_label("success"), do: gettext("Success")
  def outcome_label("failure"), do: gettext("Failure")
  def outcome_label(outcome), do: humanize_key(outcome)

  @spec format_actor(map()) :: String.t()
  def format_actor(%{actor_type: "system"}), do: gettext("system")
  def format_actor(%{actor_user_email: email}) when is_binary(email) and email != "", do: email
  def format_actor(%{actor_user_id: id}), do: format_uuid(id)

  @spec format_uuid(String.t() | nil) :: String.t()
  def format_uuid(nil), do: gettext("not recorded")
  def format_uuid(id), do: id

  def detail_value(%{details: details}, key) when is_map(details) do
    value = Map.get(details, key) || Map.get(details, to_string(key))

    value = useful_string(value)

    if blank?(value) do
      nil
    else
      value
    end
  end

  def format_detail_value(value) when is_binary(value), do: value
  def format_detail_value(value) when is_atom(value), do: Atom.to_string(value)
  def format_detail_value(value), do: inspect(value, printable_limit: 80, limit: 10)

  def useful_string(nil), do: nil

  def useful_string(value) do
    value = value |> format_detail_value() |> String.trim()

    if String.downcase(value) in ["", "nil", "null", "not recorded"] do
      nil
    else
      value
    end
  end

  @spec humanize_key(term()) :: String.t()
  def humanize_key(value) do
    key = to_string(value)
    known_key_label(key) || key |> String.replace(["_", "."], " ") |> String.capitalize()
  end

  def short_identifier(value) do
    value
    |> to_string()
    |> String.slice(0, 8)
  end

  @spec format_datetime(DateTime.t() | nil, map()) :: String.t()
  def format_datetime(datetime, preferences) do
    DateTimeDisplay.format_datetime(datetime, preferences, missing_label: gettext("not recorded"))
  end

  def format_total(1), do: "1"
  def format_total(total), do: Integer.to_string(total || 0)

  def blank_to_nil(value), do: if(blank?(value), do: nil, else: String.trim(to_string(value)))
  def blank?(nil), do: true
  def blank?(value), do: String.trim(to_string(value)) == ""

  defp known_key_label("pool"), do: gettext("Pool")
  defp known_key_label("upstream_identity"), do: gettext("Upstream identity")
  defp known_key_label("api_key"), do: gettext("Api key")
  defp known_key_label("mcp_token"), do: gettext("Mcp token")
  defp known_key_label("alert_rule"), do: gettext("Alert rule")
  defp known_key_label("alert_channel"), do: gettext("Alert channel")
  defp known_key_label("alert_incident"), do: gettext("Alert incident")
  defp known_key_label("instance_settings"), do: gettext("Instance settings")
  defp known_key_label("role"), do: gettext("Role")
  defp known_key_label("previous_role"), do: gettext("Previous role")
  defp known_key_label("status"), do: gettext("Status")
  defp known_key_label("previous_status"), do: gettext("Previous status")
  defp known_key_label("email"), do: gettext("Email")
  defp known_key_label("invited_email"), do: gettext("Invited email")
  defp known_key_label("name"), do: gettext("Name")
  defp known_key_label("label"), do: gettext("Label")
  defp known_key_label("account_label"), do: gettext("Account label")
  defp known_key_label("pool_name"), do: gettext("Pool name")
  defp known_key_label("changed_fields"), do: gettext("Changed fields")
  defp known_key_label("reason"), do: gettext("Reason")
  defp known_key_label("error"), do: gettext("Error")
  defp known_key_label("message"), do: gettext("Message")
  defp known_key_label("routing_strategy"), do: gettext("Routing strategy")
  defp known_key_label("model"), do: gettext("Model")
  defp known_key_label("serving_mode"), do: gettext("Serving mode")
  defp known_key_label("previous_serving_mode"), do: gettext("Previous serving mode")
  defp known_key_label("assigned_pool_ids"), do: gettext("Assigned pool ids")
  defp known_key_label("pool_ids"), do: gettext("Pool ids")
  defp known_key_label("totp_enabled"), do: gettext("Totp enabled")
  defp known_key_label("password_change_required"), do: gettext("Password change required")
  defp known_key_label("send_email"), do: gettext("Send email")
  defp known_key_label("channel_type"), do: gettext("Channel type")
  defp known_key_label("severity"), do: gettext("Severity")
  defp known_key_label("state"), do: gettext("State")
  defp known_key_label("rule_kind"), do: gettext("Rule kind")
  defp known_key_label(_key), do: nil

  defp action_label("auth.bootstrap"), do: gettext("First owner account created")
  defp action_label("auth.login"), do: gettext("Operator signed in")
  defp action_label("auth.logout"), do: gettext("Operator signed out")
  defp action_label("auth.session_revoked"), do: gettext("Browser session signed out")
  defp action_label("auth.sessions_revoked"), do: gettext("Other browser sessions signed out")
  defp action_label("auth.recovery_code_used"), do: gettext("Recovery code used")
  defp action_label("auth.password_change"), do: gettext("Password changed")
  defp action_label("auth.required_password_change"), do: gettext("Required password change completed")
  defp action_label("auth.totp_enrolled"), do: gettext("Authenticator app enrolled")
  defp action_label("operator.create"), do: gettext("Operator account created")
  defp action_label("operator.update"), do: gettext("Operator account updated")
  defp action_label("operator.deactivate"), do: gettext("Operator account deactivated")
  defp action_label("operator.reactivate"), do: gettext("Operator account reactivated")
  defp action_label("operator.password_reset"), do: gettext("Temporary password issued")
  defp action_label("operator.temporary_password_resend"), do: gettext("Temporary password resent")
  defp action_label("pool.create"), do: gettext("Pool created")
  defp action_label("pool.update"), do: gettext("Pool updated")
  defp action_label("pool.status_update"), do: gettext("Pool status changed")
  defp action_label("pool.routing_update"), do: gettext("Pool routing updated")
  defp action_label("pool.model_serving_modes_update"), do: gettext("Pool model serving modes updated")
  defp action_label("pool.assignment_add"), do: gettext("Pool upstream account assigned")
  defp action_label("pool.assignment_remove"), do: gettext("Pool upstream account unassigned")
  defp action_label("pool.delete_requested"), do: gettext("Pool deletion requested")
  defp action_label("pool.delete"), do: gettext("Pool deleted")
  defp action_label("invite.create"), do: gettext("Pool invite created")
  defp action_label("invite.revoke"), do: gettext("Pool invite revoked")
  defp action_label("upstream_account.import"), do: gettext("Upstream account imported")
  defp action_label("upstream_account.oauth_browser_link"), do: gettext("Upstream account linked via browser OAuth")
  defp action_label("upstream_account.oauth_device_link"), do: gettext("Upstream account linked via device code")
  defp action_label("upstream_account.rename"), do: gettext("Upstream account renamed")
  defp action_label("upstream_account.pause"), do: gettext("Upstream account paused")
  defp action_label("upstream_account.reactivate"), do: gettext("Upstream account reactivated")
  defp action_label("upstream_account.refresh_enqueue"), do: gettext("Upstream account token refresh queued")
  defp action_label("upstream_account.delete_requested"), do: gettext("Upstream account deletion requested")
  defp action_label("upstream_account.delete"), do: gettext("Upstream account deleted")
  defp action_label("upstream_account.saved_reset_policy_update"), do: gettext("Upstream account saved reset policy updated")
  defp action_label("upstream_account.provider_credits_policy_update"), do: gettext("Upstream account provider credits policy updated")
  defp action_label("upstream_account.saved_reset_redeem_enqueue"), do: gettext("Upstream account saved reset redemption queued")
  defp action_label("api_key.create"), do: gettext("API key created")
  defp action_label("api_key.update"), do: gettext("API key updated")
  defp action_label("api_key.pause"), do: gettext("API key paused")
  defp action_label("api_key.resume"), do: gettext("API key resumed")
  defp action_label("api_key.revoke"), do: gettext("API key revoked")
  defp action_label("api_key.rotate"), do: gettext("API key rotated")
  defp action_label("api_key.delete_requested"), do: gettext("API key deletion requested")
  defp action_label("api_key.delete"), do: gettext("API key deleted")
  defp action_label("mcp.operator_enable"), do: gettext("Operator MCP enabled")
  defp action_label("mcp.operator_disable"), do: gettext("Operator MCP disabled")
  defp action_label("mcp.token_create"), do: gettext("MCP token created")
  defp action_label("mcp.token_update"), do: gettext("MCP token label updated")
  defp action_label("mcp.token_delete"), do: gettext("MCP token deleted")
  defp action_label("alert_rule.create"), do: gettext("Alert rule created")
  defp action_label("alert_rule.update"), do: gettext("Alert rule updated")
  defp action_label("alert_rule.enable"), do: gettext("Alert rule enabled")
  defp action_label("alert_rule.disable"), do: gettext("Alert rule disabled")
  defp action_label("alert_rule.delete"), do: gettext("Alert rule deleted")
  defp action_label("alert_channel.create"), do: gettext("Alert channel created")
  defp action_label("alert_channel.update"), do: gettext("Alert channel updated")
  defp action_label("alert_channel.enable"), do: gettext("Alert channel enabled")
  defp action_label("alert_channel.disable"), do: gettext("Alert channel disabled")
  defp action_label("alert_channel.delete"), do: gettext("Alert channel deleted")
  defp action_label("alert_incident.acknowledge"), do: gettext("Alert incident acknowledged")
  defp action_label("alert_incident.resolve"), do: gettext("Alert incident resolved")
  defp action_label("instance_settings.update"), do: gettext("Instance settings updated")
  defp action_label(_action), do: nil
end
