defmodule CodexPooler.Gateway.Payloads.DebugPayloadSummary do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.ToolResultShape

  require Logger

  @spec record(String.t(), map(), map(), map(), String.t()) :: map() | nil
  def record(endpoint, payload, upstream_payload, opts, transport) do
    if enabled?() do
      summary = summary(endpoint, payload, upstream_payload, opts, transport)
      response_id_preview = response_id_preview(Map.get(payload, "previous_response_id"))

      Logger.info(fn ->
        [
          "codex_pooler gateway_debug payload",
          "request_id=#{summary["request_id"] || "unknown"}",
          "transport=#{summary["transport"] || "unknown"}",
          "endpoint=#{summary["endpoint"] || "unknown"}",
          "previous_response_id_action=#{summary["previous_response_id_summary"]["action"]}",
          "previous_response_id_preview=#{summary["previous_response_id_summary"]["preview"] || "none"}",
          "response_id_preview=#{response_id_preview || "none"}",
          "client_json_bytes=#{summary["shape"]["client"]["json"]["bytes"]}",
          "client_approx_tokens=#{summary["shape"]["client"]["json"]["approx_tokens"]}",
          "upstream_json_bytes=#{summary["shape"]["upstream"]["json"]["bytes"]}",
          "upstream_approx_tokens=#{summary["shape"]["upstream"]["json"]["approx_tokens"]}",
          "client_entry_count=#{summary["shape"]["client"]["entries"]["count"]}",
          "client_chat_entry_count=#{summary["shape"]["client"]["chat_entries"]["count"]}",
          "client_string_bytes=#{summary["shape"]["client"]["string_stats"]["string_bytes"]}",
          "input_item_types=#{inspect(summary["items"]["item_types"])}",
          "tool_result_types=#{inspect(summary["items"]["tool_result_types"])}",
          "tool_result_call_id_previews=#{inspect(summary["items"]["tool_result_call_id_previews"])}"
        ]
        |> Enum.join(" ")
      end)

      summary
    else
      nil
    end
  end

  @spec attempt_metadata(RequestOptions.t() | map()) :: map()
  def attempt_metadata(%RequestOptions{runtime: %{gateway_debug_payload: summary}}),
    do: attempt_metadata(%{gateway_debug_payload: summary})

  def attempt_metadata(%{gateway_debug_payload: summary}) when is_map(summary) do
    if enabled?(), do: %{"gateway_debug" => summary}, else: %{}
  end

  def attempt_metadata(_opts), do: %{}

  defp summary(endpoint, payload, upstream_payload, opts, transport) do
    previous_response_id = clean_string(Map.get(payload, "previous_response_id"))

    upstream_previous_response_id =
      clean_string(Map.get(upstream_payload, "previous_response_id"))

    input = Map.get(payload, "input")

    %{
      "endpoint" => endpoint,
      "transport" => transport,
      "request_id" => clean_string(Map.get(opts, :request_id)),
      "codex_session_id" => session_id(opts),
      "previous_response_id_summary" => %{
        "present" => not is_nil(previous_response_id),
        "action" => previous_response_action(previous_response_id, upstream_previous_response_id),
        "preview" => secret_preview(previous_response_id)
      },
      "shape" => %{
        "client" => shape_summary(payload),
        "upstream" => shape_summary(upstream_payload)
      },
      "items" => %{
        "item_types" => input_item_types(input),
        "tool_result_types" => tool_result_types(input),
        "tool_result_call_id_previews" => tool_result_call_id_previews(input)
      }
    }
  end

  defp previous_response_action(nil, _upstream_previous_response_id), do: "absent"
  defp previous_response_action(_previous_response_id, nil), do: "dropped"

  defp previous_response_action(_previous_response_id, _upstream_previous_response_id),
    do: "preserved"

  defp session_id(%{codex_session: %{id: id}}), do: id
  defp session_id(_opts), do: nil

  defp shape_summary(payload) when is_map(payload) do
    %{
      "json" => json_shape(payload),
      "top_level_keys" => payload |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      "entries" => sequence_shape(Map.get(payload, "input")),
      "chat_entries" => sequence_shape(Map.get(payload, "messages")),
      "string_stats" => content_shape(payload),
      "flags" => %{
        "stream" => Map.get(payload, "stream"),
        "generate" => Map.get(payload, "generate"),
        "has_previous_response_id" => is_binary(Map.get(payload, "previous_response_id")),
        "has_instructions" => Map.has_key?(payload, "instructions")
      },
      "routing" => %{
        "model_present" => is_binary(Map.get(payload, "model")),
        "reasoning_effort" => get_in(payload, ["reasoning", "effort"]),
        "service_tier" => Map.get(payload, "service_tier")
      }
    }
  end

  defp json_shape(payload) do
    bytes = json_bytes(payload)

    %{
      "bytes" => bytes,
      "approx_tokens" => div(bytes + 3, 4),
      "strategy" => "json_bytes_div_4_ceil"
    }
  end

  defp json_bytes(payload) do
    case Jason.encode(payload) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> 0
    end
  end

  defp sequence_shape(value) when is_list(value) do
    %{
      "kind" => "list",
      "count" => length(value),
      "item_types" => item_type_counts(value),
      "tool_result_count" => length(ToolResultShape.items(value)),
      "attachment_like_count" => type_like_count(value, "file"),
      "visual_asset_count" => type_like_count(value, "image")
    }
  end

  defp sequence_shape(value) when is_binary(value) do
    %{
      "kind" => "string",
      "count" => 1,
      "item_types" => %{},
      "tool_result_count" => 0,
      "attachment_like_count" => 0,
      "visual_asset_count" => 0
    }
  end

  defp sequence_shape(nil) do
    %{
      "kind" => "absent",
      "count" => 0,
      "item_types" => %{},
      "tool_result_count" => 0,
      "attachment_like_count" => 0,
      "visual_asset_count" => 0
    }
  end

  defp sequence_shape(_value) do
    %{
      "kind" => "other",
      "count" => 1,
      "item_types" => %{},
      "tool_result_count" => 0,
      "attachment_like_count" => 0,
      "visual_asset_count" => 0
    }
  end

  defp item_type_counts(items) do
    items
    |> Enum.map(fn
      %{} = item -> clean_string(Map.get(item, "type")) || "map"
      item when is_binary(item) -> "string"
      _item -> "other"
    end)
    |> Enum.frequencies()
  end

  defp content_shape(value) do
    value
    |> content_stats(%{string_count: 0, string_bytes: 0, max_string_bytes: 0})
    |> Map.new(fn {key, content_value} -> {Atom.to_string(key), content_value} end)
  end

  defp content_stats(value, acc) when is_binary(value) do
    bytes = byte_size(value)

    %{
      acc
      | string_count: acc.string_count + 1,
        string_bytes: acc.string_bytes + bytes,
        max_string_bytes: max(acc.max_string_bytes, bytes)
    }
  end

  defp content_stats(value, acc) when is_list(value),
    do: Enum.reduce(value, acc, &content_stats/2)

  defp content_stats(value, acc) when is_map(value) do
    value
    |> Map.values()
    |> Enum.reduce(acc, &content_stats/2)
  end

  defp content_stats(_value, acc), do: acc

  defp type_like_count(value, needle) when is_list(value) do
    Enum.reduce(value, 0, &(&2 + type_like_count(&1, needle)))
  end

  defp type_like_count(%{} = value, needle) do
    own_count =
      value
      |> Map.get("type")
      |> clean_string()
      |> case do
        nil -> 0
        type -> if String.contains?(type, needle), do: 1, else: 0
      end

    value
    |> Map.values()
    |> Enum.reduce(own_count, &(&2 + type_like_count(&1, needle)))
  end

  defp type_like_count(_value, _needle), do: 0

  defp input_item_types(input) when is_list(input) do
    input
    |> Enum.map(fn
      %{} = item -> Map.get(item, "type")
      _item -> nil
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp input_item_types(_input), do: []

  defp tool_result_types(input),
    do: input |> ToolResultShape.items() |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort()

  defp tool_result_call_id_previews(input) do
    input
    |> ToolResultShape.items()
    |> Enum.map(&secret_preview(&1.call_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp enabled?, do: OperationalSettings.current().gateway_debug?

  defp response_id_preview("resp_" <> suffix = response_id)
       when byte_size(suffix) in 13..1020 do
    if response_id =~ ~r/\Aresp_[A-Za-z0-9_-]+\z/,
      do: "resp_" <> binary_part(suffix, 0, 12)
  end

  defp response_id_preview(_response_id), do: nil

  defp secret_preview(nil), do: nil

  defp secret_preview(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil
end
