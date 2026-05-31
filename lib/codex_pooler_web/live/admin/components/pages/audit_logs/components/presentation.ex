defmodule CodexPoolerWeb.Admin.AuditLogsComponents.Presentation do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Audit

  @outcome_options ~w(success failure)
  @actor_type_options ~w(user system)

  def outcome_options,
    do: [{"Any outcome", ""} | Enum.map(@outcome_options, &{String.capitalize(&1), &1})]

  def outcome_filter_label(outcome) do
    outcome
    |> blank_to_nil()
    |> case do
      nil -> "Any outcome"
      outcome -> outcome_label(outcome)
    end
  end

  def outcome_filter_icon("success"), do: "hero-check-circle"
  def outcome_filter_icon("failure"), do: "hero-x-circle"
  def outcome_filter_icon(_outcome), do: "hero-squares-2x2"

  def outcome_filter_icon_class("success"), do: "text-success"
  def outcome_filter_icon_class("failure"), do: "text-error"
  def outcome_filter_icon_class(_outcome), do: "text-base-content/60"

  def actor_type_options,
    do: [{"Any actor", ""} | Enum.map(@actor_type_options, &{String.capitalize(&1), &1})]

  def action_options, do: [{"Any event", ""} | Audit.action_options()]

  def action_filter_label(action) do
    action
    |> blank_to_nil()
    |> case do
      nil -> "Any event"
      action -> Audit.action_label(action) || fallback_event_title(action)
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

  def event_title(%{action: action}) when is_binary(action) do
    Audit.action_label(action) || fallback_event_title(action)
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

  def target_label(%{target_type: "user"} = event),
    do: detail_value(event, "email") || "Operator account"

  def target_label(%{target_type: "session"}), do: "Browser session"
  def target_label(%{target_type: "recovery_code"}), do: "Recovery code"
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

  def request_label(event) do
    case request_identifier(event) do
      nil -> "request"
      request_id -> "request #{short_identifier(request_id)}"
    end
  end

  def request_identifier(%{request_id: request_id}) when is_binary(request_id), do: request_id
  def request_identifier(%{target_id: target_id}) when is_binary(target_id), do: target_id
  def request_identifier(_event), do: nil

  def event_summary_rows(event) do
    [
      {"Outcome", outcome_label(event.outcome)},
      {"Actor", format_actor(event)},
      {"Target", target_label(event)},
      {"Request", request_identifier(event)},
      {"Correlation", event.correlation_id},
      {"IP address", event.ip_address},
      {"Action", event.action},
      {"Event id", event.id}
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

  def outcome_label("success"), do: "Success"
  def outcome_label("failure"), do: "Failure"
  def outcome_label(outcome), do: humanize_key(outcome)

  def format_actor(%{actor_type: "system"}), do: "system"
  def format_actor(%{actor_user_email: email}) when is_binary(email) and email != "", do: email
  def format_actor(%{actor_user_id: id}), do: format_uuid(id)

  def format_uuid(nil), do: "not recorded"
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

  def humanize_key(value) do
    value
    |> to_string()
    |> String.replace(["_", "."], " ")
    |> String.capitalize()
  end

  def short_identifier(value) do
    value
    |> to_string()
    |> String.slice(0, 8)
  end

  def format_datetime(nil), do: "not recorded"

  def format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  def format_total(1), do: "1"
  def format_total(total), do: Integer.to_string(total || 0)

  def blank_to_nil(value), do: if(blank?(value), do: nil, else: String.trim(to_string(value)))
  def blank?(nil), do: true
  def blank?(value), do: String.trim(to_string(value)) == ""
end
