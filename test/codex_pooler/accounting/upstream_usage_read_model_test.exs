defmodule CodexPooler.Accounting.UpstreamUsageReadModelTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting

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
end
