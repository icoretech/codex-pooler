defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Filter do
  @moduledoc false

  @spec apply([map()], map()) :: [map()]
  def apply(accounts, filters) when is_list(accounts) and is_map(filters) do
    accounts
    |> filter_by_status(Map.get(filters, "status"))
    |> filter_by_query(Map.get(filters, "query"))
  end

  defp filter_by_status(accounts, status) when is_binary(status) and status != "" do
    Enum.filter(accounts, &(&1.identity.status == status))
  end

  defp filter_by_status(accounts, _status), do: accounts

  defp filter_by_query(accounts, query) when is_binary(query) do
    query = String.downcase(String.trim(query))

    if query == "" do
      accounts
    else
      Enum.filter(accounts, &(search_haystack(&1) =~ query))
    end
  end

  defp filter_by_query(accounts, _query), do: accounts

  defp search_haystack(account) do
    account
    |> safe_search_terms()
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
  end

  defp safe_search_terms(account) do
    [
      account.label,
      account.identity.chatgpt_account_id,
      account.workspace_ref,
      account.workspace_label,
      account.plan_label,
      account.identity.plan_family,
      account.identity.status,
      account.quota_readiness.label,
      account.quota_readiness.state,
      account.routing_readiness.label,
      account.routing_readiness.state
      | assignment_search_terms(account.assignments)
    ]
  end

  defp assignment_search_terms(assignments) when is_list(assignments) do
    Enum.flat_map(assignments, &assignment_search_terms/1)
  end

  defp assignment_search_terms(assignment) do
    [
      assignment.assignment_label,
      Map.get(assignment, :stored_assignment_label),
      assignment.pool_label
    ]
  end
end
