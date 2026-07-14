defmodule CodexPoolerWeb.Admin.RequestLogDetailDrawer.Attempts do
  @moduledoc false

  import CodexPoolerWeb.Admin.RequestLogsDisplay, only: [format_route_latency: 1]

  @type detail_row :: %{
          id: String.t(),
          label: String.t(),
          value: term(),
          mono: boolean()
        }

  @spec attempt_rows(map()) :: [detail_row()]
  def attempt_rows(attempt) do
    [
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-ref",
        "Attempt ref",
        attempt.attempt_ref,
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-assignment",
        "Assignment id",
        attempt.pool_upstream_assignment_id,
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-status-code",
        "Upstream status",
        attempt.upstream_status_code
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-network-error",
        "Network error",
        attempt.network_error_code,
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-upstream-error-param",
        "Upstream error parameter",
        Map.get(attempt, :upstream_error_param),
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-latency",
        "Latency",
        format_route_latency(attempt.latency_ms),
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-retryable",
        "Retryable",
        attempt.retryable
      ),
      detail("request-log-detail-attempt-#{attempt.attempt_number}-final", "Final", attempt.final)
    ]
    |> present_rows()
  end

  @spec transport_failure_rows(map()) :: [detail_row()]
  def transport_failure_rows(attempt) do
    failure = attempt.transport_failure
    prefix = "request-log-detail-transport-#{attempt.attempt_number}"

    [
      detail("#{prefix}-exception", "Exception", Map.get(failure, :exception), mono: true),
      detail("#{prefix}-reason-class", "Reason class", Map.get(failure, :reason_class),
        mono: true
      ),
      detail("#{prefix}-reason", "Reason", Map.get(failure, :reason), mono: true),
      detail("#{prefix}-phase", "Phase", Map.get(failure, :phase), mono: true),
      detail(
        "#{prefix}-pre-visible-output",
        "Pre-visible output",
        Map.get(failure, :pre_visible_output)
      ),
      detail("#{prefix}-terminal-seen", "Terminal seen", Map.get(failure, :terminal_seen)),
      detail(
        "#{prefix}-text-frame-count",
        "Text frame count",
        Map.get(failure, :text_frame_count)
      )
    ]
    |> present_rows()
  end

  @spec debug_attempts(map()) :: [map()]
  def debug_attempts(%{debug: %{attempts: attempts}}) when is_list(attempts), do: attempts
  def debug_attempts(_log), do: []

  @spec transport_failure_attempts(map()) :: [map()]
  def transport_failure_attempts(log) do
    log
    |> debug_attempts()
    |> Enum.filter(
      &(is_map(Map.get(&1, :transport_failure)) and map_size(&1.transport_failure) > 0)
    )
  end

  defp detail(id, label, value, opts \\ []) do
    %{id: id, label: label, value: value, mono: Keyword.get(opts, :mono, false)}
  end

  defp present_rows(rows), do: Enum.reject(rows, &(blank?(&1.value) or &1.value == "-"))

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
