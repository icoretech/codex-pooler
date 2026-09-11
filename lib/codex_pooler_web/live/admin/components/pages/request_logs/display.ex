defmodule CodexPoolerWeb.Admin.RequestLogsDisplay do
  @moduledoc false

  alias CodexPooler.ServiceTier
  alias CodexPoolerWeb.Admin.Format
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

  @doc """
  `:fast` when the request was priced at the priority tier, so the bolt never
  claims priority for a request that only asked for it. Rows that recorded no
  tier at all fall back to the legacy fast-mode request metadata.
  """
  def speed_tier_mode(%{cost: %{pricing_availability: "priced"}, service_tier: tier})
      when is_binary(tier) do
    if fast_service_tier?(tier), do: :fast
  end

  def speed_tier_mode(log) when is_map(log), do: speed_tier_mode_unpriced(log)

  def speed_tier_mode(_log), do: nil

  # Rows without a priced settlement have no billed tier yet, so the bolt
  # mirrors the pricing rule instead.
  defp speed_tier_mode_unpriced(log) do
    case pricing_basis_tier(log) do
      nil -> if fast_metadata?(Map.get(log, :metadata)), do: :fast
      tier -> if fast_service_tier?(tier), do: :fast
    end
  end

  def speed_tier_label(:fast), do: "Priced at priority tier"

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
      :fast -> "#{transport_label}; fast mode"
      nil -> transport_label
    end
  end

  @protocol_chip_base "inline-flex h-4.5 shrink-0 items-center whitespace-nowrap rounded-full border px-2 text-[10px] font-semibold uppercase leading-none tracking-[0.04em]"

  def protocol_badge_class("websocket"),
    do: "#{@protocol_chip_base} border-info/20 bg-info/10 text-info"

  def protocol_badge_class("http_sse"),
    do: "#{@protocol_chip_base} border-success/20 bg-success/10 text-success"

  def protocol_badge_class("http_multipart"),
    do: "#{@protocol_chip_base} border-warning/20 bg-warning/10 text-warning"

  def protocol_badge_class("http_json"),
    do: "#{@protocol_chip_base} border-primary/20 bg-primary/10 text-primary"

  def protocol_badge_class(_transport),
    do: "#{@protocol_chip_base} border-base-300 bg-base-200 text-base-content/60"

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
      total when is_integer(total) -> "#{Format.token_count(total)} tokens"
      _total -> "-"
    end
  end

  def total_token_count(%{total_tokens: total}) when is_integer(total), do: total
  def total_token_count(_counts), do: nil

  # The row sits under a "Tokens" header, so the word would be printed once per
  # record to say what the column already says. The drawer keeps it, since there
  # the value stands next to a label instead of a column.
  def format_token_totals(request_log) do
    case total_token_count(request_log.token_counts) do
      total when is_integer(total) -> Format.token_count(total)
      _total -> "-"
    end
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

  def format_usage_cost(%{status: "priced", usd: %Decimal{} = usd}),
    do: Format.money_precise(usd)

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

  def compression_savings_line(%{payload_compression: compression})
      when is_map(compression) do
    with "tokens" <- Map.get(compression, :unit),
         saved when is_integer(saved) <- Map.get(compression, :saved_count),
         percent when is_number(percent) <- Map.get(compression, :savings_percent),
         ratio when is_number(ratio) <- Map.get(compression, :compression_ratio),
         true <- saved > 0 and ratio < 1 do
      "#{format_compression_count(saved)} (#{format_percent(percent)})"
    else
      _value -> nil
    end
  end

  def compression_savings_line(_log), do: nil

  def compression_savings_title(%{payload_compression: compression})
      when is_map(compression) do
    [
      compression_title_part("status", Map.get(compression, :status)),
      compression_title_part("reason", Map.get(compression, :reason)),
      compression_count_title_part("candidates", Map.get(compression, :candidate_count)),
      compression_count_title_part("compressed", Map.get(compression, :compressed_count)),
      compression_count_title_part("skipped", Map.get(compression, :skipped_count)),
      compression_count_title_part(
        "tokenizer input skipped",
        Map.get(compression, :tokenizer_input_skipped_count)
      ),
      "percent is measured against rewritten tool-output candidates, not total request tokens"
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "; ")
    end
  end

  def compression_savings_title(_log), do: nil

  def compression_savings_unit(%{payload_compression: %{unit: unit}})
      when unit in ["tokens", "bytes"],
      do: unit

  def compression_savings_unit(_log), do: nil

  def compression_savings_status(%{payload_compression: %{status: status}})
      when is_binary(status) and status != "",
      do: status

  def compression_savings_status(_log), do: nil

  def compression_savings_reason(%{payload_compression: %{reason: reason}})
      when is_binary(reason) and reason != "",
      do: reason

  def compression_savings_reason(_log), do: nil

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
    reasoning = format_model_reasoning_slot(log)

    [
      format_model_name(log),
      reasoning,
      format_requested_reasoning_detail(log),
      service_tier_phrase(format_model_service_tier(log), reasoning),
      format_requested_tier_detail(log)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  What the row prints in the effort slot: the recorded effort, the model-default
  token when nothing was sent, or nothing when the request has no reasoning
  concept or the outcome cannot say.
  """
  def format_model_reasoning_slot(log) do
    cond do
      reasoning = format_model_reasoning(log) -> reasoning
      model_default_reasoning?(log) -> "model default"
      true -> nil
    end
  end

  @doc """
  True when a Responses-family request reached an upstream, succeeded, and no
  effort was recorded at any stage — the client sent none and no key policy
  injected one — so the backend chose the model's own default.

  Only a succeeded request qualifies: attempts gain their reasoning snapshot when
  an upstream response is processed, so a failed or in-flight row without one
  cannot tell "nothing sent" apart from "not recorded yet".
  """
  def model_default_reasoning?(log) when is_map(log) do
    is_nil(format_model_reasoning(log)) and Map.get(log, :status) == "succeeded" and
      reasoning_endpoint?(log) and dispatched_upstream?(log)
  end

  def model_default_reasoning?(_log), do: false

  @reasoning_endpoint_suffixes ["/responses", "/responses/compact", "/chat/completions"]

  @doc """
  Endpoints whose payload carries a reasoning effort: Responses, its compact
  variant, and chat completions, on both the backend and `/v1` surfaces.
  """
  def reasoning_endpoint?(%{endpoint: endpoint}) when is_binary(endpoint),
    do: String.ends_with?(endpoint, @reasoning_endpoint_suffixes)

  def reasoning_endpoint?(_log), do: false

  def format_model_reasoning(log) do
    [
      Map.get(log, :effective_reasoning_effort),
      Map.get(log, :applied_reasoning_effort),
      Map.get(log, :reasoning_effort)
    ]
    |> Enum.find_value(&present_string/1)
  end

  def format_requested_reasoning_detail(log) do
    requested = present_string(Map.get(log, :reasoning_effort))
    displayed = format_model_reasoning(log)

    if is_binary(requested) and requested != displayed do
      "requested: #{requested}"
    else
      nil
    end
  end

  def format_model_service_tier(log) do
    case effective_service_tier(log) do
      tier when is_binary(tier) -> if(blank?(tier), do: nil, else: tier)
      _tier -> nil
    end
  end

  @doc """
  The requested tier, when it differs from the tier the row prints. The ChatGPT
  Codex backend reports `default` for `priority` requests, so this is what keeps
  "tier default" from hiding that priority was asked for.
  """
  def format_requested_tier_detail(log) do
    requested = ServiceTier.canonicalize(Map.get(log, :requested_service_tier))

    if requested && !same_service_tier?(requested, format_model_service_tier(log)) do
      "#{requested} requested"
    end
  end

  def format_cached_token_breakdown(%{token_counts: nil}), do: nil

  def format_cached_token_breakdown(log) do
    cached = log.token_counts.cached_input_tokens

    if cached && cached != 0 do
      "#{Format.token_count(cached)} cached"
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

  @doc """
  Source endpoint for requests translated from an OpenAI-compatible surface,
  e.g. "/v1/chat/completions".
  """
  def translated_origin(%{metadata: metadata}) when is_map(metadata) do
    case nested_metadata_value(metadata, "openai_compatibility", "source_endpoint") do
      endpoint when is_binary(endpoint) -> endpoint
      _endpoint -> nil
    end
  end

  def translated_origin(_log), do: nil

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

  defp fast_service_tier?(tier), do: ServiceTier.fast_mode?(tier)

  # Mirrors how accounting picks the tier it prices: the upstream-reported tier
  # unless it is absent or `auto`, then the requested tier, then the effective
  # column for rows that recorded neither.
  defp pricing_basis_tier(log) do
    reported = ServiceTier.canonicalize(Map.get(log, :actual_service_tier))
    requested = ServiceTier.canonicalize(Map.get(log, :requested_service_tier))

    cond do
      reported not in [nil, "auto"] -> reported
      requested -> requested
      reported -> reported
      true -> ServiceTier.canonicalize(Map.get(log, :service_tier))
    end
  end

  # `default` is the provider's name for the tier that pricing calls `standard`.
  defp same_service_tier?(left, right), do: comparable_tier(left) == comparable_tier(right)

  defp comparable_tier(tier) do
    case ServiceTier.canonicalize(tier) do
      "standard" -> "default"
      canonical -> canonical
    end
  end

  defp fast_metadata?(%{} = metadata) do
    truthy?(Map.get(metadata, "fast_mode")) or Map.get(metadata, "codex_mode") == "fast" or
      nested_metadata_value(metadata, "codex", "mode") == "fast" or
      nested_metadata_value(metadata, "request", "mode") == "fast"
  end

  defp fast_metadata?(_metadata), do: false

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp token_part(_label, nil), do: nil
  defp token_part(_label, 0), do: nil

  defp token_part(label, value) when is_integer(value),
    do: "#{Format.token_count(value)} #{label}"

  defp token_part(_label, _value), do: nil

  defp format_cost(%{status: "priced", usd: %Decimal{} = usd}) do
    Format.money(usd)
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

  # "tier" keeps the value from reading as an effort; the slash only separates
  # it from an effort token, so a row without one does not open on a dangle.
  defp service_tier_phrase(nil, _reasoning), do: nil
  defp service_tier_phrase(tier, nil), do: "tier #{tier}"
  defp service_tier_phrase(tier, _reasoning), do: "/ tier #{tier}"

  defp dispatched_upstream?(log) do
    present_string(Map.get(log, :upstream_identity_id)) != nil or
      present_string(Map.get(log, :pool_upstream_assignment_id)) != nil
  end

  defp endpoint_model?(model), do: String.starts_with?(String.trim(model), "/")

  defp route_class(%{metadata: metadata}) when is_map(metadata),
    do: nested_metadata_value(metadata, "routing", "route_class")

  defp route_class(_log), do: nil

  defp request_content_type(%{metadata: metadata}) when is_map(metadata),
    do: nested_metadata_value(metadata, "request", "content_type")

  defp request_content_type(_log), do: nil

  defp request_body_size(%{metadata: metadata}) when is_map(metadata) do
    case nested_metadata_value(metadata, "request", "body_bytes") do
      bytes when is_integer(bytes) and bytes >= 0 -> "#{format_integer(bytes)} bytes"
      _bytes -> nil
    end
  end

  defp request_body_size(_log), do: nil

  defp nested_metadata_value(%{} = metadata, key, nested_key) do
    case Map.get(metadata, key) do
      %{} = nested_metadata -> Map.get(nested_metadata, nested_key)
      _value -> nil
    end
  end

  defp verbose_cached_token_breakdown(%{token_counts: nil}), do: nil

  defp verbose_cached_token_breakdown(log) do
    total = total_token_count(log.token_counts)
    cached = log.token_counts.cached_input_tokens

    if cached && cached != 0 do
      [verbose_non_cached_tokens(total, cached), "#{Format.token_count(cached)} cached input"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")
    else
      nil
    end
  end

  defp verbose_non_cached_tokens(total, cached) when is_integer(total) and is_integer(cached),
    do: "#{Format.token_count(max(total - cached, 0))} non-cached"

  defp verbose_non_cached_tokens(_total, _cached), do: nil

  defp format_seconds(value) when rem(value, 1_000) == 0, do: "#{div(value, 1_000)}s"
  defp format_seconds(value), do: "#{Float.round(value / 1_000, 1)}s"

  defp format_cached_input_cost(%Decimal{} = usd),
    do: "Cached input cost #{Format.money(usd)} is included in the total cost"

  defp format_cached_input_cost(_usd), do: nil

  defp compact_cached_input_cost(%Decimal{} = usd),
    do: "(#{Format.money(usd)} cached)"

  defp compact_cached_input_cost(_usd), do: nil

  defp format_compression_count(saved), do: Format.token_count(saved)

  defp format_percent(percent), do: "#{format_decimal(percent)}%"

  defp format_decimal(value) when is_integer(value), do: Integer.to_string(value)

  defp format_decimal(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 4)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp compression_title_part(_label, nil), do: nil
  defp compression_title_part(label, value), do: "#{label}: #{value}"

  defp compression_count_title_part(_label, nil), do: nil
  defp compression_count_title_part(label, value), do: "#{label}: #{Format.integer(value)}"

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
end
