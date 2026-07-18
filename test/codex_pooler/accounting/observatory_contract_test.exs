defmodule CodexPooler.Accounting.ObservatoryContractTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions.Principal, as: DashboardPrincipal
  alias CodexPooler.Accounting.Usage.Observatory
  alias CodexPooler.Accounting.Usage.Observatory.Principal
  alias CodexPooler.Repo

  @unauthorized %{
    code: :unauthorized,
    message: "Observatory reporting requires an authenticated principal"
  }

  defmodule ImposterPrincipal do
    @moduledoc false
    defstruct [:api_key, :pool]
  end

  test "allowlisted windows have deterministic UTC bounds and bucket counts" do
    pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)
    as_of = ~U[2026-07-17 12:34:56.987654Z]

    windows = [
      {"1h", 3_600, 300, 12},
      {"5h", 18_000, 900, 20},
      {"24h", 86_400, 3_600, 24},
      {"7d", 604_800, 21_600, 28}
    ]

    for {key, duration, bucket_seconds, bucket_count} <- windows do
      assert {:ok, projection} =
               Observatory.read(dashboard_principal(pool, api_key), key, as_of: as_of)

      assert projection.window.ended_at == ~U[2026-07-17 12:34:56Z]
      assert projection.window.started_at == DateTime.add(projection.window.ended_at, -duration)
      assert projection.window.bucket_seconds == bucket_seconds
      assert projection.window.bucket_count == bucket_count
      assert length(projection.buckets) == bucket_count
      assert hd(projection.buckets).started_at == projection.window.started_at
      assert List.last(projection.buckets).ended_at == projection.window.ended_at
      assert projection.accounting.status == "missing"
      assert projection.totals.cost.confidence == "unavailable"
    end
  end

  test "read/2 canonicalizes the dashboard principal before reporting" do
    pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)

    {result, events} =
      collect_repo_query_events(fn ->
        Observatory.read(dashboard_principal(pool, api_key), "1h")
      end)

    assert {:ok, _projection} = result

    assert Enum.map(events, & &1.projection) == [
             :observatory_principal,
             :observatory_grid,
             :observatory_outcomes
           ]

    assert length(events) == 3
    assert length(events) <= 8
  end

  test "malformed input and caller-provided ids fail before issuing a query" do
    pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)
    valid = dashboard_principal(pool, api_key)

    {results, events} =
      collect_repo_query_events(fn ->
        [
          Observatory.read(valid, "30m"),
          Observatory.read(valid, "1h", api_key_id: Ecto.UUID.generate()),
          Observatory.read(valid, "1h", pool_id: Ecto.UUID.generate()),
          Observatory.read(valid, "1h", as_of: "not-a-datetime"),
          Observatory.read(%{api_key: api_key, pool: pool}, "1h"),
          Observatory.read(%ImposterPrincipal{api_key: api_key, pool: pool}, "1h")
        ]
      end)

    assert Enum.all?(results, &match?({:error, _error}, &1))
    assert events == []
  end

  test "a caller-constructed resolved principal is rejected at the public boundary" do
    pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)
    resolved = %Principal{pool: pool, api_key: api_key}

    {result, events} =
      collect_repo_query_events(fn -> Observatory.read(resolved, "1h") end)

    assert result == {:error, @unauthorized}
    assert events == []
  end

  test "canonical dashboard principal is revalidated after key lifecycle changes" do
    scenarios = [
      {"dashboard access disabled", %{dashboard_access: false}},
      {"paused key", %{status: "paused"}},
      {"revoked key", %{status: "revoked"}},
      {
        "expired key",
        %{
          expires_at:
            DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)
        }
      }
    ]

    for {label, attrs} <- scenarios do
      pool = pool_fixture()
      api_key = dashboard_api_key_fixture(pool)
      principal = dashboard_principal(pool, api_key)

      assert {:ok, _projection} =
               Observatory.read(principal, "1h", as_of: ~U[2026-07-17 12:00:00Z])

      api_key
      |> APIKey.changeset(attrs)
      |> Repo.update!()

      assert Observatory.read(principal, "1h", as_of: ~U[2026-07-17 12:00:00Z]) ==
               {:error, @unauthorized},
             label
    end
  end

  test "canonical dashboard principal rejects a mismatched Pool" do
    pool = pool_fixture()
    other_pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)
    principal = dashboard_principal(other_pool, api_key)

    assert Observatory.read(principal, "1h", as_of: ~U[2026-07-17 12:00:00Z]) ==
             {:error, @unauthorized}
  end

  test "refresh executes four bounded projections and returns at most twelve outcomes" do
    pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "gpt-observatory-bounded"})
    upper_bound = ~U[2026-07-17 12:00:00Z]

    for offset <- 1..13 do
      pool
      |> timed_request(api_key, DateTime.add(upper_bound, -offset), %{
        model_id: model.id,
        status: "succeeded"
      })
    end

    {{:ok, projection}, events} =
      collect_repo_query_events(fn ->
        Observatory.read(dashboard_principal(pool, api_key), "1h", as_of: upper_bound)
      end)

    assert Enum.map(events, & &1.projection) == [
             :observatory_principal,
             :observatory_grid,
             :observatory_outcomes
           ]

    assert length(events) == 3
    assert length(events) <= 8
    assert projection.totals.requests.total == 13
    assert length(projection.outcomes) == 12

    assert Enum.map(projection.outcomes, &DateTime.to_unix(&1.timestamp)) ==
             Enum.map(1..12, &(upper_bound |> DateTime.add(-&1) |> DateTime.to_unix()))

    assert Enum.all?(projection.outcomes, fn outcome ->
             Map.keys(outcome) |> Enum.sort() ==
               [
                 :code,
                 :cost,
                 :endpoint_class,
                 :model,
                 :response_status_code,
                 :status,
                 :timestamp,
                 :total_tokens
               ]
           end)
  end

  def handle_repo_query_event(_event, _measurements, metadata, {handler_id, test_pid}) do
    projection = get_in(metadata, [:options, :reporting_projection])

    if metadata[:repo] == Repo do
      send(test_pid, {handler_id, %{projection: projection}})
    end
  end

  defp collect_repo_query_events(fun) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        &__MODULE__.handle_repo_query_event/4,
        {handler_id, self()}
      )

    try do
      {fun.(), drain_repo_query_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_query_events(handler_id, events) do
    receive do
      {^handler_id, event} -> drain_repo_query_events(handler_id, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp dashboard_api_key_fixture(pool) do
    %{api_key: api_key} = active_api_key_fixture(pool)

    api_key
    |> APIKey.changeset(%{dashboard_access: true})
    |> Repo.update!()
  end

  defp dashboard_principal(pool, api_key) do
    DashboardPrincipal.new(%{
      api_key_id: api_key.id,
      pool_id: pool.id,
      display_name: api_key.display_name,
      key_prefix: api_key.key_prefix
    })
  end

  defp timed_request(pool, api_key, timestamp, attrs) do
    timestamp = %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}}

    %{pool: pool, api_key: api_key}
    |> request_fixture(attrs)
    |> Ecto.Changeset.change(%{admitted_at: timestamp, completed_at: timestamp})
    |> Repo.update!()
  end
end
