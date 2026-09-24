defmodule CodexPooler.MCP.Tools.LogMetadata.AuditLogPresenter do
  @moduledoc false

  alias CodexPooler.MCP.{MetadataSanitizer, PrivacyMatrix}
  alias CodexPooler.MCP.Tools.ReadableText

  @spec item(map()) :: map()
  def item(event) do
    details = MetadataSanitizer.safe_metadata(event.details || %{})

    projected =
      PrivacyMatrix.project!(:audit_logs, %{
        id: event.id,
        occurred_at: iso8601(event.occurred_at),
        actor_type: event.actor_type,
        actor_user_id: event.actor_user_id,
        actor_user_email: event.actor_user_email,
        actor_summary: %{summary: actor_summary(event)},
        pool_id: event.pool_id,
        pool_name: event.pool_name,
        pool_slug: event.pool_slug,
        request_id: event.request_id,
        action: event.action,
        target_type: event.target_type,
        target_id: event.target_id,
        target_summary: %{summary: target_summary(event)},
        outcome: event.outcome,
        correlation_id: event.correlation_id,
        ip_address: event.ip_address,
        details: details,
        details_summary: %{summary: details_summary(details)}
      })

    stringify_keys(projected)
  end

  @spec list_text(map()) :: String.t()
  def list_text(%{"items" => items, "total" => total, "offset" => offset} = page) do
    first_line = first_line(items, total_text(total, Map.get(page, "totalExact", true)), offset)

    if items == [] do
      first_line
    else
      "audit events"
      |> ReadableText.list(text_rows(items), list_text_fields(), total: total, offset: offset)
      |> replace_first_line(first_line)
    end
  end

  @spec detail_text(map()) :: String.t()
  def detail_text(%{"status" => "ok", "item" => item}) do
    ReadableText.detail("audit event", detail_text_row(item), detail_text_fields())
  end

  def detail_text(%{"status" => "not_found"}), do: ReadableText.not_found("audit event")

  defp first_line(items, total, offset) do
    shown_count = min(length(items), 10)
    action_text = tally_text(items, "action")
    outcome_text = tally_text(items, "outcome")

    "#{shown_count} audit events returned; total #{total}; offset #{offset}; actions #{action_text}; outcomes #{outcome_text}"
  end

  # An inexact total is a lower bound: more events than it match.
  defp total_text(total, true), do: Integer.to_string(total)
  defp total_text(total, false), do: "more than #{total}"

  defp text_rows(items), do: Enum.map(items, &text_row/1)

  defp text_row(item) do
    item
    |> Map.take(["occurred_at", "action", "outcome"])
    |> Map.put("actor", actor_text(item))
    |> Map.put("target", target_text(item))
    |> Map.put("pool", pool_text(item))
    |> Map.put("details", details_text(item))
  end

  defp detail_text_row(item) do
    item
    |> text_row()
    |> maybe_put_value("request", Map.get(item, "request_id"))
    |> maybe_put_value("correlation", Map.get(item, "correlation_id"))
  end

  defp list_text_fields do
    [
      {"occurred_at", "occurred_at", required: true},
      {"action", "action", required: true},
      {"outcome", "outcome", required: true},
      {"actor", "actor", required: true},
      {"target", "target", required: true},
      {"pool", "pool", required: true},
      {"details", "details", required: true}
    ]
  end

  defp detail_text_fields do
    list_text_fields() ++
      [
        {"request", "request"},
        {"correlation", "correlation"}
      ]
  end

  defp actor_text(item) do
    summary_text(Map.get(item, "actor_summary")) || blank_to_nil(Map.get(item, "actor_type")) ||
      "unknown"
  end

  defp target_text(item) do
    summary_text(Map.get(item, "target_summary")) || blank_to_nil(Map.get(item, "target_type")) ||
      "unknown"
  end

  defp pool_text(item) do
    blank_to_nil(Map.get(item, "pool_slug")) || blank_to_nil(Map.get(item, "pool_name")) ||
      "system"
  end

  defp details_text(item),
    do: summary_text(Map.get(item, "details_summary")) || "0 safe detail keys"

  defp summary_text(%{"summary" => summary}), do: blank_to_nil(summary)
  defp summary_text(_summary), do: nil

  defp actor_summary(%{actor_type: "user", actor_user_id: user_id}) when is_binary(user_id),
    do: "user #{short_id(user_id)}"

  defp actor_summary(%{actor_type: actor_type}) when is_binary(actor_type), do: actor_type
  defp actor_summary(_event), do: "unknown actor"

  defp target_summary(%{target_type: type, target_id: id}) when is_binary(type) and is_binary(id),
    do: "#{type} #{short_id(id)}"

  defp target_summary(%{target_type: type}) when is_binary(type), do: type
  defp target_summary(_event), do: "unknown target"

  defp details_summary(details) when is_map(details) do
    keys = details |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.take(5)

    "#{map_size(details)} safe detail keys" <>
      if(keys == [], do: "", else: ": #{Enum.join(keys, ", ")}")
  end

  defp maybe_put_value(row, _key, nil), do: row
  defp maybe_put_value(row, key, value), do: Map.put(row, key, value)

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

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), MetadataSanitizer.safe_value(value)} end)
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
