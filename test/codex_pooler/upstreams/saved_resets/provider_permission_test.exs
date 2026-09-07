defmodule CodexPooler.Upstreams.SavedResets.ProviderPermissionTest do
  use CodexPooler.DataCase, async: true

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.PostResetEvidence

  @now ~U[2026-09-07 10:00:00.000000Z]

  test "persisted full-percent available sibling fences automatic redemption" do
    identity = identity_with_permission(:available, @now, 1)
    windows = put_window(identity, @now)
    assert AutoEligibility.locked_sibling_usable_capacity?(identity, %{quota_scope: %{}}, @now)

    assert PostResetEvidence.classify(identity, windows, DateTime.add(@now, -60), @now) ==
             :confirmed
  end

  test "blocked, stale and credential-mismatched permissions cannot attest capacity" do
    for {state, observed_at, epoch} <- [
          {:blocked, @now, 1},
          {:available, DateTime.add(@now, -3600), 1},
          {:available, @now, 2}
        ] do
      identity = identity_with_permission(state, observed_at, epoch)
      windows = put_window(identity, @now)
      refute AutoEligibility.locked_sibling_usable_capacity?(identity, %{quota_scope: %{}}, @now)

      assert PostResetEvidence.classify(identity, windows, DateTime.add(@now, -60), @now) ==
               :reblocked
    end
  end

  test "explicit denial at full usage remains reblocked" do
    identity = identity_with_permission(:blocked, @now, 1)
    [window] = put_window(identity, @now)

    window =
      window
      |> Ecto.Changeset.change(
        metadata: %{
          "rate_limit_allowed" => false,
          "rate_limit_reached" => true
        }
      )
      |> Repo.update!()

    refute AutoEligibility.locked_sibling_usable_capacity?(identity, %{quota_scope: %{}}, @now)

    assert PostResetEvidence.classify(identity, [window], DateTime.add(@now, -60), @now) ==
             :reblocked
  end

  test "fresh explicit denial reblocks low-percent post-consume evidence" do
    identity = identity_with_permission(:blocked, @now, 1)
    [window] = put_window(identity, @now)

    window =
      window
      |> Ecto.Changeset.change(
        used_percent: Decimal.new(3),
        metadata: %{
          "rate_limit_allowed" => false,
          "rate_limit_reached" => true
        }
      )
      |> Repo.update!()

    assert PostResetEvidence.classify(identity, [window], DateTime.add(@now, -60), @now) ==
             :reblocked
  end

  test "unknown permission cannot promote exhausted evidence" do
    identity = identity_with_permission(:unknown, @now, 1)
    windows = put_window(identity, @now)

    assert PostResetEvidence.classify(identity, windows, DateTime.add(@now, -60), @now) ==
             :reblocked
  end

  test "pre-consume available evidence cannot confirm a consumed reset" do
    observed_at = DateTime.add(@now, -120)
    identity = identity_with_permission(:available, observed_at, 1)
    windows = put_window(identity, observed_at)

    assert PostResetEvidence.classify(identity, windows, DateTime.add(@now, -60), @now) ==
             :pending
  end

  defp identity_with_permission(state, observed_at, epoch) do
    active_upstream_identity_fixture()
    |> Ecto.Changeset.change(
      metadata: %{
        "credential_epoch" => 1,
        "quota_account_availability" =>
          AccountAvailabilityStore.encode!(state, observed_at, epoch)
      }
    )
    |> Repo.update!()
  end

  defp put_window(identity, observed_at) do
    {:ok, windows} =
      Windows.upsert_quota_windows(identity, [
        %{
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new(100),
          reset_at: DateTime.add(@now, 2, :day),
          observed_at: observed_at,
          last_sync_at: observed_at,
          source: "codex_usage_api",
          source_precision: "observed",
          freshness_state: "fresh",
          metadata: %{"rate_limit_allowed" => true, "rate_limit_reached" => false}
        }
      ])

    windows
  end
end
