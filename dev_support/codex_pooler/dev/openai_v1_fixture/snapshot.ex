defmodule CodexPooler.Dev.OpenAIV1Fixture.Snapshot do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.OpenAIV1Fixture.SnapshotReader
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}

  @type row :: %{optional(atom()) => term()}
  @opaque t :: %{
            required(:identity) => row() | nil,
            required(:identity_secrets) => [row()],
            required(:identity_quota_windows) => [row()],
            required(:pool) => row() | nil,
            required(:api_keys) => [row()],
            required(:routing_settings) => row() | nil,
            required(:assignment) => row() | nil,
            required(:models) => [row()],
            required(:routing_circuit_states) => [row()],
            required(:bridge_demotions) => [row()]
          }

  @keys ~w(identity identity_secrets identity_quota_windows pool api_keys routing_settings assignment models routing_circuit_states bridge_demotions)a
  @decode_modules [
    APIKey,
    Model,
    BridgeDemotion,
    RoutingCircuitState,
    Pool,
    RoutingSettings,
    EncryptedSecret,
    PoolUpstreamAssignment,
    UpstreamIdentity,
    AccountQuotaWindow,
    Ecto.Association.NotLoaded,
    DateTime,
    Decimal
  ]

  @spec capture() :: t()
  def capture, do: SnapshotReader.capture()

  @spec prepare_decode!() :: :ok
  def prepare_decode! do
    Enum.each(@decode_modules, &Code.ensure_loaded!/1)
    :ok
  end

  @spec parse(term()) :: {:ok, t()} | :error
  def parse(%{} = value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(@keys) and
         Enum.all?([:identity, :pool, :routing_settings, :assignment], fn key ->
           is_nil(value[key]) or is_map(value[key])
         end) and
         Enum.all?(
           [
             :identity_secrets,
             :identity_quota_windows,
             :api_keys,
             :models,
             :routing_circuit_states,
             :bridge_demotions
           ],
           fn key -> is_list(value[key]) and Enum.all?(value[key], &is_map/1) end
         ) do
      {:ok, value}
    else
      :error
    end
  end

  def parse(_value), do: :error

  @spec restore!(t()) :: :ok
  def restore!(snapshot) do
    existing_identity_id = get_in(snapshot, [:identity, :id])
    existing_pool_id = get_in(snapshot, [:pool, :id])

    restore_step!(:delete_fixture_rows, fn ->
      delete_fixture_rows!(snapshot, existing_identity_id, existing_pool_id)
    end)

    restore_step!(:pool, fn -> restore_row!(Pool, snapshot.pool) end)
    restore_step!(:identity, fn -> restore_row!(UpstreamIdentity, snapshot.identity) end)

    restore_step!(:routing_settings, fn ->
      restore_row!(RoutingSettings, snapshot.routing_settings, :pool_id)
    end)

    restore_step!(:assignment, fn ->
      restore_row!(PoolUpstreamAssignment, snapshot.assignment)
    end)

    restore_step!(:api_keys, fn -> restore_rows!(APIKey, snapshot.api_keys) end)
    restore_step!(:models, fn -> restore_rows!(Model, snapshot.models) end)

    restore_step!(:identity_secrets, fn ->
      restore_rows!(EncryptedSecret, snapshot.identity_secrets)
    end)

    restore_step!(:quota_windows, fn ->
      restore_rows!(AccountQuotaWindow, snapshot.identity_quota_windows)
    end)

    restore_step!(:routing_circuit_states, fn ->
      restore_rows!(RoutingCircuitState, snapshot.routing_circuit_states)
    end)

    restore_step!(:bridge_demotions, fn ->
      restore_rows!(BridgeDemotion, snapshot.bridge_demotions)
    end)
  end

  defp restore_step!(phase, function) do
    function.()
  rescue
    error ->
      raise RuntimeError,
            "OpenAI V1 fixture restore failed at #{phase} (#{inspect(error.__struct__)})"
  end

  defp delete_fixture_rows!(snapshot, existing_identity_id, existing_pool_id) do
    pool_id = existing_pool_id || SnapshotReader.fixture_pool_id()
    identity_id = existing_identity_id || SnapshotReader.fixture_identity_id()

    delete_pool_children(snapshot, pool_id)
    delete_identity_children(snapshot, identity_id)
    delete_assignment_state(snapshot, pool_id, identity_id)
    delete_created_parents(snapshot, pool_id, identity_id, existing_pool_id, existing_identity_id)
  end

  defp delete_pool_children(snapshot, pool_id) when is_binary(pool_id) do
    Repo.delete_all(
      from key in APIKey,
        where: key.pool_id == ^pool_id and key.id not in ^row_ids(snapshot.api_keys)
    )

    Repo.delete_all(
      from model in Model,
        where: model.pool_id == ^pool_id and model.id not in ^row_ids(snapshot.models)
    )
  end

  defp delete_pool_children(_snapshot, _pool_id), do: :ok

  defp delete_identity_children(snapshot, identity_id) when is_binary(identity_id) do
    Repo.delete_all(
      from window in AccountQuotaWindow,
        where:
          window.upstream_identity_id == ^identity_id and
            window.id not in ^row_ids(snapshot.identity_quota_windows)
    )

    Repo.delete_all(
      from secret in EncryptedSecret,
        where:
          secret.upstream_identity_id == ^identity_id and
            secret.id not in ^row_ids(snapshot.identity_secrets)
    )
  end

  defp delete_identity_children(_snapshot, _identity_id), do: :ok

  defp delete_assignment_state(snapshot, pool_id, identity_id) do
    case get_in(snapshot, [:assignment, :id]) do
      assignment_id when is_binary(assignment_id) ->
        delete_duplicate_assignments(pool_id, identity_id, assignment_id)

        delete_route_state(
          RoutingCircuitState,
          snapshot.routing_circuit_states,
          pool_id,
          assignment_id
        )

        delete_route_state(BridgeDemotion, snapshot.bridge_demotions, pool_id, assignment_id)

      nil ->
        assignment_id = SnapshotReader.fixture_assignment_id(pool_id, identity_id)
        delete_route_state(RoutingCircuitState, [], pool_id, assignment_id)
        delete_route_state(BridgeDemotion, [], pool_id, assignment_id)
        delete_assignment(assignment_id)
    end
  end

  defp delete_duplicate_assignments(pool_id, identity_id, assignment_id)
       when is_binary(pool_id) and is_binary(identity_id) do
    Repo.delete_all(
      from assignment in PoolUpstreamAssignment,
        where:
          assignment.pool_id == ^pool_id and assignment.upstream_identity_id == ^identity_id and
            assignment.id != ^assignment_id
    )
  end

  defp delete_duplicate_assignments(_pool_id, _identity_id, _assignment_id), do: :ok

  defp delete_created_parents(
         snapshot,
         pool_id,
         identity_id,
         existing_pool_id,
         existing_identity_id
       ) do
    if is_nil(existing_pool_id) and is_binary(pool_id) do
      Repo.delete_all(from settings in RoutingSettings, where: settings.pool_id == ^pool_id)
      Repo.delete_all(from pool in Pool, where: pool.id == ^pool_id)
    end

    if is_binary(existing_pool_id) and is_nil(snapshot.routing_settings) do
      Repo.delete_all(from settings in RoutingSettings, where: settings.pool_id == ^pool_id)
    end

    if is_nil(existing_identity_id) and is_binary(identity_id) do
      Repo.delete_all(from identity in UpstreamIdentity, where: identity.id == ^identity_id)
    end
  end

  defp delete_route_state(schema, rows, pool_id, assignment_id)
       when is_binary(pool_id) and is_binary(assignment_id) do
    Repo.delete_all(
      from state in schema,
        where:
          state.pool_id == ^pool_id and state.pool_upstream_assignment_id == ^assignment_id and
            state.id not in ^row_ids(rows)
    )
  end

  defp delete_route_state(_schema, _rows, _pool_id, _assignment_id), do: :ok

  defp delete_assignment(assignment_id) when is_binary(assignment_id) do
    Repo.delete_all(
      from assignment in PoolUpstreamAssignment, where: assignment.id == ^assignment_id
    )
  end

  defp delete_assignment(_assignment_id), do: :ok

  defp restore_rows!(schema, rows), do: Enum.each(rows, &restore_row!(schema, &1))
  defp restore_row!(schema, row, key \\ :id)
  defp restore_row!(_schema, nil, _key), do: :ok

  defp restore_row!(schema, row, key) do
    id = Map.fetch!(row, key)
    values = row |> Map.delete(key) |> Map.to_list()

    {1, _rows} =
      Repo.update_all(from(record in schema, where: field(record, ^key) == ^id), set: values)

    :ok
  end

  defp row_ids(rows), do: Enum.map(rows, & &1.id)
end
