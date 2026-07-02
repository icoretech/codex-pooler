defmodule CodexPooler.Alerts.WebhookPayload do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Alerts.Schemas.{AlertChannel, AlertDeliveryAttempt, AlertIncident}

  @safe_summary_keys ~w(
    assignment_count
    available_count
    enabled_assignment_count
    impacted_pool_count
    model
    path_style
    quota_state
    reason_code
    reset_expires_at
    reset_first_seen_at
    routing_usable
    source
    status
    target_state
    threshold_used_percent
    usable_assignment_count
    used_percent
    window_selector
  )

  @forbidden_text_fragments ~w(
    access_token
    auth_json
    authorization
    bearer
    body
    cookie
    file
    header
    idempotency_key
    payload
    prompt
    provider_payload
    refresh_token
    request_body
    response_body
    secret
    token
    webhook
    websocket
  )

  @type payload :: map()
  @type encoded_payload :: %{required(:event_id) => String.t(), required(:body) => binary()}

  @spec payload(AlertIncident.t(), AlertChannel.t(), AlertDeliveryAttempt.t()) :: payload()
  def payload(
        %AlertIncident{} = incident,
        %AlertChannel{} = channel,
        %AlertDeliveryAttempt{} = attempt
      ) do
    event_id = event_id(incident, channel, attempt)
    evidence = safe_metadata(incident.safe_evidence_snapshot)

    %{
      "event_id" => event_id,
      "attempt_id" => attempt.id,
      "incident_id" => incident.id,
      "channel_id" => channel.id,
      "dedupe_key" => incident.dedupe_key,
      "severity" => incident.severity,
      "rule_kind" => incident.rule_kind,
      "reason_code" => reason_code(evidence),
      "scope_metadata" => scope_metadata(incident),
      "safe_evidence_summary" => safe_evidence_summary(evidence),
      "occurrence_count" => incident.occurrence_count,
      "first_seen_at" => iso8601_or_nil(incident.first_seen_at),
      "last_seen_at" => iso8601_or_nil(incident.last_seen_at)
    }
    |> compact_map()
  end

  @spec encode(AlertIncident.t(), AlertChannel.t(), AlertDeliveryAttempt.t()) :: encoded_payload()
  def encode(
        %AlertIncident{} = incident,
        %AlertChannel{} = channel,
        %AlertDeliveryAttempt{} = attempt
      ) do
    payload = payload(incident, channel, attempt)

    %{
      event_id: Map.fetch!(payload, "event_id"),
      body: payload |> canonical_json_value() |> Jason.encode!()
    }
  end

  @spec event_id(AlertIncident.t(), AlertChannel.t(), AlertDeliveryAttempt.t()) :: String.t()
  def event_id(
        %AlertIncident{} = incident,
        %AlertChannel{} = channel,
        %AlertDeliveryAttempt{} = attempt
      ) do
    "alert.#{incident.id}.#{channel.id}.#{attempt.attempt_number}"
  end

  @spec safe_evidence_summary(map()) :: map()
  def safe_evidence_summary(%{} = evidence) do
    evidence
    |> safe_metadata()
    |> Map.take(@safe_summary_keys)
    |> Map.new(fn {key, value} -> {key, safe_summary_value(value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def safe_evidence_summary(_evidence), do: %{}

  defp safe_metadata(metadata) do
    metadata
    |> normalize_decimal_values()
    |> Kernel.||(%{})
    |> Accounting.sanitize_metadata()
  end

  defp normalize_decimal_values(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp normalize_decimal_values(%{} = value) do
    Map.new(value, fn {key, item} -> {key, normalize_decimal_values(item)} end)
  end

  defp normalize_decimal_values(values) when is_list(values),
    do: Enum.map(values, &normalize_decimal_values/1)

  defp normalize_decimal_values(value), do: value

  defp scope_metadata(%AlertIncident{} = incident) do
    %{}
    |> Map.put("scope_type", incident.scope_type)
    |> Map.put("pool_id", incident.pool_id)
    |> Map.put("upstream_identity_id", incident.upstream_identity_id)
    |> compact_map()
  end

  defp reason_code(%{} = evidence) do
    case safe_summary_value(Map.get(evidence, "reason_code") || Map.get(evidence, :reason_code)) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp safe_summary_value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: value

  defp safe_summary_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp safe_summary_value(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.length(value) > 120 -> nil
      unsafe_text?(value) -> nil
      true -> value
    end
  end

  defp safe_summary_value(_value), do: nil

  defp canonical_json_value(%{} = value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical_json_value(item)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_json_value(values) when is_list(values),
    do: Enum.map(values, &canonical_json_value/1)

  defp canonical_json_value(value), do: value

  defp iso8601_or_nil(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp iso8601_or_nil(_timestamp), do: nil

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
    |> Map.new()
  end

  defp unsafe_text?(value) do
    normalized = String.downcase(value)
    Enum.any?(@forbidden_text_fragments, &String.contains?(normalized, &1))
  end
end
