defmodule CodexPooler.Accounting.UpstreamUsageReadModelTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  test "account-id usage read model refuses ambiguous workspace slots" do
    pool = pool_fixture()
    account_id = "acct_usage_ambiguous_#{System.unique_integer([:positive])}"

    upstream_assignment_fixture(pool, %{
      chatgpt_account_id: account_id,
      workspace_id: "workspace-usage-alpha"
    })

    upstream_assignment_fixture(pool, %{
      chatgpt_account_id: account_id,
      workspace_id: "workspace-usage-beta"
    })

    assert {:error, %{code: :ambiguous_chatgpt_account, message: message}} =
             Accounting.build_codex_usage_for_chatgpt_account(account_id)

    assert message == "chatgpt-account-id matches multiple upstream workspaces"
  end

  test "public usage read models preserve the canonical plan label" do
    pool = pool_fixture()
    account_id = "acct_usage_plan_label_#{System.unique_integer([:positive])}"

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        plan_label: "enterprise_cbp_automation",
        plan_family: "enterprise-cbp-automation"
      })

    put_fresh_account_quota(identity)

    assert {:ok, %{plan_type: "enterprise_cbp_automation"}} =
             Accounting.build_codex_usage_for_pool(pool)

    assert {:ok, %{plan_type: "enterprise_cbp_automation"}} =
             Accounting.build_codex_usage_for_chatgpt_account(account_id)
  end

  test "public usage read models fall back to the stored plan family" do
    pool = pool_fixture()
    account_id = "acct_usage_plan_family_#{System.unique_integer([:positive])}"

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: account_id,
        plan_label: nil,
        plan_family: "enterprise"
      })

    put_fresh_account_quota(identity)

    assert {:ok, %{plan_type: "enterprise"}} = Accounting.build_codex_usage_for_pool(pool)

    assert {:ok, %{plan_type: "enterprise"}} =
             Accounting.build_codex_usage_for_chatgpt_account(account_id)
  end

  defp put_fresh_account_quota(identity) do
    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 window_kind: "primary",
                 window_minutes: 300,
                 used_percent: Decimal.new("12"),
                 reset_at: DateTime.add(DateTime.utc_now(), 300, :second),
                 source: "test",
                 freshness_state: "fresh"
               }
             ])
  end
end
