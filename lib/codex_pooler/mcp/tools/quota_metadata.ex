defmodule CodexPooler.MCP.Tools.QuotaMetadata do
  @moduledoc """
  Metadata-only MCP tools for upstream quota summaries.
  """

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.MCP.Tools.DetailEnvelope
  alias CodexPooler.MCP.Tools.QuotaMetadata.ReadModel
  alias CodexPooler.MCP.Tools.ReadableText
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams

  @default_limit 50
  @max_limit 100
  @max_offset 10_000
  @max_candidates 10

  @status_values ~w(pending active paused refresh_due refreshing refresh_failed reauth_required deleted disabled errored)
  @freshness_status_values ~w(fresh stale unknown)
  @filter_names ~w(pool_id status plan_family freshness_status routing_usable)

  @read_only_annotations %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @list_input_schema %{
    "type" => "object",
    "properties" => %{
      "pool_id" => %{"type" => "string"},
      "status" => %{"type" => "string"},
      "plan_family" => %{"type" => "string"},
      "freshness_status" => %{"type" => "string"},
      "routing_usable" => %{"type" => "boolean"},
      "limit" => %{"type" => "integer"},
      "offset" => %{"type" => "integer"}
    },
    "required" => [],
    "additionalProperties" => false
  }

  @get_input_schema %{
    "type" => "object",
    "properties" => %{"selector" => %{"type" => "string"}},
    "required" => ["selector"],
    "additionalProperties" => false
  }

  @list_output_schema %{
    "type" => "object",
    "required" => ["items", "count", "limit", "offset", "filters"],
    "additionalProperties" => false,
    "properties" => %{
      "items" => %{"type" => "array"},
      "count" => %{"type" => "integer"},
      "limit" => %{"type" => "integer"},
      "offset" => %{"type" => "integer"},
      "filters" => %{"type" => "object"}
    }
  }

  @get_output_schema DetailEnvelope.output_schema()

  @spec tools() :: [map()]
  def tools do
    [list_upstream_quotas_tool(), get_upstream_quota_tool()]
  end

  @spec list_upstream_quotas(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_upstream_quotas(arguments, context) do
    with {:ok, scope} <- scope_from_context(context),
         {:ok, pools} <- load_pools(scope),
         {:ok, filters} <- list_filters(arguments, pools) do
      limit = limit_arg(arguments)
      offset = offset_arg(arguments)

      items =
        scope
        |> all_visible_accounts()
        |> Enum.map(&stringify_keys/1)
        |> apply_filters(filters)

      paged_items = items |> Enum.drop(offset) |> Enum.take(limit)

      structured = %{
        "items" => paged_items,
        "count" => length(items),
        "limit" => limit,
        "offset" => offset,
        "filters" => filter_summary(filters)
      }

      {:ok, structured, quota_list_text(structured)}
    end
  end

  @spec get_upstream_quota(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_upstream_quota(%{"selector" => selector}, context) do
    with {:ok, scope} <- scope_from_context(context) do
      accounts =
        scope
        |> all_visible_accounts()
        |> Enum.map(&stringify_keys/1)

      case resolve_account(accounts, selector) do
        {:ok, account} ->
          structured = DetailEnvelope.ok("upstream_quota", account)
          {:ok, structured, quota_detail_text(account)}

        {:ambiguous, candidates} ->
          candidates = candidates |> Enum.take(@max_candidates) |> Enum.map(&candidate/1)

          structured =
            DetailEnvelope.ambiguous(
              "upstream_quota",
              candidates,
              "Upstream quota selector is ambiguous"
            )

          {:ok, structured, quota_ambiguity_text(candidates)}

        :not_found ->
          structured =
            DetailEnvelope.not_found(
              "upstream_quota",
              "Upstream quota selector did not match"
            )

          {:ok, structured, ReadableText.not_found("upstream quota metadata record")}
      end
    end
  end

  def get_upstream_quota(_arguments, _context) do
    {:error, %{code: :tool_execution_failed, message: "MCP authenticated actor is unavailable"}}
  end

  defp list_upstream_quotas_tool do
    %{
      name: "codex_pooler_list_upstream_quotas",
      title: "List upstream quota metadata",
      description: """
      Use when an MCP client needs bounded discovery of sanitized quota evidence for upstream accounts visible to the authenticated operator.
      Returns sanitized upstream account summaries with quota summary and quota window evidence only.
      Never returns raw selectors, raw filter values, raw emails, auth.json, tokens, raw metadata, provider payloads, prompts, request bodies, headers, cookies, websocket frames, or raw idempotency keys.
      Filters/limits: accepts optional pool_id, status, plan_family, freshness_status, routing_usable, limit, and offset; limit is clamped to 1..100 and offset to 0..10000.
      """,
      input_schema: @list_input_schema,
      output_schema: @list_output_schema,
      annotations: @read_only_annotations,
      handler: {__MODULE__, :list_upstream_quotas}
    }
  end

  defp get_upstream_quota_tool do
    %{
      name: "codex_pooler_get_upstream_quota",
      title: "Get upstream quota metadata",
      description: """
      Use when an MCP client needs exact sanitized quota evidence for one visible upstream account.
      Returns one sanitized upstream account quota summary, a not-found marker, or structured ambiguity candidates when the selector matches multiple accounts.
      Never returns raw selectors, raw filter values, raw emails, auth.json, tokens, raw metadata, provider payloads, prompts, request bodies, headers, cookies, websocket frames, or raw idempotency keys.
      Filters/limits: selector is required; exact id and stored account id are preferred, label matches can be ambiguous, and ambiguity candidates are bounded to 10.
      """,
      input_schema: @get_input_schema,
      output_schema: @get_output_schema,
      annotations: @read_only_annotations,
      handler: {__MODULE__, :get_upstream_quota}
    }
  end

  defp scope_from_context(%{auth: %{scope: %Scope{} = scope}}), do: {:ok, scope}

  defp scope_from_context(%{auth: %{operator: operator}}), do: {:ok, Scope.for_user(operator)}

  defp scope_from_context(_context) do
    {:error, %{code: :tool_execution_failed, message: "MCP authenticated actor is unavailable"}}
  end

  defp load_pools(scope), do: {:ok, Pools.list_visible_pools(scope)}

  defp all_visible_accounts(scope) do
    scope
    |> visible_account_pages(0, [])
    |> Enum.reverse()
  end

  defp visible_account_pages(scope, offset, acc) do
    %{items: items, count: count} =
      ReadModel.list_accounts(scope, limit: @max_limit, offset: offset)

    acc = Enum.reverse(items) ++ acc
    next_offset = offset + @max_limit

    if next_offset >= count or items == [] do
      acc
    else
      visible_account_pages(scope, next_offset, acc)
    end
  end

  defp list_filters(arguments, pools) do
    with {:ok, status} <- enum_filter(arguments, "status", @status_values),
         {:ok, plan_family} <- plan_family_filter(arguments),
         {:ok, freshness_status} <-
           enum_filter(arguments, "freshness_status", @freshness_status_values),
         {:ok, routing_usable} <- boolean_filter(arguments, "routing_usable"),
         {:ok, pool_filter} <- pool_filter(arguments, pools) do
      {:ok,
       %{
         "pool_id" => pool_filter,
         "status" => status,
         "plan_family" => plan_family,
         "freshness_status" => freshness_status,
         "routing_usable" => routing_usable
       }
       |> reject_nil_values()}
    end
  end

  defp enum_filter(arguments, key, values) do
    case Map.get(arguments, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> enum_value(value, values, key)
      _value -> invalid_argument(key)
    end
  end

  defp enum_value(value, values, key) do
    if value in values, do: {:ok, value}, else: invalid_argument(key)
  end

  defp plan_family_filter(arguments) do
    case Map.get(arguments, "plan_family") do
      nil -> {:ok, nil}
      value when is_binary(value) -> trimmed_plan_family(value)
      _value -> invalid_argument("plan_family")
    end
  end

  defp trimmed_plan_family(value) do
    case String.trim(value) do
      "" -> invalid_argument("plan_family")
      trimmed -> {:ok, trimmed}
    end
  end

  defp boolean_filter(arguments, key) do
    case Map.get(arguments, key) do
      nil -> {:ok, nil}
      value when is_boolean(value) -> {:ok, value}
      _value -> invalid_argument(key)
    end
  end

  defp pool_filter(arguments, pools) do
    case string_filter(arguments, "pool_id") do
      nil ->
        {:ok, nil}

      pool_id ->
        case Enum.find(pools, &(&1.id == pool_id)) do
          %Pool{} = pool -> {:ok, {:visible_pool, pool.id}}
          nil -> {:ok, :not_visible_pool}
        end
    end
  end

  defp string_filter(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) -> blank_to_nil(value)
      _value -> nil
    end
  end

  defp invalid_argument(key),
    do: {:error, %{code: :invalid_arguments, message: "Invalid #{key}"}}

  defp reject_nil_values(filters) do
    filters
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp limit_arg(%{"limit" => limit}) when is_integer(limit),
    do: limit |> max(1) |> min(@max_limit)

  defp limit_arg(_arguments), do: @default_limit

  defp offset_arg(%{"offset" => offset}) when is_integer(offset),
    do: offset |> max(0) |> min(@max_offset)

  defp offset_arg(_arguments), do: 0

  defp apply_filters(items, filters) do
    Enum.filter(items, fn item ->
      Enum.all?(filters, fn
        {"pool_id", {:visible_pool, pool_id}} ->
          pool_assigned?(item["id"], pool_id)

        {"pool_id", :not_visible_pool} ->
          false

        {"status", status} ->
          item["status"] == status

        {"plan_family", plan_family} ->
          item["plan_family"] == plan_family

        {"freshness_status", freshness_status} ->
          get_in(item, ["quota_summary", "freshness_status"]) == freshness_status

        {"routing_usable", routing_usable} ->
          get_in(item, ["quota_summary", "routing_usable"]) == routing_usable
      end)
    end)
  end

  defp pool_assigned?(identity_id, pool_id) do
    case Upstreams.get_upstream_identity(identity_id) do
      nil ->
        false

      identity ->
        identity
        |> Upstreams.list_pool_assignments_for_identity()
        |> Enum.reject(&(&1.status == "deleted"))
        |> Enum.any?(&(&1.pool_id == pool_id))
    end
  end

  defp filter_summary(filters) do
    applied =
      filters
      |> Map.keys()
      |> Enum.filter(&(&1 in @filter_names))
      |> Enum.sort()

    %{"applied" => applied, "count" => length(applied)}
  end

  defp resolve_account(accounts, selector) do
    selector = normalize_selector(selector)

    cond do
      account = Enum.find(accounts, &(normalize_selector(&1["id"]) == selector)) ->
        {:ok, account}

      account = Enum.find(accounts, &(normalize_selector(&1["stored_account_id"]) == selector)) ->
        {:ok, account}

      true ->
        accounts
        |> Enum.filter(&(normalize_selector(&1["label"]) == selector))
        |> one_ambiguous_or_missing()
    end
  end

  defp one_ambiguous_or_missing([item]), do: {:ok, item}
  defp one_ambiguous_or_missing([]), do: :not_found
  defp one_ambiguous_or_missing(items), do: {:ambiguous, items}

  defp candidate(account) do
    Map.take(account, ["id", "label", "stored_account_id", "status", "plan_family"])
  end

  defp quota_list_text(%{"items" => []}),
    do: ReadableText.empty("upstream quota metadata records")

  defp quota_list_text(%{"items" => items, "count" => count, "offset" => offset}) do
    "#{min(length(items), 10)} upstream quota metadata records returned; total #{count}; offset #{offset}\n" <>
      (items |> Enum.take(10) |> Enum.map_join("\n", &account_text/1))
  end

  defp quota_detail_text(account),
    do: "1 upstream quota metadata record returned\n" <> account_text(account)

  defp quota_ambiguity_text(candidates) do
    ReadableText.ambiguous("upstream quota metadata record", candidates, [
      {"id", "id"},
      {"label", "label", required: true},
      {"stored_account_id", "account"},
      {"status", "status", required: true}
    ])
  end

  defp account_text(account) do
    header =
      "- account #{text_value(account["label"])} status #{text_value(account["status"])} account #{text_value(account["stored_account_id"])} plan #{text_value(account["plan_family"])}"

    quota_lines = Enum.map(account["quota_windows"] || [], &quota_line/1)

    Enum.join([header | quota_lines], "\n")
  end

  defp quota_line(window) do
    "  - #{text_value(window["quota_kind"])}: #{remaining_text(window)}, #{used_text(window)}, resets #{text_value(window["reset_at"])}, #{text_value(window["freshness_status"])}, #{routing_text(window)}"
  end

  defp remaining_text(%{"remaining_value" => remaining, "active_limit" => limit})
       when is_integer(remaining) and is_integer(limit),
       do: "#{remaining}/#{limit} remaining"

  defp remaining_text(%{"remaining_value" => remaining}) when is_integer(remaining),
    do: "#{remaining}/unknown remaining"

  defp remaining_text(_window), do: "unknown remaining"

  defp used_text(%{"used_percent" => percent}) when is_float(percent),
    do: "#{Float.to_string(percent)}% used"

  defp used_text(%{"used_percent" => percent}) when is_integer(percent), do: "#{percent}.0% used"
  defp used_text(_window), do: "unknown used"

  defp routing_text(%{"routing_usable" => true}), do: "routing usable"

  defp routing_text(%{"routing_usable" => false, "routing_unusable_reason" => reason}),
    do: "routing unusable #{text_value(reason)}"

  defp routing_text(_window), do: "routing unknown"

  defp text_value(value), do: ReadableText.scalar(value, required: true)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp normalize_selector(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_selector(_value), do: ""

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
