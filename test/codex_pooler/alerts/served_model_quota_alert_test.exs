defmodule CodexPooler.Alerts.Evaluation.ServedModelQuotaAlertTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @retired "gpt-example-retired"

  # An unscoped quota-state rule judges the account by its account windows
  # plus the model windows of models one of the account's Pools serves. A
  # model no Pool serves any more (retired, stale, suppressed) keeps its last
  # rows until retention, and those rows must not make the account stale.
  describe "a rule without a model" do
    test "ignores model rows of a model no Pool of the account serves" do
      now = now()
      %{pool: pool, identity: identity} = account_with_usable_account_windows!(now)
      insert_expired_model_row!(identity, @retired, now)

      assert [%{action: :clear}] = evaluate(pool, "pool_all_assignments_in_state", "stale", nil, now)
      assert [%{action: :clear}] = evaluate(pool, "pool_no_usable_assignments", nil, nil, now)
    end

    test "ignores them when only another Pool serves no such model either" do
      now = now()
      %{pool: pool, identity: identity} = account_with_usable_account_windows!(now)
      other_pool = pool_fixture()
      assign_to_pool!(other_pool, identity, now)
      model_fixture(other_pool, %{exposed_model_id: "gpt-example-other", upstream_model_id: "gpt-example-other"})
      insert_expired_model_row!(identity, @retired, now)

      assert [%{action: :clear}] = evaluate(pool, "pool_all_assignments_in_state", "stale", nil, now)
    end

    # Control: a served model's rows keep counting, from this Pool or from
    # another Pool of the same account.
    test "keeps model rows of a model one of the account's Pools serves" do
      now = now()
      %{pool: pool, identity: identity} = account_with_usable_account_windows!(now)
      other_pool = pool_fixture()
      assign_to_pool!(other_pool, identity, now)
      model_fixture(other_pool, %{exposed_model_id: @retired, upstream_model_id: @retired})
      insert_expired_model_row!(identity, @retired, now)

      assert [%{action: :match, match_attrs: match}] = evaluate(pool, "pool_all_assignments_in_state", "stale", nil, now)
      assert match.safe_evidence_snapshot["state_counts"] == %{"stale" => 1}
    end
  end

  describe "a rule with a model" do
    test "reports model_not_served instead of quota staleness when the Pool does not serve the model" do
      now = now()
      %{pool: pool, identity: identity} = account_with_usable_account_windows!(now)
      insert_expired_model_row!(identity, @retired, now)

      assert [%{action: :clear}] = evaluate(pool, "pool_all_assignments_in_state", "stale", @retired, now)

      assert [%{action: :match, match_attrs: match}] = evaluate(pool, "pool_no_usable_assignments", nil, @retired, now)
      assert match.safe_evidence_snapshot["state_counts"] == %{"model_not_served" => 1}
      assert match.safe_evidence_snapshot["reason_code"] == "no_usable_assignments"
    end

    test "keeps evaluating the model's rows when the Pool serves it" do
      now = now()
      %{pool: pool, identity: identity} = account_with_usable_account_windows!(now)
      model_fixture(pool, %{exposed_model_id: @retired, upstream_model_id: @retired})
      insert_expired_model_row!(identity, @retired, now)

      assert [%{action: :match, match_attrs: match}] = evaluate(pool, "pool_all_assignments_in_state", "stale", @retired, now)
      assert match.safe_evidence_snapshot["state_counts"] == %{"stale" => 1}
    end
  end

  # Threshold rules need fresh evidence, so the case that matters is a model
  # the account still reports fresh usage for while no Pool of the account
  # serves it.
  describe "an upstream quota threshold rule" do
    test "without a model is never triggered by a model no Pool of the account serves" do
      now = now()
      %{pool: pool, identity: identity} = account_with_usable_account_windows!(now)
      insert_fresh_exhausted_model_row!(identity, @retired, now)

      assert [%{action: :clear}] = evaluate_threshold(pool, nil, now)
    end

    test "without a model is still triggered by a served model's window" do
      now = now()
      %{pool: pool, identity: identity} = account_with_usable_account_windows!(now)
      model_fixture(pool, %{exposed_model_id: @retired, upstream_model_id: @retired})
      insert_fresh_exhausted_model_row!(identity, @retired, now)

      assert [%{action: :match, match_attrs: match}] = evaluate_threshold(pool, nil, now)
      assert match.safe_evidence_snapshot.quota_scope == "model"
      assert match.safe_evidence_snapshot.quota_key == "example_meter"
    end

    test "naming a model its Pool does not serve clears instead of reporting quota" do
      now = now()
      %{pool: pool, identity: identity} = account_with_usable_account_windows!(now)
      insert_fresh_exhausted_model_row!(identity, @retired, now)

      assert [%{action: :clear}] = evaluate_threshold(pool, @retired, now)
    end

    test "naming a served model keeps today's behaviour" do
      now = now()
      %{pool: pool, identity: identity} = account_with_usable_account_windows!(now)
      model_fixture(pool, %{exposed_model_id: @retired, upstream_model_id: @retired})
      insert_fresh_exhausted_model_row!(identity, @retired, now)

      assert [%{action: :match}] = evaluate_threshold(pool, @retired, now)
    end
  end

  defp evaluate_threshold(pool, model, now) do
    pool
    |> alert_rule_fixture(Enum.reject([rule_kind: "upstream_quota_threshold", scope_type: "upstream_identity", threshold_used_percent: Decimal.new("90"), model: model], &is_nil(elem(&1, 1))))
    |> Alerts.evaluate_rule(at: now)
  end

  defp insert_fresh_exhausted_model_row!(identity, model, now) do
    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(%{
      upstream_identity_id: identity.id,
      quota_key: "example_meter",
      quota_scope: "model",
      quota_family: "codex_model",
      model: model,
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("95"),
      reset_at: DateTime.add(now, 3_600, :second),
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: now,
      observed_at: now,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp evaluate(pool, rule_kind, target_state, model, now) do
    pool
    |> alert_rule_fixture(Enum.reject([rule_kind: rule_kind, target_state: target_state, model: model], &is_nil(elem(&1, 1))))
    |> Alerts.evaluate_rule(at: now)
  end

  defp account_with_usable_account_windows!(now) do
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    assert {:ok, [_, _]} =
             Windows.upsert_quota_windows(identity, [
               account_attrs("primary", 300, DateTime.add(now, 3_600, :second), now),
               account_attrs("secondary", 10_080, DateTime.add(now, 3, :day), now)
             ])

    %{pool: pool, identity: identity}
  end

  defp assign_to_pool!(pool, identity, now) do
    %PoolUpstreamAssignment{
      pool_id: pool.id,
      upstream_identity_id: identity.id,
      assignment_label: "Second Pool",
      status: "active",
      health_status: "active",
      eligibility_status: "eligible",
      created_at: now,
      updated_at: now,
      metadata: %{}
    }
    |> Repo.insert!()
  end

  defp account_attrs(kind, minutes, reset_at, now) do
    %{quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: kind, window_minutes: minutes, used_percent: Decimal.new("10"), reset_at: reset_at, source: "codex_usage_api", source_precision: "observed", freshness_state: "fresh", last_sync_at: now, observed_at: now}
  end

  # The last row of a model window, five days after its reset: inside the
  # 30-day retention, so every reader still sees it.
  defp insert_expired_model_row!(identity, model, now) do
    reset_at = DateTime.add(now, -5, :day)
    observed_at = DateTime.add(reset_at, -5, :hour)

    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(%{
      upstream_identity_id: identity.id,
      quota_key: "example_meter",
      quota_scope: "model",
      quota_family: "codex_model",
      model: model,
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new("0"),
      reset_at: reset_at,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: observed_at,
      observed_at: observed_at,
      metadata: %{},
      created_at: observed_at,
      updated_at: observed_at
    })
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
