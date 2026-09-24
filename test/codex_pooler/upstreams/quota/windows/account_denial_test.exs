defmodule CodexPooler.Upstreams.Quota.Windows.AccountDenialTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows.AccountDenial

  @denied_at ~U[2026-09-24 09:12:02.000000Z]
  @primary_reset ~U[2026-09-24 11:16:24.000000Z]
  @secondary_reset ~U[2026-09-27 08:00:00.000000Z]

  for type <- AccountDenial.account_denial_types() do
    test "#{type} on windows below 100 percent is in force until the earliest reported reset" do
      snapshot = snapshot(denied_windows(unquote(type)), at: DateTime.add(@denied_at, 10, :second))

      assert %{reached_type: unquote(type), reset_at: @primary_reset, observed_at: @denied_at, source: "codex_response_headers"} =
               AccountDenial.active(snapshot)

      assert AccountDenial.active(%{snapshot | as_of: DateTime.add(@primary_reset, -1, :second)})
      refute AccountDenial.active(%{snapshot | as_of: @primary_reset})
    end
  end

  test "ordinary, unknown and absent reached types are not account denials" do
    for type <- ["rate_limit_reached", "future_workspace_limit", nil] do
      refute AccountDenial.active(snapshot(denied_windows(type), at: DateTime.add(@denied_at, 10, :second)))
    end
  end

  test "a model-scoped window carrying the marker still denies the account" do
    [primary | _rest] = denied_windows("workspace_member_credits_depleted")
    spark = %{primary | quota_scope: "model", quota_family: "codex_bengalfox", model: "gpt-5.3-codex-spark"}

    assert %{reached_type: "workspace_member_credits_depleted"} =
             AccountDenial.active(snapshot([spark], at: DateTime.add(@denied_at, 10, :second)))
  end

  test "an earlier available reading, like the poll just before the 429, does not lift the denial" do
    availability = availability(:available, DateTime.add(@denied_at, -1, :second), 1)
    snapshot = snapshot(denied_windows("workspace_member_credits_depleted"), at: DateTime.add(@denied_at, 10, :second), availability: availability)

    assert AccountDenial.active(snapshot)
  end

  test "a later available reading for the current credential epoch lifts the denial" do
    later = DateTime.add(@denied_at, 60, :second)
    windows = denied_windows("workspace_member_credits_depleted")

    refute AccountDenial.active(snapshot(windows, at: DateTime.add(later, 1, :second), availability: availability(:available, later, 1)))

    for {state, epoch} <- [{:blocked, 1}, {:unknown, 1}, {:available, 2}] do
      assert AccountDenial.active(snapshot(windows, at: DateTime.add(later, 1, :second), availability: availability(state, later, epoch)))
    end
  end

  test "an available reading from the snapshot's future does not lift the denial" do
    at = DateTime.add(@denied_at, 10, :second)
    availability = availability(:available, DateTime.add(at, 30, :second), 1)

    assert AccountDenial.active(snapshot(denied_windows("workspace_member_credits_depleted"), at: at, availability: availability))
  end

  test "only the latest marked observation decides the deadline" do
    [primary, secondary] = denied_windows("workspace_member_credits_depleted")
    older = %{primary | observed_at: DateTime.add(@denied_at, -3_600, :second), reset_at: DateTime.add(@denied_at, -60, :second)}

    assert %{reset_at: @secondary_reset} =
             AccountDenial.active(snapshot([older, secondary], at: DateTime.add(@denied_at, 10, :second)))
  end

  test "a resetless marker holds only while it is fresh" do
    windows = Enum.map(denied_windows("workspace_member_credits_depleted"), &%{&1 | reset_at: nil})
    ttl = Evidence.freshness_ttl_seconds()

    assert AccountDenial.active(snapshot(windows, at: DateTime.add(@denied_at, ttl, :second)))
    refute AccountDenial.active(snapshot(windows, at: DateTime.add(@denied_at, ttl + 1, :second)))
  end

  test "a marker observed after the snapshot instant is not visible" do
    refute AccountDenial.active(snapshot(denied_windows("workspace_member_credits_depleted"), at: DateTime.add(@denied_at, -1, :second)))
  end

  test "no snapshot means no denial" do
    refute AccountDenial.active(nil)
  end

  defp denied_windows(type) do
    metadata = if type, do: %{"header_limit_id" => "codex", "rate_limit_reached_type" => type}, else: %{"header_limit_id" => "codex"}

    [
      window("primary", 300, "97", @primary_reset, metadata),
      window("secondary", 10_080, "96", @secondary_reset, metadata)
    ]
  end

  defp window(kind, minutes, used_percent, reset_at, metadata) do
    %AccountQuotaWindow{
      id: Ecto.UUID.generate(),
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: kind,
      window_minutes: minutes,
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      source: "codex_response_headers",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: @denied_at,
      last_sync_at: @denied_at,
      metadata: metadata
    }
  end

  defp availability(state, observed_at, epoch),
    do: %AccountAvailabilityStore.Snapshot{state: state, observed_at: observed_at, credential_epoch: epoch}

  defp snapshot(windows, opts) do
    %RoutingQuotaSnapshot{
      upstream_identity_id: Ecto.UUID.generate(),
      raw_windows: windows,
      availability: Keyword.get(opts, :availability),
      credential_epoch: 1,
      as_of: Keyword.fetch!(opts, :at)
    }
  end
end
