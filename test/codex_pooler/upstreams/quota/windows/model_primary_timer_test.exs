defmodule CodexPooler.Upstreams.Quota.Windows.ModelPrimaryTimerTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.PoolerFixtures
  alias CodexPooler.Quotas.Evidence.CodexParsers
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection

  @start ~U[2026-08-01 09:00:00.000000Z]

  test "provider sliding model primary becomes starts on use then preserves the real activation anchor" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    assert {:ok, _} = persist(identity, @start, @start)
    t1 = DateTime.add(@start, 60)
    assert {:ok, _} = persist(identity, t1, t1)
    t2 = DateTime.add(@start, 240)
    assert {:ok, floating} = persist(identity, t2, t2)
    assert floating.reset_at == DateTime.add(t2, 18_000)
    assert floating.metadata["reset_state"] == "floating"

    assert Enum.any?(
             QuotaProjection.quota_limit_rows([floating], %{}, t2),
             &(&1.reset_label == "starts on use")
           )

    t3 = DateTime.add(t2, 90)
    assert {:ok, anchored} = persist(identity, t3, t2)
    assert anchored.reset_at == floating.reset_at
    assert anchored.metadata["reset_state"] == "anchored"

    assert Enum.any?(
             QuotaProjection.quota_limit_rows([anchored], %{}, t3),
             &(&1.reset_display_state == :countdown and &1.reset_at == anchored.reset_at)
           )

    assert {:ok, replayed} = persist(identity, t1, t1)
    assert replayed.reset_at == anchored.reset_at
    assert replayed.observed_at == anchored.observed_at
    assert replayed.metadata["reset_state"] == "anchored"
  end

  test "a legacy pinned timer converges to a distant provider anchor after repeated live countdowns" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    assert {:ok, original} = persist(identity, @start, @start)
    t1 = DateTime.add(@start, 7200)
    cycle = DateTime.add(t1, -600)
    assert {:ok, candidate} = persist(identity, t1, cycle)
    assert candidate.reset_at == original.reset_at
    t2 = DateTime.add(t1, 180)
    assert {:ok, anchored} = persist(identity, t2, cycle)
    assert anchored.reset_at == DateTime.add(cycle, 18_000)
    assert anchored.metadata["reset_state"] == "anchored"
  end

  test "a single zero observation does not erase positive model usage" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    assert {:ok, used} = persist(identity, @start, @start, 35)
    t1 = DateTime.add(@start, 90)
    assert {:ok, candidate} = persist(identity, t1, t1)
    assert Decimal.equal?(candidate.used_percent, used.used_percent)
    assert candidate.reset_at == used.reset_at
  end

  defp persist(identity, at, cycle_start, used_percent \\ 0) do
    reset = DateTime.add(cycle_start, 18_000)

    payload = %{
      "additional_rate_limits" => [
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "gpt-5.3-codex-spark",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => 18_000,
              "reset_after_seconds" => DateTime.diff(reset, at),
              "reset_at" => DateTime.to_unix(reset)
            }
          }
        }
      ]
    }

    {:ok, [evidence]} = CodexParsers.parse_codex_usage_payload(payload, at)
    EvidenceStore.record_evidence(identity, evidence, at, at)
  end
end
