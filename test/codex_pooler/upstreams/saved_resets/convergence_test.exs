defmodule CodexPooler.Upstreams.SavedResets.ConvergenceTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.SavedResets.Convergence

  defp identity_with_pending(consumed_at, opts \\ []) do
    deadline = Keyword.get(opts, :deadline_at, DateTime.add(consumed_at, 15, :minute))
    phase = Keyword.get(opts, :phase, "consumed_pending_probe")

    redemption =
      case phase do
        nil ->
          %{"status" => "succeeded", "result" => %{"code" => "reset", "applied" => true}}

        phase ->
          %{
            "status" => "redeeming",
            "phase" => phase,
            "attempt_id" => Ecto.UUID.generate(),
            "generation" => 3,
            "trigger_kind" => "gateway_auto",
            "started_at" => DateTime.to_iso8601(consumed_at),
            "consumed_at" => DateTime.to_iso8601(consumed_at),
            "deadline_at" => DateTime.to_iso8601(deadline),
            "finished_at" => nil,
            "result" => %{"code" => "reset", "applied" => true}
          }
      end

    %{identity: identity} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{"saved_reset_redemption" => redemption}
      })

    identity
  end

  defp upsert_account_window!(identity, used_percent) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, [_window]} =
             Windows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: "secondary",
                 window_minutes: 10_080,
                 used_percent: used_percent,
                 reset_at: DateTime.add(now, 2, :day),
                 observed_at: now,
                 last_sync_at: now,
                 source: "codex_usage_api",
                 source_precision: "observed",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh"
               }
             ])
  end

  defp redemption(identity), do: Repo.reload!(identity).metadata["saved_reset_redemption"]

  test "fresh usable evidence confirms a pending reset" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at)
    upsert_account_window!(identity, Decimal.new("0"))

    assert {:ok, :confirmed_by_quota} = Convergence.converge(identity)

    assert redemption(identity)["phase"] == "confirmed_by_quota"
    assert redemption(identity)["status"] == "succeeded"
    assert redemption(identity)["terminal_reason"] == "converged_confirmed_by_quota"
  end

  test "fresh exhausted evidence reblocks a pending reset" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at)
    upsert_account_window!(identity, Decimal.new("100"))

    assert {:ok, :reblocked} = Convergence.converge(identity)
    assert redemption(identity)["phase"] == "reblocked"
    assert redemption(identity)["status"] == "failed"
  end

  test "a pending reset without fresh evidence stays pending until its window elapses" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at)

    # No fresh account window observed after consume -> nothing to converge yet.
    assert {:ok, :unchanged} = Convergence.converge(identity)
    assert redemption(identity)["phase"] == "consumed_pending_probe"
  end

  test "a pending reset past its bounded window expires fail-closed" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at)

    assert {:ok, :expired} = Convergence.converge(identity)
    assert redemption(identity)["phase"] == "expired"
    assert redemption(identity)["status"] == "failed"
  end

  test "a legacy record without a phase is never converged" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at, phase: nil)
    upsert_account_window!(identity, Decimal.new("0"))

    assert {:ok, :unchanged} = Convergence.converge(identity)
    assert redemption(identity)["status"] == "succeeded"
    refute Map.has_key?(redemption(identity), "phase")
  end
end
