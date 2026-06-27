defmodule CodexPooler.MCP.Tools.PoolMetadata.Pools do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.MCP.PrivacyMatrix
  alias CodexPooler.MCP.ToolRegistry
  alias CodexPooler.MCP.Tools.DetailEnvelope
  alias CodexPooler.MCP.Tools.PoolMetadata.Common
  alias CodexPooler.MCP.Tools.ReadableText
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams

  @spec tools() :: [map()]
  def tools, do: [list_tool(), get_tool()]

  @spec list_pools(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_pools(arguments, context) do
    with {:ok, scope} <- Common.scope_from_context(context),
         {:ok, pools} <- Common.load_pools(scope) do
      limit = Common.bounded_limit(arguments)

      items =
        pools
        |> Common.filter_by_status(Map.get(arguments, "status"))
        |> Common.filter_by_query(Map.get(arguments, "query"), &pool_search_text/1)
        |> Enum.take(limit)
        |> pool_items()

      structured = %{
        "status" => "ok",
        "count" => length(items),
        "limit" => limit,
        "items" => items
      }

      {:ok, structured, list_text(items)}
    end
  end

  @spec get_pool(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_pool(%{"selector" => selector}, context) when is_binary(selector) do
    with {:ok, scope} <- Common.scope_from_context(context),
         {:ok, pools} <- Common.load_pools(scope) do
      case Common.resolve_pool(pools, selector) do
        {:ok, pool} ->
          item = item(pool, count_maps([pool]))
          structured = DetailEnvelope.ok("pool", item)
          {:ok, structured, detail_text(item)}

        {:ambiguous, candidates} ->
          candidates = Enum.map(candidates, &candidate/1)
          structured = DetailEnvelope.ambiguous("pool", candidates, "Pool selector is ambiguous")

          {:ok, structured, ambiguity_text(candidates)}

        :not_found ->
          structured = DetailEnvelope.not_found("pool", "Pool selector did not match")
          {:ok, structured, ReadableText.not_found("Pool metadata record")}
      end
    end
  end

  def get_pool(_arguments, _context), do: Common.required_argument("selector")

  @spec item(Pool.t(), map()) :: map()
  def item(%Pool{} = pool, %{api_keys: api_key_counts, upstreams: upstream_counts}) do
    presenter =
      presenter(pool, %{
        api_key_count: Map.get(api_key_counts, pool.id, 0),
        upstream_count: Map.get(upstream_counts, pool.id, 0)
      })

    :pools
    |> PrivacyMatrix.project!(presenter)
    |> Common.stringify_keys()
  end

  @spec count_maps([Pool.t()]) :: map()
  def count_maps(pools) do
    pool_ids = Enum.map(pools, & &1.id)

    %{
      api_keys: Access.count_api_keys_by_pool_ids(pool_ids),
      upstreams: Upstreams.count_pool_assignments_by_pool_ids(pool_ids)
    }
  end

  @spec candidate(Pool.t()) :: map()
  def candidate(pool) do
    %{
      "id" => pool.id,
      "slug" => pool.slug,
      "name" => pool.name,
      "status" => pool.status
    }
  end

  defp pool_items(pools) do
    count_maps = count_maps(pools)
    Enum.map(pools, &item(&1, count_maps))
  end

  defp presenter(pool, counts) do
    %{
      id: pool.id,
      slug: pool.slug,
      name: pool.name,
      status: pool.status,
      created_at: Common.timestamp(pool.created_at),
      updated_at: Common.timestamp(pool.updated_at),
      disabled_at: Common.timestamp(pool.disabled_at),
      created_by_user_id: pool.created_by_user_id,
      api_key_count: counts.api_key_count,
      upstream_count: counts.upstream_count,
      request_summary: %{count: 0, status: "not_loaded", summary: "request metrics omitted"},
      routing_summary: %{status: pool.status, summary: routing_summary(pool)}
    }
  end

  defp routing_summary(pool) do
    case Pools.get_routing_settings(pool) do
      nil -> "routing settings unavailable"
      settings -> "strategy #{settings.routing_strategy}"
    end
  end

  defp list_text(items) do
    ReadableText.list(
      "Pool metadata records",
      Enum.map(items, &text_row/1),
      text_fields()
    )
  end

  defp detail_text(item) do
    ReadableText.detail("Pool metadata record", text_row(item), [
      {:id, "id"} | text_fields()
    ])
  end

  defp ambiguity_text(candidates) do
    ReadableText.ambiguous("Pool metadata record", candidates, [
      {:id, "id"},
      {:slug, "slug", required: true},
      {:name, "name", required: true},
      {:status, "status", required: true}
    ])
  end

  defp text_fields do
    [
      {:name, "name", required: true},
      {:slug, "slug", required: true},
      {:status, "status", required: true},
      {:upstream_count, "upstreams", required: true},
      {:api_key_count, "api_keys", required: true},
      {:routing, "routing", required: true}
    ]
  end

  defp text_row(item) do
    item
    |> Map.take(["id", "name", "slug", "status", "upstream_count", "api_key_count"])
    |> Map.put("routing", Common.summary_text(item, "routing_summary"))
  end

  defp pool_search_text(pool), do: Common.searchable([pool.id, pool.slug, pool.name, pool.status])

  defp list_tool do
    %{
      name: "codex_pooler_list_pools",
      title: "List Pools",
      description:
        ToolRegistry.metadata_description(
          use_when: "an MCP client needs bounded Pool metadata discovery",
          returns:
            "sanitized Pool records with status, routing summary, upstream counts, and Pool API-key counts",
          never_returns: "raw Pool API keys, key hashes, MCP token prefixes, or setup snippets",
          filters_limits:
            "accepts optional query, status, and limit; limit is capped at #{Common.max_limit()} records"
        ),
      input_schema: Common.list_schema(),
      output_schema: Common.list_output_schema(),
      annotations: Common.read_only_annotations(),
      handler: {__MODULE__, :list_pools}
    }
  end

  defp get_tool do
    %{
      name: "codex_pooler_get_pool",
      title: "Get Pool",
      description:
        ToolRegistry.metadata_description(
          use_when: "an MCP client needs one Pool metadata record by id, slug, or name",
          returns:
            "one sanitized Pool record or structured ambiguity candidates when the selector matches multiple records",
          never_returns: "raw Pool API keys, key hashes, MCP token prefixes, or setup snippets",
          filters_limits:
            "requires selector; exact id and slug are preferred, while duplicate names return ambiguity candidates"
        ),
      input_schema: Common.selector_schema(),
      output_schema: Common.get_output_schema(),
      annotations: Common.read_only_annotations(),
      handler: {__MODULE__, :get_pool}
    }
  end
end
