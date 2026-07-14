defmodule CodexPooler.Upstreams.SavedResets.ProbeLeaseTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.SavedResets.ProbeLease
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle

  @generation 3
  @attempt "attempt-abc"

  defp identity_with_pending(opts \\ []) do
    consumed_at =
      Keyword.get_lazy(opts, :consumed_at, fn ->
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)
      end)

    phase = Keyword.get(opts, :phase, "consumed_pending_probe")

    redemption =
      %{
        "status" => RedemptionLifecycle.legacy_status_for(phase) || "redeeming",
        "phase" => phase,
        "attempt_id" => Keyword.get(opts, :attempt_id, @attempt),
        "generation" => Keyword.get(opts, :generation, @generation),
        "trigger_kind" => "gateway_auto",
        "consumed_at" => DateTime.to_iso8601(consumed_at),
        "deadline_at" =>
          consumed_at |> RedemptionLifecycle.deadline_at() |> DateTime.to_iso8601(),
        "result" => %{"code" => "reset", "applied" => true}
      }
      |> Map.merge(Keyword.get(opts, :extra, %{}))

    %{identity: identity} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{"saved_reset_redemption" => redemption}
      })

    identity
  end

  defp probe_holder(identity),
    do:
      RedemptionLifecycle.probe_holder(Repo.reload!(identity).metadata["saved_reset_redemption"])

  test "the first token claims the probe and becomes the holder" do
    identity = identity_with_pending()

    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, "token-A")
    assert probe_holder(identity) == "token-A"
  end

  test "a competing token is rejected once the probe is claimed" do
    identity = identity_with_pending()

    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, "token-A")
    assert {:error, :unavailable} = ProbeLease.claim(identity, @generation, @attempt, "token-B")
    assert probe_holder(identity) == "token-A"
  end

  test "the holding token can re-claim idempotently" do
    identity = identity_with_pending()

    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, "token-A")
    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, "token-A")
    assert probe_holder(identity) == "token-A"
  end

  test "a stale generation cannot claim the probe" do
    identity = identity_with_pending()

    assert {:error, :unavailable} =
             ProbeLease.claim(identity, @generation - 1, @attempt, "token-A")

    assert probe_holder(identity) == nil
  end

  test "a mismatched attempt cannot claim the probe" do
    identity = identity_with_pending()

    assert {:error, :unavailable} =
             ProbeLease.claim(identity, @generation, "other-attempt", "token-A")

    assert probe_holder(identity) == nil
  end

  test "a settled (confirmed) redemption is not probeable" do
    identity = identity_with_pending(phase: "confirmed_by_quota")

    assert {:error, :unavailable} = ProbeLease.claim(identity, @generation, @attempt, "token-A")
    assert probe_holder(identity) == nil
  end

  test "an elapsed bounded window is not probeable" do
    old = DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)
    identity = identity_with_pending(consumed_at: old)

    assert {:error, :unavailable} = ProbeLease.claim(identity, @generation, @attempt, "token-A")
    assert probe_holder(identity) == nil
  end

  defp phase(identity),
    do: RedemptionLifecycle.phase(Repo.reload!(identity).metadata["saved_reset_redemption"])

  test "a successful probe confirms the holding token as upstream-confirmed" do
    identity = identity_with_pending()
    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, "token-A")

    assert {:ok, :confirmed} = ProbeLease.confirm_upstream(identity, "token-A")
    assert phase(identity) == "confirmed_by_upstream"
  end

  test "a non-holding token cannot confirm the probe" do
    identity = identity_with_pending()
    assert {:ok, :claimed} = ProbeLease.claim(identity, @generation, @attempt, "token-A")

    assert {:ok, :unchanged} = ProbeLease.confirm_upstream(identity, "token-B")
    assert phase(identity) == "consumed_pending_probe"
  end

  test "confirming an unclaimed probe is a no-op" do
    identity = identity_with_pending()

    assert {:ok, :unchanged} = ProbeLease.confirm_upstream(identity, "token-A")
    assert phase(identity) == "consumed_pending_probe"
  end

  test "a probe already settled by quota is not re-confirmed by a late success" do
    identity =
      identity_with_pending(
        phase: "confirmed_by_quota",
        extra: %{"probe" => %{"token" => "token-A"}}
      )

    assert {:ok, :unchanged} = ProbeLease.confirm_upstream(identity, "token-A")
    assert phase(identity) == "confirmed_by_quota"
  end
end
