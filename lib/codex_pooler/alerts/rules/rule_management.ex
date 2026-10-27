defmodule CodexPooler.Alerts.Rules.RuleManagement do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts.AuditLog, as: AlertAudit
  alias CodexPooler.Alerts.Authorization
  alias CodexPooler.Alerts.ChannelManagement
  alias CodexPooler.Alerts.Incidents.IncidentLifecycle
  alias CodexPooler.Alerts.Incidents.NotificationEvents

  alias CodexPooler.Alerts.Schemas.{
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Repo

  @saved_reset_first_seen_rule_kind "upstream_saved_reset_banked_first_seen"
  @condition_fields ~w(pool_id scope_type rule_kind model route_class min_usable_assignments target_state window_selector threshold_used_percent)a

  @type access_error :: Authorization.access_error()
  @type rule_result :: {:ok, AlertRule.t()} | {:error, Ecto.Changeset.t() | access_error()}

  @spec list_rules(term(), keyword()) :: {:ok, [AlertRule.t()]} | {:error, access_error()}
  def list_rules(scope, opts \\ [])

  def list_rules(%Scope{} = scope, opts) when is_list(opts) do
    with {:ok, pool_ids} <-
           Authorization.authorized_pool_filter(scope, Keyword.get(opts, :pool_id)) do
      {:ok,
       Repo.all(
         from rule in AlertRule,
           where: rule.pool_id in ^pool_ids,
           order_by: [asc: rule.created_at, asc: rule.id]
       )}
    end
  end

  def list_rules(_scope, _opts),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  @spec create_rule(term(), map()) :: rule_result()
  def create_rule(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, pool_id} <- pool_id_from_attrs(attrs),
         {:ok, _decision} <- Authorization.authorize_pool_operation(scope, pool_id) do
      now = now()

      attrs
      |> rule_attrs(scope, pool_id, now)
      |> insert_rule_with_channels(
        scope,
        Map.get(attrs, :channel_ids) || Map.get(attrs, "channel_ids") || [],
        now
      )
      |> AlertAudit.audit_rule_create(scope)
    end
  end

  def create_rule(_scope, _attrs),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  @spec update_rule(term(), AlertRule.t() | Ecto.UUID.t(), map()) :: rule_result()
  @spec update_rule(term(), AlertRule.t() | Ecto.UUID.t(), map(), keyword()) :: rule_result()
  def update_rule(scope, rule, attrs, opts \\ [])

  def update_rule(%Scope{} = scope, %AlertRule{id: id}, attrs, opts) when is_map(attrs) and is_list(opts), do: update_rule(scope, id, attrs, opts)

  def update_rule(%Scope{} = scope, rule_id, attrs, opts) when is_binary(rule_id) and is_map(attrs) and is_list(opts) do
    case Repo.transact(fn -> update_rule_in_transaction(scope, rule_id, attrs, opts) end) do
      {:ok, {previous, updated}} -> AlertAudit.audit_rule_update({:ok, updated}, scope, previous, attrs)
      {:error, _reason} = error -> error
    end
  end

  def update_rule(_scope, _rule, _attrs, _opts),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  @spec delete_rule(term(), AlertRule.t() | Ecto.UUID.t()) :: rule_result()
  @spec delete_rule(term(), AlertRule.t() | Ecto.UUID.t(), keyword()) :: rule_result()
  def delete_rule(scope, rule, opts \\ [])

  def delete_rule(%Scope{} = scope, %AlertRule{id: id}, opts) when is_list(opts),
    do: delete_rule(scope, id, opts)

  def delete_rule(%Scope{} = scope, rule_id, opts) when is_binary(rule_id) and is_list(opts) do
    delete_rule_transaction(scope, rule_id, opts)
    |> AlertAudit.audit_rule_delete(scope)
  end

  def delete_rule(_scope, _rule, _opts),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  defp delete_rule_transaction(scope, rule_id, opts) do
    NotificationEvents.invalidate_after_cascade({:rule, rule_id}, fn ->
      Repo.transact(fn -> delete_rule_in_transaction(scope, rule_id, opts) end)
    end)
  end

  defp delete_rule_in_transaction(scope, rule_id, opts) do
    case Repo.one(from rule in AlertRule, where: rule.id == ^rule_id, lock: "FOR UPDATE") do
      %AlertRule{} = rule -> delete_locked_rule(scope, rule, opts)
      nil -> Repo.rollback(Authorization.access_error(:rule_not_found, "alert rule was not found"))
    end
  end

  defp delete_locked_rule(scope, rule, opts) do
    with {:ok, _decision} <- Authorization.authorize_pool_operation(scope, rule.pool_id),
         :ok <- check_delete_revision(rule, opts),
         {:ok, deleted_rule} <- Repo.delete(rule) do
      {:ok, deleted_rule}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp check_delete_revision(rule, opts) do
    case Keyword.fetch(opts, :expected_updated_at) do
      :error -> :ok
      {:ok, expected} when expected == rule.updated_at -> :ok
      {:ok, _expected} -> {:error, Authorization.access_error(:stale_update, "alert rule changed since it was opened")}
    end
  end

  defp update_rule_in_transaction(scope, rule_id, attrs, opts) do
    case Repo.one(from rule in AlertRule, where: rule.id == ^rule_id, lock: "FOR UPDATE") do
      %AlertRule{} = rule -> update_locked_rule(scope, rule, attrs, opts)
      nil -> {:error, Authorization.access_error(:rule_not_found, "alert rule was not found")}
    end
  end

  defp update_locked_rule(scope, rule, attrs, opts) do
    target_pool_id = Map.get(attrs, :pool_id) || Map.get(attrs, "pool_id") || rule.pool_id
    timestamp = now()
    normalized = rule_update_attrs(rule, attrs, target_pool_id, timestamp)
    changeset = AlertRule.changeset(rule, normalized)

    with {:ok, _existing} <- Authorization.authorize_pool_operation(scope, rule.pool_id),
         {:ok, _target} <- Authorization.authorize_pool_operation(scope, target_pool_id),
         :ok <- check_update_revision(rule, opts),
         {:ok, updated} <- Repo.update(changeset),
         {:ok, _channels} <- maybe_sync_rule_channels(scope, updated, normalized, timestamp) do
      if Enum.any?(@condition_fields, &Ecto.Changeset.changed?(changeset, &1)) do
        IncidentLifecycle.retire_rule_targets(rule.id, timestamp)
      end

      {:ok, {rule, updated}}
    end
  end

  defp check_update_revision(rule, opts) do
    case Keyword.fetch(opts, :expected_updated_at) do
      :error -> :ok
      {:ok, expected} when expected == rule.updated_at -> :ok
      {:ok, _expected} -> {:error, Authorization.access_error(:stale_update, "alert rule changed since it was opened")}
    end
  end

  defp pool_id_from_attrs(attrs) do
    case Map.get(attrs, :pool_id) || Map.get(attrs, "pool_id") do
      pool_id when is_binary(pool_id) -> {:ok, pool_id}
      _other -> {:error, Authorization.access_error(:invalid_request, "pool id must be a string")}
    end
  end

  defp rule_attrs(attrs, scope, pool_id, timestamp) do
    attrs
    |> normalize_attrs(rule_attribute_keys())
    |> Map.merge(%{
      pool_id: pool_id,
      created_by_user_id: scope.user.id,
      disabled_at: disabled_at_for_state(Map.get(attrs, :state) || Map.get(attrs, "state"), timestamp),
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{},
      created_at: timestamp,
      updated_at: timestamp
    })
    |> maybe_put_saved_reset_first_seen_create_baseline(timestamp)
  end

  defp rule_update_attrs(%AlertRule{} = rule, attrs, target_pool_id, timestamp) do
    attrs
    |> normalize_attrs(rule_update_attribute_keys())
    |> maybe_clear_unsupported_route_class(rule, attrs)
    |> Map.put(:pool_id, target_pool_id)
    |> maybe_put_disabled_at(attrs, timestamp)
    |> maybe_put_saved_reset_first_seen_enable_baseline(rule, timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp insert_rule_with_channels(attrs, scope, channel_ids, timestamp) do
    Repo.transaction(fn ->
      with {:ok, rule} <- %AlertRule{} |> AlertRule.changeset(attrs) |> Repo.insert(),
           {:ok, _channels} <- sync_rule_channels(scope, rule, channel_ids, timestamp) do
        rule
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp maybe_sync_rule_channels(scope, rule, attrs, timestamp) do
    case Map.fetch(attrs, :channel_ids) do
      {:ok, channel_ids} -> sync_rule_channels(scope, rule, channel_ids, timestamp)
      :error -> {:ok, []}
    end
  end

  defp sync_rule_channels(%Scope{} = scope, %AlertRule{} = rule, channel_ids, timestamp)
       when is_list(channel_ids) do
    channel_ids = Enum.filter(channel_ids, &is_binary/1) |> Enum.uniq()

    with {:ok, channel_ids} <- authorize_rule_channel_ids(scope, channel_ids) do
      Repo.delete_all(from link in AlertRuleChannel, where: link.alert_rule_id == ^rule.id)

      links =
        Enum.map(channel_ids, fn channel_id ->
          %{alert_rule_id: rule.id, alert_channel_id: channel_id, created_at: timestamp}
        end)

      if links == [] do
        {:ok, []}
      else
        {count, _rows} = Repo.insert_all(AlertRuleChannel, links)
        {:ok, count}
      end
    end
  end

  defp sync_rule_channels(_scope, _rule, _channel_ids, _timestamp),
    do: {:error, Authorization.access_error(:invalid_request, "channel ids must be a list")}

  defp authorize_rule_channel_ids(%Scope{} = scope, channel_ids) do
    authorized_count =
      Repo.aggregate(
        from(channel in ChannelManagement.scope_query(scope), where: channel.id in ^channel_ids),
        :count,
        :id
      )

    if authorized_count == length(channel_ids) do
      {:ok, channel_ids}
    else
      {:error, ChannelManagement.not_found_error()}
    end
  end

  defp rule_attribute_keys do
    [
      :pool_id,
      :scope_type,
      :rule_kind,
      :display_name,
      :severity,
      :cooldown_minutes,
      :state,
      :model,
      :route_class,
      :min_usable_assignments,
      :target_state,
      :window_selector,
      :threshold_used_percent,
      :metadata
    ]
  end

  defp rule_update_attribute_keys do
    rule_attribute_keys() ++ [:channel_ids]
  end

  defp normalize_attrs(attrs, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.fetch(attrs, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> maybe_put_string_key(acc, attrs, key)
      end
    end)
  end

  defp maybe_put_string_key(acc, attrs, key) do
    string_key = Atom.to_string(key)

    case Map.fetch(attrs, string_key) do
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end

  defp maybe_clear_unsupported_route_class(normalized_attrs, rule, raw_attrs) do
    final_rule_kind = Map.get(normalized_attrs, :rule_kind, rule.rule_kind)

    cond do
      final_rule_kind in AlertRule.route_class_rule_kinds() ->
        normalized_attrs

      route_class_submitted?(raw_attrs) ->
        normalized_attrs

      final_rule_kind != rule.rule_kind ->
        Map.put(normalized_attrs, :route_class, nil)

      true ->
        normalized_attrs
    end
  end

  defp route_class_submitted?(attrs),
    do: Map.has_key?(attrs, :route_class) or Map.has_key?(attrs, "route_class")

  defp maybe_put_disabled_at(attrs, raw_attrs, timestamp) do
    case Map.get(raw_attrs, :state) || Map.get(raw_attrs, "state") do
      "disabled" -> Map.put(attrs, :disabled_at, timestamp)
      "active" -> Map.put(attrs, :disabled_at, nil)
      _state -> attrs
    end
  end

  defp disabled_at_for_state("disabled", timestamp), do: timestamp
  defp disabled_at_for_state(_state, _timestamp), do: nil

  defp maybe_put_saved_reset_first_seen_create_baseline(attrs, timestamp) do
    if saved_reset_first_seen_rule?(attrs) and
         Map.get(attrs, :state, AlertRule.active_state()) == AlertRule.active_state() do
      put_saved_reset_first_seen_baseline(attrs, timestamp)
    else
      attrs
    end
  end

  defp maybe_put_saved_reset_first_seen_enable_baseline(attrs, rule, timestamp) do
    final_state = Map.get(attrs, :state, rule.state)
    final_rule_kind = Map.get(attrs, :rule_kind, rule.rule_kind)

    if final_rule_kind == @saved_reset_first_seen_rule_kind and final_state == "active" and
         (rule.state == "disabled" or rule.rule_kind != @saved_reset_first_seen_rule_kind) do
      attrs
      |> Map.put_new(:metadata, rule.metadata || %{})
      |> put_saved_reset_first_seen_baseline(timestamp)
    else
      attrs
    end
  end

  defp saved_reset_first_seen_rule?(attrs),
    do: Map.get(attrs, :rule_kind) == @saved_reset_first_seen_rule_kind

  defp put_saved_reset_first_seen_baseline(attrs, timestamp) do
    metadata =
      (Map.get(attrs, :metadata) || %{})
      |> Map.put(AlertRule.saved_reset_first_seen_baseline_key(), DateTime.to_iso8601(timestamp))

    Map.put(attrs, :metadata, metadata)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
