defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.ReinviteLink do
  @moduledoc false

  use CodexPoolerWeb, :verified_routes

  alias CodexPoolerWeb.Admin.PoolInviteForm

  @spec path_for_account(map()) :: String.t() | nil
  def path_for_account(%{assignments: [assignment | _assignments]} = account) do
    path_for_action(%{available?: true}, field(assignment, :pool_id), email_candidates(account))
  end

  def path_for_account(_account), do: nil

  @spec path_for_cockpit(map()) :: String.t() | nil
  def path_for_cockpit(%{actions: %{reinvite: action}} = cockpit) do
    path_for_action(action, default_pool_id(cockpit), [field(cockpit.identity, :account_email)])
  end

  def path_for_cockpit(_cockpit), do: nil

  @spec path_for_action(map(), String.t() | nil, [term()]) :: String.t() | nil
  def path_for_action(%{available?: true}, pool_id, candidates) when is_binary(pool_id) do
    pool_id = String.trim(pool_id)

    if pool_id == "" do
      nil
    else
      ~p"/admin/invites?#{PoolInviteForm.reinvite_params(pool_id, candidates)}"
    end
  end

  def path_for_action(_action, _pool_id, _candidates), do: nil

  defp default_pool_id(%{assignments: %{items: [assignment | _items]}}),
    do: field(assignment, :pool_id)

  defp default_pool_id(_cockpit), do: nil

  defp email_candidates(account) do
    [
      field(account.identity, :account_email),
      field(account.identity, :chatgpt_account_id),
      field(account, :label)
    ]
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_map, _key), do: nil
end
