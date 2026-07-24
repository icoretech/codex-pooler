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
      "expired" => "Reset confirmation expired"
    }

    for {phase, label} <- labels do
      snapshot = SavedResetProjection.snapshot(metadata(phase), @prefs)

      assert snapshot.reset_lifecycle.phase == phase
      assert snapshot.reset_lifecycle.label == label
      assert is_binary(snapshot.reset_lifecycle.consumed_at)
      assert is_binary(snapshot.reset_lifecycle.deadline_at)
    end
  end

  test "never leaks the probe correlation token to operators" do
    meta = metadata("confirmed_by_upstream", %{"probe" => %{"token" => "secret-probe-token"}})

    snapshot = SavedResetProjection.snapshot(meta, @prefs)

    refute Map.has_key?(snapshot.last_redemption, "probe")
    refute inspect(snapshot) =~ "secret-probe-token"
  end

  test "has no lifecycle for legacy records without a phase" do
    meta = %{"saved_reset_redemption" => %{"status" => "succeeded"}}

    snapshot = SavedResetProjection.snapshot(meta, @prefs)

    assert snapshot.reset_lifecycle == nil
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
