defmodule CodexPooler.Alerts.AuditLog do
  @moduledoc false

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertIncident,
    AlertRule
  }

  @rule_update_fields ~w(pool_id scope_type rule_kind display_name severity cooldown_minutes state model min_usable_assignments target_state window_selector threshold_used_percent metadata channel_ids)
  @channel_update_fields ~w(channel_type display_name state email_to endpoint_url delivery_endpoint_url endpoint_scheme endpoint_host endpoint_path_prefix endpoint_fingerprint metadata webhook_signing_secret_action)

  @type mutation_result :: {:ok, term()} | {:error, term()} | term()

  @spec audit_rule_create(mutation_result(), Scope.t()) :: mutation_result()
  def audit_rule_create(result, %Scope{} = scope) do
    audit_rule_change(result, scope, "alert_rule.create")
  end

  @spec audit_rule_update(mutation_result(), Scope.t(), AlertRule.t(), map()) :: mutation_result()
  def audit_rule_update(result, %Scope{} = scope, %AlertRule{} = previous_rule, attrs)
      when is_map(attrs) do
    tap(result, fn
      {:ok, %AlertRule{} = rule} ->
        extra_details = %{changed_fields: changed_fields(attrs, @rule_update_fields)}

        record_rule_change(
          scope,
          rule,
          rule_update_action(rule, previous_rule),
          previous_rule,
          extra_details
        )

      _result ->
        :ok
    end)
  end

  @spec audit_rule_delete(mutation_result(), Scope.t()) :: mutation_result()
  def audit_rule_delete(result, %Scope{} = scope) do
    audit_rule_change(result, scope, "alert_rule.delete")
  end

  @spec audit_channel_create(mutation_result(), Scope.t()) :: mutation_result()
  def audit_channel_create(result, %Scope{} = scope) do
    audit_channel_change(result, scope, "alert_channel.create")
  end

  @spec audit_channel_update(mutation_result(), Scope.t(), AlertChannel.t(), map()) ::
          mutation_result()
  def audit_channel_update(result, %Scope{} = scope, %AlertChannel{} = previous_channel, attrs)
      when is_map(attrs) do
    tap(result, fn
      {:ok, %AlertChannel{} = channel} ->
        extra_details = %{changed_fields: changed_fields(attrs, @channel_update_fields)}

        record_channel_change(
          scope,
          channel,
          channel_update_action(channel, previous_channel),
          previous_channel,
          extra_details
        )

      _result ->
        :ok
    end)
  end

  @spec audit_channel_delete(mutation_result(), Scope.t()) :: mutation_result()
  def audit_channel_delete(result, %Scope{} = scope) do
    audit_channel_change(result, scope, "alert_channel.delete")
  end

  @spec audit_incident_transition(mutation_result(), Scope.t(), AlertIncident.t(), atom()) ::
          mutation_result()
  def audit_incident_transition(
        result,
        %Scope{} = scope,
        %AlertIncident{} = previous_incident,
        action
      ) do
    audit_incident_change(result, scope, incident_action(action), previous_incident)
  end

  def audit_incident_transition(result, _scope, _previous_incident, _action), do: result

  defp audit_rule_change(result, scope, action, previous_rule \\ nil, extra_details \\ %{}) do
    tap(result, fn
      {:ok, %AlertRule{} = rule} ->
        record_rule_change(scope, rule, action, previous_rule, extra_details)

      _result ->
        :ok
    end)
  end

  defp audit_channel_change(result, scope, action, previous_channel \\ nil, extra_details \\ %{}) do
    tap(result, fn
      {:ok, %AlertChannel{} = channel} ->
        record_channel_change(scope, channel, action, previous_channel, extra_details)

      _result ->
        :ok
    end)
  end

  defp audit_incident_change(result, scope, action, previous_incident) do
    tap(result, fn
      {:ok, incident} when is_map(incident) ->
        record_user_event(scope, %{
          pool_id: incident_pool_id(incident),
          action: action,
          target_type: "alert_incident",
          target_id: field(incident, :id),
          details:
            incident
            |> incident_details()
            |> maybe_put_previous_state(previous_incident)
        })

      _result ->
        :ok
    end)
  end

  defp record_user_event(%Scope{user: %User{} = user}, attrs),
    do: Audit.record_user_event(user, attrs)

  defp record_user_event(_scope, _attrs), do: :ok

  defp record_rule_change(scope, %AlertRule{} = rule, action, previous_rule, extra_details) do
    record_user_event(scope, %{
      pool_id: rule.pool_id,
      action: action,
      target_type: "alert_rule",
      target_id: rule.id,
      details:
        rule
        |> rule_details()
        |> maybe_put_previous_state(previous_rule)
        |> Map.merge(extra_details)
    })
  end

  defp record_channel_change(
         scope,
         %AlertChannel{} = channel,
         action,
         previous_channel,
         extra_details
       ) do
    record_user_event(scope, %{
      action: action,
      target_type: "alert_channel",
      target_id: channel.id,
      details:
        channel
        |> channel_details()
        |> maybe_put_previous_state(previous_channel)
        |> Map.merge(extra_details)
    })
  end

  defp rule_update_action(%AlertRule{state: state}, %AlertRule{state: previous_state})
       when state != previous_state do
    state_action("alert_rule", state)
  end

  defp rule_update_action(_rule, _previous_rule), do: "alert_rule.update"

  defp channel_update_action(%AlertChannel{} = channel, %AlertChannel{state: previous_state}) do
    case channel.state do
      state when state != previous_state -> state_action("alert_channel", state)
      _state -> "alert_channel.update"
    end
  end

  defp state_action(prefix, "active"), do: prefix <> ".enable"
  defp state_action(prefix, "disabled"), do: prefix <> ".disable"
  defp state_action(prefix, _state), do: prefix <> ".update"

  defp incident_action(:acknowledge), do: "alert_incident.acknowledge"
  defp incident_action(:resolve), do: "alert_incident.resolve"
  defp incident_action(action), do: "alert_incident." <> to_string(action)

  defp rule_details(%AlertRule{} = rule) do
    %{
      alert_rule_id: rule.id,
      pool_id: rule.pool_id,
      scope_type: rule.scope_type,
      rule_kind: rule.rule_kind,
      display_name: rule.display_name,
      severity: rule.severity,
      state: rule.state,
      cooldown_minutes: rule.cooldown_minutes,
      model: rule.model,
      target_state: rule.target_state,
      window_selector: rule.window_selector,
      min_usable_assignments: rule.min_usable_assignments,
      threshold_used_percent: decimal_string(rule.threshold_used_percent)
    }
  end

  defp channel_details(channel) do
    %{
      alert_channel_id: field(channel, :id),
      channel_type: field(channel, :channel_type),
      display_name: field(channel, :display_name),
      state: field(channel, :state),
      email_domain: email_domain(field(channel, :email_to)),
      endpoint_scheme: field(channel, :endpoint_scheme),
      endpoint_host: field(channel, :endpoint_host),
      endpoint_path_prefix: field(channel, :endpoint_path_prefix),
      endpoint_fingerprint: field(channel, :endpoint_fingerprint),
      webhook_signing_secret_configured:
        configured?(field(channel, :webhook_signing_secret_key_version))
    }
  end

  defp incident_details(incident) do
    %{
      alert_incident_id: field(incident, :id),
      dedupe_key_fingerprint: fingerprint(field(incident, :dedupe_key)),
      scope_type: field(incident, :scope_type),
      rule_kind: field(incident, :rule_kind),
      severity: field(incident, :severity),
      state: field(incident, :state),
      pool_id: field(incident, :pool_id),
      upstream_identity_id: field(incident, :upstream_identity_id),
      occurrence_count: field(incident, :occurrence_count),
      visible_impacted_pool_count: field(incident, :visible_impacted_pool_count),
      hidden_impacted_pool_count: field(incident, :hidden_impacted_pool_count),
      total_impacted_pool_count: field(incident, :total_impacted_pool_count)
    }
  end

  defp maybe_put_previous_state(details, %{state: previous_state}) when is_binary(previous_state),
    do: Map.put(details, :previous_state, previous_state)

  defp maybe_put_previous_state(details, _previous), do: details

  defp incident_pool_id(%{} = incident) do
    case field(incident, :pool_id) do
      pool_id when is_binary(pool_id) -> pool_id
      _nil -> first_impacted_pool_id(field(incident, :impacted_pools))
    end
  end

  defp first_impacted_pool_id([%{} = pool | _rest]), do: field(pool, :id)
  defp first_impacted_pool_id(_pools), do: nil

  defp changed_fields(attrs, allowed_fields) when is_map(attrs) do
    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in allowed_fields))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp field(%{} = resource, key),
    do: Map.get(resource, key) || Map.get(resource, to_string(key))

  defp email_domain(value) when is_binary(value) do
    case String.split(value, "@", parts: 2) do
      [_local, domain] -> domain
      _other -> nil
    end
  end

  defp email_domain(_value), do: nil

  defp configured?(value) when is_binary(value), do: String.trim(value) != ""
  defp configured?(_value), do: false

  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(value), do: value

  defp fingerprint(value) when is_binary(value) and value != "" do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp fingerprint(_value), do: nil
end
