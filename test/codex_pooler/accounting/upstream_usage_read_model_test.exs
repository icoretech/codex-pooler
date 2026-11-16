defmodule CodexPooler.Accounting.UpstreamUsageReadModelTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  test "public usage reset countdowns share the snapshot clock across account and additional windows" do
    as_of = ~U[2026-09-01 12:00:00.000000Z]
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool)

    windows =
      for {quota_key, window_kind, window_minutes, reset_after} <- [
            {"account", "primary", 300, 7_200},
            {"account", "secondary", 10_080, 86_400},
            {"sample_feature", "primary", 300, 3_600},
            {"sample_feature", "secondary", 10_080, 172_800}
          ] do
        %{
          quota_key: quota_key,
          window_kind: window_kind,
          window_minutes: window_minutes,
          used_percent: Decimal.new(25),
          observed_at: as_of,
          reset_at: DateTime.add(as_of, reset_after, :second),
          source: "codex_usage_api",
          freshness_state: "fresh"
        }
      end

    assert {:ok, _} = QuotaWindows.upsert_quota_windows(identity, windows)
    assert {:ok, usage} = Accounting.build_codex_usage_for_pool(pool, as_of: as_of)
    assert {:ok, ^usage} = Accounting.build_codex_usage_for_pool(pool, as_of: as_of)

    assert {:ok, ^usage} =
             Accounting.build_codex_usage_for_upstream_identity(identity, as_of: as_of)

    assert [%{quota_key: "sample_feature", rate_limit: additional}] = usage.additional_rate_limits
    snapshots = [usage.rate_limit.primary_window, usage.rate_limit.secondary_window, additional.primary_window, additional.secondary_window]

    assert Enum.map(snapshots, & &1.reset_after_seconds) == [7_200, 86_400, 3_600, 172_800]
    assert Enum.map(snapshots, & &1.reset_at) == Enum.map(windows, &DateTime.to_unix(&1.reset_at))
    assert Enum.map(snapshots, & &1.limit_window_seconds) == [18_000, 604_800, 18_000, 604_800]
    assert Enum.map(snapshots, & &1.used_percent) == [25, 25, 25, 25]

    assert {:ok, later_usage} =
             Accounting.build_codex_usage_for_pool(pool, as_of: DateTime.add(as_of, 61, :second))

    assert [%{rate_limit: later_additional}] = later_usage.additional_rate_limits
    later_snapshots = [later_usage.rate_limit.primary_window, later_usage.rate_limit.secondary_window, later_additional.primary_window, later_additional.secondary_window]

    assert later_snapshots == Enum.map(snapshots, &Map.update!(&1, :reset_after_seconds, fn seconds -> seconds - 61 end))
  end

  test "upstream usage preserves current permission at rounded weekly exhaustion" do
    as_of = DateTime.utc_now() |> DateTime.truncate(:second)
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        identity_metadata: %{
          "credential_epoch" => 1,
          AccountAvailabilityStore.metadata_key() => AccountAvailabilityStore.encode!(:available, as_of, 1)
        }
      })

    assert {:ok, _} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 quota_scope: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: Decimal.new(100),
                 observed_at: as_of,
                 reset_at: DateTime.add(as_of, 86_400, :second),
                 source: "codex_usage_api",
                 freshness_state: "fresh",
                 metadata: %{"rate_limit_allowed" => true, "rate_limit_reached" => false}
               }
             ])

    assert {:ok, %{rate_limit: rate_limit}} =
             Accounting.build_codex_usage_for_pool(pool, as_of: as_of)

    assert rate_limit.allowed
    refute rate_limit.limit_reached
    assert rate_limit.secondary_window.used_percent == 100

    assert {:ok, _} =
             QuotaWindows.upsert_quota_windows_from_codex_headers(
               identity,
               [
                 {"x-codex-secondary-used-percent", "100"},
                 {"x-codex-secondary-window-minutes", "10080"},
                 {"x-codex-secondary-reset-at", Integer.to_string(DateTime.to_unix(DateTime.add(as_of, 86_400, :second)))}
               ],
               DateTime.add(as_of, 1, :second)
             )

    assert {:ok, %{rate_limit: %{allowed: true, limit_reached: false}}} =
             Accounting.build_codex_usage_for_pool(pool, as_of: DateTime.add(as_of, 2, :second))

    for {state, observed_at, epoch} <- [
          {:blocked, as_of, 1},
          {:available, DateTime.add(as_of, -7_201, :second), 1},
          {:available, as_of, 2}
        ] do
      identity
      |> Ecto.Changeset.change(
        metadata: %{
          "credential_epoch" => 1,
          AccountAvailabilityStore.metadata_key() => AccountAvailabilityStore.encode!(state, observed_at, epoch)
        }
      )
      |> CodexPooler.Repo.update!()

      assert {:ok, %{rate_limit: %{allowed: false, limit_reached: true}}} =
               Accounting.build_codex_usage_for_pool(pool, as_of: DateTime.add(as_of, 2, :second))
    end
  end

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

  test "representative usage recognizes workspace and consumer plan SKUs without substring matching" do
    workspace_plans = ~w(team business ent26 enterprise enterprise_cbp_automation enterprise_cbp_usage_based self_serve_business_prolite self_serve_business_usage_based edu edu_plus edu_pro hc education sci sci_plus)

    pairs = Enum.map(workspace_plans, &{&1, "promax"}) ++ Enum.map(~w(pro prolite promax), &{&1, "plus"}) ++ [{"plus", "go"}, {"go", "unknown"}, {"free", "enterprise_preview_unknown"}, {"free", "sci_preview_unknown"}, {"free", "sci_plus_preview_unknown"}]

    for {preferred, other} <- pairs do
      pool = pool_fixture()

      for plan <- [other, preferred] do
        %{identity: identity} = upstream_assignment_fixture(pool, %{plan_label: plan, plan_family: String.replace(plan, "_", "-")})
        put_fresh_account_quota(identity)
      end

      assert {:ok, %{plan_type: ^preferred}} = Accounting.build_codex_usage_for_pool(pool)
    end
  end

  test "public usage selects a fresh available identity without account windows" do
    as_of = ~U[2026-09-01 12:00:00.000000Z]
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct_usage_windowless_#{System.unique_integer([:positive])}",
        identity_metadata: %{
          "credential_epoch" => 1,
          AccountAvailabilityStore.metadata_key() => AccountAvailabilityStore.encode!(:available, as_of, 1)
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
            AccountAvailabilityStore.metadata_key() => AccountAvailabilityStore.encode!(state, observed_at, availability_epoch)
          }
        })

      assert {:error, %{code: :no_upstream_usage}} =
               Accounting.build_codex_usage_for_pool(pool, as_of: as_of)

      assert {:error, %{code: :no_upstream_usage}} =
               Accounting.build_codex_usage_for_upstream_identity(identity, as_of: as_of)
    end
  end

  test "public usage speaks for an uncapped account, and for a capped one only when every account is capped" do
    pool = pool_fixture()
    %{identity: capped} = upstream_assignment_fixture(pool, %{plan_label: "pro", plan_family: "pro"})
    %{identity: open} = upstream_assignment_fixture(pool, %{plan_label: "plus", plan_family: "plus"})
    put_weekly_quota(capped, "85")
    put_weekly_quota(open, "95")
    capped |> Ecto.Changeset.change(usage_cap_percent: 80) |> CodexPooler.Repo.update!()

    assert {:ok, %{plan_type: "plus", rate_limit: %{secondary_window: %{used_percent: 95}}}} = Accounting.build_codex_usage_for_pool(pool)

    open |> Ecto.Changeset.change(usage_cap_percent: 90) |> CodexPooler.Repo.update!()
    assert {:ok, %{plan_type: "pro"}} = Accounting.build_codex_usage_for_pool(pool)
  end

  defp put_weekly_quota(identity, used_percent) do
    now = DateTime.utc_now()

    assert {:ok, _windows} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{window_kind: "primary", window_minutes: 300, used_percent: Decimal.new("5"), reset_at: DateTime.add(now, 300, :second), source: "test", freshness_state: "fresh"},
               %{quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: "secondary", window_minutes: 10_080, used_percent: Decimal.new(used_percent), reset_at: DateTime.add(now, 3, :day), source: "test", freshness_state: "fresh"}
             ])
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
