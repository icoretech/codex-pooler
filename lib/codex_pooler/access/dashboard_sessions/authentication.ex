defmodule CodexPooler.Access.DashboardSessions.Authentication do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Access.DashboardSessions.Principal
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @invalid_session {:error, :invalid_dashboard_session}

  @spec authenticate_token_hash(binary()) ::
          {:ok, Principal.t()} | {:error, :invalid_dashboard_session}
  def authenticate_token_hash(token_hash) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    eligible_session_query(now)
    |> where([session, _api_key, _pool], session.token_hash == ^token_hash)
    |> principal_result()
  end

  @spec authenticate_session_id(Ecto.UUID.t()) ::
          {:ok, Principal.t()} | {:error, :invalid_dashboard_session}
  def authenticate_session_id(dashboard_session_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    eligible_session_query(now)
    |> where([session, _api_key, _pool], session.id == ^dashboard_session_id)
    |> principal_result()
  end

  @doc false
  @spec eligible_session_query(DateTime.t()) :: Ecto.Query.t()
  def eligible_session_query(now) do
    from session in APIKeyDashboardSession,
      join: api_key in APIKey,
      on: api_key.id == session.api_key_id,
      join: pool in Pool,
      on: pool.id == api_key.pool_id,
      where: session.expires_at > ^now,
      where: api_key.status == "active",
      where: api_key.dashboard_access == true,
      where: is_nil(api_key.expires_at) or api_key.expires_at > ^now,
      where: pool.status == "active"
  end

  defp principal_result(query) do
    query =
      select(query, [_session, api_key, pool], %{
        api_key_id: api_key.id,
        pool_id: pool.id,
        display_name: api_key.display_name,
        key_prefix: api_key.key_prefix
      })

    case Repo.one(query) do
      %{api_key_id: _api_key_id} = principal -> {:ok, Principal.new(principal)}
      nil -> @invalid_session
    end
  end
end
