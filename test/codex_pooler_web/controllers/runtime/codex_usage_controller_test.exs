defmodule CodexPoolerWeb.Runtime.CodexUsageControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [monthly_only_account_primary_quota_window_attrs: 1]

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounting.UsageResponses
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore

  @removed_reset_credit_paths [
    "/api/codex/rate-limit-reset-credits/consume",
    "/wham/rate-limit-reset-credits/consume",
    "/backend-api/wham/rate-limit-reset-credits/consume"
  ]

  test "GET /api/codex/usage returns API-key Codex usage shape", %{conn: conn} do
    setup = active_api_key_fixture()

    conn =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> get("/api/codex/usage")

    response = json_response(conn, 200)

    assert %{"plan_type" => "api_key", "rate_limit" => rate_limit} = response
    assert is_map(rate_limit)
    refute Map.has_key?(response, "credits")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/api/codex/usage"
    assert request.transport == "http_json"
    assert request.status == "succeeded"
    assert request.request_metadata["operation"] == "usage"
  end

  test "GET /backend-api/wham/usage is logged and returns the best routable upstream usage", %{
    conn: conn
  } do
    pool = pool_fixture()
    setup = active_api_key_fixture(pool)

    %{identity: free_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "usage-free-account",
        plan_family: "free"
      })

    %{identity: pro_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "usage-pro-account",
        plan_family: "pro"
      })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(free_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(pro_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("12"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("chatgpt-account-id", "usage-free-account")
      |> get("/backend-api/wham/usage")

    assert %{
             "plan_type" => "pro",
             "rate_limit" => %{
               "allowed" => true,
               "limit_reached" => false,
               "primary_window" => %{"used_percent" => 12}
             }
           } = json_response(conn, 200)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^pool.id))
    assert request.endpoint == "/backend-api/wham/usage"
    assert request.status == "succeeded"
    assert request.request_metadata["operation"] == "usage"
  end

  test "GET /backend-api/wham/usage does not report a superseded frozen 5h window", %{
    conn: conn
  } do
    pool = pool_fixture()
    setup = active_api_key_fixture(pool)

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "usage-superseded-account",
        plan_family: "pro"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    frozen_observed_at = DateTime.add(now, -2 * 3600, :second)

    assert {:ok, _frozen} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("58"),
                 reset_at: DateTime.add(frozen_observed_at, 10_800, :second),
                 source: "codex_response_headers",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 last_sync_at: frozen_observed_at,
                 observed_at: frozen_observed_at
               }
             ])

    assert {:ok, _weekly} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("1"),
                 reset_at: DateTime.add(now, 6, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 last_sync_at: now,
                 observed_at: now
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("chatgpt-account-id", "usage-superseded-account")
      |> get("/backend-api/wham/usage")

    assert %{"rate_limit" => rate_limit} = json_response(conn, 200)
    assert rate_limit["primary_window"] == nil
    assert %{"used_percent" => 1} = rate_limit["secondary_window"]
  end

  test "GET /backend-api/wham/usage does not let effectively quota-less identities outrank exhausted ones",
       %{conn: conn} do
    pool = pool_fixture()
    setup = active_api_key_fixture(pool)

    # ghost identity: raw account rows exist but none survive the effective
    # view — it must not win candidacy with an allowed-looking empty payload
    %{identity: ghost_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "usage-ghost-account",
        plan_family: "pro"
      })

    %{identity: exhausted_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "usage-exhausted-account",
        plan_family: "pro"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # the ghost's only account evidence is future-dated: raw rows exist, the
    # effective view at request time is empty
    assert {:ok, _future_primary} =
             QuotaWindows.upsert_quota_windows(ghost_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("1"),
                 reset_at: DateTime.add(now, 10_800, :second),
                 source: "codex_response_headers",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 last_sync_at: DateTime.add(now, 120, :second),
                 observed_at: DateTime.add(now, 120, :second)
               }
             ])

    assert {:ok, _exhausted_weekly} =
             QuotaWindows.upsert_quota_windows(exhausted_identity, [
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("100"),
                 credits: 0,
                 reset_at: DateTime.add(now, 6, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 last_sync_at: now,
                 observed_at: now
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("chatgpt-account-id", "usage-exhausted-account")
      |> get("/backend-api/wham/usage")

    assert %{"rate_limit" => rate_limit} = json_response(conn, 200)
    assert rate_limit["allowed"] == false
    assert rate_limit["limit_reached"] == true
    assert %{"used_percent" => 100} = rate_limit["secondary_window"]
  end

  test "GET /api/codex/usage follows a confirmed fixed-anchor weekly reset", %{conn: conn} do
    setup = usage_reset_identity_fixture()
    %{identity: identity, observed_at: observed_at, reset_at: reset_at} = setup

    assert {:ok, canonical} =
             EvidenceStore.record_evidence(
               identity,
               weekly_quota_evidence(observed_at, reset_at, "100", %{},
                 active_limit: 243,
                 credits: 0
               ),
               observed_at,
               observed_at
             )

    candidate_at = DateTime.add(observed_at, 5, :minute)

    assert {:ok, _pending} =
             EvidenceStore.record_evidence(
               identity,
               safe_weekly_zero(candidate_at, reset_at),
               candidate_at,
               candidate_at
             )

    pending = Repo.get!(AccountQuotaWindow, canonical.id)
    assert Decimal.equal?(pending.used_percent, Decimal.new("100"))
    assert_exhausted_routing(identity, pending, candidate_at)
    assert_exhausted_usage_response(conn, setup)

    confirmed_at = DateTime.add(candidate_at, 180, :second)

    assert {:ok, _confirmed} =
             EvidenceStore.record_evidence(
               identity,
               safe_weekly_zero(confirmed_at, reset_at),
               confirmed_at,
               confirmed_at
             )

    confirmed = Repo.get!(AccountQuotaWindow, canonical.id)
    assert Decimal.equal?(confirmed.used_percent, Decimal.new("0"))
    assert confirmed.active_limit == nil
    assert confirmed.credits == nil

    assert %{
             eligible?: true,
             routing_state: :weekly_only_probe,
             selection: %{secondary: %AccountQuotaWindow{id: confirmed_id}, blocked_windows: []}
           } = QuotaWindows.routing_quota_eligibility(identity, at: confirmed_at)

    assert confirmed_id == confirmed.id

    assert %{
             "rate_limit" => %{
               "allowed" => true,
               "limit_reached" => false,
               "secondary_window" => %{"used_percent" => 0}
             }
           } = usage_response(recycle(conn), setup)
  end

  test "GET /api/codex/usage keeps contradictory and replayed weekly resets exhausted", %{
    conn: conn
  } do
    cases = [
      {:contradictory,
       fn candidate_at, confirmed_at, reset_at ->
         {
           weekly_quota_evidence(candidate_at, reset_at, "0", safe_status()),
           weekly_quota_evidence(confirmed_at, reset_at, "0", %{
             "rate_limit_allowed" => true,
             "rate_limit_reached" => true
           })
         }
       end},
      {:replayed,
       fn candidate_at, confirmed_at, reset_at ->
         {
           safe_weekly_zero(candidate_at, reset_at),
           safe_weekly_zero(confirmed_at, reset_at, provider_at: candidate_at)
         }
       end}
    ]

    Enum.reduce(cases, conn, fn {_name, observations_for}, current_conn ->
      setup = usage_reset_identity_fixture()
      %{identity: identity, observed_at: observed_at, reset_at: reset_at} = setup

      assert {:ok, canonical} =
               EvidenceStore.record_evidence(
                 identity,
                 weekly_quota_evidence(observed_at, reset_at, "100", %{},
                   active_limit: 243,
                   credits: 0
                 ),
                 observed_at,
                 observed_at
               )

      candidate_at = DateTime.add(observed_at, 5, :minute)
      confirmed_at = DateTime.add(candidate_at, 180, :second)
      {candidate, confirmation} = observations_for.(candidate_at, confirmed_at, reset_at)

      for {evidence, at} <- [{candidate, candidate_at}, {confirmation, confirmed_at}] do
        assert {:ok, _row} = EvidenceStore.record_evidence(identity, evidence, at, at)
      end

      persisted = Repo.get!(AccountQuotaWindow, canonical.id)
      assert Decimal.equal?(persisted.used_percent, Decimal.new("100"))
      assert persisted.active_limit == 243
      assert persisted.credits == 0
      assert_exhausted_routing(identity, persisted, confirmed_at)
      assert_exhausted_usage_response(recycle(current_conn), setup)

      recycle(current_conn)
    end)
  end

  test "GET /api/codex/usage supports ChatGPT account usage branch", %{conn: conn} do
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "chatgpt-account-1",
        account_label: "Percent-only selected account",
        plan_family: "pro"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "upstream-chatgpt-token"
             })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("67"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               },
               %{
                 quota_key: "gpt_5_3_codex_spark",
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("55"),
                 display_label: "GPT-5.3-Codex-Spark",
                 limit_name: "codex_other",
                 metered_feature: "codex_bengalfox",
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer upstream-chatgpt-token")
      |> put_req_header("chatgpt-account-id", "chatgpt-account-1")
      |> get("/api/codex/usage")

    response = json_response(conn, 200)

    assert %{
             "plan_type" => "pro",
             "rate_limit" => %{
               "allowed" => true,
               "limit_reached" => false,
               "primary_window" => %{"used_percent" => 67}
             },
             "additional_rate_limits" => [
               %{
                 "quota_key" => "codex_spark",
                 "display_label" => "GPT-5.3-Codex-Spark",
                 "metered_feature" => "codex_bengalfox",
                 "rate_limit" => %{"primary_window" => %{"used_percent" => 55}}
               }
             ]
           } = response

    refute Map.has_key?(response, "credits")

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^pool.id))
    assert request.api_key_id == nil
    assert request.endpoint == "/api/codex/usage"
    assert request.status == "succeeded"
    assert request.request_metadata["auth_mode"] == "chatgpt_account_token"
    assert request.upstream_account_label == identity.account_label
    assert is_nil(request.upstream_account_email)

    assert %{items: [log], total: 1} = Accounting.list_request_logs(pool)
    assert log.api_key_id == nil
    assert log.upstream_account_label == identity.account_label
    assert is_nil(log.upstream_account_email)
  end

  test "Codex rate-limit output keeps absent and jointly healthy windows allowed" do
    assert %{
             allowed: true,
             limit_reached: false,
             primary_window: nil,
             secondary_window: nil
           } = UsageResponses.codex_rate_limit(nil, nil)

    primary = %{
      remaining_value: 1,
      max_value: nil,
      current_value: nil,
      used_percent: 12,
      reset_at: nil,
      limit_window: "5h"
    }

    secondary = %{
      remaining_value: 1,
      max_value: nil,
      current_value: nil,
      used_percent: 40,
      reset_at: nil,
      limit_window: "7d"
    }

    assert %{
             allowed: true,
             limit_reached: false,
             primary_window: %{used_percent: 12},
             secondary_window: %{used_percent: 40}
           } = UsageResponses.codex_rate_limit(primary, secondary)
  end

  test "additional Codex rate limits require every emitted window to allow" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    primary = %AccountQuotaWindow{
      quota_key: "codex_spark",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("100"),
      reset_at: DateTime.add(now, 5, :hour),
      source: "test",
      freshness_state: "fresh",
      observed_at: now
    }

    secondary = %AccountQuotaWindow{
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("40"),
      reset_at: DateTime.add(now, 7, :day),
      source: "test",
      freshness_state: "fresh",
      observed_at: now
    }

    assert [
             %{
               quota_key: "codex_spark",
               rate_limit: %{
                 allowed: false,
                 limit_reached: true,
                 primary_window: %{used_percent: 100},
                 secondary_window: %{used_percent: 40}
               }
             }
           ] = UsageResponses.additional_codex_rate_limits([primary, secondary], now)
  end

  test "GET /api/codex/usage requires every account rate-limit window to allow", %{conn: conn} do
    pool = pool_fixture()
    account_id = "two-window-account-#{System.unique_integer([:positive])}"
    token = "two-window-token-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        plan_family: "pro"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: token
             })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(now, 5, :hour),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 last_sync_at: now,
                 observed_at: now
               },
               %{
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new("40"),
                 reset_at: DateTime.add(now, 7, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 freshness_state: "fresh",
                 last_sync_at: now,
                 observed_at: now
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("chatgpt-account-id", account_id)
      |> get("/api/codex/usage")

    assert %{
             "rate_limit" => %{
               "allowed" => false,
               "limit_reached" => true,
               "primary_window" => %{"used_percent" => 100},
               "secondary_window" => %{"used_percent" => 40}
             }
           } = json_response(conn, 200)
  end

  test "GET /api/codex/usage ChatGPT token branch returns only that account usage", %{conn: conn} do
    pool = pool_fixture()

    %{identity: free_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "chatgpt-free-account",
        plan_family: "free"
      })

    %{identity: pro_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "chatgpt-pro-account",
        plan_family: "pro"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(free_identity, %{
               secret_kind: "access_token",
               plaintext: "free-upstream-token"
             })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(pro_identity, %{
               secret_kind: "access_token",
               plaintext: "pro-upstream-token"
             })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(free_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("100"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(pro_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("5"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer free-upstream-token")
      |> put_req_header("chatgpt-account-id", "chatgpt-free-account")
      |> get("/api/codex/usage")

    assert %{
             "plan_type" => "free",
             "rate_limit" => %{
               "allowed" => false,
               "limit_reached" => true,
               "primary_window" => %{"used_percent" => 100}
             }
           } = json_response(conn, 200)
  end

  test "GET /api/codex/usage ChatGPT token branch selects the token-matched workspace slot", %{
    conn: conn
  } do
    pool = pool_fixture()
    account_id = "chatgpt-shared-account-#{System.unique_integer([:positive])}"

    %{identity: free_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        workspace_id: "ws_usage_free",
        account_label: "Selected token workspace account",
        plan_family: "free",
        plan_label: "Selected token workspace plan"
      })

    %{identity: pro_identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        workspace_id: "ws_usage_pro",
        account_label: "Rival workspace account",
        plan_family: "pro",
        plan_label: "Rival workspace plan"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(free_identity, %{
               secret_kind: "access_token",
               plaintext: "free-slot-token"
             })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(pro_identity, %{
               secret_kind: "access_token",
               plaintext: "pro-slot-token"
             })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(free_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("91"),
                 active_limit: 100,
                 credits: 9,
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(pro_identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("53"),
                 active_limit: 100,
                 credits: 47,
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer free-slot-token")
      |> put_req_header("chatgpt-account-id", account_id)
      |> get("/api/codex/usage")

    assert %{
             "plan_type" => "Selected token workspace plan",
             "rate_limit" => %{
               "allowed" => true,
               "limit_reached" => false,
               "primary_window" => %{"used_percent" => 91}
             },
             "credits" => %{"has_credits" => true, "unlimited" => false, "balance" => "9"}
           } = json_response(conn, 200)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^pool.id))
    assert request.upstream_account_label == free_identity.account_label
  end

  test "GET /api/codex/usage preserves provider percent for a credit-bearing usage payload", %{
    conn: conn
  } do
    pool = pool_fixture()
    account_id = "credit-percent-account-#{System.unique_integer([:positive])}"
    token = "credit-percent-token-#{System.unique_integer([:positive])}"

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        account_label: "Credit percent account",
        plan_family: "pro"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: token
             })

    observed_at =
      DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond)

    reset_at = DateTime.add(observed_at, 20, :day)

    assert {:ok, [window]} =
             QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
               identity,
               %{
                 "credits" => %{"balance" => 601},
                 "rate_limit" => %{
                   "primary_window" => %{
                     "used_percent" => 3,
                     "limit_window_seconds" => 2_592_000,
                     "reset_at" => DateTime.to_unix(reset_at)
                   }
                 }
               },
               observed_at
             )

    assert window.active_limit == 601
    assert window.credits == 601
    assert Decimal.equal?(window.used_percent, Decimal.new("3"))

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("chatgpt-account-id", account_id)
      |> get("/api/codex/usage")

    assert %{
             "rate_limit" => %{
               "allowed" => true,
               "limit_reached" => false,
               "primary_window" => %{"used_percent" => 3}
             },
             "credits" => %{"has_credits" => true, "unlimited" => false, "balance" => "601"}
           } = json_response(conn, 200)

    burn_observed_at = DateTime.add(observed_at, 60, :second)

    assert {:ok, [burning_window]} =
             QuotaWindows.upsert_quota_windows_from_codex_usage_payload(
               identity,
               %{
                 "credits" => %{"balance" => 500},
                 "rate_limit" => %{
                   "primary_window" => %{
                     "used_percent" => 100,
                     "limit_window_seconds" => 2_592_000,
                     "reset_at" => DateTime.to_unix(reset_at)
                   }
                 }
               },
               burn_observed_at
             )

    assert burning_window.active_limit == 601
    assert burning_window.credits == 500

    burn_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("chatgpt-account-id", account_id)
      |> get("/api/codex/usage")

    assert %{
             "rate_limit" => %{
               "allowed" => true,
               "limit_reached" => false,
               "primary_window" => %{"used_percent" => 100}
             },
             "credits" => %{"has_credits" => true, "unlimited" => false, "balance" => "500"}
           } = json_response(burn_conn, 200)
  end

  test "GET /api/codex/usage returns monthly-only primary window seconds without secondary synthesis",
       %{
         conn: conn
       } do
    pool = pool_fixture()
    now = ~U[2026-06-07 12:00:00Z]
    account_id = "monthly-account-#{System.unique_integer([:positive])}"

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        account_label: "Monthly usage account",
        plan_label: "Free-looking label"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "monthly-usage-token"
             })

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               monthly_only_account_primary_quota_window_attrs(%{
                 observed_at: now,
                 last_sync_at: now,
                 reset_at: DateTime.add(now, 30, :day)
               })
             ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer monthly-usage-token")
      |> put_req_header("chatgpt-account-id", account_id)
      |> get("/api/codex/usage")

    response = json_response(conn, 200)

    assert %{
             "plan_type" => "unknown",
             "rate_limit" =>
               %{"primary_window" => %{"limit_window_seconds" => 2_592_000} = primary_window} =
                 rate_limit
           } = response

    assert primary_window["used_percent"] == 43
    assert is_nil(rate_limit["secondary_window"])
    refute Map.has_key?(response, "credits")

    response_text = conn.resp_body
    refute response_text =~ "1134"
    refute response_text =~ "Free-looking label"
  end

  test "GET /api/codex/usage returns a statusful gateway error for inactive ChatGPT account usage",
       %{conn: conn} do
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "inactive-chatgpt-account",
        assignment_status: "disabled"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "inactive-account-token"
             })

    conn =
      conn
      |> put_req_header("authorization", "Bearer inactive-account-token")
      |> put_req_header("chatgpt-account-id", "inactive-chatgpt-account")
      |> get("/api/codex/usage")

    assert %{"error" => error} = json_response(conn, 404)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "invalid_chatgpt_account"
    assert error["message"] == "unknown or inactive chatgpt-account-id"
  end

  test "GET /api/codex/usage requires a bearer token for ChatGPT account mode", %{conn: conn} do
    conn = conn |> put_req_header("chatgpt-account-id", "acct") |> get("/api/codex/usage")

    assert json_response(conn, 401)["error"]["code"] == "invalid_authorization"
  end

  test "GET /api/codex/usage rejects invalid auth before admission", %{conn: conn} do
    attach_admission_probe()

    conn = conn |> put_req_header("chatgpt-account-id", "acct") |> get("/api/codex/usage")

    assert json_response(conn, 401)["error"]["code"] == "invalid_authorization"
    refute_received {:usage_admission_event, _event, _metadata}
  end

  test "GET /api/codex/usage rejects mismatched ChatGPT account token", %{conn: conn} do
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "chatgpt-account-2"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "real-token"
             })

    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-token")
      |> put_req_header("chatgpt-account-id", "chatgpt-account-2")
      |> get("/api/codex/usage")

    assert json_response(conn, 401)["error"]["code"] == "invalid_authorization"
  end

  test "POST reset-credit consume routes are absent before malformed body handling" do
    for path <- @removed_reset_credit_paths do
      assert Phoenix.Router.route_info(CodexPoolerWeb.Router, "POST", path, "example.com") ==
               :error

      conn =
        build_conn()
        |> put_req_header("content-type", "application/octet-stream")
        |> post(path, ~s({"redeem_request_id":))

      assert response(conn, 404) =~ "Not Found"
    end

    assert Repo.aggregate(Request, :count, :id) == 0
  end

  defp attach_admission_probe do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:codex_pooler, :gateway, :admission, :accepted],
          [:codex_pooler, :gateway, :admission, :enqueued],
          [:codex_pooler, :gateway, :admission, :rejected]
        ],
        fn event, _measurements, metadata, test_pid ->
          send(test_pid, {:usage_admission_event, event, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp usage_reset_identity_fixture do
    pool = pool_fixture()
    unique = System.unique_integer([:positive])
    account_id = "weekly-reset-account-#{unique}"
    token = "weekly-reset-token-#{unique}"

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        plan_family: "pro"
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: token
             })

    observed_at =
      DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)

    %{
      identity: identity,
      account_id: account_id,
      authorization: "Bearer #{token}",
      observed_at: observed_at,
      reset_at: DateTime.add(observed_at, 5, :day)
    }
  end

  defp weekly_quota_evidence(observed_at, reset_at, used_percent, status, opts \\ []) do
    provider_at = Keyword.get(opts, :provider_at, observed_at)

    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      active_limit: Keyword.get(opts, :active_limit),
      credits: Keyword.get(opts, :credits),
      freshness_state: "fresh",
      metadata:
        Map.put(status, "reset_after_seconds", DateTime.diff(reset_at, provider_at, :second))
    }
  end

  defp safe_weekly_zero(observed_at, reset_at, opts \\ []) do
    weekly_quota_evidence(observed_at, reset_at, "0", safe_status(), opts)
  end

  defp safe_status do
    %{"rate_limit_allowed" => true, "rate_limit_reached" => false}
  end

  defp assert_exhausted_routing(identity, persisted, as_of) do
    assert %{
             eligible?: false,
             routing_state: :blocked,
             exclusions: [%{code: "quota_weekly_exhausted", reason_codes: ["exhausted"]}],
             selection: %{
               secondary: %AccountQuotaWindow{id: persisted_id},
               blocked_windows: [%AccountQuotaWindow{id: blocked_id}]
             }
           } = QuotaWindows.routing_quota_eligibility(identity, at: as_of)

    assert persisted_id == persisted.id
    assert blocked_id == persisted.id

    {primary, secondary} =
      identity
      |> QuotaWindows.list_quota_windows(as_of)
      |> UsageResponses.account_usage_windows(as_of)

    assert %{allowed: false, limit_reached: true, secondary_window: %{used_percent: 100}} =
             UsageResponses.codex_rate_limit(primary, secondary)
  end

  defp assert_exhausted_usage_response(conn, setup) do
    assert %{
             "rate_limit" => %{
               "allowed" => false,
               "limit_reached" => true,
               "secondary_window" => %{"used_percent" => 100}
             }
           } = usage_response(conn, setup)
  end

  defp usage_response(conn, setup) do
    conn
    |> put_req_header("authorization", setup.authorization)
    |> put_req_header("chatgpt-account-id", setup.account_id)
    |> get("/api/codex/usage")
    |> json_response(200)
  end
end
