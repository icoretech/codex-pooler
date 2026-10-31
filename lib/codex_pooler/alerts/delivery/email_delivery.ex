defmodule CodexPooler.Alerts.Delivery.EmailDelivery do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPooler.Accounting

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident
  }

  alias CodexPooler.Alerts.Delivery.{AttemptLifecycle, Execution}
  alias CodexPooler.Alerts.StatusVocabulary.AssignmentState
  alias CodexPooler.Mailer
  alias CodexPooler.Mailer.Config, as: MailerConfig
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass
  alias CodexPooler.SupportedLocales

  @delivery_adapter "email"
  @retry_delays_seconds %{1 => 60, 2 => 300, 3 => 900, 4 => 1800}
  @retryable_failure_codes ~w(
    smtp_test_email_timeout
    smtp_test_email_connection_failed
    smtp_test_email_tls_failed
    smtp_test_email_temporary_failure
  )
  @circuit_blocked_reasons ~w(open_cooldown open_no_probe probe_saturated)
  # reset_expires_at / reset_first_seen_at are the evidence v1 names; the
  # current evaluator emits the *_reset_* v2 keys, but stored incidents can
  # still carry v1 evidence on redelivery, so both generations stay listed.
  @safe_summary_keys ~w(
    assignment_count
    available_count
    circuit_blocked_assignment_count
    circuit_blocked_lane_count
    circuit_blocked_reasons
    circuit_blocked_route_classes
    circuit_recency_seconds
    earliest_reset_first_seen_at
    enabled_assignment_count
    impacted_pool_count
    latest_reset_expires_at
    latest_reset_first_seen_at
    model
    model_membership_resolved
    new_reset_count
    next_reset_expires_at
    non_serving_assignment_count
    path_style
    quota_state
    reason_code
    reset_expires_at
    reset_first_seen_at
    route_class_scope
    routing_usable
    source
    state_counts
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

  @type delivery_error ::
          :invalid_alert_delivery_args
          | :alert_incident_not_found
          | :alert_channel_not_found
          | :unsupported_alert_channel
          | :channel_disabled
          | :mailer_unconfigured
          | :cooldown_suppressed
          | Ecto.Changeset.t()
          | %{required(:code) => String.t(), optional(:retryable) => boolean()}

  @type delivery_result :: {:ok, AlertDeliveryAttempt.t()} | {:error, delivery_error()}

  @spec deliver_incident_to_channel(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), keyword()) ::
          delivery_result()
  def deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts \\ [])

  def deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts)
      when is_binary(incident_id) and is_binary(channel_id) and is_integer(attempt_number) do
    execution = Keyword.get_lazy(opts, :delivery_execution, &Execution.new/0)

    case Execution.storage(execution, fn -> prepare_delivery(incident_id, channel_id, attempt_number, opts, execution) end) do
      {:ok, attempt, incident, channel} ->
        result = Execution.run(execution, fn -> deliver_email(incident, channel, execution) end)

        Execution.storage(execution, fn ->
          record_delivery_result(result, attempt, incident, channel, {timestamp(opts), Keyword.get(opts, :retry_attempt, attempt_number)})
        end)

      result ->
        result
    end
  end

  def deliver_incident_to_channel(_incident_id, _channel_id, _attempt_number, _opts),
    do: {:error, :invalid_alert_delivery_args}

  defp prepare_delivery(incident_id, channel_id, attempt_number, opts, execution) do
    timestamp = timestamp(opts)

    with {:ok, incident} <- fetch_incident(incident_id),
         {:ok, channel} <- fetch_channel(channel_id),
         :ok <- validate_email_channel(channel),
         :ok <- AttemptLifecycle.ensure_not_suppressed(incident, channel, timestamp, @delivery_adapter),
         :ok <- ensure_mailer_configured(),
         {:ok, attempt} <- AttemptLifecycle.insert_pending_attempt(incident, channel, attempt_number, timestamp, base_metadata(incident, channel), execution) do
      {:ok, attempt, incident, channel}
    else
      {:discard, code, message} ->
        AttemptLifecycle.record_discarded_attempt(incident_id, channel_id, attempt_number, timestamp, @delivery_adapter, code, message)

      {:failure, code, message} ->
        AttemptLifecycle.record_failed_attempt(incident_id, channel_id, attempt_number, timestamp, @delivery_adapter, code, message)

      {:error, _} = error ->
        error
    end
  rescue
    error ->
      AttemptLifecycle.record_failed_attempt(incident_id, channel_id, attempt_number, timestamp(opts), @delivery_adapter, "alert_email_delivery_exception", exception_message(error))
  end

  defp deliver_email(incident, channel, execution) do
    # gen_smtp's timeout bounds connect only; Execution owns the whole SMTP exchange.
    incident
    |> alert_email(channel)
    |> Mailer.deliver(timeout: max(Execution.remaining(execution), 1))
  rescue
    error -> {:delivery_exception, exception_message(error)}
  end

  @spec alert_email(AlertIncident.t(), AlertChannel.t()) :: Swoosh.Email.t()
  def alert_email(%AlertIncident{} = incident, %AlertChannel{channel_type: "email"} = channel) do
    Gettext.with_locale(SupportedLocales.gettext_locale(channel.locale), fn ->
      Swoosh.Email.new()
      |> Swoosh.Email.from(Mailer.default_sender())
      |> Swoosh.Email.to(channel.email_to)
      |> Swoosh.Email.subject(alert_subject(incident))
      |> Swoosh.Email.text_body(text_body(incident, channel))
    end)
  end

  @spec retry_delay_seconds(pos_integer()) :: non_neg_integer()
  def retry_delay_seconds(attempt_number), do: Map.get(@retry_delays_seconds, attempt_number, 0)

  defp fetch_incident(incident_id) do
    case Repo.get(AlertIncident, incident_id) do
      %AlertIncident{} = incident -> {:ok, incident}
      nil -> {:failure, "alert_incident_not_found", "alert incident was not found"}
    end
  end

  defp fetch_channel(channel_id) do
    case Repo.get(AlertChannel, channel_id) do
      %AlertChannel{} = channel -> {:ok, channel}
      nil -> {:failure, "alert_channel_not_found", "alert channel was not found"}
    end
  end

  defp validate_email_channel(%AlertChannel{
         channel_type: "email",
         state: "active",
         email_to: email_to
       })
       when is_binary(email_to) and email_to != "",
       do: :ok

  defp validate_email_channel(%AlertChannel{channel_type: "email", state: "disabled"}),
    do: {:discard, "alert_channel_disabled", "alert channel is disabled"}

  defp validate_email_channel(%AlertChannel{channel_type: "email"}),
    do: {:failure, "alert_channel_missing_recipient", "alert email recipient is unavailable"}

  defp validate_email_channel(%AlertChannel{}),
    do: {:discard, "alert_channel_type_unsupported", "alert channel is not an email channel"}

  defp ensure_mailer_configured do
    if Mailer.configured?(),
      do: :ok,
      else: {:failure, "alert_email_mailer_unconfigured", "email delivery is not configured"}
  end

  defp record_delivery_result({:ok, _receipt}, attempt, incident, channel, {timestamp, _retry_attempt}) do
    AttemptLifecycle.mark_sent_attempt(attempt, timestamp, success_metadata(incident, channel))
  end

  defp record_delivery_result({:error, :delivery_timeout}, attempt, incident, channel, {timestamp, retry_attempt}) do
    retryable = retry_attempt < AlertDeliveryAttempt.fixed_max_attempts()

    AttemptLifecycle.finalize_failed_attempt(attempt, timestamp, @delivery_adapter, "alert_email_delivery_timeout", "email delivery deadline exceeded; delivery outcome unknown",
      retryable: retryable,
      next_retry_at: next_retry_at(timestamp, retry_attempt, retryable),
      response_metadata: Map.put(base_metadata(incident, channel), "delivery_outcome", "unknown")
    )
  end

  defp record_delivery_result({:delivery_exception, message}, attempt, _incident, _channel, {timestamp, _retry_attempt}) do
    AttemptLifecycle.finalize_failed_attempt(attempt, timestamp, @delivery_adapter, "alert_email_delivery_exception", message)
  end

  defp record_delivery_result({:error, reason}, attempt, incident, channel, {timestamp, retry_attempt}) do
    sanitized = MailerConfig.sanitize_delivery_error(reason)
    code = sanitized.code |> Atom.to_string()
    retryable = retryable_failure_code?(code) and retry_attempt < AlertDeliveryAttempt.fixed_max_attempts()

    AttemptLifecycle.finalize_failed_attempt(attempt, timestamp, @delivery_adapter, code, sanitized.message,
      next_retry_at: next_retry_at(timestamp, retry_attempt, retryable),
      retryable: retryable,
      response_metadata: base_metadata(incident, channel)
    )
  end

  defp success_metadata(%AlertIncident{} = incident, %AlertChannel{} = channel) do
    incident
    |> base_metadata(channel)
    |> Map.put("delivery_status", "sent")
  end

  defp base_metadata(%AlertIncident{} = incident, %AlertChannel{} = channel) do
    %{}
    |> Map.put("delivery_adapter", @delivery_adapter)
    |> Map.put("incident_id", incident.id)
    |> Map.put("channel_id", channel.id)
    |> Map.put("channel_type", channel.channel_type)
    |> Map.put("recipient_domain", recipient_domain(channel.email_to))
    |> Map.merge(incident_metadata(incident))
    |> safe_metadata()
  end

  defp incident_metadata(%AlertIncident{} = incident) do
    %{}
    |> Map.put("scope_type", incident.scope_type)
    |> Map.put("rule_kind", incident.rule_kind)
    |> Map.put("severity", incident.severity)
    |> Map.put("state", incident.state)
    |> Map.put("pool_id", incident.pool_id)
    |> Map.put("upstream_identity_id", incident.upstream_identity_id)
    |> Map.put("occurrence_count", incident.occurrence_count)
    |> Map.put("reason_code", reason_code(incident.safe_evidence_snapshot))
    |> Map.put("first_seen_at", iso8601_or_nil(incident.first_seen_at))
    |> Map.put("last_seen_at", iso8601_or_nil(incident.last_seen_at))
    |> Map.put("safe_evidence_summary", safe_evidence_summary(incident.safe_evidence_snapshot))
    |> compact_map()
  end

  defp alert_subject(%AlertIncident{} = incident) do
    [dgettext("emails", "Codex Pooler alert"), incident.severity, incident.rule_kind]
    |> Enum.reject(&blank?/1)
    |> Enum.join(": ")
  end

  defp text_body(%AlertIncident{} = incident, %AlertChannel{} = channel) do
    metadata = incident_metadata(incident)
    summary = Map.get(metadata, "safe_evidence_summary", %{})

    [
      dgettext("emails", "Codex Pooler alert notification"),
      "",
      dgettext("emails", "Incident id: %{id}", id: incident.id),
      dgettext("emails", "Channel id: %{id}", id: channel.id),
      dgettext("emails", "Scope type: %{scope}", scope: incident.scope_type),
      dgettext("emails", "Rule kind: %{kind}", kind: incident.rule_kind),
      dgettext("emails", "Severity: %{severity}", severity: incident.severity),
      dgettext("emails", "Incident state: %{state}", state: incident.state),
      optional_line(:pool_id, incident.pool_id),
      optional_line(:upstream_identity_id, incident.upstream_identity_id),
      optional_line(:reason_code, Map.get(metadata, "reason_code")),
      dngettext("emails", "Occurrence count: %{count}", "Occurrence count: %{count}", incident.occurrence_count, count: incident.occurrence_count),
      dgettext("emails", "First seen at: %{time}", time: DateTime.to_iso8601(incident.first_seen_at)),
      dgettext("emails", "Last seen at: %{time}", time: DateTime.to_iso8601(incident.last_seen_at)),
      "",
      dgettext("emails", "Safe evidence summary:"),
      summary_lines(summary),
      "",
      dgettext("emails", "This alert contains metadata only. Runtime content and credentials are never included.")
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp summary_lines(summary) when map_size(summary) == 0, do: [dgettext("emails", "- none")]

  defp summary_lines(summary) do
    summary
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "- #{key}: #{value}" end)
  end

  defp safe_evidence_summary(%{} = evidence) do
    evidence
    |> safe_metadata()
    |> Map.take(@safe_summary_keys)
    |> Map.new(fn {key, value} -> {key, safe_summary_value(key, value, evidence)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_evidence_summary(_evidence), do: %{}

  defp safe_summary_value("circuit_blocked_route_classes", _value, evidence) do
    bounded_safe_list(
      evidence,
      "circuit_blocked_route_classes",
      :circuit_blocked_route_classes,
      RouteClass.all()
    )
  end

  # Per-assignment state counts from the evaluation, bounded to the alert
  # state vocabulary, so an incident caused by, for example, an unserved model
  # says so instead of only `model_membership_resolved=false`.
  defp safe_summary_value("state_counts", _value, evidence),
    do: AssignmentState.describe(Map.get(evidence, "state_counts") || Map.get(evidence, :state_counts))

  defp safe_summary_value("circuit_blocked_reasons", _value, evidence) do
    bounded_safe_list(
      evidence,
      "circuit_blocked_reasons",
      :circuit_blocked_reasons,
      @circuit_blocked_reasons
    )
  end

  defp safe_summary_value(_key, value, _evidence)
       when is_integer(value) or is_float(value) or is_boolean(value),
       do: value

  defp safe_summary_value(_key, %Decimal{} = value, _evidence),
    do: Decimal.to_string(value, :normal)

  defp safe_summary_value(_key, value, _evidence) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.length(value) > 120 -> nil
      unsafe_text?(value) -> nil
      true -> value
    end
  end

  defp safe_summary_value(_key, _value, _evidence), do: nil

  defp reason_code(%{} = evidence) do
    case safe_summary_value(
           "reason_code",
           Map.get(evidence, "reason_code") || Map.get(evidence, :reason_code),
           evidence
         ) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp reason_code(_evidence), do: nil

  defp safe_metadata(metadata), do: Accounting.sanitize_metadata(metadata)

  defp bounded_safe_list(evidence, string_key, atom_key, vocabulary) do
    values = Map.get(evidence, string_key) || Map.get(evidence, atom_key)

    values =
      case values do
        values when is_list(values) ->
          values
          |> Enum.filter(&(&1 in vocabulary))
          |> Enum.uniq()
          |> Enum.sort()

        _value ->
          []
      end

    if values == [], do: nil, else: values
  end

  defp optional_line(_label, nil), do: nil
  defp optional_line(:pool_id, value), do: dgettext("emails", "Pool id: %{id}", id: value)
  defp optional_line(:upstream_identity_id, value), do: dgettext("emails", "Upstream identity id: %{id}", id: value)
  defp optional_line(:reason_code, value), do: dgettext("emails", "Reason code: %{code}", code: value)

  defp recipient_domain(email_to) when is_binary(email_to) do
    case String.split(email_to, "@", parts: 2) do
      [_local, domain] -> String.downcase(domain)
      _parts -> nil
    end
  end

  defp recipient_domain(_email_to), do: nil

  defp retryable_failure_code?(code), do: code in @retryable_failure_codes

  defp next_retry_at(_timestamp, _attempt_number, false), do: nil

  defp next_retry_at(timestamp, attempt_number, true) do
    DateTime.add(timestamp, retry_delay_seconds(attempt_number), :second)
  end

  defp timestamp(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = timestamp -> DateTime.truncate(timestamp, :microsecond)
      _value -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp iso8601_or_nil(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp iso8601_or_nil(_timestamp), do: nil

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp unsafe_text?(value) do
    normalized = String.downcase(value)
    Enum.any?(@forbidden_text_fragments, &String.contains?(normalized, &1))
  end

  defp exception_message(%{__struct__: struct}) do
    "#{inspect(struct)} raised during alert email delivery"
  end
end
