defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetProjectionTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetProjection
  alias CodexPoolerWeb.DateTimeDisplay

  @prefs DateTimeDisplay.preferences_for_user(nil)

  defp metadata(phase, extra \\ %{}) do
    consumed_at = ~U[2026-07-14 03:20:00.000000Z]

    redemption =
      Map.merge(
        %{
          "status" => "redeeming",
          "phase" => phase,
          "attempt_id" => "attempt-1",
          "generation" => 3,
          "consumed_at" => DateTime.to_iso8601(consumed_at),
          "deadline_at" => consumed_at |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
          "result" => %{"code" => "reset", "applied" => true}
        },
        extra
      )

    %{"saved_reset_redemption" => redemption}
  end

  test "surfaces a human-readable lifecycle for each phase" do
    labels = %{
      "consuming" => "Redeeming",
      "consumed_pending_probe" => "Reset consumed — confirming",
      "confirmed_by_upstream" => "Reset confirmed by probe",
      "confirmed_by_quota" => "Reset confirmed by quota",
      "reblocked" => "Still blocked after reset",
      "expired" => "Reset confirmation expired",
      "consume_not_applied" => "Reset was not applied"
    }

    for {phase, label} <- labels do
      snapshot = SavedResetProjection.snapshot(metadata(phase), @prefs)

      assert snapshot.reset_lifecycle.phase == phase
      assert snapshot.reset_lifecycle.label == label
      assert is_binary(snapshot.reset_lifecycle.consumed_at)
      assert is_binary(snapshot.reset_lifecycle.deadline_at)
    end
  end

  test "renders an applied reblock recovered by quota as confirmed" do
    snapshot =
      SavedResetProjection.snapshot(
        metadata("confirmed_by_quota", %{
          "status" => "succeeded",
          "terminal_reason" => "converged_confirmed_by_quota"
        }),
        @prefs
      )

    assert snapshot.reset_lifecycle.phase == "confirmed_by_quota"
    assert snapshot.reset_lifecycle.label == "Reset confirmed by quota"
    refute snapshot.reset_lifecycle.label == "Still blocked after reset"
  end

  @tag :saved_reset_redemption_cause
  test "projects only the five recognized automatic redemption causes" do
    causes = %{
      {"gateway_auto", "exhausted"} => "Request · weekly exhausted",
      {"gateway_auto", "threshold"} => "Request · quota threshold",
      {"scheduled_expiry_rescue", "exhausted"} => "Scheduled · weekly exhausted",
      {"scheduled_expiry_rescue", "threshold"} => "Scheduled · quota threshold",
      {"scheduled_expiry_rescue", "last_call"} => "Scheduled · last call"
    }

    for {{trigger_kind, trigger_detail}, label} <- causes do
      snapshot =
        SavedResetProjection.snapshot(
          metadata("confirmed_by_upstream", %{
            "trigger_kind" => trigger_kind,
            "trigger_detail" => trigger_detail
          }),
          @prefs
        )

      assert snapshot.last_auto_redemption_cause == %{label: label}
    end
  end

  @tag :saved_reset_redemption_cause
  test "fails closed without rendering redemption metadata" do
    sensitive_sentinel = "saved-reset-projection-sensitive-sentinel"

    for redemption <- [
          %{"trigger_kind" => "admin_manual", "trigger_detail" => "exhausted"},
          %{"trigger_kind" => "gateway_auto", "trigger_detail" => "unrecognized"},
          %{"trigger_kind" => "scheduled_expiry_rescue"},
          %{"trigger_detail" => "last_call"},
          %{"status" => "succeeded"}
        ] do
      snapshot =
        SavedResetProjection.snapshot(
          %{
            "saved_reset_redemption" =>
              Map.merge(redemption, %{
                "probe" => %{"token" => sensitive_sentinel},
                "result" => %{"body" => sensitive_sentinel},
                "credit_id" => sensitive_sentinel,
                "arbitrary_metadata" => sensitive_sentinel
              })
          },
          @prefs
        )

      assert snapshot.last_auto_redemption_cause == nil
      refute inspect(snapshot) =~ sensitive_sentinel
    end
  end

  @tag :saved_reset_redemption_cause
  test "never leaks the probe correlation token to operators" do
    meta = metadata("confirmed_by_upstream", %{"probe" => %{"token" => "secret-probe-token"}})

    snapshot = SavedResetProjection.snapshot(meta, @prefs)

    refute Map.has_key?(snapshot, :last_redemption)
    refute inspect(snapshot) =~ "secret-probe-token"
  end

  @tag :saved_reset_redemption_cause
  test "does not project a raw terminal reason" do
    terminal_reason_sentinel = "saved-reset-terminal-reason-sensitive-sentinel"

    snapshot =
      SavedResetProjection.snapshot(
        metadata("expired", %{"terminal_reason" => terminal_reason_sentinel}),
        @prefs
      )

    refute Map.has_key?(snapshot.reset_lifecycle, :terminal_reason)
    refute inspect(snapshot) =~ terminal_reason_sentinel
  end

  @tag :saved_reset_redemption_cause
  test "has no lifecycle for legacy records without a phase" do
    meta = %{"saved_reset_redemption" => %{"status" => "succeeded"}}

    snapshot = SavedResetProjection.snapshot(meta, @prefs)

    assert snapshot.reset_lifecycle == nil
    assert snapshot.last_auto_redemption_cause == nil
  end

  test "projects a sanitized granted date from current saved-reset expiration rows" do
    expires_at = "2026-08-20T03:20:00Z"
    first_seen_at = "2026-07-20T03:20:00Z"
    granted_at = "2026-07-18T03:20:00-04:00"

    snapshot =
      SavedResetProjection.snapshot(
        %{
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 1,
            "available_expirations" => [
              %{
                "expires_at" => expires_at,
                "first_seen_at" => first_seen_at,
                "granted_at" => granted_at
              }
            ]
          }
        },
        @prefs
      )

    assert snapshot.available_expirations == [
             %{
               expires_at: expires_at,
               first_seen_at: first_seen_at,
               granted_at: "2026-07-18T07:20:00Z"
             }
           ]
  end

  test "keeps missing, nil, and malformed grant dates unavailable without estimating them" do
    expires_at = "2026-08-20T03:20:00Z"
    first_seen_at = "2026-07-20T03:20:00Z"

    snapshot =
      SavedResetProjection.snapshot(
        %{
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 3,
            "available_expirations" => [
              %{"expires_at" => expires_at, "first_seen_at" => first_seen_at},
              %{
                "expires_at" => "2026-08-21T03:20:00Z",
                "first_seen_at" => first_seen_at,
                "granted_at" => nil
              },
              %{
                "expires_at" => "2026-08-22T03:20:00Z",
                "first_seen_at" => first_seen_at,
                "granted_at" => "not-a-date"
              }
            ]
          }
        },
        @prefs
      )

    assert Enum.map(snapshot.available_expirations, & &1.granted_at) == [nil, nil, nil]
    refute Enum.any?(snapshot.available_expirations, &(&1.granted_at == "2026-07-21T03:20:00Z"))
  end
end
