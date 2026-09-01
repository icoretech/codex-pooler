defmodule CodexPooler.Accounting.UpstreamUsageReadModelTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
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

  test "public usage selects a fresh available identity without account windows" do
    as_of = ~U[2026-09-01 12:00:00.000000Z]
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct_usage_windowless_#{System.unique_integer([:positive])}",
        identity_metadata: %{
          "credential_epoch" => 1,
          AccountAvailabilityStore.metadata_key() =>
            AccountAvailabilityStore.encode!(:available, as_of, 1)
        }
      })

    assert {:ok,
            %{
              rate_limit: %{
                allowed: true,
                limit_reached: false,
                primary_window: nil,
                secondary_window: nil
              },
              additional_rate_limits: []
            } = usage} = Accounting.build_codex_usage_for_pool(pool, as_of: as_of)

    assert MapSet.new(Map.keys(usage)) ==
             MapSet.new([:plan_type, :rate_limit, :additional_rate_limits])

    assert {:ok, %{rate_limit: %{allowed: true, limit_reached: false}}} =
             Accounting.build_codex_usage_for_upstream_identity(identity, as_of: as_of)
  end

  test "public usage refuses blocked unknown expired and credential-mismatched no-window identities" do
    as_of = ~U[2026-09-01 12:00:00.000000Z]

    for {state, observed_at, availability_epoch} <- [
          {:blocked, as_of, 1},
          {:unknown, as_of, 1},
          {:available, DateTime.add(as_of, -7_201, :second), 1},
          {:available, as_of, 2}
        ] do
      pool = pool_fixture()

      %{identity: identity} =
        upstream_assignment_fixture(pool, %{
          identity_metadata: %{
            "credential_epoch" => 1,
            AccountAvailabilityStore.metadata_key() =>
              AccountAvailabilityStore.encode!(state, observed_at, availability_epoch)
          }
        })

      assert {:error, %{code: :no_upstream_usage}} =
               Accounting.build_codex_usage_for_pool(pool, as_of: as_of)

      assert {:error, %{code: :no_upstream_usage}} =
               Accounting.build_codex_usage_for_upstream_identity(identity, as_of: as_of)
    end
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
