defmodule CodexPooler.Upstreams.StatusVocabularyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Lifecycle.IdentityRouting
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "upstream identity exports helpers for every lifecycle status" do
    assert helper_values(UpstreamIdentity, [
             :pending_status,
             :active_status,
             :paused_status,
             :refresh_due_status,
             :refreshing_status,
             :refresh_failed_status,
             :reauth_required_status,
             :deleted_status,
             :disabled_status,
             :errored_status
           ]) == UpstreamIdentity.statuses()
  end

  test "pool assignment exports helpers for every lifecycle and routing status" do
    assert helper_values(PoolUpstreamAssignment, [
             :pending_status,
             :active_status,
             :paused_status,
             :refresh_due_status,
             :refreshing_status,
             :refresh_failed_status,
             :reauth_required_status,
             :deleted_status,
             :disabled_status,
             :errored_status
           ]) == PoolUpstreamAssignment.statuses()

    assert helper_values(PoolUpstreamAssignment, [
             :unknown_health_status,
             :active_health_status,
             :cooldown_health_status,
             :degraded_health_status,
             :disabled_health_status,
             :errored_health_status
           ]) == PoolUpstreamAssignment.health_statuses()

    assert helper_values(PoolUpstreamAssignment, [
             :eligible_status,
             :ineligible_status
           ]) == PoolUpstreamAssignment.eligibility_statuses()
  end

  test "identity routing predicates expose model and file routeability by lifecycle status" do
    matrix =
      Map.new(UpstreamIdentity.statuses(), fn status ->
        identity = %UpstreamIdentity{status: status}

        {status,
         %{
           model: IdentityRouting.model_routable?(status),
           model_identity: IdentityRouting.model_routable?(identity),
           file: IdentityRouting.file_routable?(status),
           file_identity: IdentityRouting.file_routable?(identity)
         }}
      end)

    assert matrix["active"] == %{
             model: true,
             model_identity: true,
             file: true,
             file_identity: true
           }

    assert matrix["refreshing"] == %{
             model: true,
             model_identity: true,
             file: false,
             file_identity: false
           }

    for status <- UpstreamIdentity.statuses() -- ["active", "refreshing"] do
      assert matrix[status] == %{
               model: false,
               model_identity: false,
               file: false,
               file_identity: false
             }
    end

    refute IdentityRouting.model_routable?(nil)
    refute IdentityRouting.file_routable?(nil)
  end

  defp helper_values(module, helpers) do
    Enum.map(helpers, &apply(module, &1, []))
  end
end
