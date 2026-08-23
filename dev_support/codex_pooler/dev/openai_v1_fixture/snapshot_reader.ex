defmodule CodexPooler.Dev.OpenAIV1Fixture.SnapshotReader do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}

  @pool_slug "openai-v1-smoke"
  @account_id "openai-v1-smoke"

  @spec capture() :: map()
  def capture do
    identity = Repo.get_by(UpstreamIdentity, chatgpt_account_id: @account_id)
    pool = Repo.get_by(Pool, slug: @pool_slug)
    assignment = assignment_for(pool, identity)

    %{
      identity: row(identity),
      identity_secrets: rows(secrets_for(identity)),
      identity_quota_windows: rows(quota_windows_for(identity)),
      pool: row(pool),
      api_keys: rows(api_keys_for(pool)),
      routing_settings: row(pool && Repo.get(RoutingSettings, pool.id)),
      assignment: row(assignment),
      models: rows(models_for(pool)),
      routing_circuit_states: rows(routing_circuit_states_for(pool, assignment)),
      bridge_demotions: rows(bridge_demotions_for(pool, assignment))
    }
  end

  @spec fixture_pool_id() :: Ecto.UUID.t() | nil
  def fixture_pool_id do
    Repo.one(from pool in Pool, where: pool.slug == ^@pool_slug, select: pool.id)
  end

  @spec fixture_identity_id() :: Ecto.UUID.t() | nil
  def fixture_identity_id do
    Repo.one(
      from identity in UpstreamIdentity,
        where: identity.chatgpt_account_id == ^@account_id,
        select: identity.id
    )
  end

  @spec fixture_assignment_id(Ecto.UUID.t() | nil, Ecto.UUID.t() | nil) ::
          Ecto.UUID.t() | nil
  def fixture_assignment_id(pool_id, identity_id)
      when is_binary(pool_id) and is_binary(identity_id) do
    Repo.one(
      from assignment in PoolUpstreamAssignment,
        where: assignment.pool_id == ^pool_id and assignment.upstream_identity_id == ^identity_id,
        select: assignment.id
    )
  end

  def fixture_assignment_id(_pool_id, _identity_id), do: nil

  defp assignment_for(%Pool{} = pool, %UpstreamIdentity{} = identity) do
    Repo.get_by(PoolUpstreamAssignment,
      pool_id: pool.id,
      upstream_identity_id: identity.id
    )
  end

  defp assignment_for(_pool, _identity), do: nil
  defp api_keys_for(nil), do: []
  defp api_keys_for(pool), do: Repo.all(from key in APIKey, where: key.pool_id == ^pool.id)
  defp secrets_for(nil), do: []

  defp secrets_for(identity),
    do:
      Repo.all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id)

  defp quota_windows_for(nil), do: []

  defp quota_windows_for(identity),
    do:
      Repo.all(
        from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id
      )

  defp models_for(nil), do: []
  defp models_for(pool), do: Repo.all(from model in Model, where: model.pool_id == ^pool.id)
  defp routing_circuit_states_for(nil, _assignment), do: []
  defp routing_circuit_states_for(_pool, nil), do: []

  defp routing_circuit_states_for(pool, assignment) do
    Repo.all(
      from state in RoutingCircuitState,
        where: state.pool_id == ^pool.id and state.pool_upstream_assignment_id == ^assignment.id
    )
  end

  defp bridge_demotions_for(nil, _assignment), do: []
  defp bridge_demotions_for(_pool, nil), do: []

  defp bridge_demotions_for(pool, assignment) do
    Repo.all(
      from demotion in BridgeDemotion,
        where:
          demotion.pool_id == ^pool.id and
            demotion.pool_upstream_assignment_id == ^assignment.id
    )
  end

  defp row(nil), do: nil
  defp row(record), do: record |> Map.from_struct() |> Map.delete(:__meta__)
  defp rows(records), do: Enum.map(records, &row/1)
end
