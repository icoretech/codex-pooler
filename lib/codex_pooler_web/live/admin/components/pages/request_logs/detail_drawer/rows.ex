defmodule CodexPoolerWeb.Admin.RequestLogDetailDrawer.Rows do
  @moduledoc false

  import CodexPoolerWeb.Admin.RequestLogsDisplay,
    only: [
      format_api_key: 1,
      format_datetime: 2,
      format_token_counts: 1,
      format_transport_route: 1,
      format_upstream_account_label: 1,
      format_usage_cost: 1,
      protocol_label: 1,
      status_label: 1
    ]

  import CodexPoolerWeb.Admin.RequestLogDetailDrawer.Format, only: [safe_text: 1]

  @type detail_row :: %{
          id: String.t(),
          label: String.t(),
          value: term(),
          mono: boolean()
        }

  @spec final_outcome_rows(map(), map()) :: [detail_row()]
  def final_outcome_rows(log, datetime_preferences) do
    [
      detail("request-log-detail-request-id", "Request id", log.id, mono: true),
      detail("request-log-detail-correlation-id", "Correlation id", log.correlation_id,
        mono: true
      ),
      detail("request-log-detail-status", "Status", status_label(log.status || "unknown")),
      detail("request-log-detail-endpoint", "Endpoint", log.endpoint, mono: true),
      detail("request-log-detail-model", "Model", log.requested_model),
      detail(
        "request-log-detail-requested-reasoning",
        "Requested reasoning",
        log.reasoning_effort, mono: true),
      detail(
        "request-log-detail-applied-reasoning",
        "Applied reasoning",
        log.applied_reasoning_effort,
        mono: true
      ),
      detail(
        "request-log-detail-upstream-reasoning",
        "Upstream reasoning",
        log.effective_reasoning_effort,
        mono: true
      ),
      detail("request-log-detail-transport", "Transport", protocol_label(log.transport)),
      detail("request-log-detail-response-status", "Response status", log.response_status_code),
      detail("request-log-detail-error-code", "Error code", log.denial_reason, mono: true),
      detail("request-log-detail-retry-count", "Retries", log.retry_count),
      detail(
        "request-log-detail-admitted-at",
        "Admitted",
        format_datetime(log.admitted_at, datetime_preferences),
        mono: true
      ),
      detail(
        "request-log-detail-completed-at",
        "Completed",
        format_datetime(log.completed_at, datetime_preferences),
        mono: true
      )
    ]
    |> present_rows()
  end

  @spec routing_rows(map()) :: [detail_row()]
  def routing_rows(log) do
    routing = metadata_section(log, "routing")

    [
      detail("request-log-detail-pool", "Pool", log.pool_name),
      detail(
        "request-log-detail-upstream",
        "Upstream account",
        format_upstream_account_label(log)
      ),
      detail("request-log-detail-assignment", "Assignment", log.assignment_label),
      detail("request-log-detail-api-key", "API key", format_api_key(log)),
      detail("request-log-detail-route", "Route", format_transport_route(log), mono: true),
      detail("request-log-detail-route-class", "Route class", Map.get(routing, "route_class"),
        mono: true
      ),
      detail("request-log-detail-routing-strategy", "Strategy", Map.get(routing, "strategy"),
        mono: true
      ),
      detail(
        "request-log-detail-selected-rank",
        "Selected rank",
        Map.get(routing, "selected_bridge_candidate_rank")
      ),
      detail(
        "request-log-detail-candidate-exclusions",
        "Candidate exclusions",
        list_count(log.metadata["candidate_exclusions"])
      )
    ]
    |> present_rows()
  end

  @spec usage_rows(map()) :: [detail_row()]
  def usage_rows(log) do
    [
      detail("request-log-detail-token-counts", "Tokens", format_token_counts(log.token_counts)),
      detail("request-log-detail-cost", "Cost", format_usage_cost(log.cost)),
      detail("request-log-detail-usage-status", "Usage status", log.usage_status, mono: true),
      detail(
        "request-log-detail-pricing-status",
        "Pricing status",
        cost_field(log.cost, :pricing_status),
        mono: true
      ),
      detail(
        "request-log-detail-cached-input",
        "Cached input",
        token_field(log.token_counts, :cached_input_tokens)
      ),
      detail(
        "request-log-detail-reasoning-tokens",
        "Reasoning tokens",
        token_field(log.token_counts, :reasoning_tokens)
      )
    ]
    |> present_rows()
  end

  @spec continuity_rows(map(), map()) :: [detail_row()]
  def continuity_rows(log, datetime_preferences) do
    debug = log.debug || %{}
    continuity = Map.get(debug, :continuity, %{})
    failure = Map.get(debug, :failure, %{})
    terminal = Map.get(debug, :terminal_state, %{})
    turn = Map.get(debug, :turn, %{})
    attempt = Map.get(debug, :attempt, %{})

    [
      detail("request-log-detail-continuity-status", "Continuity", continuity[:status],
        mono: true
      ),
      detail("request-log-detail-session-ref", "Session ref", continuity[:session_ref],
        mono: true
      ),
      detail("request-log-detail-turn-ref", "Turn ref", continuity[:turn_ref] || turn[:turn_ref],
        mono: true
      ),
      detail(
        "request-log-detail-turn-status",
        "Turn status",
        continuity[:turn_status] || turn[:status],
        mono: true
      ),
      detail(
        "request-log-detail-final-attempt-ref",
        "Final attempt ref",
        turn[:final_attempt_ref],
        mono: true
      ),
      detail("request-log-detail-failure-source", "Failure source", failure[:error_source],
        mono: true
      ),
      detail("request-log-detail-debug-error", "Debug error", failure[:error_code], mono: true),
      detail("request-log-detail-terminal-state", "Terminal state", terminal[:state], mono: true),
      detail("request-log-detail-terminal-mismatch", "Terminal mismatch", terminal[:mismatch]),
      detail("request-log-detail-attempt-count", "Attempt count", attempt[:attempt_count]),
      detail(
        "request-log-detail-latest-attempt",
        "Latest attempt",
        attempt[:latest_attempt_number]
      ),
      detail(
        "request-log-detail-turn-completed-at",
        "Turn completed",
        format_debug_timestamp(turn[:completed_at], datetime_preferences),
        mono: true
      )
    ]
    |> present_rows()
  end

  @spec sanitized_metadata_rows(map()) :: [detail_row()]
  def sanitized_metadata_rows(log) do
    quota = metadata_section(log, "quota_decision")
    compression = log.payload_compression || %{}
    file = metadata_section(log, "file")

    [
      detail("request-log-detail-quota-summary", "Quota summary", Map.get(quota, "summary")),
      detail(
        "request-log-detail-operation",
        "Operation",
        Map.get(log.metadata || %{}, "operation"),
        mono: true
      ),
      detail("request-log-detail-file-status", "File status", Map.get(file, "status"),
        mono: true
      ),
      detail("request-log-detail-compression-status", "Compression status", compression[:status],
        mono: true
      ),
      detail("request-log-detail-compression-reason", "Compression reason", compression[:reason],
        mono: true
      ),
      detail(
        "request-log-detail-compression-saved",
        "Compression saved",
        compression_saved(compression)
      )
    ]
    |> present_rows()
  end

  defp metadata_section(%{metadata: metadata}, key) when is_map(metadata) do
    case Map.get(metadata, key) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp metadata_section(_log, _key), do: %{}

  defp detail(id, label, value, opts \\ []) do
    %{id: id, label: label, value: value, mono: Keyword.get(opts, :mono, false)}
  end

  defp present_rows(rows), do: Enum.reject(rows, &(blank?(&1.value) or &1.value == "-"))

  defp token_field(nil, _key), do: nil
  defp token_field(counts, key), do: Map.get(counts, key)

  defp cost_field(nil, _key), do: nil
  defp cost_field(cost, key), do: Map.get(cost, key)

  defp list_count(value) when is_list(value), do: length(value)
  defp list_count(_value), do: nil

  defp compression_saved(%{saved_count: saved, unit: unit})
       when is_integer(saved) and is_binary(unit),
       do: "#{safe_text(saved)} #{unit}"

  defp compression_saved(_compression), do: nil

  defp format_debug_timestamp(nil, _preferences), do: nil

  defp format_debug_timestamp(value, preferences) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> format_datetime(datetime, preferences)
      _error -> value
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
