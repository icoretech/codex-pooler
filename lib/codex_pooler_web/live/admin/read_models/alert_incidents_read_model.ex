defmodule CodexPoolerWeb.Admin.AlertIncidentsReadModel do
  @moduledoc false

  import Ecto.Query
  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.AlertIncidentRelationships
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertChannel
  alias CodexPooler.Alerts.Schemas.AlertIncident
  alias CodexPooler.Alerts.Schemas.AlertRule
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.AlertRuleForm
  alias CodexPoolerWeb.Admin.PoolFilterComponents

  @page_size 50
  @email_like_regex ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/
  @jwt_like_regex ~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/
  @sensitive_identity_regex ~r/(?i)\b(authorization|bearer|cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|prompt|secret|token)\b/
  @uuid_regex ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/i

  @type filter_error :: %{required(:field) => atom(), required(:message) => String.t()}
  @type option :: %{
          required(:label) => String.t(),
          required(:value) => String.t(),
          required(:icon) => String.t()
        }
  @type delivery_detail :: %{
          required(:label) => String.t(),
          required(:value) => String.t()
        }
  @type delivery_attempt :: %{
          required(:id) => Ecto.UUID.t(),
          required(:channel_id) => Ecto.UUID.t(),
          required(:channel_label) => String.t(),
          required(:status) => String.t(),
          required(:status_label) => String.t(),
          required(:attempt_number) => pos_integer(),
          required(:max_attempts) => pos_integer(),
          required(:attempted_at) => DateTime.t() | nil,
          required(:completed_at) => DateTime.t() | nil,
          required(:response_status_code) => integer() | nil,
          required(:retryable) => boolean(),
          required(:failure_code) => String.t() | nil,
          required(:failure_message) => String.t() | nil,
          required(:details) => [delivery_detail()]
        }
  @type delivery_summary :: %{
          required(:total_count) => non_neg_integer(),
          required(:sent_count) => non_neg_integer(),
          required(:attention_count) => non_neg_integer(),
          required(:latest_status) => String.t() | nil,
          required(:label) => String.t(),
          required(:attempts) => [delivery_attempt()]
        }
  @type incident_row :: %{
          required(:id) => Ecto.UUID.t(),
          required(:scope_type) => String.t(),
          required(:rule_kind) => String.t(),
          required(:rule_kind_label) => String.t(),
          required(:severity) => String.t(),
          required(:severity_label) => String.t(),
          required(:state) => String.t(),
          required(:state_label) => String.t(),
          required(:reason_title) => String.t(),
          required(:reason_detail) => String.t(),
          required(:upstream_account_label) => String.t() | nil,
          required(:occurrence_count) => pos_integer(),
          required(:first_seen_at) => DateTime.t(),
          required(:last_seen_at) => DateTime.t(),
          required(:resolved_at) => DateTime.t() | nil,
          required(:impacted_pools) => [Alerts.pool_target()],
          required(:visible_impacted_pool_count) => non_neg_integer(),
          required(:hidden_impacted_pool_count) => non_neg_integer(),
          required(:linked_rules) => [option()],
          required(:linked_channels) => [option()],
          required(:delivery_summary) => delivery_summary()
        }
  @type page_state :: %{
          required(:manageable_pools) => [term()],
          required(:pool_lookup) => %{String.t() => term()},
          required(:rules) => [AlertRule.t()],
          required(:channels) => [AlertChannel.t()],
          required(:incidents) => [incident_row()],
          required(:filter_form) => Phoenix.HTML.Form.t(),
          required(:filter_values) => %{String.t() => String.t()},
          required(:filter_errors) => [filter_error()],
          required(:pool_filter_options) => [map()],
          required(:severity_filter_options) => [option()],
          required(:state_filter_options) => [option()],
          required(:rule_filter_options) => [option()],
          required(:channel_filter_options) => [option()],
          required(:total_count) => non_neg_integer(),
          required(:page_size) => pos_integer()
        }

  @spec load(Scope.t(), map()) :: page_state()
  def load(%Scope{} = scope, params) when is_map(params) do
    pools = manageable_pools(scope)
    rules = visible_rules(scope)
    channels = visible_channels(scope)
    {filters, form_values, filter_errors} = parse_filters(params, pools, rules, channels)
    incidents = load_incidents(scope, filters, filter_errors)
    rows = incident_rows(scope, incidents, filters)

    %{
      manageable_pools: pools,
      pool_lookup: Map.new(pools, &{&1.id, &1}),
      rules: rules,
      channels: channels,
      incidents: Enum.take(rows, @page_size),
      filter_form: to_form(form_values, as: :filters, errors: form_errors(filter_errors)),
      filter_values: form_values,
      filter_errors: filter_errors,
      pool_filter_options: PoolFilterComponents.pool_filter_options(pools),
      severity_filter_options: severity_filter_options(),
      state_filter_options: state_filter_options(),
      rule_filter_options: rule_filter_options(rules),
      channel_filter_options: channel_filter_options(channels),
      total_count: length(rows),
      page_size: @page_size
    }
  end

  @spec query_params(map()) :: map()
  def query_params(params) when is_map(params) do
    params
    |> Map.take(~w(pool_id severity state rule_id channel_id))
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
    |> Map.put("tab", "incidents")
  end

  @spec severity_label(String.t() | nil) :: String.t()
  def severity_label("critical"), do: "Critical"
  def severity_label("warning"), do: "Warning"
  def severity_label("info"), do: "Info"
  def severity_label(_severity), do: "Unknown severity"

  @spec state_label(String.t() | nil) :: String.t()
  def state_label("open"), do: "Open"
  def state_label("acknowledged"), do: "Acknowledged"
  def state_label("resolved"), do: "Resolved"
  def state_label(_state), do: "Unknown state"

  defp manageable_pools(scope) do
    case Alerts.list_manageable_pools(scope) do
      {:ok, pools} -> pools
      {:error, _reason} -> []
    end
  end

  defp visible_rules(scope) do
    case Alerts.list_rules(scope) do
      {:ok, rules} -> rules
      {:error, _reason} -> []
    end
  end

  defp visible_channels(scope) do
    case Alerts.list_channels(scope) do
      {:ok, channels} -> channels
      {:error, _reason} -> []
    end
  end

  defp parse_filters(params, pools, rules, channels) do
    form_values = %{
      "pool_id" => string_param(params, "pool_id"),
      "severity" => string_param(params, "severity"),
      "state" => string_param(params, "state"),
      "rule_id" => string_param(params, "rule_id"),
      "channel_id" => string_param(params, "channel_id")
    }

    {pool_id, pool_error} = parse_pool_id(form_values["pool_id"], pools)

    {severity, severity_error} =
      parse_member(
        form_values["severity"],
        AlertIncident.severities(),
        :severity,
        "Severity filter is not supported"
      )

    {state, state_error} =
      parse_member(
        form_values["state"],
        AlertIncident.states(),
        :state,
        "State filter is not supported"
      )

    {rule_id, rule_error} =
      parse_known_id(
        form_values["rule_id"],
        Enum.map(rules, & &1.id),
        :rule_id,
        "Rule filter is not available"
      )

    {channel_id, channel_error} =
      parse_known_id(
        form_values["channel_id"],
        Enum.map(channels, & &1.id),
        :channel_id,
        "Channel filter is not available"
      )

    filters = %{
      pool_id: pool_id,
      severity: severity,
      state: state,
      rule_id: rule_id,
      channel_id: channel_id
    }

    form_values = %{
      "pool_id" => pool_id || "",
      "severity" => severity || "",
      "state" => state || "",
      "rule_id" => rule_id || "",
      "channel_id" => channel_id || ""
    }

    errors =
      Enum.reject([pool_error, severity_error, state_error, rule_error, channel_error], &is_nil/1)

    {filters, form_values, errors}
  end

  defp parse_pool_id(nil, _pools), do: {nil, nil}
  defp parse_pool_id("", _pools), do: {nil, nil}

  defp parse_pool_id(pool_id, pools) do
    if Enum.any?(pools, &(&1.id == pool_id)) do
      {pool_id, nil}
    else
      {nil, %{field: :pool_id, message: "Pool filter did not match an available Pool"}}
    end
  end

  defp parse_member(nil, _allowed, _field, _message), do: {nil, nil}
  defp parse_member("", _allowed, _field, _message), do: {nil, nil}

  defp parse_member(value, allowed, field, message) do
    if value in allowed do
      {value, nil}
    else
      {nil, %{field: field, message: message}}
    end
  end

  defp parse_known_id(nil, _ids, _field, _message), do: {nil, nil}
  defp parse_known_id("", _ids, _field, _message), do: {nil, nil}

  defp parse_known_id(id, ids, field, message) do
    if id in ids do
      {id, nil}
    else
      {nil, %{field: field, message: message}}
    end
  end

  defp load_incidents(_scope, _filters, [_error | _errors]), do: []

  defp load_incidents(scope, filters, []) do
    case AlertIncidentRelationships.list_incidents(scope, filters) do
      {:ok, incidents} -> incidents
      {:error, _reason} -> []
    end
  end

  defp incident_rows(scope, incidents, filters) do
    projections = AlertIncidentRelationships.incident_relationship_projections(scope, incidents)
    upstream_account_labels = upstream_account_labels(incidents)

    linked_rules_by_incident = projections.linked_rules_by_incident

    delivery_summaries =
      projections.delivery_summaries_by_incident
      |> Map.new(fn {incident_id, summary} -> {incident_id, delivery_summary(summary)} end)

    incidents
    |> Enum.filter(&incident_matches_severity?(&1, filters.severity))
    |> Enum.map(
      &incident_row(&1, linked_rules_by_incident, delivery_summaries, upstream_account_labels)
    )
    |> Enum.filter(&incident_matches_link_filters?(&1, filters))
  end

  defp incident_row(
         incident,
         linked_rules_by_incident,
         delivery_summaries,
         upstream_account_labels
       ) do
    linked_rules =
      linked_rules_by_incident
      |> Map.get(incident.id, [])
      |> linked_rule_options()

    upstream_account_label = Map.get(upstream_account_labels, incident.upstream_identity_id)

    %{
      id: incident.id,
      scope_type: incident.scope_type,
      rule_kind: incident.rule_kind,
      rule_kind_label: AlertRuleForm.rule_kind_label(incident.rule_kind),
      severity: incident.severity,
      severity_label: severity_label(incident.severity),
      state: incident.state,
      state_label: state_label(incident.state),
      reason_title: reason_title(incident),
      reason_detail: reason_detail(incident, upstream_account_label),
      upstream_account_label: upstream_account_label,
      occurrence_count: incident.occurrence_count,
      first_seen_at: incident.first_seen_at,
      last_seen_at: incident.last_seen_at,
      resolved_at: incident.resolved_at,
      impacted_pools: incident.impacted_pools,
      visible_impacted_pool_count: incident.visible_impacted_pool_count,
      hidden_impacted_pool_count: incident.hidden_impacted_pool_count,
      linked_rules: linked_rules,
      linked_channels: linked_channels(linked_rules),
      delivery_summary: Map.get(delivery_summaries, incident.id, empty_delivery_summary())
    }
  end

  defp incident_matches_severity?(_incident, nil), do: true
  defp incident_matches_severity?(incident, severity), do: incident.severity == severity

  defp incident_matches_rule?(_row, nil), do: true

  defp incident_matches_rule?(row, rule_id),
    do: Enum.any?(row.linked_rules, &(&1.value == rule_id))

  defp incident_matches_channel?(_row, nil), do: true

  defp incident_matches_channel?(row, channel_id),
    do: Enum.any?(row.linked_channels, &(&1.value == channel_id))

  defp incident_matches_link_filters?(row, filters) do
    incident_matches_rule?(row, filters.rule_id) and
      incident_matches_channel?(row, filters.channel_id)
  end

  defp delivery_summary(summary) do
    total_count = summary.total_count
    sent_count = summary.sent_count
    attention_count = summary.attention_count
    latest_status = summary.latest_status

    %{
      total_count: total_count,
      sent_count: sent_count,
      attention_count: attention_count,
      latest_status: latest_status,
      label: delivery_label(total_count, sent_count, attention_count, latest_status),
      attempts: Enum.map(summary.attempts, &delivery_attempt/1)
    }
  end

  defp linked_rule_options(rules) do
    Enum.map(rules, fn rule ->
      %{
        label: rule.label,
        value: rule.value,
        icon: "hero-bell-alert",
        channels: linked_channel_options(rule.channels)
      }
    end)
  end

  defp linked_channel_options(channels) do
    Enum.map(channels, fn channel ->
      %{label: channel.label, value: channel.value, icon: channel_icon(channel.channel_type)}
    end)
  end

  defp linked_channels(linked_rules) do
    linked_rules
    |> Enum.flat_map(& &1.channels)
    |> Enum.uniq_by(& &1.value)
  end

  defp empty_delivery_summary do
    %{
      total_count: 0,
      sent_count: 0,
      attention_count: 0,
      latest_status: nil,
      label: "No delivery attempts",
      attempts: []
    }
  end

  defp delivery_label(0, _sent_count, _attention_count, _latest_status),
    do: "No delivery attempts"

  defp delivery_label(total_count, sent_count, attention_count, latest_status) do
    [
      pluralize(total_count, "attempt", "attempts"),
      pluralize(sent_count, "sent", "sent"),
      attention_count > 0 && pluralize(attention_count, "needs attention", "needs attention"),
      latest_status && "latest #{delivery_status_label(latest_status)}"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp delivery_attempt(attempt) do
    %{
      id: attempt.id,
      channel_id: attempt.channel_id,
      channel_label: attempt.channel_label,
      status: attempt.status,
      status_label: delivery_status_label(attempt.status),
      attempt_number: attempt.attempt_number,
      max_attempts: attempt.max_attempts,
      attempted_at: attempt.attempted_at,
      completed_at: attempt.completed_at,
      response_status_code: attempt.response_status_code,
      retryable: attempt.retryable,
      failure_code: attempt.failure_code,
      failure_message: attempt.failure_message,
      details: delivery_attempt_details(attempt)
    }
  end

  defp delivery_attempt_details(attempt) do
    metadata = attempt.response_metadata || %{}
    failure_metadata = attempt.failure_metadata || %{}

    [
      detail("Adapter", metadata["delivery_adapter"]),
      detail("Channel type", metadata["channel_type"]),
      detail("Endpoint host", metadata["endpoint_host"]),
      detail("Endpoint path", metadata["endpoint_path_prefix"]),
      detail("Endpoint fingerprint", metadata["endpoint_fingerprint"]),
      detail("Recipient domain", metadata["recipient_domain"]),
      detail("Payload bytes", metadata["payload_bytes"]),
      detail("HTTP status", attempt.response_status_code || metadata["response_status_code"]),
      detail("Reason", metadata["reason_code"]),
      detail("Delivery", metadata["delivery_status"]),
      detail("Failure code", attempt.failure_code || failure_metadata["failure_code"]),
      detail("Retryable", retryable_label(attempt.retryable || failure_metadata["retryable"]))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.take(8)
  end

  defp detail(_label, nil), do: nil
  defp detail(_label, ""), do: nil

  defp detail(label, value) do
    safe_value = safe_detail_value(value)

    if safe_value == "" do
      nil
    else
      %{label: label, value: safe_value}
    end
  end

  defp safe_detail_value(value) when is_binary(value), do: safe_text(value)
  defp safe_detail_value(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_detail_value(value) when is_boolean(value), do: if(value, do: "yes", else: "no")
  defp safe_detail_value(value), do: value |> to_string() |> safe_text()

  defp safe_text(value) do
    value
    |> String.replace(~r{https?://[^\s<>"]+}i, "[redacted url]")
    |> String.replace(~r/(?i)bearer\s+[a-z0-9._~+\/=:-]+/, "Bearer [redacted]")
    |> String.replace(secret_pair_regex(), "[redacted]")
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.trim()
    |> truncate_detail_value()
  end

  defp secret_pair_regex do
    ~r/(?i)\b(authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|prompt|secret|token|dedupe[_-]?key)\b\s*[:=]\s*[^,;\s]+/
  end

  defp truncate_detail_value(value) when byte_size(value) > 180,
    do: value |> binary_part(0, 180) |> String.trim() |> Kernel.<>("...")

  defp truncate_detail_value(value), do: value

  defp retryable_label(true), do: "yes"
  defp retryable_label(false), do: nil
  defp retryable_label(_value), do: nil

  defp upstream_account_labels(incidents) do
    ids =
      incidents
      |> Enum.map(& &1.upstream_identity_id)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case ids do
      [] ->
        %{}

      [_ | _] ->
        UpstreamIdentity
        |> where([identity], identity.id in ^ids)
        |> select([identity], %{
          id: identity.id,
          account_label: identity.account_label,
          chatgpt_account_id: identity.chatgpt_account_id
        })
        |> Repo.all()
        |> Map.new(&{&1.id, upstream_account_label(&1)})
    end
  end

  defp upstream_account_label(identity) do
    safe_account_identifier(identity.account_label) ||
      safe_account_identifier(identity.chatgpt_account_id) ||
      "Upstream account"
  end

  defp safe_account_identifier(value) do
    case present_string(value) do
      nil -> nil
      label -> if account_identifier_safe?(label), do: label
    end
  end

  defp account_identifier_safe?(label) do
    cond do
      label == "[redacted]" -> false
      String.match?(label, @email_like_regex) -> false
      String.match?(label, @uuid_regex) -> false
      String.match?(label, @jwt_like_regex) -> false
      String.match?(label, @sensitive_identity_regex) -> false
      true -> true
    end
  end

  defp reason_title(%{rule_kind: "pool_no_usable_assignments"}), do: "No usable assignments"

  defp reason_title(%{rule_kind: "pool_low_usable_assignments"}),
    do: "Low usable assignment coverage"

  defp reason_title(%{rule_kind: "pool_all_assignments_in_state"}),
    do: "Assignments match an attention state"

  defp reason_title(%{rule_kind: "upstream_quota_threshold"}), do: "Quota threshold reached"
  defp reason_title(%{rule_kind: "upstream_auth_state"}), do: "Upstream auth attention needed"

  defp reason_title(%{rule_kind: "upstream_saved_reset_banked_first_seen"}),
    do: "New banked reset evidence"

  defp reason_title(_incident), do: "Alert condition matched"

  defp reason_detail(incident, upstream_account_label)

  defp reason_detail(%{rule_kind: "upstream_quota_threshold"}, _upstream_account_label) do
    "Persisted quota evidence crossed the configured threshold for at least one manageable impacted Pool."
  end

  defp reason_detail(%{rule_kind: "upstream_auth_state"}, _upstream_account_label) do
    "Persisted upstream account state matched an alert condition for at least one manageable impacted Pool."
  end

  defp reason_detail(
         %{rule_kind: "upstream_saved_reset_banked_first_seen"} = incident,
         upstream_account_label
       ) do
    label = upstream_account_label || "Upstream account"

    [
      "Persisted metadata shows new banked reset evidence on an upstream account: #{label}.",
      saved_reset_count_detail(incident.safe_evidence_snapshot || %{}),
      saved_reset_expiration_detail(incident.safe_evidence_snapshot || %{})
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp reason_detail(%{rule_kind: "pool_all_assignments_in_state"}, _upstream_account_label) do
    "Persisted assignment and quota evidence show all enabled assignments in the selected attention state."
  end

  defp reason_detail(%{rule_kind: "pool_low_usable_assignments"}, _upstream_account_label) do
    "Persisted routing evidence shows fewer usable assignments than this rule requires."
  end

  defp reason_detail(_incident, _upstream_account_label) do
    "Persisted routing evidence shows no currently usable assignment for this condition."
  end

  defp saved_reset_count_detail(%{} = evidence) do
    [
      count_fragment(evidence["new_reset_count"], "new reset", "new resets"),
      count_fragment(
        evidence["available_count"],
        "banked reset available",
        "banked resets available"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp saved_reset_count_detail(_evidence), do: nil

  defp saved_reset_expiration_detail(%{} = evidence) do
    [
      expiration_fragment(
        "next expires",
        evidence["next_reset_expires_at"] || evidence["reset_expires_at"]
      ),
      expiration_fragment("latest expires", evidence["latest_reset_expires_at"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp saved_reset_expiration_detail(_evidence), do: nil

  defp count_fragment(count, singular, plural) when is_integer(count) and count >= 0,
    do: pluralize(count, singular, plural)

  defp count_fragment(_count, _singular, _plural), do: nil

  defp expiration_fragment(label, value) when is_binary(value) do
    value = safe_detail_value(value)
    if value == "", do: nil, else: "#{label} #{value}"
  end

  defp expiration_fragment(_label, _value), do: nil

  defp severity_filter_options do
    [%{label: "Any severity", value: "", icon: "hero-adjustments-horizontal"}] ++
      Enum.map(AlertIncident.severities(), fn severity ->
        %{label: severity_label(severity), value: severity, icon: severity_icon(severity)}
      end)
  end

  defp state_filter_options do
    [%{label: "Any state", value: "", icon: "hero-adjustments-horizontal"}] ++
      Enum.map(AlertIncident.states(), fn state ->
        %{label: state_label(state), value: state, icon: state_icon(state)}
      end)
  end

  defp rule_filter_options(rules) do
    [%{label: "Any rule", value: "", icon: "hero-bell-alert"}] ++
      Enum.map(rules, fn rule ->
        %{label: rule.display_name, value: rule.id, icon: "hero-bell-alert"}
      end)
  end

  defp channel_filter_options(channels) do
    [%{label: "Any channel", value: "", icon: "hero-paper-airplane"}] ++
      Enum.map(channels, fn channel ->
        %{
          label: channel.display_name,
          value: channel.id,
          icon: channel_icon(channel.channel_type)
        }
      end)
  end

  defp channel_icon("webhook"), do: "hero-globe-alt"
  defp channel_icon(_channel_type), do: "hero-envelope"

  defp severity_icon("critical"), do: "hero-fire"
  defp severity_icon("warning"), do: "hero-exclamation-triangle"
  defp severity_icon(_severity), do: "hero-information-circle"

  defp state_icon("resolved"), do: "hero-check-circle"
  defp state_icon("acknowledged"), do: "hero-hand-raised"
  defp state_icon(_state), do: "hero-bell-alert"

  defp delivery_status_label("sent"), do: "sent"
  defp delivery_status_label("retryable"), do: "retryable"
  defp delivery_status_label("failed"), do: "failed"
  defp delivery_status_label("discarded"), do: "discarded"
  defp delivery_status_label("pending"), do: "pending"
  defp delivery_status_label(_status), do: "unknown"

  defp pluralize(1, singular, _plural), do: "1 #{singular}"
  defp pluralize(count, _singular, plural), do: "#{count} #{plural}"

  defp present_string(value) when is_binary(value) do
    value = safe_text(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp form_errors(errors), do: Enum.map(errors, &{&1.field, {&1.message, []}})

  defp string_param(params, key), do: params |> Map.get(key) |> blank_to_nil()

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
end
