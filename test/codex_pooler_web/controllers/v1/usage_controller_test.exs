defmodule CodexPoolerWeb.V1.UsageControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [monthly_only_account_primary_quota_window_attrs: 1]

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting.{DailyRollup, Request}
  alias CodexPooler.Accounting.UsageReadModel.UpstreamUsage
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Usage
  alias CodexPooler.Repo

  test "GET /v1/usage returns zeroed scoped usage with sanitized metadata logging", %{conn: conn} do
    setup = active_api_key_fixture()

    conn = conn |> auth(setup) |> get("/v1/usage")

    response = json_response(conn, 200)

    assert response["request_count"] == 0
    assert response["total_tokens"] == 0
    assert response["cached_input_tokens"] == 0
    assert response["total_cost_usd"] == 0.0
    assert response["total_cost_status"] == "unpriced"
    assert response["limits"] == []
    assert response["upstream_limits"] == []

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/v1/usage"
    assert request.transport == "http_json"
    assert request.status == "succeeded"
    assert request.request_metadata["operation"] == "usage"
    refute inspect(request.request_metadata) =~ "prompt"
    refute inspect(request.request_metadata) =~ "upload_url"
  end

  test "GET /v1/usage scopes totals and upstream limits to the authenticated key and pool", %{
    conn: conn
  } do
    pool = pool_fixture()
    setup = active_api_key_fixture(pool)
    other_key = active_api_key_fixture(pool)
    other_pool = pool_fixture()
    other_pool_key = active_api_key_fixture(other_pool)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    insert_daily_rollup!(pool.id, setup.api_key.id, %{
      request_count: 2,
      total_tokens: 77,
      cached_input_tokens: 11
    })

    insert_daily_rollup!(pool.id, other_key.api_key.id, %{
      request_count: 9,
      total_tokens: 999,
      cached_input_tokens: 55
    })

    insert_daily_rollup!(other_pool.id, other_pool_key.api_key.id, %{
      request_count: 5,
      total_tokens: 500,
      cached_input_tokens: 20
    })

    request =
      request_fixture(setup, %{
        correlation_id: "v1-usage-cost-primary",
        request_metadata: %{
          "prompt" => "V1_USAGE_PROMPT_SENTINEL",
          "upload_url" => "https://upload.example.invalid/V1_USAGE_SENTINEL"
        }
      })

    ledger_entry_fixture(request, %{
      settled_cost_micros: 3_450_000,
      details: %{"settled_cost_micros" => "3450000"}
    })

    upsert_default_policy_binding!(setup.api_key.id, now, %{
      max_requests_per_minute: 60,
      max_tokens_per_day: 1_000
    })

    %{identity: usage_identity} =
      active_upstream_assignment_fixture(pool, %{account_label: "V1 usage upstream"})

    %{identity: other_pool_identity} =
      active_upstream_assignment_fixture(other_pool, %{account_label: "Other pool upstream"})

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(usage_identity, [
               %{
                 quota_key: "account",
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 120,
                 credits: 108,
                 reset_at: DateTime.add(now, 300, :second),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh",
                 last_sync_at: now,
                 observed_at: now,
                 merge_precedence: 70,
                 metadata: %{}
               },
               %{
                 quota_key: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 active_limit: 1_200,
                 credits: 1_050,
                 reset_at: DateTime.add(now, 7, :day),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh",
                 last_sync_at: now,
                 observed_at: now,
                 merge_precedence: 70,
                 metadata: %{}
               }
             ])

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(other_pool_identity, [
               %{
                 quota_key: "account",
                 window_kind: "primary",
                 window_minutes: 300,
                 active_limit: 999,
                 credits: 0,
                 reset_at: DateTime.add(now, 300, :second),
                 source: "codex_usage_api",
                 source_precision: "observed",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh",
                 last_sync_at: now,
                 observed_at: now,
                 merge_precedence: 70,
                 metadata: %{}
               }
             ])

    conn = conn |> auth(setup) |> get("/v1/usage")

    assert %{
             "request_count" => 2,
             "total_tokens" => 77,
             "cached_input_tokens" => 11,
             "total_cost_usd" => 3.45,
             "total_cost_status" => "priced",
             "limits" => limits,
             "upstream_limits" => upstream_limits
           } = json_response(conn, 200)

    assert Enum.map(
             limits,
             &Map.take(&1, [
               "limit_type",
               "limit_window",
               "max_value",
               "current_value",
               "remaining_value",
               "model_filter",
               "source"
             ])
           ) == [
             %{
               "limit_type" => "credits",
               "limit_window" => "daily",
               "max_value" => 1000,
               "current_value" => 77,
               "remaining_value" => 923,
               "model_filter" => nil,
               "source" => "api_key_compatibility"
             },
             %{
               "limit_type" => "total_tokens",
               "limit_window" => "daily",
               "max_value" => 1000,
               "current_value" => 77,
               "remaining_value" => 923,
               "model_filter" => nil,
               "source" => "api_key_limit"
             },
             %{
               "limit_type" => "request_count",
               "limit_window" => "minute",
               "max_value" => 60,
               "current_value" => 1,
               "remaining_value" => 59,
               "model_filter" => nil,
               "source" => "api_key_limit"
             }
           ]

    assert Enum.map(
             upstream_limits,
             &Map.take(&1, [
               "limit_type",
               "limit_window",
               "max_value",
               "current_value",
               "remaining_value",
               "model_filter",
               "source"
             ])
           ) == [
             %{
               "limit_type" => "credits",
               "limit_window" => "5h",
               "max_value" => 120,
               "current_value" => 12,
               "remaining_value" => 108,
               "model_filter" => nil,
               "source" => "upstream_usage"
             },
             %{
               "limit_type" => "credits",
               "limit_window" => "7d",
               "max_value" => 1200,
               "current_value" => 150,
               "remaining_value" => 1050,
               "model_filter" => nil,
               "source" => "upstream_usage"
             }
           ]

    response_text = conn.resp_body
    refute response_text =~ "V1_USAGE_PROMPT_SENTINEL"
    refute response_text =~ "V1_USAGE_SENTINEL"

    assert [metadata_request] =
             Repo.all(
               from(r in Request,
                 where: r.pool_id == ^pool.id and r.endpoint == "/v1/usage",
                 order_by: [desc: r.admitted_at],
                 limit: 1
               )
             )

    assert metadata_request.api_key_id == setup.api_key.id
  end

  test "GET /v1/usage labels monthly-only account primary limits as 30d without fake capacity", %{
    conn: conn
  } do
    pool = pool_fixture()
    setup = active_api_key_fixture(pool)
    now = ~U[2026-06-07 12:00:00Z]

    %{identity: identity} =
      active_upstream_assignment_fixture(pool, %{account_label: "Monthly-only usage upstream"})

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               monthly_only_account_primary_quota_window_attrs(%{
                 observed_at: now,
                 last_sync_at: now,
                 reset_at: DateTime.add(now, 30, :day)
               })
             ])

    conn = conn |> auth(setup) |> get("/v1/usage")

    assert %{
             "upstream_limits" => [monthly_limit]
           } = json_response(conn, 200)

    assert monthly_limit["limit_type"] == "percent"
    assert monthly_limit["limit_window"] == "30d"
    assert monthly_limit["max_value"] == nil
    assert monthly_limit["current_value"] == nil
    assert monthly_limit["remaining_value"] == nil
    assert monthly_limit["model_filter"] == nil
    assert monthly_limit["source"] == "upstream_usage"

    response_text = conn.resp_body
    refute response_text =~ "1134"
    refute response_text =~ "free"
    refute response_text =~ "secondary_window"
  end

  test "upstream usage selection ranks credit-backed probes between precise and weekly probes" do
    pool = pool_fixture()
    now = ~U[2026-06-01 12:00:00Z]
    %{identity: weekly_identity} = upstream_assignment_fixture(pool)
    %{identity: credit_identity} = upstream_assignment_fixture(pool)

    insert_usage_windows!(weekly_identity, [
      weekly_usage_window(now, active_limit: 700, credits: 630, used_percent: Decimal.new("10"))
    ])

    insert_usage_windows!(credit_identity, [
      primary_usage_window(now, active_limit: 220, credits: 176, used_percent: Decimal.new("20")),
      weekly_usage_window(now, active_limit: 1_000, credits: 25, used_percent: Decimal.new("100"))
    ])

    assert upstream_limit_keys(pool.id, now) == [
             {"5h", 220, 176},
             {"7d", 1_000, 25}
           ]

    %{identity: precise_identity} = upstream_assignment_fixture(pool)

    insert_usage_windows!(precise_identity, [
      primary_usage_window(now, active_limit: 333, credits: 300, used_percent: Decimal.new("10"))
    ])

    assert upstream_limit_keys(pool.id, now) == [{"5h", 333, 300}]
  end

  test "GET /v1/usage rejects unsupported filters without side effects", %{conn: conn} do
    setup = active_api_key_fixture()

    conn = conn |> auth(setup) |> get("/v1/usage?start_time=123")

    assert %{"error" => error} = json_response(conn, 400)
    assert error["type"] == "invalid_request_error"
    assert error["code"] == "unsupported_parameter"
    assert error["param"] == "start_time"
    assert error["message"] == "Unsupported parameter: start_time"
    assert Repo.aggregate(Request, :count) == 0
  end

  test "usage gateway normalizes accounting invalid-request errors before returning" do
    setup = active_api_key_fixture()

    auth = %{
      api_key: setup.api_key,
      api_key_id: setup.api_key.id,
      pool: nil,
      pool_id: nil,
      key_prefix: setup.api_key.key_prefix
    }

    assert {:error,
            %{
              status: 400,
              code: "invalid_request",
              message: "authenticated pool and api key are required"
            }} =
             Usage.v1_usage(auth, %{}, RequestOptions.build(%{}, "/v1/usage", %{}))
  end

  defp auth(conn, setup), do: put_req_header(conn, "authorization", setup.authorization)

  defp insert_daily_rollup!(pool_id, api_key_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%DailyRollup{
      rollup_date: Date.utc_today(),
      dimension_kind: "api_key",
      pool_id: pool_id,
      api_key_id: api_key_id,
      pool_upstream_assignment_id: nil,
      upstream_identity_id: nil,
      model_id: nil,
      request_count: Map.get(attrs, :request_count, 0),
      success_count: Map.get(attrs, :success_count, Map.get(attrs, :request_count, 0)),
      failure_count: Map.get(attrs, :failure_count, 0),
      retry_count: Map.get(attrs, :retry_count, 0),
      input_tokens: Map.get(attrs, :input_tokens, 0),
      cached_input_tokens: Map.get(attrs, :cached_input_tokens, 0),
      output_tokens: Map.get(attrs, :output_tokens, 0),
      reasoning_tokens: Map.get(attrs, :reasoning_tokens, 0),
      total_tokens: Map.get(attrs, :total_tokens, 0),
      estimated_cost_micros: Decimal.new(Map.get(attrs, :estimated_cost_micros, 0)),
      settled_cost_micros: Decimal.new(Map.get(attrs, :settled_cost_micros, 0)),
      created_at: now,
      updated_at: now
    })
  end

  defp upstream_limit_keys(pool_id, now) do
    pool_id
    |> UpstreamUsage.v1_upstream_limits_for_pool(now, [])
    |> Enum.map(&{&1.limit_window, &1.max_value, &1.remaining_value})
  end

  defp insert_usage_windows!(identity, attrs) do
    assert {:ok, windows} = QuotaWindows.upsert_quota_windows(identity, attrs)
    windows
  end

  defp primary_usage_window(now, overrides) do
    usage_window(
      now,
      [
        quota_key: "account",
        window_kind: "primary",
        window_minutes: 300,
        reset_at: DateTime.add(now, 5, :hour)
      ],
      overrides
    )
  end

  defp weekly_usage_window(now, overrides) do
    usage_window(
      now,
      [
        quota_key: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        reset_at: DateTime.add(now, 7, :day)
      ],
      overrides
    )
  end

  defp usage_window(now, base, overrides) do
    base
    |> Keyword.merge(
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      observed_at: now,
      last_sync_at: now,
      merge_precedence: 70,
      metadata: %{}
    )
    |> Keyword.merge(overrides)
    |> Map.new()
  end

  defp upsert_default_policy_binding!(api_key_id, now, attrs) do
    params =
      Map.merge(attrs, %{
        api_key_id: api_key_id,
        binding_scope: "default",
        status: "active",
        created_at: now,
        updated_at: now
      })

    case Repo.get_by(APIKeyPolicyBinding,
           api_key_id: api_key_id,
           binding_scope: "default",
           status: "active"
         ) do
      %APIKeyPolicyBinding{} = binding ->
        binding
        |> APIKeyPolicyBinding.changeset(params)
        |> Repo.update!()

      nil ->
        Repo.insert!(APIKeyPolicyBinding.changeset(%APIKeyPolicyBinding{}, params))
    end
  end
end
