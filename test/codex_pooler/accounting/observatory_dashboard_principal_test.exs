defmodule CodexPooler.Accounting.ObservatoryDashboardPrincipalTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Accounting.ObservatoryDashboardPrincipalFixture, as: Fixture
  alias CodexPooler.Accounting.ObservatoryDashboardPrincipalSupport, as: Support
  alias CodexPooler.Accounting.Usage.Observatory
  alias CodexPooler.ObservatorySecrecy, as: Secrecy
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  @as_of ~U[2026-07-17 12:00:00Z]
  @occurred_at ~U[2026-07-17 11:30:00.000000Z]
  @unauthorized %{
    code: :unauthorized,
    message: "Observatory reporting requires an authenticated principal"
  }

  test "authenticated key independently excludes another key and another Pool" do
    %{principal: principal, conflicts: conflicts} = Fixture.isolation_fixture!()

    assert {:ok, baseline} = Observatory.read(principal, "1h", as_of: Fixture.as_of())
    Fixture.insert_conflicting_facts!(conflicts)
    assert {:ok, report} = Observatory.read(principal, "1h", as_of: Fixture.as_of())
    assert report == baseline

    assert report.totals.requests == %{total: 3, succeeded: 1, failed: 1, in_progress: 1}

    assert report.totals.tokens == %{
             input: 12,
             cached_input: 4,
             output: 8,
             reasoning: 1,
             total: 25
           }

    assert report.totals.cost == %{
             settled: %{status: "settled", micros: 125},
             estimated: %{status: "estimated", micros: 250},
             unavailable_requests: 1,
             confidence: "partial"
           }

    empty = {0, 0, 0, 0, 0, "unavailable", 0, "unavailable", 0, 0}

    assert Enum.map(report.buckets, &Support.bucket_signature/1) == [
             {1, 0, 1, 0, 25, "settled", 125, "unavailable", 0, 0},
             empty,
             empty,
             empty,
             empty,
             empty,
             {1, 1, 0, 0, 0, "unavailable", 0, "estimated", 250, 0},
             empty,
             empty,
             empty,
             empty,
             {1, 0, 0, 1, 0, "unavailable", 0, "unavailable", 0, 1}
           ]

    assert report.models == [
             %{
               label: "gpt-observatory-principal",
               request_count: 3,
               total_tokens: 25,
               share_percent: 100.0,
               cost_micros: 375
             }
           ]

    assert Enum.map(report.outcomes, fn outcome ->
             Map.take(outcome, [:timestamp, :status, :code, :model, :total_tokens, :cost])
           end) == [
             %{
               timestamp: ~U[2026-07-17 11:58:00.000000Z],
               status: "in_progress",
               code: nil,
               model: "gpt-observatory-principal",
               total_tokens: 0,
               cost: %{status: "unavailable", micros: 0}
             },
             %{
               timestamp: ~U[2026-07-17 11:31:00.000000Z],
               status: "succeeded",
               code: nil,
               model: "gpt-observatory-principal",
               total_tokens: 0,
               cost: %{status: "estimated", micros: 250}
             },
             %{
               timestamp: ~U[2026-07-17 11:02:00.000000Z],
               status: "failed",
               code: "request_failed",
               model: "gpt-observatory-principal",
               total_tokens: 25,
               cost: %{status: "settled", micros: 125}
             }
           ]

    hostile_metadata_is_opaque? =
      Secrecy.safe_observable?(inspect(report, limit: :infinity), Fixture.excluded_artifacts())

    assert hostile_metadata_is_opaque?
  end

  test "dashboard principal lifecycle and association failures share one unauthorized shape" do
    pool = pool_fixture()
    other_pool = pool_fixture()
    valid_key = Fixture.opted_in_api_key_fixture(pool)

    missing_key = %{
      Fixture.dashboard_principal(valid_key, pool)
      | api_key_id: Ecto.UUID.generate()
    }

    opted_out_key = active_api_key_fixture(pool).api_key
    paused_key = Fixture.opted_in_api_key_fixture(pool, %{status: "paused"})
    revoked_key = Fixture.opted_in_api_key_fixture(pool, %{status: "revoked"})

    expired_key =
      Fixture.opted_in_api_key_fixture(pool, %{
        expires_at: DateTime.utc_now() |> DateTime.add(-60, :second)
      })

    disabled_pool = pool_fixture()
    disabled_pool_key = Fixture.opted_in_api_key_fixture(disabled_pool)

    disabled_pool
    |> Pool.changeset(%{
      status: "disabled",
      disabled_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()

    principals = [
      Fixture.dashboard_principal(valid_key, other_pool),
      missing_key,
      Fixture.dashboard_principal(opted_out_key, pool),
      Fixture.dashboard_principal(paused_key, pool),
      Fixture.dashboard_principal(revoked_key, pool),
      Fixture.dashboard_principal(expired_key, pool),
      Fixture.dashboard_principal(disabled_pool_key, disabled_pool)
    ]

    for principal <- principals do
      assert Observatory.read(principal, "1h", as_of: @as_of) == {:error, @unauthorized}
    end
  end

  test "dashboard read executes one canonical load and five bounded reporting queries" do
    pool = pool_fixture()
    api_key = Fixture.opted_in_api_key_fixture(pool)
    Fixture.record_usage(pool, api_key, "bounded-model", 23, @occurred_at)

    {result, projections} =
      Support.collect_repo_queries(fn ->
        Observatory.read(Fixture.dashboard_principal(api_key, pool), "1h", as_of: @as_of)
      end)

    assert {:ok, report} = result
    assert report.totals.requests.total == 1

    assert projections == [
             :observatory_principal,
             :observatory_grid,
             :observatory_outcomes
           ]
  end

  test "canonical loading and reporting do not touch keys, sessions, or accounting rows" do
    pool = pool_fixture()
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture(pool)
    api_key = Fixture.enable_dashboard_access!(api_key)
    Fixture.record_usage(pool, api_key, "side-effect-check", 31, @occurred_at)

    assert {:ok, %{token: browser_token}} = Access.issue_dashboard_session(raw_key)
    assert {:ok, principal} = Access.authenticate_dashboard_session(browser_token)

    session = Repo.get_by!(APIKeyDashboardSession, api_key_id: api_key.id)
    session_state = {session.expires_at, session.inserted_at}
    accounting_counts = Support.accounting_counts()
    audit_count = Support.audit_count()
    last_used_at = Repo.get!(APIKey, api_key.id).last_used_at
    session_count = Repo.aggregate(APIKeyDashboardSession, :count, :id)

    assert {:ok, _report} = Observatory.read(principal, "1h", as_of: @as_of)

    reloaded_session = Repo.get!(APIKeyDashboardSession, session.id)
    assert {reloaded_session.expires_at, reloaded_session.inserted_at} == session_state
    assert Repo.aggregate(APIKeyDashboardSession, :count, :id) == session_count
    assert Repo.get!(APIKey, api_key.id).last_used_at == last_used_at
    assert Support.accounting_counts() == accounting_counts
    assert Support.audit_count() == audit_count
  end

  test "dashboard authentication and reporting keep raw credentials out of logs and telemetry" do
    pool = pool_fixture()
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture(pool)
    api_key = Fixture.enable_dashboard_access!(api_key)
    Fixture.record_usage(pool, api_key, "telemetry-boundary", 37, @occurred_at)

    assert {:ok, %{token: browser_token}} = Access.issue_dashboard_session(raw_key)
    parent = self()

    logs =
      capture_log(fn ->
        {result, telemetry_metadata} =
          Support.collect_repo_queries(
            fn ->
              with {:ok, principal} <- Access.authenticate_dashboard_session(browser_token) do
                Observatory.read(principal, "1h", as_of: @as_of)
              end
            end,
            true
          )

        send(parent, {:observatory_credential_capture, result, telemetry_metadata})
      end)

    assert_receive {:observatory_credential_capture, {:ok, _report}, telemetry_metadata}

    credential_secrecy? =
      Secrecy.safe_observable?([logs | telemetry_metadata], [raw_key, browser_token])

    assert credential_secrecy?
  end
end
