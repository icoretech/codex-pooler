defmodule CodexPooler.MCP.Tools.PoolMetadata.ApiKeys do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.MCP.PrivacyMatrix
  alias CodexPooler.MCP.ToolRegistry
  alias CodexPooler.MCP.Tools.DetailEnvelope
  alias CodexPooler.MCP.Tools.PoolMetadata.Common
  alias CodexPooler.MCP.Tools.ReadableText
  alias CodexPooler.Pools.Pool

  @spec tools() :: [map()]
  def tools, do: [list_tool(), get_tool()]

  @spec list_pool_api_keys(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_pool_api_keys(arguments, context) do
    with {:ok, scope} <- Common.scope_from_context(context),
         {:ok, pools} <- Common.load_pools(scope),
         {:ok, pool_filter} <-
           Common.resolve_optional_pool(pools, Map.get(arguments, "pool_selector")),
         {:ok, api_keys_with_policy} <- Access.list_api_keys_with_policy(scope) do
      limit = Common.bounded_limit(arguments)
      pool_lookup = Map.new(pools, &{&1.id, &1})

      items =
        api_keys_with_policy
        |> filter_for_pool(pool_filter)
        |> filter_by_status(Map.get(arguments, "status"))
        |> Common.filter_by_query(Map.get(arguments, "query"), &search_text/1)
        |> Enum.take(limit)
        |> Enum.map(&item(&1, pool_lookup))

      structured = %{
        "status" => "ok",
        "count" => length(items),
        "limit" => limit,
        "items" => items
      }

      {:ok, structured, list_text(items)}
    end
  end

  @spec get_pool_api_key(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_pool_api_key(%{"selector" => selector}, context) when is_binary(selector) do
    with {:ok, scope} <- Common.scope_from_context(context),
         {:ok, pools} <- Common.load_pools(scope),
         {:ok, api_keys_with_policy} <- Access.list_api_keys_with_policy(scope) do
      pool_lookup = Map.new(pools, &{&1.id, &1})

      case resolve(api_keys_with_policy, selector) do
        {:ok, api_key_with_policy} ->
          api_key_item = item(api_key_with_policy, pool_lookup)

          structured = DetailEnvelope.ok("pool_api_key", api_key_item)

          {:ok, structured, detail_text(api_key_item)}

        {:ambiguous, candidates} ->
          candidates = Enum.map(candidates, &candidate(&1, pool_lookup))

          structured =
            DetailEnvelope.ambiguous(
              "pool_api_key",
              candidates,
              "Pool API key selector is ambiguous"
            )

          {:ok, structured, ambiguity_text(candidates)}

        :not_found ->
          structured =
            DetailEnvelope.not_found(
              "pool_api_key",
              "Pool API key selector did not match"
            )

          {:ok, structured, ReadableText.not_found("Pool API key metadata record")}
      end
    end
  end

  def get_pool_api_key(_arguments, _context), do: Common.required_argument("selector")

  @spec item(map(), map()) :: map()
  def item(%{api_key: api_key, policy: policy, policy_bindings: bindings}, pool_lookup) do
    pool = Map.get(pool_lookup, api_key.pool_id)

    presenter = presenter(api_key, policy, bindings, pool)

    :pool_api_keys
    |> PrivacyMatrix.project!(presenter)
    |> Common.stringify_keys()
  end

  @spec candidate(map(), map()) :: map()
  def candidate(%{api_key: api_key}, pool_lookup) do
    pool = Map.get(pool_lookup, api_key.pool_id)

    %{
      "id" => api_key.id,
      "pool_id" => api_key.pool_id,
      "pool_slug" => pool && pool.slug,
      "display_name" => Common.safe_label(api_key.display_name),
      "key_prefix" => api_key.key_prefix,
      "status" => api_key.status
    }
  end

  defp presenter(api_key, policy, bindings, pool) do
    %{
      id: api_key.id,
      pool_id: api_key.pool_id,
      pool_name: pool && pool.name,
      pool_slug: pool && pool.slug,
      display_name: Common.safe_label(api_key.display_name),
      key_prefix: api_key.key_prefix,
      api_key_prefix: api_key.key_prefix,
      status: api_key.status,
      expires_at: Common.timestamp(api_key.expires_at),
      last_used_at: Common.timestamp(api_key.last_used_at),
      allowed_model_identifiers: api_key.allowed_model_identifiers,
      enforced_model_identifier: api_key.enforced_model_identifier,
      enforced_reasoning_effort: api_key.enforced_reasoning_effort,
      enforced_service_tier: api_key.enforced_service_tier,
      created_by_user_id: api_key.created_by_user_id,
      created_at: Common.timestamp(api_key.created_at),
      revoked_at: Common.timestamp(api_key.revoked_at),
      metadata: %{
        status: Common.metadata_status(api_key.metadata),
        summary: "metadata keys omitted"
      },
      policy_summary: policy_summary(policy, bindings),
      usage_summary: usage_summary(api_key)
    }
  end

  defp policy_summary(policy, bindings) do
    model_mode = policy.model_mode |> to_string() |> String.replace("_", " ")

    %{
      count: length(bindings),
      status: model_mode,
      summary: "#{model_mode}; #{length(bindings)} active policy bindings"
    }
  end

  defp usage_summary(api_key) do
    %{
      count: if(api_key.last_used_at, do: 1, else: 0),
      status: if(api_key.last_used_at, do: "used", else: "unused"),
      summary: "last-used metadata only"
    }
  end

  defp resolve(api_keys_with_policy, selector) do
    selector = Common.normalize_selector(selector)

    cond do
      match = Enum.find(api_keys_with_policy, &(&1.api_key.id == selector)) ->
        {:ok, match}

      match =
          Enum.find(
            api_keys_with_policy,
            &(String.downcase(&1.api_key.key_prefix || "") == selector)
          ) ->
        {:ok, match}

      true ->
        api_keys_with_policy
        |> Enum.filter(&(String.downcase(&1.api_key.display_name || "") == selector))
        |> Common.one_ambiguous_or_missing()
    end
  end

  defp filter_for_pool(api_keys, nil), do: api_keys

  defp filter_for_pool(api_keys, %Pool{id: pool_id}) do
    Enum.filter(api_keys, &(&1.api_key.pool_id == pool_id))
  end

  defp filter_by_status(items, status) when status in [nil, "", "all"], do: items

  defp filter_by_status(items, status) do
    normalized = Common.normalize_selector(status)
    Enum.filter(items, &(String.downcase(&1.api_key.status || "") == normalized))
  end

  defp search_text(%{api_key: api_key}) do
    Common.searchable([api_key.id, api_key.display_name, api_key.key_prefix, api_key.status])
  end

  defp list_text(items) do
    ReadableText.list(
      "Pool API key metadata records",
      Enum.map(items, &text_row/1),
      text_fields()
    )
  end

  defp detail_text(item) do
    ReadableText.detail("Pool API key metadata record", text_row(item), [
      {:id, "id"} | text_fields()
    ])
  end

  defp ambiguity_text(candidates) do
    ReadableText.ambiguous("Pool API key metadata record", candidates, [
      {:id, "id"},
      {:display_name, "name", required: true},
      {:key_prefix, "prefix", required: true},
      {:pool_slug, "pool"},
      {:status, "status", required: true}
    ])
  end

  defp text_fields do
    [
      {:display_name, "name", required: true},
      {:status, "status", required: true},
      {:prefix, "prefix", required: true},
      {:pool, "pool", required: true},
      {:policy, "policy", required: true},
      {:usage, "usage", required: true}
    ]
  end

  defp text_row(item) do
    item
    |> Map.take(["id", "display_name", "status"])
    |> Map.put("prefix", Map.get(item, "api_key_prefix") || Map.get(item, "key_prefix"))
    |> Map.put("pool", Map.get(item, "pool_slug") || Map.get(item, "pool_name"))
    |> Map.put("policy", Common.summary_text(item, "policy_summary"))
    |> Map.put("usage", Common.summary_text(item, "usage_summary"))
  end

  defp list_tool do
    %{
      name: "codex_pooler_list_pool_api_keys",
      title: "List Pool API keys",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an MCP client needs bounded Pool API key metadata discovery. Pool API keys, not MCP tokens",
          returns:
            "sanitized Pool API key records with Pool labels, status, prefixes, policy summaries, and usage summaries only",
          never_returns: "raw Pool API keys, key hashes, MCP token prefixes, or setup snippets",
          filters_limits:
            "accepts optional query, status, pool_selector, and limit; limit is capped at #{Common.max_limit()} records"
        ),
      input_schema: Common.list_schema(),
      output_schema: Common.list_output_schema(),
      annotations: Common.read_only_annotations(),
      handler: {__MODULE__, :list_pool_api_keys}
    }
  end

  defp get_tool do
    %{
      name: "codex_pooler_get_pool_api_key",
      title: "Get Pool API key",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an MCP client needs one Pool API key metadata record by id, Pool API-key prefix, or display name. Pool API keys, not MCP tokens",
          returns:
            "one sanitized Pool API key record or structured ambiguity candidates when the selector matches multiple records",
          never_returns: "raw Pool API keys, key hashes, MCP token prefixes, or setup snippets",
          filters_limits:
            "requires selector; exact id and Pool API-key prefix are preferred, while duplicate display names return ambiguity candidates"
        ),
      input_schema: Common.selector_schema(),
      output_schema: Common.get_output_schema(),
      annotations: Common.read_only_annotations(),
      handler: {__MODULE__, :get_pool_api_key}
    }
  end
end
