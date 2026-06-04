defmodule CodexPooler.MCP.Tools.PoolMetadata do
  @moduledoc """
  Metadata-only MCP tools for pools, upstreams, and Pool API keys.
  """

  alias CodexPooler.Access
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.MCP.PrivacyMatrix
  alias CodexPooler.MCP.Tools.DetailEnvelope
  alias CodexPooler.MCP.Tools.ReadableText
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @default_limit 25
  @max_limit 100

  @read_only_annotations %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @selector_schema %{
    "type" => "object",
    "properties" => %{
      "selector" => %{"type" => "string"}
    },
    "required" => ["selector"],
    "additionalProperties" => false
  }

  @list_schema %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string"},
      "status" => %{"type" => "string"},
      "pool_selector" => %{"type" => "string"},
      "limit" => %{"type" => "integer"}
    },
    "required" => [],
    "additionalProperties" => false
  }

  @list_output_schema %{
    "type" => "object",
    "required" => ["status", "count", "limit", "items"],
    "additionalProperties" => false,
    "properties" => %{
      "status" => %{"type" => "string"},
      "count" => %{"type" => "integer"},
      "limit" => %{"type" => "integer"},
      "items" => %{"type" => "array"}
    }
  }

  @get_output_schema DetailEnvelope.output_schema()

  @spec tools() :: [map()]
  def tools do
    [
      list_pools_tool(),
      get_pool_tool(),
      list_upstreams_tool(),
      get_upstream_tool(),
      list_pool_api_keys_tool(),
      get_pool_api_key_tool()
    ]
  end

  @spec list_pools(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_pools(arguments, context) do
    with {:ok, scope} <- scope_from_context(context),
         {:ok, pools} <- load_pools(scope) do
      limit = bounded_limit(arguments)

      items =
        pools
        |> filter_by_status(Map.get(arguments, "status"))
        |> filter_by_query(Map.get(arguments, "query"), &pool_search_text/1)
        |> Enum.take(limit)
        |> pool_items()

      structured = %{
        "status" => "ok",
        "count" => length(items),
        "limit" => limit,
        "items" => items
      }

      {:ok, structured, pool_list_text(items)}
    end
  end

  @spec get_pool(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_pool(%{"selector" => selector}, context) do
    with {:ok, scope} <- scope_from_context(context),
         {:ok, pools} <- load_pools(scope) do
      case resolve_pool(pools, selector) do
        {:ok, pool} ->
          item = pool_item(pool, pool_count_maps([pool]))
          structured = DetailEnvelope.ok("pool", item)
          {:ok, structured, pool_detail_text(item)}

        {:ambiguous, candidates} ->
          candidates = Enum.map(candidates, &pool_candidate/1)
          structured = DetailEnvelope.ambiguous("pool", candidates, "Pool selector is ambiguous")

          {:ok, structured, pool_ambiguity_text(candidates)}

        :not_found ->
          structured = DetailEnvelope.not_found("pool", "Pool selector did not match")
          {:ok, structured, ReadableText.not_found("Pool metadata record")}
      end
    end
  end

  @spec list_upstreams(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_upstreams(arguments, context) do
    with {:ok, scope} <- scope_from_context(context),
         {:ok, pools} <- load_pools(scope),
         {:ok, pool_filter} <- resolve_optional_pool(pools, Map.get(arguments, "pool_selector")) do
      limit = bounded_limit(arguments)
      pool_lookup = Map.new(pools, &{&1.id, &1})

      items =
        scope
        |> Upstreams.list_visible_upstream_identities()
        |> filter_upstreams_for_pool(pool_filter)
        |> filter_by_status(Map.get(arguments, "status"))
        |> filter_by_query(Map.get(arguments, "query"), &upstream_search_text/1)
        |> Enum.take(limit)
        |> Enum.map(&upstream_item(&1, pool_lookup))

      structured = %{
        "status" => "ok",
        "count" => length(items),
        "limit" => limit,
        "items" => items
      }

      {:ok, structured, upstream_list_text(items)}
    end
  end

  @spec get_upstream(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_upstream(%{"selector" => selector}, context) do
    with {:ok, scope} <- scope_from_context(context),
         {:ok, pools} <- load_pools(scope) do
      upstreams = Upstreams.list_visible_upstream_identities(scope)
      pool_lookup = Map.new(pools, &{&1.id, &1})

      case resolve_upstream(upstreams, selector) do
        {:ok, upstream} ->
          item = upstream_item(upstream, pool_lookup)
          structured = DetailEnvelope.ok("upstream", item)
          {:ok, structured, upstream_detail_text(item)}

        {:ambiguous, candidates} ->
          candidates = Enum.map(candidates, &upstream_candidate/1)

          structured =
            DetailEnvelope.ambiguous("upstream", candidates, "Upstream selector is ambiguous")

          {:ok, structured, upstream_ambiguity_text(candidates)}

        :not_found ->
          structured = DetailEnvelope.not_found("upstream", "Upstream selector did not match")
          {:ok, structured, ReadableText.not_found("upstream metadata record")}
      end
    end
  end

  @spec list_pool_api_keys(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_pool_api_keys(arguments, context) do
    with {:ok, scope} <- scope_from_context(context),
         {:ok, pools} <- load_pools(scope),
         {:ok, pool_filter} <- resolve_optional_pool(pools, Map.get(arguments, "pool_selector")),
         {:ok, api_keys_with_policy} <- Access.list_api_keys_with_policy(scope) do
      limit = bounded_limit(arguments)
      pool_lookup = Map.new(pools, &{&1.id, &1})

      items =
        api_keys_with_policy
        |> filter_api_keys_for_pool(pool_filter)
        |> filter_api_keys_by_status(Map.get(arguments, "status"))
        |> filter_by_query(Map.get(arguments, "query"), &api_key_search_text/1)
        |> Enum.take(limit)
        |> Enum.map(&api_key_item(&1, pool_lookup))

      structured = %{
        "status" => "ok",
        "count" => length(items),
        "limit" => limit,
        "items" => items
      }

      {:ok, structured, api_key_list_text(items)}
    end
  end

  @spec get_pool_api_key(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_pool_api_key(%{"selector" => selector}, context) do
    with {:ok, scope} <- scope_from_context(context),
         {:ok, pools} <- load_pools(scope),
         {:ok, api_keys_with_policy} <- Access.list_api_keys_with_policy(scope) do
      pool_lookup = Map.new(pools, &{&1.id, &1})

      case resolve_api_key(api_keys_with_policy, selector) do
        {:ok, api_key_with_policy} ->
          item = api_key_item(api_key_with_policy, pool_lookup)

          structured = DetailEnvelope.ok("pool_api_key", item)

          {:ok, structured, api_key_detail_text(item)}

        {:ambiguous, candidates} ->
          candidates = Enum.map(candidates, &api_key_candidate(&1, pool_lookup))

          structured =
            DetailEnvelope.ambiguous(
              "pool_api_key",
              candidates,
              "Pool API key selector is ambiguous"
            )

          {:ok, structured, api_key_ambiguity_text(candidates)}

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

  defp pool_list_text(items) do
    ReadableText.list(
      "Pool metadata records",
      Enum.map(items, &pool_text_row/1),
      pool_text_fields()
    )
  end

  defp pool_detail_text(item) do
    ReadableText.detail("Pool metadata record", pool_text_row(item), [
      {:id, "id"} | pool_text_fields()
    ])
  end

  defp pool_ambiguity_text(candidates) do
    ReadableText.ambiguous("Pool metadata record", candidates, [
      {:id, "id"},
      {:slug, "slug", required: true},
      {:name, "name", required: true},
      {:status, "status", required: true}
    ])
  end

  defp pool_text_fields do
    [
      {:name, "name", required: true},
      {:slug, "slug", required: true},
      {:status, "status", required: true},
      {:upstream_count, "upstreams", required: true},
      {:api_key_count, "api_keys", required: true},
      {:routing, "routing", required: true}
    ]
  end

  defp pool_text_row(item) do
    item
    |> Map.take(["id", "name", "slug", "status", "upstream_count", "api_key_count"])
    |> Map.put("routing", summary_text(item, "routing_summary"))
  end

  defp upstream_list_text(items) do
    ReadableText.list(
      "upstream metadata records",
      Enum.map(items, &upstream_text_row/1),
      upstream_text_fields()
    )
  end

  defp upstream_detail_text(item) do
    ReadableText.detail("upstream metadata record", upstream_text_row(item), [
      {:id, "id"} | upstream_text_fields()
    ])
  end

  defp upstream_ambiguity_text(candidates) do
    ReadableText.ambiguous("upstream metadata record", candidates, [
      {:id, "id"},
      {:account_label, "label", required: true},
      {:workspace_ref, "workspace", required: true},
      {:workspace_label, "workspace_label"},
      {:status, "status", required: true}
    ])
  end

  defp upstream_text_fields do
    [
      {:account_label, "label", required: true},
      {:status, "status", required: true},
      {:account, "account", required: true},
      {:workspace, "workspace", required: true},
      {:plan, "plan", required: true},
      {:assignments, "assignments", required: true}
    ]
  end

  defp upstream_text_row(item) do
    item
    |> Map.take(["id", "account_label", "status"])
    |> Map.put("account", Map.get(item, "account_email") || Map.get(item, "chatgpt_account_id"))
    |> Map.put("workspace", Map.get(item, "workspace_label") || Map.get(item, "workspace_ref"))
    |> Map.put("plan", Map.get(item, "plan_label") || Map.get(item, "plan_family"))
    |> Map.put("assignments", summary_text(item, "assignment_summary"))
  end

  defp api_key_list_text(items) do
    ReadableText.list(
      "Pool API key metadata records",
      Enum.map(items, &api_key_text_row/1),
      api_key_text_fields()
    )
  end

  defp api_key_detail_text(item) do
    ReadableText.detail("Pool API key metadata record", api_key_text_row(item), [
      {:id, "id"} | api_key_text_fields()
    ])
  end

  defp api_key_ambiguity_text(candidates) do
    ReadableText.ambiguous("Pool API key metadata record", candidates, [
      {:id, "id"},
      {:display_name, "name", required: true},
      {:key_prefix, "prefix", required: true},
      {:pool_slug, "pool"},
      {:status, "status", required: true}
    ])
  end

  defp api_key_text_fields do
    [
      {:display_name, "name", required: true},
      {:status, "status", required: true},
      {:prefix, "prefix", required: true},
      {:pool, "pool", required: true},
      {:policy, "policy", required: true},
      {:usage, "usage", required: true}
    ]
  end

  defp api_key_text_row(item) do
    item
    |> Map.take(["id", "display_name", "status"])
    |> Map.put("prefix", Map.get(item, "api_key_prefix") || Map.get(item, "key_prefix"))
    |> Map.put("pool", Map.get(item, "pool_slug") || Map.get(item, "pool_name"))
    |> Map.put("policy", summary_text(item, "policy_summary"))
    |> Map.put("usage", summary_text(item, "usage_summary"))
  end

  defp summary_text(item, key) do
    case Map.get(item, key) do
      %{"summary" => summary} -> summary
      _other -> nil
    end
  end

  defp list_pools_tool do
    %{
      name: "codex_pooler_list_pools",
      title: "List Pools",
      description: """
      Use when an MCP client needs bounded Pool metadata discovery.
      Returns sanitized Pool records with status, routing summary, upstream counts, and Pool API-key counts.
      Never returns raw Pool API keys, key hashes, MCP tokens, token prefixes, setup snippets, credentials, headers, cookies, prompts, request bodies, upstream secret material, or raw domain structs.
      Filters/limits: accepts optional query, status, and limit; limit is capped at #{@max_limit} records.
      """,
      input_schema: @list_schema,
      output_schema: @list_output_schema,
      annotations: @read_only_annotations,
      handler: {__MODULE__, :list_pools}
    }
  end

  defp get_pool_tool do
    %{
      name: "codex_pooler_get_pool",
      title: "Get Pool",
      description: """
      Use when an MCP client needs one Pool metadata record by id, slug, or name.
      Returns one sanitized Pool record or structured ambiguity candidates when the selector matches multiple records.
      Never returns raw Pool API keys, key hashes, MCP tokens, token prefixes, setup snippets, credentials, headers, cookies, prompts, request bodies, upstream secret material, or raw domain structs.
      Filters/limits: requires selector; exact id and slug are preferred, while duplicate names return ambiguity candidates.
      """,
      input_schema: @selector_schema,
      output_schema: @get_output_schema,
      annotations: @read_only_annotations,
      handler: {__MODULE__, :get_pool}
    }
  end

  defp list_upstreams_tool do
    %{
      name: "codex_pooler_list_upstreams",
      title: "List upstreams",
      description: """
      Use when an MCP client needs bounded upstream account metadata discovery.
      Returns sanitized upstream identity records with masked account emails and assignment summaries.
      Never returns raw Pool API keys, key hashes, auth.json, access tokens, refresh tokens, MCP tokens, token prefixes, setup snippets, credentials, headers, cookies, prompts, request bodies, upstream secret material, or raw domain structs.
      Filters/limits: accepts optional query, status, pool_selector, and limit; limit is capped at #{@max_limit} records.
      """,
      input_schema: @list_schema,
      output_schema: @list_output_schema,
      annotations: @read_only_annotations,
      handler: {__MODULE__, :list_upstreams}
    }
  end

  defp get_upstream_tool do
    %{
      name: "codex_pooler_get_upstream",
      title: "Get upstream",
      description: """
      Use when an MCP client needs one upstream account metadata record by id, stored account id, or label.
      Returns one sanitized upstream identity record or structured ambiguity candidates when the selector matches multiple records.
      Never returns raw Pool API keys, key hashes, auth.json, access tokens, refresh tokens, MCP tokens, token prefixes, setup snippets, credentials, headers, cookies, prompts, request bodies, upstream secret material, or raw domain structs.
      Filters/limits: requires selector; exact id and stored account id are preferred, while duplicate labels return ambiguity candidates.
      """,
      input_schema: @selector_schema,
      output_schema: @get_output_schema,
      annotations: @read_only_annotations,
      handler: {__MODULE__, :get_upstream}
    }
  end

  defp list_pool_api_keys_tool do
    %{
      name: "codex_pooler_list_pool_api_keys",
      title: "List Pool API keys",
      description: """
      Use when an MCP client needs bounded Pool API key metadata discovery. Pool API keys, not MCP tokens.
      Returns sanitized Pool API key records with Pool labels, status, prefixes, policy summaries, and usage summaries only.
      Never returns raw Pool API keys, key hashes, MCP tokens, MCP token prefixes, setup snippets, credentials, headers, cookies, prompts, request bodies, upstream secret material, or raw domain structs.
      Filters/limits: accepts optional query, status, pool_selector, and limit; limit is capped at #{@max_limit} records.
      """,
      input_schema: @list_schema,
      output_schema: @list_output_schema,
      annotations: @read_only_annotations,
      handler: {__MODULE__, :list_pool_api_keys}
    }
  end

  defp get_pool_api_key_tool do
    %{
      name: "codex_pooler_get_pool_api_key",
      title: "Get Pool API key",
      description: """
      Use when an MCP client needs one Pool API key metadata record by id, Pool API-key prefix, or display name. Pool API keys, not MCP tokens.
      Returns one sanitized Pool API key record or structured ambiguity candidates when the selector matches multiple records.
      Never returns raw Pool API keys, key hashes, MCP tokens, MCP token prefixes, setup snippets, credentials, headers, cookies, prompts, request bodies, upstream secret material, or raw domain structs.
      Filters/limits: requires selector; exact id and Pool API-key prefix are preferred, while duplicate display names return ambiguity candidates.
      """,
      input_schema: @selector_schema,
      output_schema: @get_output_schema,
      annotations: @read_only_annotations,
      handler: {__MODULE__, :get_pool_api_key}
    }
  end

  defp scope_from_context(%{auth: %{scope: %Scope{} = scope}}), do: {:ok, scope}

  defp scope_from_context(%{auth: %{operator: operator}}), do: {:ok, Scope.for_user(operator)}

  defp scope_from_context(_context) do
    {:error, %{code: :tool_execution_failed, message: "MCP authenticated actor is unavailable"}}
  end

  defp load_pools(scope), do: {:ok, Pools.list_visible_pools(scope)}

  defp resolve_optional_pool(_pools, selector) when selector in [nil, ""], do: {:ok, nil}

  defp resolve_optional_pool(pools, selector) do
    case resolve_pool(pools, selector) do
      {:ok, pool} ->
        {:ok, pool}

      {:ambiguous, candidates} ->
        {:error, ambiguity_error("Pool selector matched #{length(candidates)} candidates")}

      :not_found ->
        {:error, %{code: :tool_execution_failed, message: "Pool selector did not match"}}
    end
  end

  defp pool_items(pools) do
    count_maps = pool_count_maps(pools)
    Enum.map(pools, &pool_item(&1, count_maps))
  end

  defp pool_item(%Pool{} = pool, %{api_keys: api_key_counts, upstreams: upstream_counts}) do
    presenter =
      pool_presenter(pool, %{
        api_key_count: Map.get(api_key_counts, pool.id, 0),
        upstream_count: Map.get(upstream_counts, pool.id, 0)
      })

    :pools
    |> PrivacyMatrix.project!(presenter)
    |> stringify_keys()
  end

  defp pool_count_maps(pools) do
    pool_ids = Enum.map(pools, & &1.id)

    %{
      api_keys: Access.count_api_keys_by_pool_ids(pool_ids),
      upstreams: Upstreams.count_pool_assignments_by_pool_ids(pool_ids)
    }
  end

  defp pool_presenter(pool, counts) do
    %{
      id: pool.id,
      slug: pool.slug,
      name: pool.name,
      status: pool.status,
      created_at: timestamp(pool.created_at),
      updated_at: timestamp(pool.updated_at),
      disabled_at: timestamp(pool.disabled_at),
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

  defp upstream_item(%UpstreamIdentity{} = identity, pool_lookup) do
    presenter = upstream_presenter(identity, pool_lookup)

    :upstreams
    |> PrivacyMatrix.project!(presenter)
    |> stringify_keys()
  end

  defp upstream_presenter(identity, pool_lookup) do
    assignments = visible_assignments_for_identity(identity, pool_lookup)
    active_count = Enum.count(assignments, &(&1.status == "active"))

    %{
      id: identity.id,
      chatgpt_account_id: identity.chatgpt_account_id,
      account_label: safe_label(identity.account_label),
      account_email: identity.account_email,
      workspace_ref: workspace_ref(identity.workspace_id),
      workspace_label: safe_label(identity.workspace_label),
      onboarding_method: identity.onboarding_method,
      status: identity.status,
      plan_family: identity.plan_family,
      plan_label: identity.plan_label,
      auth_fresh_at: timestamp(identity.auth_fresh_at),
      auth_verified_at: timestamp(identity.auth_verified_at),
      headers_profile_version: identity.headers_profile_version,
      last_successful_refresh_at: timestamp(identity.last_successful_refresh_at),
      last_successful_sync_at: timestamp(identity.last_successful_sync_at),
      disabled_at: timestamp(identity.disabled_at),
      created_by_user_id: identity.created_by_user_id,
      created_at: timestamp(identity.created_at),
      updated_at: timestamp(identity.updated_at),
      assignment_summary: %{
        count: length(assignments),
        status: identity.status,
        summary: "#{active_count} active of #{length(assignments)} Pool assignments"
      },
      metadata: %{status: metadata_status(identity.metadata), summary: "metadata keys omitted"}
    }
  end

  defp visible_assignments_for_identity(identity, pool_lookup) do
    visible_pool_ids = pool_lookup |> Map.keys() |> MapSet.new()

    identity
    |> Upstreams.list_pool_assignments_for_identity()
    |> Enum.reject(&(&1.status == "deleted"))
    |> Enum.filter(&MapSet.member?(visible_pool_ids, &1.pool_id))
  end

  defp api_key_item(%{api_key: api_key, policy: policy, policy_bindings: bindings}, pool_lookup) do
    pool = Map.get(pool_lookup, api_key.pool_id)

    presenter = api_key_presenter(api_key, policy, bindings, pool)

    :pool_api_keys
    |> PrivacyMatrix.project!(presenter)
    |> stringify_keys()
  end

  defp api_key_presenter(api_key, policy, bindings, pool) do
    %{
      id: api_key.id,
      pool_id: api_key.pool_id,
      pool_name: pool && pool.name,
      pool_slug: pool && pool.slug,
      display_name: safe_label(api_key.display_name),
      key_prefix: api_key.key_prefix,
      api_key_prefix: api_key.key_prefix,
      status: api_key.status,
      expires_at: timestamp(api_key.expires_at),
      last_used_at: timestamp(api_key.last_used_at),
      allowed_model_identifiers: api_key.allowed_model_identifiers,
      enforced_model_identifier: api_key.enforced_model_identifier,
      enforced_reasoning_effort: api_key.enforced_reasoning_effort,
      enforced_service_tier: api_key.enforced_service_tier,
      created_by_user_id: api_key.created_by_user_id,
      created_at: timestamp(api_key.created_at),
      revoked_at: timestamp(api_key.revoked_at),
      metadata: %{status: metadata_status(api_key.metadata), summary: "metadata keys omitted"},
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

  defp resolve_pool(pools, selector) do
    selector = normalize_selector(selector)

    cond do
      pool = Enum.find(pools, &(&1.id == selector)) ->
        {:ok, pool}

      pool = Enum.find(pools, &(String.downcase(&1.slug || "") == selector)) ->
        {:ok, pool}

      true ->
        pools
        |> Enum.filter(&(String.downcase(&1.name || "") == selector))
        |> one_ambiguous_or_missing()
    end
  end

  defp resolve_upstream(upstreams, selector) do
    selector = normalize_selector(selector)

    account_matches =
      Enum.filter(upstreams, &(String.downcase(&1.chatgpt_account_id || "") == selector))

    cond do
      upstream = Enum.find(upstreams, &(&1.id == selector)) ->
        {:ok, upstream}

      account_matches != [] ->
        one_ambiguous_or_missing(account_matches)

      true ->
        upstreams
        |> Enum.filter(&(String.downcase(&1.account_label || "") == selector))
        |> one_ambiguous_or_missing()
    end
  end

  defp resolve_api_key(api_keys_with_policy, selector) do
    selector = normalize_selector(selector)

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
        |> one_ambiguous_or_missing()
    end
  end

  defp one_ambiguous_or_missing([item]), do: {:ok, item}
  defp one_ambiguous_or_missing([]), do: :not_found
  defp one_ambiguous_or_missing(items), do: {:ambiguous, items}

  defp pool_candidate(pool) do
    %{
      "id" => pool.id,
      "slug" => pool.slug,
      "name" => pool.name,
      "status" => pool.status
    }
  end

  defp upstream_candidate(identity) do
    %{
      "id" => identity.id,
      "account_label" => safe_label(identity.account_label),
      "workspace_ref" => workspace_ref(identity.workspace_id),
      "workspace_label" => safe_label(identity.workspace_label),
      "status" => identity.status
    }
  end

  defp api_key_candidate(%{api_key: api_key}, pool_lookup) do
    pool = Map.get(pool_lookup, api_key.pool_id)

    %{
      "id" => api_key.id,
      "pool_id" => api_key.pool_id,
      "pool_slug" => pool && pool.slug,
      "display_name" => safe_label(api_key.display_name),
      "key_prefix" => api_key.key_prefix,
      "status" => api_key.status
    }
  end

  defp filter_api_keys_for_pool(api_keys, nil), do: api_keys

  defp filter_api_keys_for_pool(api_keys, %Pool{id: pool_id}) do
    Enum.filter(api_keys, &(&1.api_key.pool_id == pool_id))
  end

  defp filter_api_keys_by_status(items, status) when status in [nil, "", "all"], do: items

  defp filter_api_keys_by_status(items, status) do
    normalized = normalize_selector(status)
    Enum.filter(items, &(String.downcase(&1.api_key.status || "") == normalized))
  end

  defp filter_upstreams_for_pool(upstreams, nil), do: upstreams

  defp filter_upstreams_for_pool(upstreams, %Pool{id: pool_id}) do
    upstream_ids =
      pool_id
      |> Upstreams.list_pool_assignments()
      |> Enum.reject(&(&1.status == "deleted"))
      |> MapSet.new(& &1.upstream_identity_id)

    Enum.filter(upstreams, &MapSet.member?(upstream_ids, &1.id))
  end

  defp filter_by_status(items, status) when status in [nil, "", "all"], do: items

  defp filter_by_status(items, status) do
    normalized = normalize_selector(status)
    Enum.filter(items, &(String.downcase(Map.get(&1, :status, "")) == normalized))
  end

  defp filter_by_query(items, query, _search_fun) when query in [nil, ""], do: items

  defp filter_by_query(items, query, search_fun) do
    normalized = normalize_selector(query)
    Enum.filter(items, &(search_fun.(&1) |> String.contains?(normalized)))
  end

  defp pool_search_text(pool), do: searchable([pool.id, pool.slug, pool.name, pool.status])

  defp upstream_search_text(identity) do
    searchable([
      identity.id,
      identity.chatgpt_account_id,
      identity.account_label,
      identity.workspace_label,
      workspace_ref(identity.workspace_id),
      identity.status
    ])
  end

  defp api_key_search_text(%{api_key: api_key}) do
    searchable([api_key.id, api_key.display_name, api_key.key_prefix, api_key.status])
  end

  defp searchable(parts) do
    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
  end

  defp bounded_limit(%{"limit" => limit}) when is_integer(limit) do
    limit |> max(1) |> min(@max_limit)
  end

  defp bounded_limit(_arguments), do: @default_limit

  defp normalize_selector(selector),
    do: selector |> to_string() |> String.trim() |> String.downcase()

  defp workspace_ref(nil), do: "legacy"

  defp workspace_ref(workspace_id) when is_binary(workspace_id) do
    digest =
      :crypto.hash(:sha256, workspace_id) |> Base.encode16(case: :lower) |> String.slice(0, 8)

    "ws:" <> digest
  end

  defp workspace_ref(_workspace_id), do: "legacy"

  defp metadata_status(metadata) when is_map(metadata) and map_size(metadata) > 0, do: "present"
  defp metadata_status(_metadata), do: "empty"

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(_value), do: nil

  defp safe_label(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/) do
      PrivacyMatrix.project!(:operators, %{email: value})[:email]
    else
      value
    end
  end

  defp safe_label(value), do: value

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp ambiguity_error(message), do: %{code: :tool_execution_failed, message: message}
end
