defmodule CodexPooler.Upstreams.SavedResetsTest do
  use CodexPooler.DataCase, async: true

  alias CodexPooler.Upstreams.SavedResets

  describe "count_from_usage_payload/1" do
    test "parses reported saved reset counts" do
      assert {:reported, 2} =
               SavedResets.count_from_usage_payload(%{
                 "rate_limit_reset_credits" => %{"available_count" => 2}
               })

      assert %{label: "2 saved resets", available?: true, reported?: true} =
               %{
                 "saved_resets" =>
                   SavedResets.usage_snapshot(
                     %{"rate_limit_reset_credits" => %{"available_count" => 2}},
                     DateTime.utc_now(),
                     "https://chatgpt.com/wham/usage"
                   )
               }
               |> SavedResets.snapshot()
    end

    test "projects sanitized reset credit expirations" do
      observed_at = ~U[2026-06-23 10:00:00Z]

      snapshot =
        %{
          "saved_resets" =>
            SavedResets.usage_snapshot(
              %{
                "rate_limit_reset_credits" => %{
                  "available_count" => 2,
                  "credits" => [
                    %{
                      "id" => "ignored-late",
                      "status" => "available",
                      "expires_at" => "2026-07-20T00:40:11.968726Z"
                    },
                    %{
                      "id" => "ignored-redeemed",
                      "status" => "redeemed",
                      "expires_at" => "2026-07-18T00:40:11.968726Z"
                    },
                    %{
                      "id" => "ignored-early",
                      "status" => "available",
                      "expires_at" => "2026-07-18T00:40:11.968726Z"
                    }
                  ]
                }
              },
              observed_at,
              "https://chatgpt.com/backend-api/wham/usage"
            )
        }
        |> SavedResets.snapshot()

      assert snapshot.available_expires_at == [
               "2026-07-18T00:40:11.968726Z",
               "2026-07-20T00:40:11.968726Z"
             ]

      assert snapshot.next_expires_at == "2026-07-18T00:40:11.968726Z"
      assert snapshot.expires_reported? == true
    end

    test "normalizes legacy expiration metadata without provider fields" do
      observed_at = ~U[2026-06-23 10:00:00Z]

      metadata =
        SavedResets.usage_snapshot(
          %{
            "rate_limit_reset_credits" => %{
              "available_count" => 2,
              "credits" => [
                %{
                  "id" => "provider-credit-late",
                  "status" => "available",
                  "expires_at" => "2026-07-20T00:40:11.968726Z",
                  "granted_at" => "2026-06-20T00:00:00Z",
                  "title" => "Provider Title",
                  "description" => "Provider description",
                  "request_id" => "provider-request"
                },
                %{
                  "id" => "provider-credit-duplicate",
                  "status" => "available",
                  "expires_at" => "2026-07-18T00:40:11.968726Z"
                },
                %{
                  "id" => "provider-credit-early",
                  "status" => "available",
                  "expires_at" => "2026-07-18T00:40:11.968726Z"
                },
                %{
                  "id" => "provider-credit-redeemed",
                  "status" => "redeemed",
                  "expires_at" => "2026-07-16T00:40:11.968726Z"
                }
              ]
            }
          },
          observed_at,
          "https://chatgpt.com/backend-api/wham/usage"
        )

      assert metadata["available_expires_at"] == [
               "2026-07-18T00:40:11.968726Z",
               "2026-07-20T00:40:11.968726Z"
             ]

      assert metadata["next_expires_at"] == "2026-07-18T00:40:11.968726Z"

      encoded = Jason.encode!(metadata)

      refute encoded =~ "provider-credit"
      refute encoded =~ "Provider Title"
      refute encoded =~ "Provider description"
      refute encoded =~ "provider-request"
      refute encoded =~ "granted_at"
    end

    test "stores sanitized available expiration rows with first seen timestamps" do
      observed_at = ~U[2026-06-23 10:00:00Z]

      metadata =
        SavedResets.usage_snapshot(
          %{
            "rate_limit_reset_credits" => %{
              "available_count" => 2,
              "credits" => [
                %{
                  "id" => "provider-credit-late",
                  "status" => "available",
                  "expires_at" => "2026-07-20T00:40:11.968726Z",
                  "granted_at" => "2026-06-20T00:00:00Z",
                  "title" => "Provider Title",
                  "description" => "Provider description",
                  "request_id" => "provider-request",
                  "raw_payload" => %{"unsafe" => true}
                },
                %{
                  "id" => "provider-credit-duplicate",
                  "status" => "available",
                  "expires_at" => "2026-07-18T00:40:11.968726Z"
                },
                %{
                  "id" => "provider-credit-early",
                  "status" => "available",
                  "expires_at" => "2026-07-18T00:40:11.968726Z"
                },
                %{
                  "id" => "provider-credit-redeemed",
                  "status" => "redeemed",
                  "expires_at" => "2026-07-16T00:40:11.968726Z"
                },
                %{
                  "id" => "provider-credit-unavailable",
                  "status" => "unavailable",
                  "expires_at" => "2026-07-15T00:40:11.968726Z"
                },
                %{
                  "id" => "provider-credit-invalid",
                  "status" => "available",
                  "expires_at" => "not-a-date"
                }
              ]
            }
          },
          observed_at,
          "https://chatgpt.com/backend-api/wham/usage"
        )

      assert metadata["available_expirations"] == [
               %{
                 "expires_at" => "2026-07-18T00:40:11.968726Z",
                 "first_seen_at" => "2026-06-23T10:00:00Z"
               },
               %{
                 "expires_at" => "2026-07-20T00:40:11.968726Z",
                 "first_seen_at" => "2026-06-23T10:00:00Z"
               }
             ]

      encoded = Jason.encode!(metadata)

      refute encoded =~ "provider-credit"
      refute encoded =~ "Provider Title"
      refute encoded =~ "Provider description"
      refute encoded =~ "provider-request"
      refute encoded =~ "raw_payload"
      refute encoded =~ "granted_at"
      refute encoded =~ "2026-06-20T00:00:00Z"
    end

    test "projects available expiration rows and keeps legacy expiration metadata" do
      snapshot =
        %{
          "saved_resets" => %{
            "status" => "reported",
            "available_count" => 2,
            "source" => "codex_usage_api",
            "path_style" => "chatgpt_api",
            "observed_at" => "2026-06-23T10:00:00Z",
            "usage_path" => "/wham/usage",
            "available_expires_at" => [
              "2026-07-20T00:40:11.968726Z",
              "2026-07-18T00:40:11.968726Z"
            ],
            "available_expirations" => [
              %{
                "expires_at" => "2026-07-20T00:40:11.968726Z",
                "first_seen_at" => "2026-06-21T09:00:00Z"
              },
              %{"expires_at" => "2026-07-18T00:40:11.968726Z"}
            ],
            "next_expires_at" => "2026-07-18T00:40:11.968726Z",
            "expires_observed_at" => "2026-06-23T10:00:00Z",
            "expires_refresh_attempted_at" => "2026-06-23T10:00:00Z",
            "reason" => nil
          }
        }
        |> SavedResets.snapshot()

      assert snapshot.available_expirations == [
               %{
                 expires_at: "2026-07-18T00:40:11.968726Z",
                 first_seen_at: nil
               },
               %{
                 expires_at: "2026-07-20T00:40:11.968726Z",
                 first_seen_at: "2026-06-21T09:00:00Z"
               }
             ]

      assert snapshot.available_expires_at == [
               "2026-07-18T00:40:11.968726Z",
               "2026-07-20T00:40:11.968726Z"
             ]

      assert snapshot.next_expires_at == "2026-07-18T00:40:11.968726Z"
      assert snapshot.expires_reported? == true
    end

    test "preserves first seen only for immediately previous current expirations" do
      observed_at = ~U[2026-06-23 10:00:00Z]

      previous_metadata = %{
        "saved_resets" => %{
          "available_expirations" => [
            %{
              "expires_at" => "2026-07-18T00:40:11.968726Z",
              "first_seen_at" => "2026-06-20T09:00:00Z"
            }
          ]
        }
      }

      metadata =
        SavedResets.usage_snapshot(
          %{
            "rate_limit_reset_credits" => %{
              "available_count" => 2,
              "credits" => [
                %{
                  "status" => "available",
                  "expires_at" => "2026-07-20T00:40:11.968726Z"
                },
                %{
                  "status" => "available",
                  "expires_at" => "2026-07-18T00:40:11.968726Z"
                }
              ]
            }
          },
          observed_at,
          "https://chatgpt.com/backend-api/wham/usage",
          previous_metadata
        )

      assert metadata["available_expirations"] == [
               %{
                 "expires_at" => "2026-07-18T00:40:11.968726Z",
                 "first_seen_at" => "2026-06-20T09:00:00Z"
               },
               %{
                 "expires_at" => "2026-07-20T00:40:11.968726Z",
                 "first_seen_at" => "2026-06-23T10:00:00Z"
               }
             ]
    end

    test "summary fallback owns first seen metadata and omits provider fields" do
      observed_at = ~U[2026-06-23 10:00:00Z]

      previous_metadata = %{
        "saved_resets" => %{
          "available_expirations" => [
            %{
              "expires_at" => "2026-07-18T00:40:11.968726Z",
              "first_seen_at" => "2026-06-20T09:00:00Z"
            },
            %{
              "expires_at" => "2026-07-16T00:40:11.968726Z",
              "first_seen_at" => "2026-06-19T09:00:00Z"
            }
          ]
        }
      }

      metadata =
        SavedResets.usage_snapshot(
          %{
            "rate_limit_reset_credits" => %{
              "available_count" => 2,
              "available_expirations" => [
                %{
                  "expires_at" => "2026-07-20T00:40:11.968726Z",
                  "first_seen_at" => "1999-01-01T00:00:00Z",
                  "provider_id" => "provider-credit-late",
                  "raw_payload" => %{"unsafe" => true}
                },
                %{
                  "expires_at" => "2026-07-18T00:40:11.968726Z",
                  "first_seen_at" => "1998-01-01T00:00:00Z",
                  "provider_title" => "Provider Title"
                }
              ]
            }
          },
          observed_at,
          "https://chatgpt.com/backend-api/wham/usage",
          previous_metadata
        )

      assert metadata["available_expires_at"] == [
               "2026-07-18T00:40:11.968726Z",
               "2026-07-20T00:40:11.968726Z"
             ]

      assert metadata["available_expirations"] == [
               %{
                 "expires_at" => "2026-07-18T00:40:11.968726Z",
                 "first_seen_at" => "2026-06-20T09:00:00Z"
               },
               %{
                 "expires_at" => "2026-07-20T00:40:11.968726Z",
                 "first_seen_at" => "2026-06-23T10:00:00Z"
               }
             ]

      assert Enum.all?(metadata["available_expirations"], fn row ->
               row |> Map.keys() |> Enum.sort() == ["expires_at", "first_seen_at"]
             end)

      encoded = Jason.encode!(metadata)

      refute encoded =~ "1999-01-01T00:00:00Z"
      refute encoded =~ "1998-01-01T00:00:00Z"
      refute encoded =~ "provider-credit-late"
      refute encoded =~ "Provider Title"
      refute encoded =~ "raw_payload"
    end

    test "clamps negative counts to zero" do
      assert {:reported, 0} =
               SavedResets.count_from_usage_payload(%{
                 "rate_limit_reset_credits" => %{"available_count" => -1}
               })

      assert %{label: "No saved resets", available?: false, reported?: true} =
               %{
                 "saved_resets" =>
                   SavedResets.usage_snapshot(
                     %{"rate_limit_reset_credits" => %{"available_count" => -1}},
                     DateTime.utc_now(),
                     "https://chatgpt.com/wham/usage"
                   )
               }
               |> SavedResets.snapshot()
    end

    test "returns unreported when the block is missing" do
      assert :unreported = SavedResets.count_from_usage_payload(%{})

      assert %{label: "Saved resets not reported", available?: false, reported?: false} =
               %{"saved_resets" => SavedResets.usage_snapshot(%{}, DateTime.utc_now(), nil)}
               |> SavedResets.snapshot()
    end

    test "projects fresh in-progress redemption metadata" do
      started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert %{in_progress?: true, redemption_stale?: false} =
               started_at
               |> saved_reset_snapshot_metadata()
               |> SavedResets.snapshot()
    end

    test "projects stale redemption metadata as retryable" do
      started_at =
        DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:microsecond)

      assert %{in_progress?: false, redemption_stale?: true} =
               started_at
               |> saved_reset_snapshot_metadata()
               |> SavedResets.snapshot()
    end
  end

  defp saved_reset_snapshot_metadata(started_at) do
    %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => 1,
        "source" => "codex_usage_api",
        "path_style" => "chatgpt_api",
        "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "usage_path" => "/wham/usage",
        "reason" => nil
      },
      "saved_reset_redemption" => %{
        "status" => "redeeming",
        "attempt_id" => Ecto.UUID.generate(),
        "generation" => 1,
        "trigger_kind" => "admin_manual",
        "started_at" => DateTime.to_iso8601(started_at),
        "finished_at" => nil,
        "result" => nil
      }
    }
  end
end
