defmodule CodexPooler.Dev.RoutingStrategyFixture.SnapshotReader do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.RoutingStrategyFixture.Names
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}

  @spec capture(pos_integer()) :: map()
  def capture(assignment_count) do
    pool = Repo.get_by(Pool, slug: Names.pool_slug())
    identities = identities(assignment_count)
    identity_ids = Enum.map(identities, & &1.id)

    %{
      pool: row(pool),
      routing_settings: row(pool && Repo.get(RoutingSettings, pool.id)),
      api_keys: rows(api_keys_for(pool)),
      models: rows(models_for(pool)),
      identities: rows(identities),
      identity_secrets: rows(secrets_for(identity_ids)),
      identity_quota_windows: rows(quota_windows_for(identity_ids)),
      assignments: rows(assignments_for(pool, identity_ids))
    }
  end

  @spec identities(pos_integer()) :: [UpstreamIdentity.t()]
  def identities(assignment_count) do
    account_ids = Names.account_ids(assignment_count)

    Repo.all(
      from identity in UpstreamIdentity,
        where: identity.chatgpt_account_id in ^account_ids,
        order_by: [asc: identity.chatgpt_account_id]
    )
  end

  @spec fixture_identity_ids(pos_integer()) :: [Ecto.UUID.t()]
  def fixture_identity_ids(assignment_count) do
    assignment_count |> identities() |> Enum.map(& &1.id)
  end

  @spec fixture_pool_id() :: Ecto.UUID.t() | nil
  def fixture_pool_id do
    Repo.one(from pool in Pool, where: pool.slug == ^Names.pool_slug(), select: pool.id)
  end

  defp api_keys_for(nil), do: []
  defp api_keys_for(pool), do: Repo.all(from key in APIKey, where: key.pool_id == ^pool.id)

  defp models_for(nil), do: []
  defp models_for(pool), do: Repo.all(from model in Model, where: model.pool_id == ^pool.id)

  defp secrets_for([]), do: []

  defp secrets_for(identity_ids) do
    Repo.all(from secret in EncryptedSecret, where: secret.upstream_identity_id in ^identity_ids)
  end

  defp quota_windows_for([]), do: []

  defp quota_windows_for(identity_ids) do
    Repo.all(
      from window in AccountQuotaWindow, where: window.upstream_identity_id in ^identity_ids
    )
  end

  defp assignments_for(nil, _identity_ids), do: []
  defp assignments_for(_pool, []), do: []

  defp assignments_for(pool, identity_ids) do
    Repo.all(
      from assignment in PoolUpstreamAssignment,
        where: assignment.pool_id == ^pool.id and assignment.upstream_identity_id in ^identity_ids
    )
  end

  defp row(nil), do: nil
  defp row(record), do: record |> Map.from_struct() |> Map.delete(:__meta__)
  defp rows(records), do: Enum.map(records, &row/1)
end
