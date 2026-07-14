defmodule CodexPooler.Audit do
  @moduledoc """
  Pool-scoped audit event APIs with metadata redaction.
  """

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @action_options [
    {"First owner account created", "auth.bootstrap"},
    {"Operator signed in", "auth.login"},
    {"Operator signed out", "auth.logout"},
    {"Browser session signed out", "auth.session_revoked"},
    {"Other browser sessions signed out", "auth.sessions_revoked"},
    {"Recovery code used", "auth.recovery_code_used"},
    {"Password changed", "auth.password_change"},
    {"Required password change completed", "auth.required_password_change"},
    {"Authenticator app enrolled", "auth.totp_enrolled"},
    {"Operator account created", "operator.create"},
    {"Operator account updated", "operator.update"},
    {"Operator account deactivated", "operator.deactivate"},
    {"Operator account reactivated", "operator.reactivate"},
    {"Temporary password issued", "operator.password_reset"},
    {"Temporary password resent", "operator.temporary_password_resend"},
    {"Pool created", "pool.create"},
    {"Pool updated", "pool.update"},
    {"Pool status changed", "pool.status_update"},
    {"Pool routing updated", "pool.routing_update"},
    {"Pool deleted", "pool.delete"},
    {"Pool invite created", "invite.create"},
    {"Pool invite revoked", "invite.revoke"},
    {"Upstream account imported", "upstream_account.import"},
    {"Upstream account assigned to Pool", "upstream_account.assign_pool"},
    {"Upstream account paused", "upstream_account.pause"},
    {"Upstream account reactivated", "upstream_account.reactivate"},
    {"Upstream account token refresh queued", "upstream_account.refresh_enqueue"},
    {"Upstream account deleted", "upstream_account.delete"},
    {"Upstream account saved reset policy updated", "upstream_account.saved_reset_policy_update"},
    {"Upstream account saved reset redemption queued",
     "upstream_account.saved_reset_redeem_enqueue"},
    {"API key created", "api_key.create"},
    {"API key updated", "api_key.update"},
    {"API key paused", "api_key.pause"},
    {"API key resumed", "api_key.resume"},
    {"API key revoked", "api_key.revoke"},
    {"API key rotated", "api_key.rotate"},
    {"API key deleted", "api_key.delete"},
    {"Operator MCP enabled", "mcp.operator_enable"},
    {"Operator MCP disabled", "mcp.operator_disable"},
    {"MCP token created", "mcp.token_create"},
    {"MCP token label updated", "mcp.token_update"},
    {"MCP token deleted", "mcp.token_delete"},
    {"Alert rule created", "alert_rule.create"},
    {"Alert rule updated", "alert_rule.update"},
    {"Alert rule enabled", "alert_rule.enable"},
    {"Alert rule disabled", "alert_rule.disable"},
    {"Alert rule deleted", "alert_rule.delete"},
    {"Alert channel created", "alert_channel.create"},
    {"Alert channel updated", "alert_channel.update"},
    {"Alert channel enabled", "alert_channel.enable"},
    {"Alert channel disabled", "alert_channel.disable"},
    {"Alert channel deleted", "alert_channel.delete"},
    {"Alert incident acknowledged", "alert_incident.acknowledge"},
    {"Alert incident resolved", "alert_incident.resolve"},
    {"Instance settings updated", "instance_settings.update"}
  ]

  @supported_actions Enum.map(@action_options, fn {_label, action} -> action end)
  @action_labels Map.new(@action_options, fn {label, action} -> {action, label} end)

  @type action :: String.t()
  @type action_option :: {String.t(), action()}
  @type audit_attrs :: %{optional(atom()) => term()}
  @type audit_filters :: Enumerable.t()
  @type list_opts :: [
          {:limit, integer()}
          | {:offset, integer()}
          | {:filters, audit_filters()}
          | {:visible_pool_ids, [Ecto.UUID.t()]}
          | {:include_global_events, boolean()}
        ]
  @type audit_result ::
          {:ok, AuditEvent.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :runtime_events_not_recorded}
  @type audit_event_row :: %{
          id: Ecto.UUID.t(),
          occurred_at: DateTime.t(),
          actor_type: String.t(),
          actor_user_id: Ecto.UUID.t() | nil,
          actor_user_email: String.t(),
          pool_id: Ecto.UUID.t() | nil,
          pool_name: String.t() | nil,
          pool_slug: String.t() | nil,
          request_id: Ecto.UUID.t() | nil,
          action: action(),
          target_type: String.t(),
          target_id: Ecto.UUID.t() | nil,
          outcome: String.t(),
          correlation_id: String.t() | nil,
          ip_address: String.t() | nil,
          details: map()
        }
  @type audit_page :: %{
          items: [audit_event_row()],
          total: non_neg_integer(),
          limit: pos_integer(),
          offset: non_neg_integer()
        }

  @spec action_options() :: [action_option()]
  def action_options, do: @action_options

  @spec supported_actions() :: [action()]
  def supported_actions, do: @supported_actions

  @spec action_label(action()) :: String.t() | nil
  def action_label(action), do: Map.get(@action_labels, action)

  @spec record_system_event(audit_attrs()) :: audit_result()
  def record_system_event(attrs) when is_map(attrs) do
    record_event(Map.merge(attrs, %{actor_type: "system", actor_user_id: nil}))
  end

  @spec record_user_event(User.t(), audit_attrs()) :: audit_result()
  def record_user_event(%User{} = user, attrs) when is_map(attrs) do
    record_event(Map.merge(attrs, %{actor_type: "user", actor_user_id: user.id}))
  end

  @spec record_event(audit_attrs()) :: audit_result()
  def record_event(%{action: "request." <> _suffix}), do: {:error, :runtime_events_not_recorded}
  def record_event(%{action: "file." <> _suffix}), do: {:error, :runtime_events_not_recorded}

  def record_event(attrs) when is_map(attrs) do
    now = Map.get(attrs, :occurred_at) || DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AuditEvent{
      occurred_at: now,
      actor_type: Map.fetch!(attrs, :actor_type),
      actor_user_id: Map.get(attrs, :actor_user_id),
      pool_id: Map.get(attrs, :pool_id),
      request_id: Map.get(attrs, :request_id),
      action: Map.fetch!(attrs, :action),
      target_type: Map.fetch!(attrs, :target_type),
      target_id: Map.get(attrs, :target_id),
      outcome: attrs |> Map.get(:outcome, "success") |> normalize_outcome(),
      correlation_id: Map.get(attrs, :correlation_id),
      ip_address: Map.get(attrs, :ip_address),
      details: CodexPooler.Accounting.sanitize_metadata(Map.get(attrs, :details, %{}))
    }
    |> Repo.insert()
  end

  @spec list_events(Pool.t() | Ecto.UUID.t() | nil, list_opts()) :: audit_page()
  def list_events(pool_or_id, opts \\ []) do
    pool_id = id_for(pool_or_id)
    list_events_for_pool_filter(pool_id, opts)
  end

  @spec list_events_for_scope(Scope.t(), list_opts()) :: audit_page()
  def list_events_for_scope(%Scope{} = scope, opts \\ []) do
    visible_pool_ids = scope |> Pools.list_log_filter_pools() |> Enum.map(& &1.id)

    opts =
      opts
      |> Keyword.put(:visible_pool_ids, visible_pool_ids)
      |> Keyword.put(:include_global_events, Pools.owner?(scope))

    list_events_for_pool_filter(nil, opts)
  end

  defp list_events_for_pool_filter(pool_id, opts) do
    limit = opts |> Keyword.get(:limit, 50) |> clamp_limit()
    offset = max(Keyword.get(opts, :offset, 0), 0)
    filters = opts |> Keyword.get(:filters, []) |> Map.new()
    visible_pool_ids = Keyword.get(opts, :visible_pool_ids)
    include_global_events = Keyword.get(opts, :include_global_events, true)

    query =
      from event in AuditEvent,
        left_join: user in User,
        on: user.id == event.actor_user_id,
        left_join: pool in Pool,
        on: pool.id == event.pool_id

    query =
      query
      |> maybe_filter_visible_pools(visible_pool_ids, include_global_events)
      |> maybe_filter_pool(pool_id)
      |> apply_event_filters(filters)

    total = Repo.aggregate(query, :count, :id)

    items =
      Repo.all(
        from [event, user, pool] in query,
          order_by: [desc: event.occurred_at, desc: event.id],
          limit: ^limit,
          offset: ^offset,
          select: {event, user.email, pool.name, pool.slug}
      )
      |> Enum.map(fn {event, user_email, pool_name, pool_slug} ->
        %{
          id: event.id,
          occurred_at: event.occurred_at,
          actor_type: event.actor_type,
          actor_user_id: event.actor_user_id,
          actor_user_email: user_email || "",
          pool_id: event.pool_id,
          pool_name: pool_name,
          pool_slug: pool_slug,
          request_id: event.request_id,
          action: event.action,
          target_type: event.target_type,
          target_id: event.target_id,
          outcome: event.outcome,
          correlation_id: event.correlation_id,
          ip_address: event.ip_address && to_string(event.ip_address),
          details: CodexPooler.Accounting.sanitize_metadata(event.details || %{})
        }
      end)

    %{items: items, total: total, limit: limit, offset: offset}
  end

  defp id_for(%{id: id}), do: id
  defp id_for(id) when is_binary(id), do: id
  defp id_for(_), do: nil

  defp maybe_filter_pool(query, nil), do: query

  defp maybe_filter_pool(query, pool_id),
    do: from([event, ...] in query, where: event.pool_id == ^pool_id)

  defp maybe_filter_visible_pools(query, nil, _include_global_events), do: query

  defp maybe_filter_visible_pools(query, pool_ids, true) when is_list(pool_ids) do
    from [event, ...] in query,
      where: is_nil(event.pool_id) or event.pool_id in ^pool_ids
  end

  defp maybe_filter_visible_pools(query, pool_ids, false) when is_list(pool_ids) do
    from [event, ...] in query,
      where: event.pool_id in ^pool_ids
  end

  defp apply_event_filters(query, filters) do
    query
    |> maybe_filter_id(Map.get(filters, :id))
    |> maybe_filter_outcome(Map.get(filters, :outcome))
    |> maybe_filter_actor_type(Map.get(filters, :actor_type))
    |> maybe_filter_actor(Map.get(filters, :actor))
    |> maybe_filter_action(Map.get(filters, :action))
    |> maybe_filter_target(Map.get(filters, :target))
    |> maybe_filter_request(Map.get(filters, :request))
    |> maybe_filter_date_from(Map.get(filters, :date_from))
    |> maybe_filter_date_to(Map.get(filters, :date_to))
  end

  defp maybe_filter_id(query, nil), do: query

  defp maybe_filter_id(query, id) do
    from([event, ...] in query, where: event.id == ^id)
  end

  defp maybe_filter_outcome(query, nil), do: query

  defp maybe_filter_outcome(query, outcome),
    do: from([event, ...] in query, where: event.outcome == ^outcome)

  defp maybe_filter_actor_type(query, nil), do: query

  defp maybe_filter_actor_type(query, actor_type),
    do: from([event, ...] in query, where: event.actor_type == ^actor_type)

  defp maybe_filter_actor(query, nil), do: query

  defp maybe_filter_actor(query, actor) do
    pattern = "%#{actor}%"

    from([event, user, _pool] in query,
      where:
        fragment("?::text ILIKE ?", event.actor_user_id, ^pattern) or
          ilike(user.email, ^pattern) or
          ilike(event.actor_type, ^pattern)
    )
  end

  defp maybe_filter_action(query, nil), do: query

  defp maybe_filter_action(query, action) do
    from([event, ...] in query, where: event.action == ^action)
  end

  defp maybe_filter_target(query, nil), do: query

  defp maybe_filter_target(query, target) do
    pattern = "%#{target}%"

    from([event, ...] in query,
      where:
        ilike(event.target_type, ^pattern) or
          fragment("?::text ILIKE ?", event.target_id, ^pattern)
    )
  end

  defp maybe_filter_request(query, nil), do: query

  defp maybe_filter_request(query, request) do
    pattern = "%#{request}%"

    from([event, ...] in query,
      where:
        fragment("?::text ILIKE ?", event.request_id, ^pattern) or
          ilike(event.correlation_id, ^pattern)
    )
  end

  defp maybe_filter_date_from(query, nil), do: query

  defp maybe_filter_date_from(query, date_from),
    do: from([event, ...] in query, where: event.occurred_at >= ^date_from)

  defp maybe_filter_date_to(query, nil), do: query

  defp maybe_filter_date_to(query, date_to),
    do: from([event, ...] in query, where: event.occurred_at <= ^date_to)

  defp clamp_limit(limit) when is_integer(limit) and limit > 0 and limit <= 200, do: limit
  defp clamp_limit(_limit), do: 50

  defp normalize_outcome("denied"), do: "failure"
  defp normalize_outcome(outcome), do: outcome
end
