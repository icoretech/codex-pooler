defmodule CodexPooler.Upstreams.SavedResets.AutoEligibility.ContextTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility.Context

  @assignment_id "00000000-0000-4000-8000-000000000001"
  @identity_id "00000000-0000-4000-8000-000000000002"
  @sibling_id "00000000-0000-4000-8000-000000000003"
  @sibling_assignment_id "00000000-0000-4000-8000-000000000004"
  @circuit_id "00000000-0000-4000-8000-000000000005"
  @now ~U[2026-08-25 10:00:00Z]

  test "normalizes the required immutable cohort separately from trigger candidates" do
    context = %{
      trigger: :blocked_weekly_exhaustion,
      pool_upstream_assignment_id: @assignment_id,
      upstream_identity_id: @identity_id,
      candidate_assignment_ids: [@assignment_id],
      candidate_identity_ids: [@identity_id],
      capacity_assignment_ids: [@assignment_id, @sibling_assignment_id],
      capacity_identity_ids: [@identity_id, @sibling_id],
      cohort_identity_ids: [@sibling_id, @identity_id, @sibling_id],
      routable_assignment_ids: [@assignment_id, @sibling_assignment_id],
      routable_identity_ids: [@identity_id, @sibling_id],
      route_class: "proxy_http"
    }

    assert {:ok, normalized} = Context.normalize(context)
    assert normalized.candidate_identity_ids == [@identity_id]
    assert normalized.cohort_identity_ids == [@identity_id, @sibling_id]
  end

  test "rejects a missing or malformed cohort" do
    context = %{
      trigger: :blocked_weekly_exhaustion,
      pool_upstream_assignment_id: @assignment_id,
      upstream_identity_id: @identity_id,
      candidate_assignment_ids: [@assignment_id],
      candidate_identity_ids: [@identity_id],
      route_class: "proxy_http"
    }

    assert {:error, :invalid_gateway_auto_context} = Context.normalize(context)

    assert {:error, :invalid_gateway_auto_context} =
             Context.normalize(Map.put(context, :cohort_identity_ids, ["not-a-uuid"]))
  end

  test "normalizes a bounded transient circuit exclusion separately from candidates" do
    context = %{
      trigger: :blocked_weekly_exhaustion,
      pool_upstream_assignment_id: @assignment_id,
      upstream_identity_id: @identity_id,
      candidate_assignment_ids: [@assignment_id],
      candidate_identity_ids: [@identity_id],
      capacity_assignment_ids: [@assignment_id, @sibling_assignment_id],
      capacity_identity_ids: [@identity_id, @sibling_id],
      cohort_identity_ids: [@identity_id, @sibling_id],
      routable_assignment_ids: [@assignment_id],
      routable_identity_ids: [@identity_id],
      route_class: "proxy_http",
      quota_scope: quota_scope(),
      transient_circuit_exclusions: [
        %{
          upstream_identity_id: @sibling_id,
          pool_upstream_assignment_id: @sibling_assignment_id,
          routing_circuit_state_id: @circuit_id,
          model_identifier: "test-model",
          route_class: "proxy_http"
        }
      ]
    }

    assert {:ok, normalized} = Context.normalize(context)
    assert [exclusion] = normalized.transient_circuit_exclusions
    assert exclusion.upstream_identity_id == @sibling_id
    assert exclusion.pool_upstream_assignment_id == @sibling_assignment_id
    assert exclusion.routing_circuit_state_id == @circuit_id
  end

  test "rejects malformed, duplicate, and oversized transient circuit exclusions" do
    second_identity_id = Ecto.UUID.generate()
    second_assignment_id = Ecto.UUID.generate()
    second_circuit_id = Ecto.UUID.generate()

    first = transient_exclusion()

    second =
      transient_exclusion(%{
        upstream_identity_id: second_identity_id,
        pool_upstream_assignment_id: second_assignment_id,
        routing_circuit_state_id: second_circuit_id
      })

    cohort = [@identity_id, @sibling_id, second_identity_id]

    invalid_exclusions = [
      [Map.delete(first, :model_identifier)],
      [Map.put(first, :model_identifier, "")],
      [Map.put(first, :model_identifier, "   ")],
      [Map.delete(first, :route_class)],
      [Map.put(first, :route_class, "")],
      [Map.put(first, :route_class, "   ")],
      [Map.put(first, :routing_circuit_state_id, "not-a-uuid")],
      [first, %{second | upstream_identity_id: first.upstream_identity_id}],
      [first, %{second | pool_upstream_assignment_id: first.pool_upstream_assignment_id}],
      [first, %{second | routing_circuit_state_id: first.routing_circuit_state_id}],
      [
        first,
        second,
        transient_exclusion(%{
          upstream_identity_id: Ecto.UUID.generate(),
          pool_upstream_assignment_id: Ecto.UUID.generate(),
          routing_circuit_state_id: Ecto.UUID.generate()
        }),
        transient_exclusion(%{
          upstream_identity_id: Ecto.UUID.generate(),
          pool_upstream_assignment_id: Ecto.UUID.generate(),
          routing_circuit_state_id: Ecto.UUID.generate()
        })
      ]
    ]

    for exclusions <- invalid_exclusions do
      context = valid_context(exclusions, cohort)
      assert {:error, :invalid_gateway_auto_context} = Context.normalize(context)
    end
  end

  test "rejects transient circuit exclusions that mismatch the request context" do
    mismatch_exclusions = [
      {transient_exclusion(%{upstream_identity_id: Ecto.UUID.generate()}),
       [@identity_id, @sibling_id]},
      {transient_exclusion(%{upstream_identity_id: @identity_id}), [@identity_id, @sibling_id]},
      {transient_exclusion(%{model_identifier: "other-model"}), [@identity_id, @sibling_id]},
      {transient_exclusion(%{route_class: "proxy_websocket"}), [@identity_id, @sibling_id]}
    ]

    for {exclusion, cohort} <- mismatch_exclusions do
      context = valid_context([exclusion], cohort)
      assert {:error, :gateway_auto_context_mismatch} = Context.normalize(context)
    end
  end

  test "model-scoped additional quota cannot trigger saved-reset auto eligibility" do
    additional_window = model_additional_window()
    policy = %{min_blocked_minutes: 60}
    snapshot = %{source: "codex_usage_api"}

    refute AutoEligibility.blocked_weekly_exhaustion?([additional_window], policy, @now)

    assert AutoEligibility.scheduled_weekly_eligibility([additional_window], snapshot, @now) ==
             :unavailable

    account_mutation = %{
      additional_window
      | quota_key: "account",
        quota_scope: "account",
        quota_family: "account"
    }

    assert AutoEligibility.blocked_weekly_exhaustion?([account_mutation], policy, @now)

    assert {:eligible, [^account_mutation]} =
             AutoEligibility.scheduled_weekly_eligibility([account_mutation], snapshot, @now)
  end

  defp valid_context(exclusions, cohort_identity_ids) do
    %{
      trigger: :blocked_weekly_exhaustion,
      pool_upstream_assignment_id: @assignment_id,
      upstream_identity_id: @identity_id,
      candidate_assignment_ids: [@assignment_id],
      candidate_identity_ids: [@identity_id],
      capacity_assignment_ids: [@assignment_id, @sibling_assignment_id],
      capacity_identity_ids: [@identity_id, @sibling_id],
      cohort_identity_ids: cohort_identity_ids,
      routable_assignment_ids: [@assignment_id],
      routable_identity_ids: [@identity_id],
      route_class: "proxy_http",
      quota_scope: quota_scope(),
      transient_circuit_exclusions: exclusions
    }
  end

  defp transient_exclusion(overrides \\ %{}) do
    Map.merge(
      %{
        upstream_identity_id: @sibling_id,
        pool_upstream_assignment_id: @sibling_assignment_id,
        routing_circuit_state_id: @circuit_id,
        model_identifier: "test-model",
        route_class: "proxy_http"
      },
      overrides
    )
  end

  defp quota_scope do
    %{
      requested_model: "test-model",
      catalog_model: "test-model",
      exposed_model_id: "test-model",
      upstream_model: "test-model-upstream",
      upstream_model_id: "test-model-upstream"
    }
  end

  defp model_additional_window do
    %AccountQuotaWindow{
      quota_key: "synthetic_model_weekly",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "synthetic-model",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("100"),
      reset_at: DateTime.add(@now, 5, :day),
      observed_at: @now,
      last_sync_at: @now,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh"
    }
  end
end
