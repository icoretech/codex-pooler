defmodule CodexPooler.Accounting.RequestLogsUsageTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Rollups
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo

  import CodexPooler.PoolerFixtures

  test "request log entries are metadata-only and usage shape is v1-compatible" do
    %{pool: pool, api_key: api_key} =
      active_api_key_fixture(pool_fixture(), %{
        default_policy: %{max_tokens_per_day: 1000, max_requests_per_minute: 60}
      })

    ensure_default_policy!(api_key)

    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-log-mini",
        upstream_model_id: "provider-gpt-log-mini",
        pricing_ref: "provider-gpt-log-mini"
      })

    %{assignment: assignment} = upstream_assignment_fixture(pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PricingSnapshot{
      model_identifier: "provider-gpt-log-mini",
      price_version: "test-v1",
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(100),
      cached_input_token_micros: Decimal.new(0),
      output_token_micros: Decimal.new(200),
      reasoning_token_micros: Decimal.new(0),
      request_base_micros: Decimal.new(0),
      effective_at: DateTime.add(now, -60, :second),
      captured_at: now,
      config: %{
        "service_tier" => "standard",
        "price_bucket" => "default",
        "pricing_type" => "per_1m_tokens"
      }
    }
    |> Repo.insert!()

    auth = %{pool: pool, api_key: api_key, key_prefix: api_key.key_prefix}

    assert {:ok, reserved} =
             Accounting.reserve(
               auth,
               model,
               %{"model" => "gpt-log-mini", "input" => "raw input text"},
               %{
                 correlation_id: "corr-request-log",
                 user_agent: "Codex CLI/1.2.3",
                 request_metadata: %{
                   "body" => %{"input" => "raw input text"},
                   "safe_id" => "req_123"
                 }
               }
             )

    assert {:ok, attempt} = Accounting.create_attempt(reserved.request, assignment)

    assert {:ok, _result} =
             Accounting.finalize_success(
               reserved.request,
               attempt,
               %{status: "usage_known", input_tokens: 2, output_tokens: 3, total_tokens: 5},
               %{response_status_code: 200}
             )

    assert %{items: [log], total: 1, limit: 50, offset: 0} = Accounting.list_request_logs(pool)
    assert log.pool_name == pool.name
    assert log.pool_slug == pool.slug
    assert log.api_key_prefix == api_key.key_prefix
    assert log.requested_model == "gpt-log-mini"
    assert log.status == "succeeded"
    assert log.user_agent == "Codex CLI/1.2.3"
    assert log.pool_upstream_assignment_id == assignment.id
    assert log.token_counts.total_tokens == 5
    assert log.cost.status == "priced"
    assert Decimal.equal?(log.cost.usd, Decimal.new("0.000800"))
    assert log.metadata["body"] == "[REDACTED]"
    assert log.metadata["safe_id"] == "req_123"
    refute inspect(log) =~ "raw input text"

    assert {:ok, usage} =
             Accounting.build_api_key_self_usage(
               pool,
               api_key,
               as_of: DateTime.add(now, 60, :second)
             )

    assert usage.request_count == 1
    assert usage.total_tokens == 5
    assert Decimal.equal?(usage.total_cost_usd, Decimal.new("0.000800"))
    assert Enum.any?(usage.limits, &(&1.limit_type == "credits" and &1.limit_window == "daily"))

    assert {:ok, codex_usage} = Accounting.build_codex_usage_for_api_key(pool, api_key)
    assert codex_usage.plan_type == "api_key"
    assert codex_usage.rate_limit.allowed in [true, false]
  end

  test "local usage read models keep request counts but exclude unknown reserve usage" do
    %{pool: pool, api_key: api_key} =
      active_api_key_fixture(pool_fixture(), %{
        default_policy: %{max_tokens_per_day: 1_000, max_requests_per_minute: 60}
      })

    %{api_key: unknown_only_key} = active_api_key_fixture(pool)
    ensure_default_policy!(api_key)
    ensure_default_policy!(unknown_only_key)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    known_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        status: "succeeded",
        correlation_id: "corr-known-read-model"
      })

    known_settlement =
      ledger_entry_fixture(known_request, %{
        input_tokens: 18,
        cached_input_tokens: 4,
        output_tokens: 8,
        reasoning_tokens: 4,
        total_tokens: 30,
        settled_cost_micros: 250_000,
        details: %{"settled_cost_micros" => "250000"},
        occurred_at: now
      })

    unknown_request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        status: "failed",
        usage_status: "usage_unknown",
        response_status_code: 502,
        correlation_id: "corr-unknown-read-model"
      })

    unknown_settlement =
      ledger_entry_fixture(unknown_request, %{
        usage_status: "usage_unknown",
        input_tokens: 8_000,
        cached_input_tokens: 500,
        output_tokens: 1_500,
        reasoning_tokens: 499,
        total_tokens: 9_999,
        estimated_cost_micros: 1_000_000,
        settled_cost_micros: 9_999_999,
        details: %{"estimated_from_reserve" => true},
        occurred_at: now
      })

    unknown_only_request =
      request_fixture(%{pool: pool, api_key: unknown_only_key}, %{
        status: "failed",
        usage_status: "usage_unknown",
        response_status_code: 502,
        correlation_id: "corr-unknown-only-read-model"
      })

    unknown_only_settlement =
      ledger_entry_fixture(unknown_only_request, %{
        usage_status: "usage_unknown",
        input_tokens: 7_000,
        output_tokens: 2_000,
        reasoning_tokens: 100,
        total_tokens: 9_100,
        estimated_cost_micros: 2_000_000,
        settled_cost_micros: 8_000_000,
        details: %{"estimated_from_reserve" => true},
        occurred_at: now
      })

    assert :ok = Rollups.accumulate!(known_request, known_settlement)
    assert :ok = Rollups.accumulate!(unknown_request, unknown_settlement)
    assert :ok = Rollups.accumulate!(unknown_only_request, unknown_only_settlement)

    summaries = Accounting.list_api_key_usage_summaries([api_key, unknown_only_key])

    assert %{
             request_count: 2,
             total_tokens: 30,
             cached_input_tokens: 4,
             total_cost_status: "priced"
           } = summaries[api_key.id]

    assert Decimal.equal?(summaries[api_key.id].total_cost_usd, Decimal.new("0.250000"))

    assert %{
             request_count: 1,
             total_tokens: 0,
             cached_input_tokens: 0,
             total_cost_status: "unpriced"
           } = summaries[unknown_only_key.id]

    assert Decimal.equal?(summaries[unknown_only_key.id].total_cost_usd, Decimal.new("0.000000"))

    assert {:ok, self_usage} =
             Accounting.build_api_key_self_usage(pool, api_key, as_of: DateTime.add(now, 60))

    assert self_usage.request_count == 2
    assert self_usage.total_tokens == 30
    assert self_usage.cached_input_tokens == 4
    assert self_usage.total_cost_status == "priced"
    assert Decimal.equal?(self_usage.total_cost_usd, Decimal.new("0.250000"))

    assert %{current_value: 30, remaining_value: 970} =
             usage_limit(self_usage.limits, "total_tokens", "daily")

    assert %{current_value: 30, remaining_value: 970} =
             usage_limit(self_usage.limits, "credits", "daily")

    assert %{current_value: 2, remaining_value: 58} =
             usage_limit(self_usage.limits, "request_count", "minute")

    assert {:ok, v1_usage} =
             Accounting.build_v1_usage_for_api_key(pool, api_key, as_of: DateTime.add(now, 60))

    assert v1_usage.request_count == 2
    assert v1_usage.total_tokens == 30
    assert v1_usage.cached_input_tokens == 4
    assert v1_usage.total_cost_status == "priced"
    assert v1_usage.total_cost_usd == 0.25

    assert %{current_value: 30, remaining_value: 970} =
             usage_limit(v1_usage.limits, "total_tokens", "daily")

    assert {:ok, codex_usage} =
             Accounting.build_codex_usage_for_api_key(pool, api_key, as_of: DateTime.add(now, 60))

    assert codex_usage.plan_type == "api_key"
    assert codex_usage.credits.balance == "970"
    assert codex_usage.rate_limit.primary_window.used_percent == 3
  end

  defp ensure_default_policy!(api_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.one(
           from b in APIKeyPolicyBinding,
             where: b.api_key_id == ^api_key.id and b.binding_scope == "default",
             limit: 1
         ) do
      %APIKeyPolicyBinding{} = binding ->
        binding
        |> Ecto.Changeset.change(%{
          max_tokens_per_day: 1000,
          max_requests_per_minute: 60,
          updated_at: now
        })
        |> Repo.update!()

      nil ->
        %APIKeyPolicyBinding{
          api_key_id: api_key.id,
          binding_scope: "default",
          status: "active",
          max_tokens_per_day: 1000,
          max_requests_per_minute: 60,
          created_at: now,
          updated_at: now
        }
        |> Repo.insert!()
    end
  end

  defp usage_limit(limits, limit_type, limit_window) do
    Enum.find(limits, &(&1.limit_type == limit_type and &1.limit_window == limit_window))
  end
end
