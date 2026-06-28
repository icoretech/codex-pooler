defmodule CodexPooler.Admin.Stats.Tables do
  @moduledoc false

  alias CodexPooler.Access.Reporting, as: AccessReporting
  alias CodexPooler.Admin.Stats.Aggregates

  @failed_statuses ~w(failed rejected interrupted cancelled)

  @spec top_api_keys([map()], [map()]) :: [map()]
  def top_api_keys([], _pools), do: []

  def top_api_keys(settlements, pools) do
    key_ids = settlements |> Enum.map(& &1.api_key_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    keys_by_id = AccessReporting.api_keys_by_id(key_ids)
    pool_names_by_id = Map.new(pools, &{&1.id, &1.name})

    settlements
    |> Enum.group_by(& &1.api_key_id)
    |> Enum.map(fn {api_key_id, entries} ->
      api_key = Map.get(keys_by_id, api_key_id)

      %{
        api_key_id: api_key_id,
        display_name: api_key && api_key.display_name,
        pool_name: usage_pool_name(entries, pool_names_by_id),
        requests: Aggregates.sum_integer(entries, :request_count),
        total_tokens: Aggregates.sum_integer(entries, :total_tokens),
        settled_cost_micros: Aggregates.sum_decimal_integer(entries, :settled_cost_micros)
      }
    end)
    |> Enum.sort_by(&{&1.total_tokens, &1.requests}, :desc)
    |> Enum.take(5)
  end

  @spec upstream_table([map()], [map()]) :: [map()]
  def upstream_table(settlements, quota_accounts) do
    entries_by_identity = Enum.group_by(settlements, & &1.upstream_identity_id)

    quota_accounts
    |> Enum.group_by(& &1.upstream_identity_id)
    |> Enum.map(fn {upstream_identity_id, accounts} ->
      entries = Map.get(entries_by_identity, upstream_identity_id, [])
      canonical_account = canonical_upstream_account(accounts)

      %{
        pool_upstream_assignment_id: single_assignment_id(accounts),
        upstream_identity_id: upstream_identity_id,
        assignment_label: shared_account_value(accounts, :assignment_label),
        upstream_label:
          shared_account_value(accounts, :upstream_label) || canonical_account.upstream_label,
        status: aggregate_account_value(accounts, :assignment_status),
        health_status: aggregate_account_value(accounts, :health_status),
        quota_state: aggregate_account_value(accounts, :state, :mixed),
        assignment_count: length(accounts),
        requests: Aggregates.sum_integer(entries, :request_count),
        total_tokens: Aggregates.sum_integer(entries, :total_tokens),
        settled_cost_micros: Aggregates.sum_decimal_integer(entries, :settled_cost_micros)
      }
    end)
    |> Enum.sort_by(fn row ->
      {-row.total_tokens, -row.requests, upstream_table_label(row),
       row.upstream_identity_id || ""}
    end)
  end

  @spec recent_failures([map()]) :: [map()]
  def recent_failures(requests) do
    requests
    |> Enum.filter(&(&1.status in @failed_statuses))
    |> Enum.take(5)
    |> Enum.map(fn request ->
      %{
        id: request.id,
        pool_id: request.pool_id,
        requested_model: request.requested_model,
        endpoint: request.endpoint,
        transport: request.transport,
        status: request.status,
        error_code: request.last_error_code,
        response_status_code: request.response_status_code,
        admitted_at: request.admitted_at
      }
    end)
  end

  @spec daily_rollup_table([map()]) :: [map()]
  def daily_rollup_table(rollups) do
    rollups
    |> Enum.take(10)
    |> Enum.map(fn rollup ->
      %{
        rollup_date: rollup.rollup_date,
        dimension_kind: rollup.dimension_kind,
        pool_id: rollup.pool_id,
        request_count: rollup.request_count || 0,
        success_count: rollup.success_count || 0,
        failure_count: rollup.failure_count || 0,
        total_tokens: rollup.total_tokens || 0,
        settled_cost_micros: Aggregates.decimal_to_integer(rollup.settled_cost_micros)
      }
    end)
  end

  @spec canonical_upstream_account([map()]) :: map()
  defp canonical_upstream_account(accounts) do
    Enum.min_by(accounts, &upstream_account_sort_key/1, fn -> %{} end)
  end

  @spec single_assignment_id([map()]) :: Ecto.UUID.t() | nil
  defp single_assignment_id([account]), do: Map.get(account, :pool_upstream_assignment_id)
  defp single_assignment_id(_accounts), do: nil

  @spec shared_account_value([map()], atom()) :: term() | nil
  defp shared_account_value(accounts, field) do
    case distinct_account_values(accounts, field) do
      [value] -> value
      _values -> nil
    end
  end

  @spec aggregate_account_value([map()], atom(), term()) :: term() | nil
  defp aggregate_account_value(accounts, field, mixed_value \\ "mixed") do
    case distinct_account_values(accounts, field) do
      [value] -> value
      [] -> nil
      _values -> mixed_value
    end
  end

  @spec distinct_account_values([map()], atom()) :: [term()]
  defp distinct_account_values(accounts, field) do
    accounts
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&blank_value?/1)
    |> Enum.uniq()
  end

  @spec upstream_account_sort_key(map()) :: {integer(), String.t(), String.t()}
  defp upstream_account_sort_key(account) do
    {
      assignment_status_rank(Map.get(account, :assignment_status)),
      safe_string(Map.get(account, :assignment_label) || Map.get(account, :upstream_label)),
      safe_string(Map.get(account, :pool_upstream_assignment_id))
    }
  end

  @spec assignment_status_rank(term()) :: non_neg_integer()
  defp assignment_status_rank("active"), do: 0
  defp assignment_status_rank("pending"), do: 1
  defp assignment_status_rank("refresh_due"), do: 2
  defp assignment_status_rank("refreshing"), do: 3
  defp assignment_status_rank("paused"), do: 4
  defp assignment_status_rank("refresh_failed"), do: 5
  defp assignment_status_rank("reauth_required"), do: 6
  defp assignment_status_rank("disabled"), do: 7
  defp assignment_status_rank("errored"), do: 8
  defp assignment_status_rank("deleted"), do: 9
  defp assignment_status_rank(_status), do: 10

  @spec upstream_table_label(map()) :: String.t()
  defp upstream_table_label(row) do
    safe_string(row.assignment_label || row.upstream_label)
  end

  @spec blank_value?(term()) :: boolean()
  defp blank_value?(nil), do: true
  defp blank_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_value?(_value), do: false

  @spec safe_string(term()) :: String.t()
  defp safe_string(nil), do: ""
  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value), do: to_string(value)

  defp usage_pool_name(entries, pool_names_by_id) do
    entries
    |> Enum.map(& &1.pool_id)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> case do
      [pool_id] -> Map.get(pool_names_by_id, pool_id)
      [] -> nil
      _pool_ids -> "Multiple Pools"
    end
  end
end
