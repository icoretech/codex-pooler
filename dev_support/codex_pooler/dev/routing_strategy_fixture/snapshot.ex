defmodule CodexPooler.Dev.RoutingStrategyFixture.Snapshot do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.RoutingStrategyFixture.SnapshotReader
  alias CodexPooler.Gateway.Persistence.{BridgeAffinity, BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}

  @type row :: %{optional(atom()) => term()}
  @opaque t :: %{
            required(:pool) => row() | nil,
            required(:routing_settings) => row() | nil,
            required(:api_keys) => [row()],
            required(:models) => [row()],
            required(:identities) => [row()],
            required(:identity_secrets) => [row()],
            required(:identity_quota_windows) => [row()],
            required(:assignments) => [row()]
          }

  @keys ~w(pool routing_settings api_keys models identities identity_secrets identity_quota_windows assignments)a
  @row_keys ~w(api_keys models identities identity_secrets identity_quota_windows assignments)a
  @decode_modules [
    APIKey,
    Model,
    BridgeAffinity,
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

  @spec capture(pos_integer()) :: t()
  def capture(assignment_count), do: SnapshotReader.capture(assignment_count)

  @spec empty_created() :: map()
  def empty_created do
    %{
      pool_id: nil,
      routing_settings_pool_id: nil,
      identity_ids: [],
      assignment_ids: [],
      model_ids: [],
      api_key_ids: [],
      request_ids: []
    }
  end

  @spec prepare_decode!() :: :ok
  def prepare_decode! do
    Enum.each(@decode_modules, &Code.ensure_loaded!/1)
    :ok
  end

  @spec parse(term()) :: {:ok, t()} | :error
  def parse(%{} = value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(@keys) and
         Enum.all?([:pool, :routing_settings], fn key ->
           is_nil(value[key]) or is_map(value[key])
         end) and
         Enum.all?(@row_keys, fn key ->
           is_list(value[key]) and Enum.all?(value[key], &is_map/1)
         end) do
      {:ok, value}
    else
      :error
    end
  end

  def parse(_value), do: :error

  @doc """
  Restores the exact captured rows and removes exactly the rows this fixture
  created, addressed by the journaled ids rather than by label or namespace.
  """
  @spec restore!(t(), map()) :: :ok
  def restore!(snapshot, created) do
    restore_step!(:delete_created_rows, fn -> delete_created_rows!(snapshot, created) end)

    restore_step!(:pool, fn -> restore_row!(Pool, snapshot.pool) end)
    restore_step!(:identities, fn -> restore_rows!(UpstreamIdentity, snapshot.identities) end)

    restore_step!(:routing_settings, fn ->
      restore_row!(RoutingSettings, snapshot.routing_settings, :pool_id)
    end)

    restore_step!(:assignments, fn ->
      restore_rows!(PoolUpstreamAssignment, snapshot.assignments)
    end)

    restore_step!(:api_keys, fn -> restore_rows!(APIKey, snapshot.api_keys) end)
    restore_step!(:models, fn -> restore_rows!(Model, snapshot.models) end)

    restore_step!(:identity_secrets, fn ->
      restore_rows!(EncryptedSecret, snapshot.identity_secrets)
    end)

    restore_step!(:quota_windows, fn ->
      restore_rows!(AccountQuotaWindow, snapshot.identity_quota_windows)
    end)

    :ok
  end

  defp restore_step!(phase, function) do
    function.()
  rescue
    error ->
      raise RuntimeError,
            "routing strategy fixture restore failed at #{phase} (#{inspect(error.__struct__)})"
  end

  defp delete_created_rows!(snapshot, created) do
    # Accounting first: deleting a request cascades its attempts and its
    # request-log fact, and the attempts reference the assignments below.
    delete_by_ids(Request, created.request_ids)

    delete_route_state(created.assignment_ids)

    delete_by_ids(APIKey, created.api_key_ids)
    delete_by_ids(Model, created.model_ids)

    identity_ids = fixture_identity_ids(snapshot, created)
    delete_identity_children(snapshot, identity_ids)

    delete_by_ids(PoolUpstreamAssignment, created.assignment_ids)
    delete_by_ids(UpstreamIdentity, created.identity_ids)

    if is_binary(created.routing_settings_pool_id) do
      Repo.delete_all(
        from settings in RoutingSettings,
          where: settings.pool_id == ^created.routing_settings_pool_id
      )
    end

    if is_binary(created.pool_id) do
      Repo.delete_all(from pool in Pool, where: pool.id == ^created.pool_id)
    end

    :ok
  end

  # Quota windows and encrypted secrets are upserted rather than created with a
  # journaled id, so they are scoped to the fixture's own identities and
  # excluded by the captured ids instead.
  defp delete_identity_children(_snapshot, []), do: :ok

  defp delete_identity_children(snapshot, identity_ids) do
    Repo.delete_all(
      from window in AccountQuotaWindow,
        where:
          window.upstream_identity_id in ^identity_ids and
            window.id not in ^row_ids(snapshot.identity_quota_windows)
    )

    Repo.delete_all(
      from secret in EncryptedSecret,
        where:
          secret.upstream_identity_id in ^identity_ids and
            secret.id not in ^row_ids(snapshot.identity_secrets)
    )

    :ok
  end

  defp delete_route_state([]), do: :ok

  defp delete_route_state(assignment_ids) do
    Enum.each([BridgeAffinity, BridgeDemotion, RoutingCircuitState], fn schema ->
      Repo.delete_all(
        from state in schema, where: state.pool_upstream_assignment_id in ^assignment_ids
      )
    end)
  end

  defp fixture_identity_ids(snapshot, created) do
    (row_ids(snapshot.identities) ++ created.identity_ids) |> Enum.uniq()
  end

  defp delete_by_ids(_schema, []), do: :ok

  defp delete_by_ids(schema, ids) when is_list(ids) do
    ids = Enum.filter(ids, &is_binary/1)

    case ids do
      [] -> :ok
      _ids -> Repo.delete_all(from record in schema, where: record.id in ^ids)
    end

    :ok
  end

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
