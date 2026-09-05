defmodule CodexPoolerWeb.Runtime.CodexUsageMeteredIdentityTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.UsageResponses
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Routing.CircuitHealth
  alias CodexPooler.Quotas.{AdditionalMeterIdentity, Evidence}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.DateTimeDisplay

  import CodexPooler.PoolerFixtures
  import Ecto.Query

  test "meter identity survives probe, reconciliation, omission TTL, all public aliases, and admin projection",
       %{
         conn: conn
       } do
    configure_upstream_secret_key!()

    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    payload = metered_usage_payload(observed_at)

    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {200, metered_usage_payload_without_additional(observed_at)}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    pool = pool_fixture()
    api_key = active_api_key_fixture(pool)
    account_id = "metered-identity-#{System.unique_integer([:positive])}"

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        metadata: %{
          "base_url" => FakeUpstream.url(upstream),
          "usage_path" => "/api/codex/usage"
        }
      })

    assert {:ok, %{status: :succeeded}} =
             Upstreams.reconcile_pool_account(pool, assignment)

    assert [] = identity |> QuotaWindows.list_evidence() |> usage_rows()
    assert [] = public_additional_limits(conn, api_key, "/api/codex/usage")
    refute Enum.any?(admin_additional_rows(identity, observed_at), &is_binary(&1.key))
    fence = mutation_fence(pool, identity)

    FakeUpstream.set_mode(upstream, {:path_json, %{"/api/codex/usage" => {200, payload}}})

    assert {:ok, %UsageProbe.Result{} = probe} =
             UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

    probe_additional = Enum.reject(probe.windows, &(&1.quota_key == "account"))
    covered_additional = Enum.reject(probe.covered_descriptors, &(elem(&1, 4) == "account"))

    assert length(probe_additional) == 2
    assert MapSet.size(MapSet.new(probe_additional, &AdditionalMeterIdentity.token/1)) == 2
    assert MapSet.size(MapSet.new(covered_additional)) == 2

    assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)
    assert mutation_fence(pool, identity) == fence

    raw_additional =
      identity
      |> QuotaWindows.list_evidence()
      |> Enum.reject(&(&1.quota_key == "account"))

    raw_usage_rows = usage_rows(raw_additional)
    assert length(raw_usage_rows) == 2

    assert MapSet.new(raw_usage_rows, &AdditionalMeterIdentity.token/1) ==
             MapSet.new(["meter_alpha", "meter_beta"])

    [first_observed_at] = raw_usage_rows |> Enum.map(& &1.observed_at) |> Enum.uniq()

    FakeUpstream.set_mode(
      upstream,
      {:path_json,
       %{
         "/api/codex/usage" => {200, metered_usage_payload_without_additional(observed_at)}
       }}
    )

    assert {:ok, %{status: :succeeded}} =
             Upstreams.reconcile_pool_account(pool, assignment)

    assert mutation_fence(pool, identity) == fence

    omitted_rows = identity |> QuotaWindows.list_evidence() |> usage_rows()

    assert MapSet.new(omitted_rows, &AdditionalMeterIdentity.token/1) ==
             MapSet.new(["meter_alpha", "meter_beta"])

    assert omitted_rows |> Enum.map(& &1.observed_at) |> Enum.uniq() == [first_observed_at]

    stale_at = DateTime.add(first_observed_at, Evidence.freshness_ttl_seconds() + 1, :second)

    stale_windows = QuotaWindows.list_quota_windows(identity, stale_at)

    assert [] = UsageResponses.additional_codex_rate_limits(stale_windows, stale_at)

    stale_admin_rows =
      stale_windows
      |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil), stale_at)

    refute Enum.any?(stale_admin_rows, &is_binary(&1.key))

    FakeUpstream.set_mode(upstream, {:path_json, %{"/api/codex/usage" => {200, payload}}})

    assert {:ok, %{status: :succeeded}} =
             Upstreams.reconcile_pool_account(pool, assignment)

    assert mutation_fence(pool, identity) == fence

    reappeared_at = DateTime.utc_now()

    effective_additional =
      identity
      |> QuotaWindows.list_quota_windows(reappeared_at)
      |> Enum.reject(&(&1.quota_key == "account"))

    assert Enum.map(effective_additional, &AdditionalMeterIdentity.token/1) == [
             "meter_alpha",
             "meter_beta"
           ]

    reappeared_rows = identity |> QuotaWindows.list_evidence() |> usage_rows()

    assert reappeared_rows |> Enum.map(& &1.observed_at) |> Enum.uniq() != [first_observed_at]

    admin_rows =
      effective_additional
      |> QuotaProjection.quota_limit_rows(
        DateTimeDisplay.preferences_for_user(nil),
        reappeared_at
      )

    assert Enum.count(admin_rows, &is_binary(&1.key)) == 2

    expected_public_additional = [
      {"shared_weekly_limit", "meter_alpha", 83},
      {"shared_weekly_limit", "meter_beta", 71}
    ]

    assert FakeUpstream.http_request_count(upstream) == 5

    for endpoint <- ["/api/codex/usage", "/wham/usage", "/backend-api/wham/usage"] do
      public_additional =
        conn
        |> recycle()
        |> put_req_header("authorization", api_key.authorization)
        |> get(endpoint)
        |> json_response(200)
        |> Map.fetch!("additional_rate_limits")

      assert Enum.map(public_additional, fn limit ->
               {
                 limit["quota_key"],
                 limit["metered_feature"],
                 get_in(limit, ["rate_limit", "secondary_window", "used_percent"])
               }
             end) == expected_public_additional
    end

    assert FakeUpstream.http_request_count(upstream) == 5
    assert mutation_fence(pool, identity) == %{fence | requests: fence.requests + 3}
  end

  test "null empty malformed and partial additional collections traverse the real usage boundary",
       %{conn: conn} do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    for {name, payload, expected_tokens} <- additional_collection_cases(observed_at) do
      configure_upstream_secret_key!()

      {:ok, upstream} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/usage" => {200, metered_usage_payload_without_additional(observed_at)}
           }}
        )

      on_exit(fn -> FakeUpstream.stop(upstream) end)
      pool = pool_fixture()
      api_key = active_api_key_fixture(pool)

      %{identity: identity, assignment: assignment} =
        active_upstream_assignment_fixture(pool, %{
          metadata: %{
            "base_url" => FakeUpstream.url(upstream),
            "usage_path" => "/api/codex/usage"
          }
        })

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)
      fence = mutation_fence(pool, identity)

      FakeUpstream.set_mode(upstream, {:path_json, %{"/api/codex/usage" => {200, payload}}})

      assert {:ok, %UsageProbe.Result{}} =
               UsageProbe.fetch_from_identity(identity, assignment, observed_at, [])

      assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

      assert Enum.map(
               identity |> QuotaWindows.list_evidence() |> usage_rows(),
               &AdditionalMeterIdentity.token/1
             ) == expected_tokens,
             name

      assert mutation_fence(pool, identity) == fence, name

      assert Enum.map(
               public_additional_limits(conn, api_key, "/wham/usage"),
               & &1["metered_feature"]
             ) == expected_tokens,
             name

      projection_at = DateTime.utc_now()

      admin_rows =
        identity
        |> QuotaWindows.list_quota_windows(projection_at)
        |> QuotaProjection.quota_limit_rows(
          DateTimeDisplay.preferences_for_user(nil),
          projection_at
        )
        |> Enum.filter(&is_binary(&1.key))

      assert length(admin_rows) == length(expected_tokens), name
      assert Enum.all?(admin_rows, &(&1.meter_state == :current)), name

      assert mutation_fence(pool, identity) == %{fence | requests: fence.requests + 1}, name
    end
  end

  test "a stable additional meter token updates one persisted row when its display label changes" do
    configure_upstream_secret_key!()

    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    first_payload = single_meter_usage_payload(observed_at, "Initial provider label")

    {:ok, upstream} =
      FakeUpstream.start_link({:path_json, %{"/api/codex/usage" => {200, first_payload}}})

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        metadata: %{
          "base_url" => FakeUpstream.url(upstream),
          "usage_path" => "/api/codex/usage"
        }
      })

    assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

    assert [%{id: first_id, raw_limit_name: "Initial provider label"}] =
             identity |> QuotaWindows.list_evidence() |> usage_rows()

    FakeUpstream.set_mode(
      upstream,
      {:path_json,
       %{
         "/api/codex/usage" =>
           {200, single_meter_usage_payload(observed_at, "Renamed provider label")}
       }}
    )

    assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

    assert [%{id: ^first_id, raw_limit_name: "Renamed provider label"}] =
             identity |> QuotaWindows.list_evidence() |> usage_rows()
  end

  test "a legacy label-derived meter row upgrades in place when the provider keeps its token" do
    configure_upstream_secret_key!()

    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" =>
             {200, single_meter_usage_payload(observed_at, "Renamed provider label")}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        metadata: %{
          "base_url" => FakeUpstream.url(upstream),
          "usage_path" => "/api/codex/usage"
        }
      })

    assert {:ok, [legacy]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "initial_provider_label",
                 quota_scope: "model",
                 quota_family: "codex_model",
                 model: "Initial provider label",
                 display_label: "Initial provider label",
                 limit_name: "Initial provider label",
                 metered_feature: "stable_meter",
                 raw_limit_id: "stable_meter",
                 raw_limit_name: "Initial provider label",
                 raw_metered_feature: "stable_meter",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("25"),
                 reset_at: DateTime.add(observed_at, 604_800, :second),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 observed_at: observed_at
               }
             ])

    assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

    assert [%{id: legacy_id, quota_key: "renamed_provider_label", quota_scope: "model"}] =
             identity |> QuotaWindows.list_evidence() |> usage_rows()

    assert legacy.id == legacy_id
  end

  defp metered_usage_payload(observed_at) do
    %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 12,
          "limit_window_seconds" => 18_000,
          "reset_at" => observed_at |> DateTime.add(18_000, :second) |> DateTime.to_unix()
        }
      },
      "additional_rate_limits" => [
        additional_limit("meter_alpha", 31, observed_at),
        additional_limit("meter_alpha", 83, observed_at),
        additional_limit("meter_beta", 71, observed_at)
      ]
    }
  end

  defp metered_usage_payload_without_additional(observed_at) do
    metered_usage_payload(observed_at)
    |> Map.delete("additional_rate_limits")
  end

  defp additional_collection_cases(observed_at) do
    base = metered_usage_payload_without_additional(observed_at)
    partial = additional_limit("partial_meter", 42, observed_at)

    [
      {"null", Map.put(base, "additional_rate_limits", nil), []},
      {"empty", Map.put(base, "additional_rate_limits", []), []},
      {"malformed", Map.put(base, "additional_rate_limits", %{}), []},
      {"partial", Map.put(base, "additional_rate_limits", [partial, %{"metered_feature" => 7}]),
       ["partial_meter"]}
    ]
  end

  defp public_additional_limits(conn, api_key, endpoint) do
    conn
    |> recycle()
    |> put_req_header("authorization", api_key.authorization)
    |> get(endpoint)
    |> json_response(200)
    |> Map.fetch!("additional_rate_limits")
  end

  defp admin_additional_rows(identity, as_of) do
    identity
    |> QuotaWindows.list_quota_windows(as_of)
    |> QuotaProjection.quota_limit_rows(DateTimeDisplay.preferences_for_user(nil), as_of)
  end

  defp mutation_fence(pool, identity) do
    current_identity = Repo.get!(UpstreamIdentity, identity.id)

    %{
      account_windows:
        identity
        |> QuotaWindows.list_evidence()
        |> Enum.filter(&(&1.quota_key == "account"))
        |> Enum.map(&{&1.credits, &1.used_percent, &1.reset_at})
        |> Enum.sort(),
      saved_resets: SavedResets.snapshot(current_identity) |> Map.drop([:observed_at]),
      circuits:
        pool.id
        |> CircuitHealth.active_circuits()
        |> Enum.map(&{&1.id, &1.status, &1.next_probe_at, &1.metadata}),
      requests:
        Repo.aggregate(from(request in Request, where: request.pool_id == ^pool.id), :count),
      attempts:
        Repo.aggregate(
          from(attempt in Attempt,
            join: request in Request,
            on: request.id == attempt.request_id,
            where: request.pool_id == ^pool.id
          ),
          :count
        ),
      ledger: Repo.aggregate(from(entry in LedgerEntry, where: entry.pool_id == ^pool.id), :count)
    }
  end

  defp single_meter_usage_payload(observed_at, label) do
    %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 12,
          "limit_window_seconds" => 18_000,
          "reset_at" => observed_at |> DateTime.add(18_000, :second) |> DateTime.to_unix()
        }
      },
      "additional_rate_limits" => [
        %{
          "limit_name" => label,
          "metered_feature" => "stable_meter",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => 25,
              "limit_window_seconds" => 604_800,
              "reset_at" => observed_at |> DateTime.add(604_800, :second) |> DateTime.to_unix()
            }
          }
        }
      ]
    }
  end

  defp usage_rows(windows) do
    Enum.filter(windows, &(&1.source == "codex_usage_api" and &1.quota_key != "account"))
  end

  defp additional_limit(meter, used_percent, observed_at) do
    %{
      "limit_name" => "Shared weekly limit",
      "metered_feature" => meter,
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => used_percent,
          "limit_window_seconds" => 604_800,
          "reset_at" => observed_at |> DateTime.add(604_800, :second) |> DateTime.to_unix()
        }
      }
    }
  end

  defp configure_upstream_secret_key! do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "metered-identity-test-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end
end
