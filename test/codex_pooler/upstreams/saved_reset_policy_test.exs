defmodule CodexPooler.Upstreams.SavedResetPolicyTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "update_saved_reset_policy_for_scope normalizes policy and records safe audit metadata" do
    scope = owner_scope()
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(pool)

    assert {:ok, %{status: :saved_reset_policy_updated, identity: updated_identity}} =
             Upstreams.update_saved_reset_policy_for_scope(scope, identity, %{
               "auto_redeem_enabled" => "on",
               "min_blocked_minutes" => "90",
               "keep_credits" => "2",
               "trigger_mode" => "threshold",
               "quota_threshold_percent" => "92",
               "trigger_kind" => "admin_form",
               "credit_id" => "credit_1"
             })

    assert updated_identity.saved_reset_auto_redeem_enabled == true
    assert updated_identity.saved_reset_auto_redeem_min_blocked_minutes == 90
    assert updated_identity.saved_reset_auto_redeem_keep_credits == 2
    assert updated_identity.saved_reset_auto_redeem_trigger_mode == "threshold"
    assert updated_identity.saved_reset_auto_redeem_quota_threshold_percent == 92

    event = Repo.get_by!(AuditEvent, action: "upstream_account.saved_reset_policy_update")
    assert event.pool_id == pool.id
    assert event.target_id == identity.id
    assert event.details["trigger_kind"] == "admin_form"
    assert event.details["pool_assignment_ids"] == [assignment.id]

    event_json = CodexPooler.JSON.encode!(event.details)
    refute event_json =~ "credit_1"
    refute event_json =~ "credit_id"
  end

  test "update_saved_reset_policy_for_scope falls back to safe defaults for invalid numbers" do
    scope = owner_scope()
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture())

    assert {:ok, %{identity: updated_identity}} =
             Upstreams.update_saved_reset_policy_for_scope(scope, identity, %{
               "auto_redeem_enabled" => "false",
               "min_blocked_minutes" => "-1",
               "keep_credits" => "not-a-number",
               "trigger_mode" => "unknown",
               "quota_threshold_percent" => "101"
             })

    assert updated_identity.saved_reset_auto_redeem_enabled == false
    assert updated_identity.saved_reset_auto_redeem_min_blocked_minutes == 60
    assert updated_identity.saved_reset_auto_redeem_keep_credits == 0
    assert updated_identity.saved_reset_auto_redeem_trigger_mode == "blocked"
    assert updated_identity.saved_reset_auto_redeem_quota_threshold_percent == 95
  end

  test "update_saved_reset_policy_for_scope keeps explicit false and zero atom-keyed values" do
    scope = owner_scope()

    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture())

    identity =
      identity
      |> UpstreamIdentity.changeset(%{
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_min_blocked_minutes: 120,
        saved_reset_auto_redeem_keep_credits: 5,
        saved_reset_auto_redeem_trigger_mode: "threshold",
        saved_reset_auto_redeem_quota_threshold_percent: 91,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    assert {:ok, %{identity: updated_identity}} =
             Upstreams.update_saved_reset_policy_for_scope(scope, identity, %{
               auto_redeem_enabled: false,
               min_blocked_minutes: 0,
               keep_credits: 0
             })

    assert updated_identity.saved_reset_auto_redeem_enabled == false
    assert updated_identity.saved_reset_auto_redeem_min_blocked_minutes == 0
    assert updated_identity.saved_reset_auto_redeem_keep_credits == 0
    assert updated_identity.saved_reset_auto_redeem_trigger_mode == "threshold"
    assert updated_identity.saved_reset_auto_redeem_quota_threshold_percent == 91
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(user, ["instance_owner"])
  end
end
