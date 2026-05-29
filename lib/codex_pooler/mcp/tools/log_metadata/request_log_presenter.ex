defmodule CodexPooler.MCP.Tools.LogMetadata.RequestLogPresenter do
  @moduledoc false

  alias CodexPooler.MCP.{MetadataSanitizer, PrivacyMatrix}
  alias CodexPooler.MCP.Tools.ReadableText

  @public_debug_sources MapSet.new([
                          "continuity",
                          "turn_state",
                          "request_state",
                          "attempt_state",
                          "request_error",
                          "turn_error",
                          "attempt_error"
                        ])

  @list_debug_keys ~w(continuity failure attempt)
  @detail_debug_keys ~w(continuity terminal_state turn attempts)

  @spec item(map()) :: map()
  def item(log) do
    projected =
      PrivacyMatrix.project!(:request_logs, %{
        id: log.id,
        pool_id: log.pool_id,
        pool_name: log.pool_name,
        pool_slug: log.pool_slug,
        api_key_id: log.api_key_id,
        api_key_display_name: log.api_key_display_name,
        api_key_prefix: log.api_key_prefix,
        requested_model: log.requested_model,
        transport: log.transport,
        status: log.status,
        usage_status: log.usage_status,
        correlation_id: log.correlation_id,
        response_status_code: log.response_status_code,
        retry_count: log.retry_count,
        denial_reason: log.denial_reason,
        latency_ms: log.latency_ms,
        token_counts: MetadataSanitizer.safe_value(log.token_counts),
        cost: MetadataSanitizer.safe_value(log.cost),
        errors: safe_errors(log.errors),
        admitted_at: iso8601(log.admitted_at),
        completed_at: iso8601(log.completed_at),
        upstream_account_label: log.upstream_account_label,
        upstream_account_email: log.upstream_account_email,
        upstream_account_plan_label: log.upstream_account_plan_label,
        upstream_account_plan_family: log.upstream_account_plan_family,
        upstream_identity_id: log.upstream_identity_id,
        upstream_identity_label: log.upstream_identity_label,
        pool_upstream_assignment_id: log.pool_upstream_assignment_id,
        assignment_label: log.assignment_label,
        reasoning_effort: log.reasoning_effort,
        service_tier: log.service_tier,
        requested_service_tier: log.requested_service_tier,
        actual_service_tier: log.actual_service_tier,
        endpoint: log.endpoint,
        user_agent: log.user_agent,
        metadata: safe_request_metadata(log.metadata || %{})
      })

    projected
    |> stringify_keys()
    |> Map.put("debug", detail_debug(log))
  end

  @spec list_item(map()) :: map()
  def list_item(log) do
    log
    |> item()
    |> Map.put("debug", list_debug(log))
  end

  @spec list_text(map()) :: String.t()
  def list_text(%{"items" => items, "total" => total, "offset" => offset}) do
    first_line = first_line(items, total, offset)

    if items == [] do
      first_line
    else
      "request logs"
      |> ReadableText.list(text_rows(items), list_text_fields(), total: total, offset: offset)
      |> replace_first_line(first_line)
    end
  end

  @spec detail_text(map()) :: String.t()
  def detail_text(%{"status" => "ok", "item" => item}) do
    ReadableText.detail("request log", detail_text_row(item), detail_text_fields())
  end

  def detail_text(%{"status" => "not_found"}), do: ReadableText.not_found("request log")

  defp first_line(items, total, offset) do
    shown_count = min(length(items), 10)
    status_text = tally_text(items, "status")

    "#{shown_count} request logs returned; total #{total}; offset #{offset}; statuses #{status_text}"
  end

  defp text_rows(items), do: Enum.map(items, &text_row/1)

  defp text_row(item) do
    item
    |> Map.take([
      "admitted_at",
      "completed_at",
      "id",
      "correlation_id",
      "endpoint",
      "status",
      "requested_model",
      "transport",
      "usage_status",
      "latency_ms"
    ])
    |> Map.put("pool", pool_text(item))
    |> Map.put("retries", Map.get(item, "retry_count") || 0)
    |> maybe_put_continuity_denial_text(Map.get(item, "errors"))
    |> maybe_put_debug_text(Map.get(item, "debug"))
  end

  defp detail_text_row(item) do
    item
    |> text_row()
    |> maybe_put_value("response", Map.get(item, "response_status_code"))
    |> Map.put("upstream", upstream_text(item))
    |> maybe_put_metadata_summary(Map.get(item, "metadata"))
  end

  defp list_text_fields do
    [
      {"admitted_at", "admitted_at"},
      {"completed_at", "completed_at"},
      {"id", "id"},
      {"correlation_id", "correlation"},
      {"pool", "pool", required: true},
      {"endpoint", "route"},
      {"status", "status"},
      {"requested_model", "model"},
      {"transport", "transport"},
      {"usage_status", "usage"},
      {"latency_ms", "latency_ms"},
      {"retries", "retries", required: true},
      {"session_ref", "session"},
      {"turn_ref", "turn"},
      {"turn_status", "turn_status"},
      {"terminal_state", "terminal"},
      {"failure_code", "failure"},
      {"denial_family", "denial_family"},
      {"continuity_family", "continuity_family"},
      {"upstream_lifecycle_family", "lifecycle"},
      {"token_refresh_reason_code_preview", "refresh_reason"},
      {"operator_action", "action"},
      {"attempt_count", "attempts"}
    ]
  end

  defp detail_text_fields do
    list_text_fields() ++
      [
        {"response", "response"},
        {"upstream", "upstream", required: true},
        {"metadata_summary", "metadata"}
      ]
  end

  defp pool_text(item) do
    blank_to_nil(Map.get(item, "pool_slug")) || blank_to_nil(Map.get(item, "pool_name")) ||
      "unknown"
  end

  defp upstream_text(item) do
    blank_to_nil(Map.get(item, "upstream_identity_label")) ||
      blank_to_nil(Map.get(item, "upstream_account_label")) || "unknown"
  end

  defp maybe_put_value(row, _key, nil), do: row
  defp maybe_put_value(row, key, value), do: Map.put(row, key, value)

  defp maybe_put_debug_text(row, %{
         "continuity" => continuity,
         "failure" => failure,
         "attempt" => attempt
       }) do
    row
    |> maybe_put_continuity_text(continuity)
    |> maybe_put_value("failure_code", Map.get(failure, "error_code"))
    |> maybe_put_value("attempt_count", Map.get(attempt, "attempt_count"))
  end

  defp maybe_put_debug_text(row, %{
         "continuity" => continuity,
         "terminal_state" => terminal_state,
         "attempts" => attempts
       }) do
    row
    |> maybe_put_continuity_text(continuity)
    |> maybe_put_value("terminal_state", Map.get(terminal_state, "state"))
    |> maybe_put_value("attempt_count", length(attempts))
  end

  defp maybe_put_debug_text(row, _debug), do: row

  defp maybe_put_continuity_denial_text(row, errors) when is_list(errors) do
    case Enum.find(errors, &(Map.get(&1, "kind") == "continuity_denial")) do
      nil ->
        row

      denial ->
        row
        |> maybe_put_value("denial_family", Map.get(denial, "denial_family"))
        |> maybe_put_value("continuity_family", Map.get(denial, "continuity_family"))
        |> maybe_put_value(
          "upstream_lifecycle_family",
          Map.get(denial, "upstream_lifecycle_family")
        )
        |> maybe_put_value(
          "token_refresh_reason_code_preview",
          Map.get(denial, "token_refresh_reason_code_preview")
        )
        |> maybe_put_value("operator_action", Map.get(denial, "operator_action"))
    end
  end

  defp maybe_put_continuity_denial_text(row, _errors), do: row

  defp maybe_put_continuity_text(row, continuity) do
    row
    |> maybe_put_value("session_ref", Map.get(continuity, "session_ref"))
    |> maybe_put_value("turn_ref", Map.get(continuity, "turn_ref"))
    |> maybe_put_value("turn_status", Map.get(continuity, "turn_status"))
    |> maybe_put_value("terminal_state", Map.get(continuity, "terminal_state"))
  end

  defp maybe_put_metadata_summary(row, metadata)
       when is_map(metadata) and map_size(metadata) > 0 do
    Map.put(row, "metadata_summary", metadata_summary(metadata))
  end

  defp maybe_put_metadata_summary(row, _metadata), do: row

  defp metadata_summary(metadata) do
    keys =
      metadata
      |> Enum.filter(fn {_key, value} -> useful_metadata_value?(value) end)
      |> Enum.map(fn {key, _value} -> ReadableText.scalar(key) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()
      |> Enum.take(5)

    "#{length(keys)} safe metadata keys" <>
      if(keys == [], do: "", else: ": #{Enum.join(keys, ", ")}")
  end

  defp useful_metadata_value?("[REDACTED]"), do: false
  defp useful_metadata_value?(nil), do: false

  defp useful_metadata_value?(value) when is_map(value),
    do: Enum.any?(value, fn {_key, child} -> useful_metadata_value?(child) end)

  defp useful_metadata_value?(value) when is_list(value),
    do: Enum.any?(value, &useful_metadata_value?/1)

  defp useful_metadata_value?(_value), do: true

  defp replace_first_line(text, first_line) do
    text
    |> String.split("\n", parts: 2)
    |> case do
      [_old_first_line, rest] -> first_line <> "\n" <> rest
      [_old_first_line] -> first_line
    end
  end

  defp tally_text([], _field), do: "none"

  defp tally_text(items, field) do
    items
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {value, _count} -> value end)
    |> Enum.map_join(", ", fn {value, count} -> "#{value}:#{count}" end)
    |> case do
      "" -> "none"
      text -> text
    end
  end

  defp safe_errors(errors) do
    errors
    |> MetadataSanitizer.safe_value()
    |> drop_error_messages()
  end

  defp drop_error_messages(errors) when is_list(errors),
    do: Enum.map(errors, &drop_error_messages/1)

  defp drop_error_messages(error) when is_map(error), do: Map.drop(error, ["message"])

  defp drop_error_messages(errors), do: errors

  defp safe_request_metadata(metadata) do
    metadata
    |> MetadataSanitizer.safe_metadata()
    |> Map.drop(["codex_session_id", "codex_session_key", "conversation_key"])
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), MetadataSanitizer.safe_value(value)} end)
  end

  defp list_debug(log) do
    log
    |> raw_debug()
    |> Map.take(@list_debug_keys)
    |> sanitize_debug_sources()
  end

  defp detail_debug(log) do
    log
    |> raw_debug()
    |> Map.take(@detail_debug_keys)
    |> sanitize_debug_sources()
  end

  defp raw_debug(log) do
    log
    |> Map.get(:debug, %{})
    |> MetadataSanitizer.safe_value()
  end

  defp sanitize_debug_sources(debug) when is_map(debug) do
    Map.new(debug, fn {key, value} -> {key, sanitize_debug_value(value)} end)
  end

  defp sanitize_debug_value(value) when is_map(value) do
    Map.new(value, fn
      {key, source}
      when key in [
             "source",
             "session_source",
             "turn_status_source",
             "terminal_state_source",
             "error_source"
           ] ->
        {key, safe_source(source)}

      {key, value} ->
        {key, sanitize_debug_value(value)}
    end)
  end

  defp sanitize_debug_value(value) when is_list(value),
    do: Enum.map(value, &sanitize_debug_value/1)

  defp sanitize_debug_value(value) when is_binary(value) do
    get_in(MetadataSanitizer.safe_metadata(%{"value" => value}), ["value"])
  end

  defp sanitize_debug_value(value), do: value

  defp safe_source(source) when is_binary(source) do
    if MapSet.member?(@public_debug_sources, source), do: source, else: nil
  end

  defp safe_source(_source), do: nil

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
