defmodule CodexPooler.Upstreams.Quota.RoutingQuotaSnapshotTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Quotas.AccountAvailability
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @as_of ~U[2026-08-25 12:00:00.000000Z]

  test "bulk load deduplicates identities into one statement and preserves zero-row coverage" do
    with_windows = identity_with_availability!(:available, 3)
    without_windows = upstream_identity_fixture(metadata: %{"credential_epoch" => 7})
    insert_window!(with_windows, @as_of)

    queries =
      capture_queries(fn ->
        snapshots =
          RoutingQuotaSnapshot.load_by_identity_ids(
            [with_windows.id, without_windows.id, with_windows.id],
            @as_of
          )

        assert Map.keys(snapshots) |> Enum.sort() ==
                 Enum.sort([with_windows.id, without_windows.id])

        assert %RoutingQuotaSnapshot{
                 upstream_identity_id: identity_id,
                 raw_windows: [_window],
                 availability: %AccountAvailabilityStore.Snapshot{state: :available},
                 credential_epoch: 3,
                 as_of: @as_of
               } = snapshots[with_windows.id]

        assert identity_id == with_windows.id

        assert %RoutingQuotaSnapshot{
                 raw_windows: [],
                 availability: nil,
                 credential_epoch: 7,
                 as_of: @as_of
               } = snapshots[without_windows.id]
      end)

    assert length(queries) == 1
    assert hd(queries) =~ ~s(FROM "upstream_identities")
    assert hd(queries) =~ ~s(LEFT OUTER JOIN "account_quota_windows")
  end

  test "time-visible raw rows stay frozen while effective rows fold the same captured generation" do
    identity = upstream_identity_fixture()
    current = insert_window!(identity, @as_of, quota_key: "account")

    future =
      insert_window!(identity, DateTime.add(@as_of, 1, :second),
        quota_key: "model:future",
        quota_scope: "model",
        quota_family: "model",
        model: "future-model"
      )

    snapshot = RoutingQuotaSnapshot.load_by_identity_ids([identity.id], @as_of)[identity.id]

    assert Enum.map(snapshot.raw_windows, & &1.id) |> Enum.sort() ==
             Enum.sort([current.id, future.id])

    assert Enum.map(RoutingQuotaSnapshot.time_visible_raw_windows(snapshot), & &1.id) == [
             current.id
           ]

    assert Enum.map(RoutingQuotaSnapshot.effective_windows(snapshot), & &1.id) == [current.id]

    insert_window!(identity, @as_of,
      quota_key: "model:after-capture",
      quota_scope: "model",
      quota_family: "model",
      model: "after-capture"
    )

    assert Enum.map(RoutingQuotaSnapshot.time_visible_raw_windows(snapshot), & &1.id) == [
             current.id
           ]

    refreshed = RoutingQuotaSnapshot.load_by_identity_ids([identity.id], @as_of)[identity.id]
    assert length(RoutingQuotaSnapshot.time_visible_raw_windows(refreshed)) == 2
  end

  test "time-visible superseded raw evidence remains inspectable while effective display folds it" do
    identity = upstream_identity_fixture()
    frozen_at = DateTime.add(@as_of, -3_600, :second)

    frozen_primary =
      insert_window!(identity, frozen_at, reset_at: DateTime.add(@as_of, -900, :second))

    current_secondary =
      insert_window!(identity, @as_of,
        window_kind: "secondary",
        window_minutes: 10_080,
        reset_at: DateTime.add(@as_of, 1, :day)
      )

    snapshot = RoutingQuotaSnapshot.load_by_identity_ids([identity.id], @as_of)[identity.id]

    assert Enum.map(RoutingQuotaSnapshot.time_visible_raw_windows(snapshot), & &1.id)
           |> Enum.sort() ==
             Enum.sort([frozen_primary.id, current_secondary.id])

    assert Enum.map(RoutingQuotaSnapshot.effective_windows(snapshot), & &1.id) == [
             current_secondary.id
           ]
  end

  test "malformed availability is captured once as absent with the current credential epoch" do
    identity =
      upstream_identity_fixture(
        metadata: %{
          "credential_epoch" => 5,
          AccountAvailabilityStore.metadata_key() => %{"version" => 1, "state" => "invalid"}
        }
      )

    assert %RoutingQuotaSnapshot{availability: nil, credential_epoch: 5, as_of: @as_of} =
             RoutingQuotaSnapshot.load_by_identity_ids([identity.id], @as_of)[identity.id]
  end

  defp identity_with_availability!(state, epoch) do
    identity = upstream_identity_fixture(metadata: %{"credential_epoch" => epoch})

    metadata =
      AccountAvailabilityStore.transition(
        identity.metadata,
        AccountAvailability.new!(state, :affirmative, :absent),
        DateTime.add(@as_of, -1, :second),
        epoch
      )

    identity
    |> UpstreamIdentity.changeset(%{metadata: metadata})
    |> Repo.update!()
  end

  defp insert_window!(identity, observed_at, overrides \\ []) do
    attrs =
      %{
        quota_key: "account",
        window_kind: "primary",
        window_minutes: 300,
        used_percent: Decimal.new("12"),
        reset_at: DateTime.add(@as_of, 1, :hour),
        observed_at: observed_at,
        last_sync_at: observed_at,
        source: "codex_usage_api",
        source_precision: "observed",
        quota_scope: "account",
        quota_family: "account",
        freshness_state: "fresh"
      }
      |> Map.merge(Map.new(overrides))

    assert {:ok, window} = Windows.record_evidence(identity, attrs, observed_at)
    window
  end

  defp capture_queries(fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, owner ->
          if metadata[:source] == "upstream_identities" do
            send(owner, {:snapshot_query, metadata.query})
          end
        end,
        self()
      )

    try do
      fun.()
      drain_queries([])
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(queries) do
    receive do
      {:snapshot_query, query} -> drain_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
