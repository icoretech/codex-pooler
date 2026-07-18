defmodule CodexPooler.Accounting.Usage.Observatory.Principal do
  @moduledoc """
  Canonical records loaded for an authenticated API-key dashboard principal.

  Dashboard authentication owns the safe authority value. This adapter resolves
  its exact key-to-Pool association and accepts no standalone identifiers.
  """

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions.Principal, as: DashboardPrincipal
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @unauthorized {:error, :unauthorized}

  @enforce_keys [:api_key, :pool]
  defstruct [:api_key, :pool]

  @type t :: %__MODULE__{api_key: APIKey.t(), pool: Pool.t()}

  @doc false
  @spec load(term()) :: {:ok, t()} | {:error, :unauthorized}
  def load(%DashboardPrincipal{api_key_id: api_key_id, pool_id: pool_id}) do
    with {:ok, api_key_id} <- Ecto.UUID.cast(api_key_id),
         {:ok, pool_id} <- Ecto.UUID.cast(pool_id) do
      load_canonical(api_key_id, pool_id)
    else
      :error -> @unauthorized
    end
  end

  def load(_principal), do: @unauthorized

  defp load_canonical(api_key_id, pool_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      from api_key in APIKey,
        join: pool in Pool,
        on: pool.id == api_key.pool_id,
        where: api_key.id == ^api_key_id,
        where: api_key.pool_id == ^pool_id,
        where: pool.id == ^pool_id,
        where: api_key.status == "active",
        where: api_key.dashboard_access == true,
        where: is_nil(api_key.expires_at) or api_key.expires_at > ^now,
        where: pool.status == "active",
        select: {api_key, pool}

    case Repo.one(query,
           telemetry_options: [reporting_projection: :observatory_principal]
         ) do
      {%APIKey{} = api_key, %Pool{} = pool} ->
        {:ok, %__MODULE__{api_key: api_key, pool: pool}}

      nil ->
        @unauthorized
    end
  end
end
