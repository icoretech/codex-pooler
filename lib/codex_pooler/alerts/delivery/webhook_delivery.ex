defmodule CodexPooler.Alerts.Delivery.WebhookDelivery do
  @moduledoc false

  alias CodexPooler.Accounting

  alias CodexPooler.Alerts.Schemas.{
    AlertChannel,
    AlertDeliveryAttempt,
    AlertIncident
  }

  alias CodexPooler.Alerts.Delivery.{AttemptLifecycle, WebhookPayload, WebhookSigning}
  alias CodexPooler.InstanceSettings.AppSecretCrypto
  alias CodexPooler.Repo
  alias CodexPooler.TransportFailureReason

  @delivery_adapter "webhook"
  @retry_delays_seconds %{1 => 60, 2 => 300, 3 => 900, 4 => 1800}
  @receive_timeout_ms :timer.seconds(10)
  @retryable_statuses [408, 409, 425, 429]
  @permanent_statuses [400, 401, 403, 404, 410, 422]

  @type delivery_error ::
          :invalid_alert_delivery_args
          | Ecto.Changeset.t()
          | %{required(:code) => String.t(), optional(:retryable) => boolean()}

  @type delivery_result :: {:ok, AlertDeliveryAttempt.t()} | {:error, delivery_error()}

  @spec deliver_incident_to_channel(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), keyword()) ::
          delivery_result()
  def deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts \\ [])

  def deliver_incident_to_channel(incident_id, channel_id, attempt_number, opts)
      when is_binary(incident_id) and is_binary(channel_id) and is_integer(attempt_number) do
    timestamp = timestamp(opts)

    with {:ok, incident} <- fetch_incident(incident_id),
         {:ok, channel} <- fetch_channel(channel_id),
         :ok <- validate_webhook_channel(channel),
         :ok <-
           AttemptLifecycle.ensure_not_suppressed(incident, channel, timestamp, @delivery_adapter),
         {:ok, endpoint_url} <- recover_endpoint_url(channel),
         {:ok, pending_attempt} <-
           AttemptLifecycle.insert_pending_attempt(
             incident,
             channel,
             attempt_number,
             timestamp,
             base_metadata(incident, channel)
           ) do
      deliver_after_pending_attempt(
        pending_attempt,
        incident,
        channel,
        endpoint_url,
        timestamp
      )
    else
      {:discard, code, message} ->
        AttemptLifecycle.record_discarded_attempt(
          incident_id,
          channel_id,
          attempt_number,
          timestamp,
          @delivery_adapter,
          code,
          message
        )

      {:failure, code, message} ->
        AttemptLifecycle.record_failed_attempt(
          incident_id,
          channel_id,
          attempt_number,
          timestamp,
          @delivery_adapter,
          code,
          message
        )

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  rescue
    error ->
      AttemptLifecycle.record_failed_attempt(
        incident_id,
        channel_id,
        attempt_number,
        timestamp(opts),
        @delivery_adapter,
        "alert_webhook_delivery_exception",
        exception_message(error)
      )
  end

  def deliver_incident_to_channel(_incident_id, _channel_id, _attempt_number, _opts),
    do: {:error, :invalid_alert_delivery_args}

  @spec retry_delay_seconds(pos_integer()) :: non_neg_integer()
  def retry_delay_seconds(attempt_number), do: Map.get(@retry_delays_seconds, attempt_number, 0)

  defp deliver_after_pending_attempt(attempt, incident, channel, endpoint_url, timestamp) do
    case recover_signing_secret(channel) do
      {:ok, signing_secret} ->
        deliver_pending_attempt(
          attempt,
          incident,
          channel,
          endpoint_url,
          signing_secret,
          timestamp
        )

      {:failure, code, message} ->
        AttemptLifecycle.finalize_failed_attempt(
          attempt,
          timestamp,
          @delivery_adapter,
          code,
          message,
          retryable: false
        )
    end
  rescue
    error ->
      AttemptLifecycle.finalize_failed_attempt(
        attempt,
        timestamp,
        @delivery_adapter,
        "alert_webhook_delivery_exception",
        exception_message(error),
        retryable: false
      )
  end

  defp deliver_pending_attempt(
         attempt,
         incident,
         channel,
         endpoint_url,
         signing_secret,
         timestamp
       ) do
    %{event_id: event_id, body: body} = WebhookPayload.encode(incident, channel, attempt)
    attempt_id = attempt.id
    signature = WebhookSigning.sign(event_id, attempt_id, body, signing_secret)

    headers = [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"x-codex-pooler-event-id", event_id},
      {"x-codex-pooler-attempt-id", attempt_id},
      {"x-codex-pooler-signature", signature}
    ]

    endpoint_url
    |> post_webhook(body, headers)
    |> record_delivery_result(attempt, incident, channel, event_id, byte_size(body), timestamp)
  end

  defp post_webhook(url, body, headers) do
    Req.post(url,
      body: body,
      headers: headers,
      decode_body: false,
      receive_timeout: @receive_timeout_ms,
      retry: false
    )
  rescue
    exception in [
      Req.TransportError,
      Req.HTTPError,
      Finch.TransportError,
      Finch.HTTPError,
      Mint.TransportError,
      Mint.HTTPError
    ] ->
      {:error, exception}
  end

  defp record_delivery_result(
         {:ok, %Req.Response{status: status}},
         attempt,
         incident,
         channel,
         event_id,
         body_bytes,
         timestamp
       )
       when status in 200..299 do
    AttemptLifecycle.mark_sent_attempt(
      attempt,
      timestamp,
      success_metadata(incident, channel, event_id, body_bytes, status),
      status
    )
  end

  defp record_delivery_result(
         {:ok, %Req.Response{status: status}},
         attempt,
         incident,
         channel,
         event_id,
         body_bytes,
         timestamp
       ) do
    retryable =
      retryable_http_status?(status) and
        attempt.attempt_number < AlertDeliveryAttempt.fixed_max_attempts()

    code = "alert_webhook_http_#{status}"
    message = http_failure_message(status)

    AttemptLifecycle.finalize_failed_attempt(
      attempt,
      timestamp,
      @delivery_adapter,
      code,
      message,
      retryable: retryable,
      response_status_code: status,
      next_retry_at: next_retry_at(timestamp, attempt.attempt_number, retryable),
      response_metadata: response_metadata(incident, channel, event_id, body_bytes, status)
    )
  end

  defp record_delivery_result(
         {:error, reason},
         attempt,
         incident,
         channel,
         event_id,
         body_bytes,
         timestamp
       ) do
    retryable = attempt.attempt_number < AlertDeliveryAttempt.fixed_max_attempts()
    reason_code = TransportFailureReason.safe_reason(reason)
    code = transport_failure_code(reason_code)
    message = "webhook delivery transport failed"

    metadata =
      incident
      |> response_metadata(channel, event_id, body_bytes, nil)
      |> maybe_put("transport_reason", reason_code)
      |> maybe_put("transport_exception", TransportFailureReason.safe_exception(reason))

    AttemptLifecycle.finalize_failed_attempt(
      attempt,
      timestamp,
      @delivery_adapter,
      code,
      message,
      retryable: retryable,
      next_retry_at: next_retry_at(timestamp, attempt.attempt_number, retryable),
      response_metadata: metadata
    )
  end

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

  defp validate_webhook_channel(%AlertChannel{channel_type: "webhook", state: "disabled"}),
    do: {:discard, "alert_channel_disabled", "alert channel is disabled"}

  defp validate_webhook_channel(%AlertChannel{channel_type: "webhook", state: "active"}), do: :ok

  defp validate_webhook_channel(%AlertChannel{channel_type: "webhook"}),
    do: {:failure, "alert_webhook_channel_invalid", "alert webhook channel is invalid"}

  defp validate_webhook_channel(%AlertChannel{}),
    do: {:discard, "alert_channel_type_unsupported", "alert channel is not a webhook channel"}

  defp recover_endpoint_url(%AlertChannel{
         endpoint_url_ciphertext: ciphertext,
         endpoint_url_nonce: nonce,
         endpoint_url_aad: aad
       })
       when is_binary(ciphertext) and is_binary(nonce) and is_map(aad) do
    case AppSecretCrypto.decrypt(ciphertext, nonce, aad) do
      {:ok, endpoint_url} when is_binary(endpoint_url) -> validate_endpoint_url(endpoint_url)
      {:error, _reason} -> endpoint_unavailable()
    end
  end

  defp recover_endpoint_url(%AlertChannel{}), do: endpoint_unavailable()

  defp validate_endpoint_url(endpoint_url) do
    case URI.parse(endpoint_url) do
      %URI{scheme: scheme, host: host, path: path} when scheme in ["http", "https"] ->
        path = path || "/"

        if is_binary(host) and host != "" and String.starts_with?(path, "/") do
          {:ok, endpoint_url}
        else
          endpoint_unavailable()
        end

      _invalid ->
        endpoint_unavailable()
    end
  end

  defp endpoint_unavailable,
    do: {:failure, "alert_webhook_endpoint_invalid", "alert webhook endpoint is invalid"}

  defp recover_signing_secret(%AlertChannel{
         webhook_signing_secret_ciphertext: ciphertext,
         webhook_signing_secret_nonce: nonce,
         webhook_signing_secret_aad: aad
       })
       when is_binary(ciphertext) and is_binary(nonce) and is_map(aad) do
    case AppSecretCrypto.decrypt(ciphertext, nonce, aad) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) > 0 ->
        {:ok, secret}

      {:ok, _empty} ->
        {:failure, "alert_webhook_signing_secret_missing",
         "webhook signing secret is unavailable"}

      {:error, _reason} ->
        {:failure, "alert_webhook_signing_secret_invalid",
         "webhook signing secret is unavailable"}
    end
  end

  defp recover_signing_secret(%AlertChannel{}),
    do:
      {:failure, "alert_webhook_signing_secret_missing", "webhook signing secret is unavailable"}

  defp success_metadata(incident, channel, event_id, body_bytes, status) do
    incident
    |> response_metadata(channel, event_id, body_bytes, status)
    |> Map.put("delivery_status", "sent")
  end

  defp response_metadata(incident, channel, event_id, body_bytes, status) do
    incident
    |> base_metadata(channel)
    |> Map.put("event_id", event_id)
    |> Map.put("payload_bytes", body_bytes)
    |> maybe_put("response_status_code", status)
  end

  defp base_metadata(%AlertIncident{} = incident, %AlertChannel{} = channel) do
    %{}
    |> Map.put("delivery_adapter", @delivery_adapter)
    |> Map.put("incident_id", incident.id)
    |> Map.put("channel_id", channel.id)
    |> Map.put("channel_type", channel.channel_type)
    |> Map.put("endpoint_scheme", channel.endpoint_scheme)
    |> Map.put("endpoint_host", channel.endpoint_host)
    |> Map.put("endpoint_path_prefix", channel.endpoint_path_prefix)
    |> Map.put("endpoint_fingerprint", channel.endpoint_fingerprint)
    |> Map.put("rule_kind", incident.rule_kind)
    |> Map.put("severity", incident.severity)
    |> Map.put("reason_code", reason_code(incident.safe_evidence_snapshot))
    |> Map.put("scope_type", incident.scope_type)
    |> Map.put("pool_id", incident.pool_id)
    |> Map.put("upstream_identity_id", incident.upstream_identity_id)
    |> Map.put(
      "safe_evidence_summary",
      WebhookPayload.safe_evidence_summary(incident.safe_evidence_snapshot || %{})
    )
    |> compact_map()
    |> safe_metadata()
  end

  defp safe_metadata(metadata), do: Accounting.sanitize_metadata(metadata)

  defp reason_code(%{} = evidence) do
    evidence = safe_metadata(evidence)

    case Map.get(evidence, "reason_code") || Map.get(evidence, :reason_code) do
      value when is_binary(value) and byte_size(value) <= 120 -> value
      _value -> nil
    end
  end

  defp reason_code(_evidence), do: nil

  defp retryable_http_status?(status), do: status in @retryable_statuses or status in 500..599

  defp http_failure_message(status) when status in @permanent_statuses,
    do: "webhook endpoint rejected the alert notification"

  defp http_failure_message(_status), do: "webhook endpoint returned a retryable failure"

  defp transport_failure_code(nil), do: "alert_webhook_transport_failed"
  defp transport_failure_code(reason), do: "alert_webhook_transport_#{reason}"

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp exception_message(%{__struct__: struct}) do
    "#{inspect(struct)} raised during alert webhook delivery"
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
    |> Map.new()
  end
end
