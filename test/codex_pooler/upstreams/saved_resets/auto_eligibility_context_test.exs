defmodule CodexPooler.Upstreams.SavedResets.AutoEligibility.ContextTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.SavedResets.AutoEligibility.Context

  @assignment_id "00000000-0000-4000-8000-000000000001"
  @identity_id "00000000-0000-4000-8000-000000000002"
  @sibling_id "00000000-0000-4000-8000-000000000003"

  test "normalizes the required immutable cohort separately from trigger candidates" do
    context = %{
      trigger: :blocked_weekly_exhaustion,
      pool_upstream_assignment_id: @assignment_id,
      upstream_identity_id: @identity_id,
      candidate_assignment_ids: [@assignment_id],
      candidate_identity_ids: [@identity_id],
      cohort_identity_ids: [@sibling_id, @identity_id, @sibling_id],
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
end
