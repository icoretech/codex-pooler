defmodule CodexPooler.MCP.Tools.PoolMetadata.Upstreams do
  @moduledoc false

  alias CodexPooler.MCP.PrivacyMatrix
  alias CodexPooler.MCP.ToolRegistry
  alias CodexPooler.MCP.Tools.DetailEnvelope
  alias CodexPooler.MCP.Tools.PoolMetadata.Common
  alias CodexPooler.MCP.Tools.ReadableText
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @spec tools() :: [map()]
  def tools, do: [list_tool(), get_tool()]

  @spec list_upstreams(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_upstreams(arguments, context) do
    with {:ok, scope} <- Common.scope_from_context(context),
         {:ok, pools} <- Common.load_pools(scope),
         {:ok, pool_filter} <-
           Common.resolve_optional_pool(pools, Map.get(arguments, "pool_selector")) do
      limit = Common.bounded_limit(arguments)
      pool_lookup = Map.new(pools, &{&1.id, &1})

      items =
        scope
        |> Upstreams.list_visible_upstream_identities()
        |> filter_for_pool(pool_filter)
        |> Common.filter_by_status(Map.get(arguments, "status"))
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

  @spec get_upstream(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_upstream(%{"selector" => selector}, context) when is_binary(selector) do
    with {:ok, scope} <- Common.scope_from_context(context),
         {:ok, pools} <- Common.load_pools(scope) do
      upstreams = Upstreams.list_visible_upstream_identities(scope)
      pool_lookup = Map.new(pools, &{&1.id, &1})

      case resolve(upstreams, selector) do
        {:ok, upstream} ->
          upstream_item = item(upstream, pool_lookup)
          structured = DetailEnvelope.ok("upstream", upstream_item)
          {:ok, structured, detail_text(upstream_item)}

        {:ambiguous, candidates} ->
          candidates = Enum.map(candidates, &candidate/1)

          structured =
            DetailEnvelope.ambiguous("upstream", candidates, "Upstream selector is ambiguous")

          {:ok, structured, ambiguity_text(candidates)}

        :not_found ->
          structured = DetailEnvelope.not_found("upstream", "Upstream selector did not match")
          {:ok, structured, ReadableText.not_found("upstream metadata record")}
      end
    end
  end

  def get_upstream(_arguments, _context), do: Common.required_argument("selector")

  @spec item(UpstreamIdentity.t(), map()) :: map()
  def item(%UpstreamIdentity{} = identity, pool_lookup) do
    presenter = presenter(identity, pool_lookup)

    :upstreams
    |> PrivacyMatrix.project!(presenter)
    |> Common.stringify_keys()
  end

  @spec candidate(UpstreamIdentity.t()) :: map()
  def candidate(identity) do
    %{
      "id" => identity.id,
      "account_label" => Common.safe_label(identity.account_label),
      "workspace_ref" => Common.workspace_ref(identity.workspace_id),
      "workspace_label" => Common.safe_label(identity.workspace_label),
      "status" => identity.status
    }
  end

  defp presenter(identity, pool_lookup) do
    assignments = visible_assignments_for_identity(identity, pool_lookup)
    active_count = Enum.count(assignments, &(&1.status == "active"))

    %{
      id: identity.id,
      chatgpt_account_id: identity.chatgpt_account_id,
      account_label: Common.safe_label(identity.account_label),
      account_email: identity.account_email,
      workspace_ref: Common.workspace_ref(identity.workspace_id),
      workspace_label: Common.safe_label(identity.workspace_label),
      onboarding_method: identity.onboarding_method,
      status: identity.status,
      plan_family: identity.plan_family,
      plan_label: identity.plan_label,
      auth_fresh_at: Common.timestamp(identity.auth_fresh_at),
      auth_verified_at: Common.timestamp(identity.auth_verified_at),
      headers_profile_version: identity.headers_profile_version,
      last_successful_refresh_at: Common.timestamp(identity.last_successful_refresh_at),
      last_successful_sync_at: Common.timestamp(identity.last_successful_sync_at),
      disabled_at: Common.timestamp(identity.disabled_at),
      created_by_user_id: identity.created_by_user_id,
      created_at: Common.timestamp(identity.created_at),
      updated_at: Common.timestamp(identity.updated_at),
      assignment_summary: %{
        count: length(assignments),
        status: identity.status,
        summary: "#{active_count} active of #{length(assignments)} Pool assignments"
      },
      metadata: %{
        status: Common.metadata_status(identity.metadata),
        summary: "metadata keys omitted"
      }
    }
  end

  defp visible_assignments_for_identity(identity, pool_lookup) do
    visible_pool_ids = pool_lookup |> Map.keys() |> MapSet.new()

    identity
    |> Upstreams.list_pool_assignments_for_identity()
    |> Enum.reject(&(&1.status == "deleted"))
    |> Enum.filter(&MapSet.member?(visible_pool_ids, &1.pool_id))
  end

  defp resolve(upstreams, selector) do
    selector = Common.normalize_selector(selector)

    account_matches =
      Enum.filter(upstreams, &(String.downcase(&1.chatgpt_account_id || "") == selector))

    cond do
      upstream = Enum.find(upstreams, &(&1.id == selector)) ->
        {:ok, upstream}

      account_matches != [] ->
        Common.one_ambiguous_or_missing(account_matches)

      true ->
        upstreams
        |> Enum.filter(&(String.downcase(&1.account_label || "") == selector))
        |> Common.one_ambiguous_or_missing()
    end
  end

  defp filter_for_pool(upstreams, nil), do: upstreams

  defp filter_for_pool(upstreams, %Pool{id: pool_id}) do
    upstream_ids =
      pool_id
      |> Upstreams.list_pool_assignments()
      |> Enum.reject(&(&1.status == "deleted"))
      |> MapSet.new(& &1.upstream_identity_id)

    Enum.filter(upstreams, &MapSet.member?(upstream_ids, &1.id))
  end

  defp search_text(identity) do
    Common.searchable([
      identity.id,
      identity.chatgpt_account_id,
      identity.account_label,
      identity.workspace_label,
      Common.workspace_ref(identity.workspace_id),
      identity.status
    ])
  end

  defp list_text(items) do
    ReadableText.list(
      "upstream metadata records",
      Enum.map(items, &text_row/1),
      text_fields()
    )
  end

  defp detail_text(item) do
    ReadableText.detail("upstream metadata record", text_row(item), [
      {:id, "id"} | text_fields()
    ])
  end

  defp ambiguity_text(candidates) do
    ReadableText.ambiguous("upstream metadata record", candidates, [
      {:id, "id"},
      {:account_label, "label", required: true},
      {:workspace_ref, "workspace", required: true},
      {:workspace_label, "workspace_label"},
      {:status, "status", required: true}
    ])
  end

  defp text_fields do
    [
      {:account_label, "label", required: true},
      {:status, "status", required: true},
      {:account, "account", required: true},
      {:workspace, "workspace", required: true},
      {:plan, "plan", required: true},
      {:assignments, "assignments", required: true}
    ]
  end

  defp text_row(item) do
    item
    |> Map.take(["id", "account_label", "status"])
    |> Map.put("account", Map.get(item, "account_email") || Map.get(item, "chatgpt_account_id"))
    |> Map.put("workspace", Map.get(item, "workspace_label") || Map.get(item, "workspace_ref"))
    |> Map.put("plan", Map.get(item, "plan_label") || Map.get(item, "plan_family"))
    |> Map.put("assignments", Common.summary_text(item, "assignment_summary"))
  end

  defp list_tool do
    %{
      name: "codex_pooler_list_upstreams",
      title: "List upstreams",
      description:
        ToolRegistry.metadata_description(
          use_when: "an MCP client needs bounded upstream account metadata discovery",
          returns:
            "sanitized upstream identity records with masked account emails and assignment summaries",
          never_returns:
            "raw Pool API keys, key hashes, auth.json, access tokens, refresh tokens, MCP token prefixes, setup snippets, or upstream secret material",
          filters_limits:
            "accepts optional query, status, pool_selector, and limit; limit is capped at #{Common.max_limit()} records"
        ),
      input_schema: Common.list_schema(),
      output_schema: Common.list_output_schema(),
      annotations: Common.read_only_annotations(),
      handler: {__MODULE__, :list_upstreams}
    }
  end

  defp get_tool do
    %{
      name: "codex_pooler_get_upstream",
      title: "Get upstream",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an MCP client needs one upstream account metadata record by id, stored account id, or label",
          returns:
            "one sanitized upstream identity record or structured ambiguity candidates when the selector matches multiple records",
          never_returns:
            "raw Pool API keys, key hashes, auth.json, access tokens, refresh tokens, MCP token prefixes, setup snippets, or upstream secret material",
          filters_limits:
            "requires selector; exact id and stored account id are preferred, while duplicate labels return ambiguity candidates"
        ),
      input_schema: Common.selector_schema(),
      output_schema: Common.get_output_schema(),
      annotations: Common.read_only_annotations(),
      handler: {__MODULE__, :get_upstream}
    }
  end
end
