defmodule CodexPoolerWeb.Admin.RequestLogsDisplay do
  @moduledoc false

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.RequestLogsDisplay.{Errors, Status, UserAgents}
  alias CodexPoolerWeb.DateTimeDisplay

  defdelegate selected_status_filter_option(status), to: Status
  defdelegate status_filter_options(), to: Status
  defdelegate selected_model_filter_option(model), to: Status
  defdelegate status_label(status), to: Status

  def format_api_key(log) do
    cond do
      is_nil(log.api_key_id) -> "external token"
      log.api_key_display_name -> log.api_key_display_name
      true -> "unnamed key"
    end
  end

  def format_upstream_account_label(%{
        upstream_account_label: label,
        upstream_identity_label: identity_label
      })
      when is_binary(label) and label != "" and is_binary(identity_label) and identity_label != "",
      do: identity_label

  def format_upstream_account_label(%{upstream_account_label: label})
      when is_binary(label) and label != "",
      do: label

  def format_upstream_account_label(%{assignment_label: label})
      when is_binary(label) and label != "",
      do: label

  def format_upstream_account_label(%{upstream_account_email: email})
      when is_binary(email) and email != "",
      do: email

  def format_upstream_account_label(%{upstream_identity_label: label})
      when is_binary(label) and label != "",
      do: label

  def format_upstream_account_label(_log), do: "—"

  def fast_mode?(log), do: speed_tier_mode(log) in [:fast, :ultrafast]

  def speed_tier_mode(log) when is_map(log) do
    metadata = Map.get(log, :metadata)
    model = Map.get(log, :requested_model)
    tier = Map.get(log, :requested_service_tier)

    cond do
      ultrafast_metadata?(metadata) or service_tier_ultrafast?(tier) -> :ultrafast
      fast_metadata?(metadata) or model == "gpt-5.4" or service_tier_priority?(tier) -> :fast
      true -> nil
    end
  end

  def speed_tier_mode(_log), do: nil

  def speed_tier_label(:ultrafast), do: "Ultrafast mode"
  def speed_tier_label(:fast), do: "Fast mode"

  def protocol_label("websocket"), do: "WebSocket"
  def protocol_label("http_sse"), do: "HTTP SSE"
  def protocol_label("http_multipart"), do: "HTTP multipart"
  def protocol_label("http_json"), do: "HTTP JSON"
  def protocol_label(_transport), do: "HTTP"

  def protocol_title(%{transport: transport} = log) do
    transport_label =
      if is_binary(transport) do
        "transport: #{transport}"
      else
        "transport not recorded"
      end

    case speed_tier_mode(log) do
      :ultrafast -> "#{transport_label}; ultrafast mode"
      :fast -> "#{transport_label}; fast mode"
      nil -> transport_label
    end
  end

  def protocol_badge_class("websocket"),
    do: "#{AdminBadges.metadata_chip_class(:info)} justify-center whitespace-nowrap"

  def protocol_badge_class("http_sse"),
    do: "#{AdminBadges.metadata_chip_class(:success)} justify-center whitespace-nowrap"

  def protocol_badge_class("http_multipart"),
    do: "#{AdminBadges.metadata_chip_class(:warning)} justify-center whitespace-nowrap"

  def protocol_badge_class("http_json"),
    do: "#{AdminBadges.metadata_chip_class(:primary)} justify-center whitespace-nowrap"

  def protocol_badge_class(_transport),
    do: "#{AdminBadges.metadata_chip_class(:neutral)} justify-center whitespace-nowrap"

  def format_total(1), do: "1"
  def format_total(total), do: Integer.to_string(total || 0)

  def format_datetime(value, datetime_preferences),
    do:
      DateTimeDisplay.format_datetime(value, datetime_preferences, missing_label: "not recorded")

  def format_datetime(nil), do: "not recorded"

  def format_record_id(nil), do: nil

  def format_record_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  def format_record_id(_id), do: nil

  defdelegate request_status_icon(status), to: Status
  defdelegate request_status_icon_class(status), to: Status
  defdelegate request_status_filter_icon_color(status), to: Status

  def format_token_counts(nil), do: "-"

  def format_token_counts(counts) do
    case total_token_count(counts) do
      total when is_integer(total) -> "#{format_compact_integer(total)} tokens"
      _total -> "-"
    end
  end

  def total_token_count(%{total_tokens: total}) when is_integer(total), do: total
  def total_token_count(_counts), do: nil

  def format_token_totals(request_log) do
    format_token_counts(request_log.token_counts)
  end

  def token_totals_title(%{token_counts: nil}), do: nil

  def token_totals_title(%{token_counts: counts}) do
    [
      token_part("input", counts.input_tokens),
      token_part("output", counts.output_tokens),
      token_part("reasoning", counts.reasoning_tokens),
      token_part("cached input", counts.cached_input_tokens)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "; ")
    end
  end

  def format_usage_cost(cost) do
    case format_cost(cost) do
      "-" -> "cost n/a"
      "unavailable" -> "cost n/a"
      cost_label -> cost_label
    end
  end

  def usage_line_applicable?(log) do
    case total_token_count(log.token_counts) do
      total when is_integer(total) and total > 0 -> true
      _total -> cost_applicable?(log.cost)
    end
  end

  def format_total_cost(cost) do
    case format_cost(cost) do
      "-" -> "Total cost unavailable"
      "unavailable" -> "Total cost unavailable"
      cost_label -> "Total cost #{cost_label}"
    end
  end

  def format_model_name(%{requested_model: model}) when is_binary(model) do
    if endpoint_model?(model), do: "—", else: model
  end

  def format_model_name(_log), do: "—"

  def format_model_details_title(log) do
    [
      format_model_name(log),
      format_model_reasoning(log),
      format_model_service_tier(log) && "/ #{format_model_service_tier(log)}",
      format_requested_tier_detail(log)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def format_model_reasoning(%{reasoning_effort: reasoning}) when not is_nil(reasoning),
    do: if(blank?(reasoning), do: nil, else: reasoning)

  def format_model_reasoning(_log), do: nil

  def format_model_service_tier(log) do
    case effective_service_tier(log) do
      tier when is_binary(tier) -> if(blank?(tier), do: nil, else: tier)
      _tier -> nil
    end
  end

  def format_requested_tier_detail(log) do
    requested = log.requested_service_tier
    effective = effective_service_tier(log)

    if !fast_mode?(log) and is_binary(requested) and requested != "" and requested != effective do
      "requested: #{requested}"
    else
      nil
    end
  end

  def format_cached_token_breakdown(%{token_counts: nil}), do: nil

  def format_cached_token_breakdown(log) do
    cached = log.token_counts.cached_input_tokens

    if cached && cached != 0 do
      "(#{format_compact_integer(cached)} cached)"
    else
      nil
    end
  end

  def usage_cached_line_title(log) do
    [
      verbose_cached_token_breakdown(log),
      cached_cost_title(log)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "; ")
    end
  end

  def format_route_latency(nil), do: nil

  def format_route_latency(value) when is_integer(value) and value >= 1_000,
    do: format_seconds(value)

  def format_route_latency(value) when is_integer(value), do: "#{value}ms"

  def format_route_latency(_value), do: nil

  def format_latency_title(nil), do: nil

  def format_latency_title(value) when is_integer(value),
    do: "Elapsed upstream attempt time #{format_integer(value)} ms"

  def format_latency_title(_value), do: nil

  def cached_cost_title(%{token_counts: nil}), do: nil

  def cached_cost_title(log),
    do: format_cached_input_cost(log.token_counts.cached_input_cost_usd)

  def usage_cost_line_title(log) do
    if cost_applicable?(log.cost) do
      cached_cost_title(log)
    else
      format_total_cost(log.cost)
    end
  end

  def format_cached_input_cost_summary(%{token_counts: nil}), do: nil

  def format_cached_input_cost_summary(log),
    do: compact_cached_input_cost(log.token_counts.cached_input_cost_usd)

  defdelegate format_user_agent(log), to: UserAgents, as: :format
  defdelegate user_agent_display(log), to: UserAgents, as: :display

  def format_transport_route(log) do
    log.endpoint || "unknown endpoint"
  end

  def format_route_metadata(log) do
    [
      openai_compatibility_origin(log),
      route_class(log),
      request_content_type(log),
      request_body_size(log)
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defdelegate format_errors(log, datetime_preferences), to: Errors

  def format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def filter_option_value(current_attr, target_attr, option) when current_attr == target_attr,
    do: option.value

  def filter_option_value(_current_attr, _target_attr, _option), do: nil

  def filter_option_active?(option, selected_value), do: option.value == selected_value

  def option_icon_class(option), do: Map.get(option, :icon_class, "text-base-content/60")

  defp service_tier_priority?(tier) when is_binary(tier),
    do: tier |> String.trim() |> String.downcase() == "priority"

  defp service_tier_priority?(_tier), do: false

  defp service_tier_ultrafast?(tier) when is_binary(tier),
    do: tier |> String.trim() |> String.downcase() == "ultrafast"

  defp service_tier_ultrafast?(_tier), do: false

  defp ultrafast_metadata?(%{} = metadata) do
    Map.get(metadata, "codex_mode") == "ultrafast" or
      get_in(metadata, ["codex", "mode"]) == "ultrafast" or
      get_in(metadata, ["request", "mode"]) == "ultrafast"
  end

  defp ultrafast_metadata?(_metadata), do: false

  defp fast_metadata?(%{} = metadata) do
    truthy?(Map.get(metadata, "fast_mode")) or Map.get(metadata, "codex_mode") == "fast" or
      get_in(metadata, ["codex", "mode"]) == "fast" or
      get_in(metadata, ["request", "mode"]) == "fast"
  end

  defp fast_metadata?(_metadata), do: false

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp token_part(_label, nil), do: nil
  defp token_part(_label, 0), do: nil
  defp token_part(label, value) when is_integer(value), do: "#{format_integer(value)} #{label}"
  defp token_part(_label, _value), do: nil

  defp format_cost(%{status: "priced", usd: %Decimal{} = usd}) do
    "$#{format_usd(usd)}"
  end

  defp format_cost(%{status: "unpriced"}), do: "-"

  defp format_cost(%{status: "unpriced_" <> _reason}), do: "-"

  defp format_cost(%{status: status}) when is_binary(status), do: status
  defp format_cost(_), do: "unavailable"

  defp cost_applicable?(cost) do
    case format_cost(cost) do
      "-" -> false
      "unavailable" -> false
      _cost_label -> true
    end
  end

  defp effective_service_tier(log) do
    log.actual_service_tier || log.service_tier || "default"
  end

  defp endpoint_model?(model), do: String.starts_with?(String.trim(model), "/")

  defp route_class(%{metadata: metadata}) when is_map(metadata),
    do: get_in(metadata, ["routing", "route_class"])

  defp route_class(_log), do: nil

  defp openai_compatibility_origin(%{metadata: metadata}) when is_map(metadata) do
    case get_in(metadata, ["openai_compatibility", "source_endpoint"]) do
      endpoint when is_binary(endpoint) -> "translated from #{endpoint}"
      _endpoint -> nil
    end
  end

  defp openai_compatibility_origin(_log), do: nil

  defp request_content_type(%{metadata: metadata}) when is_map(metadata),
    do: get_in(metadata, ["request", "content_type"])

  defp request_content_type(_log), do: nil

  defp request_body_size(%{metadata: metadata}) when is_map(metadata) do
    case get_in(metadata, ["request", "body_bytes"]) do
      bytes when is_integer(bytes) and bytes >= 0 -> "#{format_integer(bytes)} bytes"
      _bytes -> nil
    end
  end

  defp request_body_size(_log), do: nil

  defp verbose_cached_token_breakdown(%{token_counts: nil}), do: nil

  defp verbose_cached_token_breakdown(log) do
    total = total_token_count(log.token_counts)
    cached = log.token_counts.cached_input_tokens

    if cached && cached != 0 do
      [verbose_non_cached_tokens(total, cached), "#{format_integer(cached)} cached input"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")
    else
      nil
    end
  end

  defp verbose_non_cached_tokens(total, cached) when is_integer(total) and is_integer(cached),
    do: "#{format_integer(max(total - cached, 0))} non-cached"

  defp verbose_non_cached_tokens(_total, _cached), do: nil

  defp format_seconds(value) when rem(value, 1_000) == 0, do: "#{div(value, 1_000)}s"
  defp format_seconds(value), do: "#{Float.round(value / 1_000, 1)}s"

  defp format_compact_integer(value) when is_integer(value) do
    cond do
      abs(value) >= 1_000_000 ->
        "#{format_compact_scaled(value, 1_000_000)}m"

      abs(value) >= 1_000 ->
        "#{format_compact_scaled(value, 1_000)}k"

      true ->
        format_integer(value)
    end
  end

  defp format_cached_input_cost(%Decimal{} = usd),
    do: "Cached input cost $#{format_usd(usd)} is included in the total cost"

  defp format_cached_input_cost(_usd), do: nil

  defp compact_cached_input_cost(%Decimal{} = usd),
    do: "($#{format_usd(usd)} cached)"

  defp compact_cached_input_cost(_usd), do: nil

  defp format_compact_scaled(value, scale) do
    scaled = value / scale

    scaled
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp format_usd(%Decimal{} = usd) do
    usd
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
    |> fixed_decimal_places(2)
  end

  defp fixed_decimal_places(value, places) do
    case String.split(value, ".", parts: 2) do
      [whole] ->
        whole <> "." <> String.duplicate("0", places)

      [whole, fraction] ->
        whole <> "." <> (fraction |> String.pad_trailing(places, "0") |> String.slice(0, places))
    end
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
end
