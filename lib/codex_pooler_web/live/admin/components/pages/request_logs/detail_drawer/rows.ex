defmodule CodexPoolerWeb.Admin.RequestLogDetailDrawer.Rows do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import CodexPoolerWeb.Admin.RequestLogsDisplay,
    only: [
      format_advised_reset: 2,
      format_api_key: 1,
      format_datetime: 2,
      format_token_counts: 1,
      format_transport_route: 1,
      format_upstream_account_label: 1,
      format_usage_cost: 1,
      model_default_reasoning?: 1,
      protocol_label: 1,
      reasoning_endpoint?: 1,
      status_label: 1
    ]

  alias CodexPooler.ServiceTier
  alias CodexPoolerWeb.Admin.RequestLogsDisplay.Status

  @serving_mode_configured_key "model_serving_mode_configured"
  @serving_mode_effective_key "model_serving_mode"
  @serving_mode_source_key "model_serving_mode_source"

  @type detail_row :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:value) => term(),
          required(:mono) => boolean(),
          optional(:role) => String.t()
        }

  @spec final_outcome_rows(map(), map()) :: [detail_row()]
  def final_outcome_rows(log, datetime_preferences) do
    [
      detail("request-log-detail-request-id", gettext("Request id"), log.id, mono: true),
      detail("request-log-detail-correlation-id", gettext("Correlation id"), log.correlation_id, mono: true),
      detail("request-log-detail-status", gettext("Status"), status_detail(log)),
      detail("request-log-detail-status-meaning", gettext("Status meaning"), Status.status_description(Map.get(log, :display_status) || log.status)),
      detail("request-log-detail-endpoint", gettext("Endpoint"), log.endpoint, mono: true),
      detail("request-log-detail-model", gettext("Model"), log.requested_model),
      model_rows(log),
      reasoning_detail(
        "request-log-detail-requested-reasoning",
        gettext("Requested reasoning"),
        log.reasoning_effort,
        reasoning_endpoint?(log) && gettext("Not set")
      ),
      reasoning_detail(
        "request-log-detail-applied-reasoning",
        gettext("Applied reasoning"),
        log.applied_reasoning_effort,
        model_default_reasoning?(log) && gettext("Not set")
      ),
      reasoning_detail(
        "request-log-detail-upstream-reasoning",
        gettext("Upstream reasoning"),
        log.effective_reasoning_effort,
        model_default_reasoning?(log) && gettext("Not sent (backend model default)")
      ),
      service_tier_rows(log),
      price_bucket_rows(log),
      detail("request-log-detail-transport", gettext("Transport"), protocol_label(log.transport)),
      detail("request-log-detail-response-status", gettext("Response status"), log.response_status_code),
      detail("request-log-detail-error-code", gettext("Error code"), log.denial_reason, mono: true),
      detail(
        "request-log-detail-advised-reset",
        gettext("Advised retry"),
        format_advised_reset(Map.get(log, :errors), datetime_preferences),
        mono: true
      ),
      detail("request-log-detail-retry-count", gettext("Retries"), log.retry_count),
      detail(
        "request-log-detail-admitted-at",
        gettext("Admitted"),
        format_datetime(log.admitted_at, datetime_preferences),
        mono: true
      ),
      detail(
        "request-log-detail-completed-at",
        gettext("Completed"),
        format_datetime(log.completed_at, datetime_preferences),
        mono: true
      )
    ]
    |> List.flatten()
    |> present_rows()
  end

  # `Model` is what the client asked for. The latest attempt also records the
  # model the Pooler sent upstream and the one the provider declared on its
  # response object; they differ when the provider substitutes a model.
  defp model_rows(log) do
    sent = Map.get(log, :upstream_model)
    served = Map.get(log, :served_model)

    if blank?(sent) and blank?(served) do
      []
    else
      [
        detail("request-log-detail-upstream-model", gettext("Sent upstream"), sent),
        detail("request-log-detail-served-model", gettext("Upstream served"), served)
      ]
    end
  end

  # The ChatGPT Codex backend reports `default` for `priority` requests and
  # accounting prices the reported tier, so the three facts stay on separate
  # rows. "Priced as" only appears once a priced settlement names the tier.
  defp service_tier_rows(log) do
    requested = ServiceTier.canonicalize(Map.get(log, :requested_service_tier))
    reported = ServiceTier.canonicalize(Map.get(log, :actual_service_tier))
    priced = priced_service_tier(log)

    if Enum.all?([requested, reported, priced], &is_nil/1) do
      []
    else
      [
        detail(
          "request-log-detail-requested-tier",
          gettext("Requested tier"),
          requested || gettext("Not set"),
          mono: !is_nil(requested)
        ),
        detail("request-log-detail-upstream-reported-tier", gettext("Upstream reported"), reported, mono: true),
        detail("request-log-detail-priced-tier", gettext("Priced as"), priced, mono: true)
      ]
    end
  end

  defp priced_service_tier(%{cost: %{pricing_availability: "priced"}} = log),
    do: ServiceTier.canonicalize(Map.get(log, :service_tier))

  defp priced_service_tier(_log), do: nil

  # Settlement reports the bucket a turn was charged at, so an ordinary turn
  # and a long-context turn that found no long-context snapshot both read
  # `default`. Pricing resolution records the substitution it made; this row
  # exists only when it made one, and names the requested bucket beside the
  # one that was priced.
  defp price_bucket_rows(log) do
    case Map.get(metadata_section(log, "pricing"), "price_bucket_fallback") do
      %{"requested" => requested, "selected" => selected}
      when is_binary(requested) and is_binary(selected) ->
        [
          detail(
            "request-log-detail-price-bucket",
            gettext("Price bucket"),
            gettext("%{selected} (%{requested} requested)", selected: selected, requested: requested),
            mono: true
          )
        ]

      _no_fallback ->
        []
    end
  end

  @spec routing_rows(map()) :: [detail_row()]
  def routing_rows(log) do
    routing = metadata_section(log, "routing")

    rows = [
      detail("request-log-detail-pool", gettext("Pool"), log.pool_name),
      detail(
        "request-log-detail-upstream",
        gettext("Upstream account"),
        format_upstream_account_label(log)
      ),
      detail("request-log-detail-assignment", gettext("Assignment"), log.assignment_label),
      detail("request-log-detail-api-key", gettext("API key"), format_api_key(log)),
      detail("request-log-detail-route", gettext("Route"), format_transport_route(log), mono: true),
      detail("request-log-detail-route-class", gettext("Route class"), Map.get(routing, "route_class"), mono: true),
      detail("request-log-detail-routing-strategy", gettext("Strategy"), Map.get(routing, "strategy"), mono: true),
      detail(
        "request-log-detail-selected-rank",
        gettext("Selected rank"),
        Map.get(routing, "selected_bridge_candidate_rank")
      ),
      detail(
        "request-log-detail-candidate-exclusions",
        gettext("Candidate exclusions"),
        list_count(log.metadata["candidate_exclusions"])
      )
    ]

    (rows ++ serving_mode_rows("request-log-detail", routing)) |> present_rows()
  end

  @spec serving_mode_rows(String.t(), map() | nil) :: [detail_row()]
  def serving_mode_rows(prefix, snapshot) do
    case valid_serving_mode_snapshot(snapshot) do
      %{configured_mode: configured_mode, effective_mode: effective_mode, source: source} ->
        [
          detail(
            "#{prefix}-model-serving-mode-configured",
            gettext("Configured serving mode"),
            configured_mode,
            mono: true
          ),
          detail(
            "#{prefix}-model-serving-mode",
            gettext("Effective serving mode"),
            effective_mode,
            mono: true
          ),
          detail(
            "#{prefix}-model-serving-mode-source",
            gettext("Serving mode source"),
            source,
            mono: true
          )
        ]

      nil ->
        []
    end
  end

  @spec usage_rows(map()) :: [detail_row()]
  def usage_rows(log) do
    [
      detail("request-log-detail-token-counts", gettext("Tokens"), format_token_counts(log.token_counts)),
      detail("request-log-detail-cost", gettext("Cost"), format_usage_cost(log.cost)),
      context_pricing_rows(Map.get(log, :context_pricing)),
      detail(
        "request-log-detail-usage-status",
        gettext("Measured usage"),
        measured_usage(log.usage_status)
      ),
      detail(
        "request-log-detail-usage-observation",
        gettext("Usage observation"),
        metadata_section(log, "usage_observation")["classification"],
        mono: true
      ),
      detail(
        "request-log-detail-pricing-status",
        gettext("Pricing availability"),
        pricing_availability(cost_field(log.cost, :pricing_availability))
      ),
      detail(
        "request-log-detail-input-tokens",
        gettext("Input tokens"),
        token_field(log.token_counts, :input_tokens)
      ),
      detail(
        "request-log-detail-output-tokens",
        gettext("Output tokens"),
        token_field(log.token_counts, :output_tokens)
      ),
      detail(
        "request-log-detail-cached-input",
        gettext("Cached input"),
        token_field(log.token_counts, :cached_input_tokens)
      ),
      detail(
        "request-log-detail-cache-write-tokens",
        gettext("Cache write tokens"),
        cache_write_token_count(log.token_counts),
        role: "cache-write-tokens"
      ),
      detail(
        "request-log-detail-cache-write-cost",
        gettext("Cache write cost"),
        format_cache_write_cost(log.token_counts),
        role: "cache-write-cost"
      ),
      detail(
        "request-log-detail-reasoning-tokens",
        gettext("Reasoning tokens"),
        token_field(log.token_counts, :reasoning_tokens)
      )
    ]
    |> List.flatten()
    |> present_rows()
  end

  defp context_pricing_rows(nil), do: []

  defp context_pricing_rows(facts) do
    [
      detail("request-log-detail-billing-cutoff", gettext("API pricing cutoff"), context_cutoff(facts)),
      detail("request-log-detail-pricing-rule", gettext("Pricing rule"), context_rule(facts)),
      detail("request-log-detail-pricing-version", gettext("Pricing version"), context_version(facts.generation), mono: true),
      detail("request-log-detail-pricing-explanation", gettext("Reporting basis"), gettext("Reporting estimate from published API prices; not a subscription charge."))
    ]
  end

  defp context_cutoff(%{status: status, long_context_input_tokens_gt: cutoff}) when status in ~w(known legacy) and is_integer(cutoff),
    do: ngettext("%{count} input token; long context above cutoff", "%{count} input tokens; long context above cutoff", cutoff, count: cutoff)

  defp context_cutoff(%{status: "uniform"}), do: gettext("No cutoff (uniform pricing)")
  defp context_cutoff(_facts), do: gettext("Unavailable")

  defp context_rule(facts) do
    basis =
      case facts.basis do
        "catalog" -> gettext("Catalog")
        "legacy_assumption" -> gettext("Legacy assumption")
        _other -> gettext("Unavailable")
      end

    [basis, facts.status, facts.reason] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  defp context_version(generation) do
    [generation.price_version || gettext("Not recorded"), generation.model_identifier, generation.service_tier, generation.importer_format_revision && gettext("importer %{revision}", revision: generation.importer_format_revision)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp measured_usage("usage_known"), do: gettext("Available")
  defp measured_usage(_status), do: gettext("Unavailable — no measured usage recorded")

  defp pricing_availability("priced"), do: gettext("Available")
  defp pricing_availability(nil), do: gettext("Unavailable")
  defp pricing_availability(status), do: gettext("Unavailable (%{status})", status: status)

  @spec compaction_bridge_rows(map()) :: [detail_row()]
  def compaction_bridge_rows(%{
        compaction_bridge: %{applied: true, result_transport: result_transport}
      })
      when result_transport in ["buffered", "sse"] do
    [
      detail("request-log-detail-compaction-bridge-applied", gettext("Compaction bridge"), gettext("applied")),
      detail(
        "request-log-detail-compaction-result-transport",
        gettext("Compaction result transport"),
        result_transport,
        mono: true
      )
    ]
  end

  def compaction_bridge_rows(_log), do: []

  defp cache_write_token_count(%{cache_write_tokens: value}) when is_integer(value),
    do: ngettext("%{count} cache write", "%{count} cache write", value, count: value)

  defp cache_write_token_count(_counts), do: nil

  defp format_cache_write_cost(%{cache_write_cost_usd: %Decimal{} = value}),
    do: "$#{Decimal.to_string(Decimal.round(value, 2), :normal)}"

  defp format_cache_write_cost(_counts), do: nil

  @spec continuity_rows(map(), map()) :: [detail_row()]
  def continuity_rows(log, datetime_preferences) do
    debug = log.debug || %{}
    continuity = Map.get(debug, :continuity, %{})
    failure = Map.get(debug, :failure, %{})
    terminal = Map.get(debug, :terminal_state, %{})
    turn = Map.get(debug, :turn, %{})
    attempt = Map.get(debug, :attempt, %{})

    [
      detail("request-log-detail-continuity-status", gettext("Continuity"), continuity[:status], mono: true),
      detail("request-log-detail-session-ref", gettext("Session ref"), continuity[:session_ref], mono: true),
      detail("request-log-detail-turn-ref", gettext("Turn ref"), continuity[:turn_ref] || turn[:turn_ref], mono: true),
      detail(
        "request-log-detail-turn-status",
        gettext("Turn status"),
        continuity[:turn_status] || turn[:status],
        mono: true
      ),
      detail(
        "request-log-detail-final-attempt-ref",
        gettext("Final attempt ref"),
        turn[:final_attempt_ref],
        mono: true
      ),
      detail("request-log-detail-failure-source", gettext("Failure source"), failure[:error_source], mono: true),
      detail("request-log-detail-debug-error", gettext("Debug error"), failure[:error_code], mono: true),
      detail("request-log-detail-terminal-state", gettext("Terminal state"), terminal[:state], mono: true),
      detail("request-log-detail-terminal-mismatch", gettext("Terminal mismatch"), terminal[:mismatch]),
      detail("request-log-detail-attempt-count", gettext("Attempt count"), attempt[:attempt_count]),
      detail(
        "request-log-detail-latest-attempt",
        gettext("Latest attempt"),
        attempt[:latest_attempt_number]
      ),
      detail(
        "request-log-detail-turn-completed-at",
        gettext("Turn completed"),
        format_debug_timestamp(turn[:completed_at], datetime_preferences),
        mono: true
      )
    ]
    |> present_rows()
  end

  @spec sanitized_metadata_rows(map()) :: [detail_row()]
  def sanitized_metadata_rows(log) do
    quota = metadata_section(log, "quota_decision")
    file = metadata_section(log, "file")

    [
      detail("request-log-detail-quota-summary", gettext("Quota summary"), Map.get(quota, "summary")),
      detail(
        "request-log-detail-operation",
        gettext("Operation"),
        Map.get(log.metadata || %{}, "operation"),
        mono: true
      ),
      detail("request-log-detail-file-status", gettext("File status"), Map.get(file, "status"), mono: true)
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

  # The requested effort comes from the request row, so its absence is known on
  # any reasoning endpoint. Applied and upstream come from the attempt snapshot,
  # which a legacy or unfinished attempt may lack; those rows only claim "not
  # set" and "not sent" when the list row claims the model default too.
  defp reasoning_detail(id, label, effort, placeholder) do
    if blank?(effort) do
      detail(id, label, placeholder || nil)
    else
      detail(id, label, effort, mono: true)
    end
  end

  defp detail(id, label, value, opts \\ []) do
    %{
      id: id,
      label: label,
      value: value,
      mono: Keyword.get(opts, :mono, false),
      role: Keyword.get(opts, :role, "request-log-detail-field")
    }
  end

  defp valid_serving_mode_snapshot(%{
         configured_mode: configured_mode,
         effective_mode: effective_mode,
         source: source
       }) do
    valid_serving_mode_snapshot(configured_mode, effective_mode, source)
  end

  defp valid_serving_mode_snapshot(%{
         @serving_mode_configured_key => configured_mode,
         @serving_mode_effective_key => effective_mode,
         @serving_mode_source_key => source
       }) do
    valid_serving_mode_snapshot(configured_mode, effective_mode, source)
  end

  defp valid_serving_mode_snapshot(_snapshot), do: nil

  defp valid_serving_mode_snapshot("auto", effective_mode, "catalog")
       when effective_mode in ~w(lite full) do
    %{configured_mode: "auto", effective_mode: effective_mode, source: "catalog"}
  end

  defp valid_serving_mode_snapshot(mode, mode, "override") when mode in ~w(lite full) do
    %{configured_mode: mode, effective_mode: mode, source: "override"}
  end

  defp valid_serving_mode_snapshot(_configured_mode, _effective_mode, _source), do: nil

  defp present_rows(rows), do: Enum.reject(rows, &(blank?(&1.value) or &1.value == "-"))

  defp token_field(nil, _key), do: nil
  defp token_field(counts, key), do: Map.get(counts, key)

  defp cost_field(nil, _key), do: nil
  defp cost_field(cost, key), do: Map.get(cost, key)

  defp list_count(value) when is_list(value), do: length(value)
  defp list_count(_value), do: nil

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

  # A client cancellation shows its class and the status it was recorded with.
  defp status_detail(%{display_status: "client_cancelled"} = log),
    do: gettext("%{status} (recorded as %{recorded})", status: status_label("client_cancelled"), recorded: String.downcase(status_label(log.status || "unknown")))

  defp status_detail(log), do: status_label(log.status || "unknown")
end
