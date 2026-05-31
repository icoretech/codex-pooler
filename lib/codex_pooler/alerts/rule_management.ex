defmodule CodexPooler.Alerts.RuleManagement do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts.AuditLog, as: AlertAudit
  alias CodexPooler.Alerts.Authorization
  alias CodexPooler.Alerts.ChannelManagement

  alias CodexPooler.Alerts.Schemas.{
    AlertRule,
    AlertRuleChannel
  }

  alias CodexPooler.Repo

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
  def update_rule(%Scope{} = scope, %AlertRule{} = rule, attrs) when is_map(attrs) do
    target_pool_id = Map.get(attrs, :pool_id) || Map.get(attrs, "pool_id") || rule.pool_id

    with {:ok, _existing_decision} <- Authorization.authorize_pool_operation(scope, rule.pool_id),
         {:ok, _target_decision} <- Authorization.authorize_pool_operation(scope, target_pool_id) do
      rule
      |> update_rule_with_channels(scope, rule_update_attrs(attrs, target_pool_id, now()))
      |> AlertAudit.audit_rule_update(scope, rule, attrs)
    end
  end

  def update_rule(%Scope{} = scope, rule_id, attrs) when is_binary(rule_id) and is_map(attrs) do
    case Repo.get(AlertRule, rule_id) do
      %AlertRule{} = rule -> update_rule(scope, rule, attrs)
      nil -> {:error, Authorization.access_error(:rule_not_found, "alert rule was not found")}
    end
  end

  def update_rule(_scope, _rule, _attrs),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  @spec delete_rule(term(), AlertRule.t() | Ecto.UUID.t()) :: rule_result()
  def delete_rule(%Scope{} = scope, %AlertRule{} = rule) do
    with {:ok, _decision} <- Authorization.authorize_pool_operation(scope, rule.pool_id) do
      delete_rule_transaction(rule)
      |> AlertAudit.audit_rule_delete(scope)
    end
  end

  def delete_rule(%Scope{} = scope, rule_id) when is_binary(rule_id) do
    case Repo.get(AlertRule, rule_id) do
      %AlertRule{} = rule -> delete_rule(scope, rule)
      nil -> {:error, Authorization.access_error(:rule_not_found, "alert rule was not found")}
    end
  end

  def delete_rule(_scope, _rule),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  defp update_rule_with_channels(rule, scope, attrs) do
    Repo.transaction(fn -> update_rule_in_transaction(rule, scope, attrs) end)
  end

  defp update_rule_in_transaction(rule, scope, attrs) do
    with {:ok, updated_rule} <- rule |> AlertRule.changeset(attrs) |> Repo.update(),
         {:ok, _channels} <- maybe_sync_rule_channels(scope, updated_rule, attrs, now()) do
      updated_rule
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp delete_rule_transaction(rule) do
    Repo.transaction(fn -> delete_rule_in_transaction(rule) end)
  end

  defp delete_rule_in_transaction(rule) do
    case Repo.delete(rule) do
      {:ok, deleted_rule} -> deleted_rule
      {:error, reason} -> Repo.rollback(reason)
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
      disabled_at:
        disabled_at_for_state(Map.get(attrs, :state) || Map.get(attrs, "state"), timestamp),
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{},
      created_at: timestamp,
      updated_at: timestamp
    })
  end

  defp rule_update_attrs(attrs, target_pool_id, timestamp) do
    attrs
    |> normalize_attrs(rule_update_attribute_keys())
    |> Map.put(:pool_id, target_pool_id)
    |> maybe_put_disabled_at(attrs, timestamp)
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

  defp maybe_put_disabled_at(attrs, raw_attrs, timestamp) do
    case Map.get(raw_attrs, :state) || Map.get(raw_attrs, "state") do
      "disabled" -> Map.put(attrs, :disabled_at, timestamp)
      "active" -> Map.put(attrs, :disabled_at, nil)
      _state -> attrs
    end
  end

  defp disabled_at_for_state("disabled", timestamp), do: timestamp
  defp disabled_at_for_state(_state, _timestamp), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
