defmodule CodexPooler.Upstreams.SavedResetsTest do
  use CodexPooler.DataCase, async: true

  alias CodexPooler.Upstreams.SavedResets

  describe "count_from_usage_payload/1" do
    test "baseline characterization preserves count coercion and current detail freshness" do
      observed_at = ~U[2026-06-23 10:00:00Z]

      metadata =
        SavedResets.usage_snapshot(
          %{
            "rate_limit_reset_credits" => %{
              "available_count" => "2.9",
              "credits" => [
                %{
                  "status" => "available",
                  "expires_at" => "2026-07-20T02:40:11.968726+02:00"
                },
                %{
                  "status" => "available",
                  "expires_at" => "2026-07-18T00:40:11.968726Z"
                }
              ]
            }
          },
          observed_at,
          "https://chatgpt.com/backend-api/wham/usage"
        )

      assert metadata["available_count"] == 2

      assert metadata["available_expires_at"] == [
               "2026-07-18T00:40:11.968726Z",
               "2026-07-20T00:40:11.968726Z"
             ]

      assert metadata["expires_observed_at"] == "2026-06-23T10:00:00Z"
      assert metadata["expires_refresh_attempted_at"] == "2026-06-23T10:00:00Z"
    end

    test "forces detail within the refresh TTL when a current expiration lacks granted_at" do
      timestamp = ~U[2026-07-24 10:00:00Z]
      observed_at = timestamp |> DateTime.add(-5, :minute) |> DateTime.to_iso8601()

      metadata = %{
        "saved_resets" => %{
          "status" => "reported",
          "available_count" => 1,
          "available_expires_at" => ["2026-08-20T00:40:11.968726Z"],
          "available_expirations" => [
            %{
              "expires_at" => "2026-08-20T00:40:11.968726Z",
              "first_seen_at" => "2026-07-23T10:00:00Z"
            }
          ],
          "next_expires_at" => "2026-08-20T00:40:11.968726Z",
          "expires_observed_at" => observed_at,
          "expires_refresh_attempted_at" => observed_at
        }
      }

      assert SavedResets.reset_credit_list_refresh_due?(metadata, 1, timestamp)
    end

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
      assert encoded =~ "\"granted_at\":null"
      refute encoded =~ "2026-06-20T00:00:00Z"
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
                 "first_seen_at" => "2026-06-23T10:00:00Z",
                 "granted_at" => nil
               },
               %{
                 "expires_at" => "2026-07-20T00:40:11.968726Z",
                 "first_seen_at" => "2026-06-23T10:00:00Z",
                 "granted_at" => nil
               }
             ]

      encoded = Jason.encode!(metadata)

      refute encoded =~ "provider-credit"
      refute encoded =~ "Provider Title"
      refute encoded =~ "Provider description"
      refute encoded =~ "provider-request"
      refute encoded =~ "raw_payload"
      refute encoded =~ "2026-06-20T00:00:00Z"
    end

    test "classifies an empty detail with a normalized zero count as authoritative" do
      observed_at = ~U[2026-06-23 10:00:00Z]

      metadata =
        SavedResets.credit_list_snapshot(
          %{"available_count" => "-1.2", "credits" => []},
          observed_at,
          "https://chatgpt.com/backend-api/wham/usage"
        )

      assert metadata["expires_detail_status"] == "authoritative_zero"
      assert metadata["available_expires_at"] == []
      assert metadata["available_expirations"] == []
      assert metadata["expires_observed_at"] == "2026-06-23T10:00:00Z"
    end

    test "classifies a positive detail with usable rows as authoritative" do
      metadata =
        SavedResets.credit_list_snapshot(
          %{
            "available_count" => "2.9",
            "credits" => [
              available_credit("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z"),
              available_credit("2026-07-18T00:40:11.968726Z", "2026-06-18T00:00:00Z")
            ]
          },
          ~U[2026-06-23 10:00:00Z],
          "https://chatgpt.com/backend-api/wham/usage"
        )

      assert metadata["expires_detail_status"] == "authoritative_rows"

      assert metadata["available_expirations"] == [
               expiration_row("2026-07-18T00:40:11.968726Z", "2026-06-18T00:00:00Z"),
               expiration_row("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z")
             ]
    end

    test "classifies a detail without count and with usable rows as authoritative" do
      metadata =
        SavedResets.credit_list_snapshot(
          %{
            "credits" => [
              available_credit("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z")
            ]
          },
          ~U[2026-06-23 10:00:00Z],
          "https://chatgpt.com/backend-api/wham/usage"
        )

      assert metadata["expires_detail_status"] == "authoritative_rows"
      assert metadata["available_count"] == 1

      assert metadata["available_expirations"] == [
               expiration_row("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z")
             ]
    end

    test "keeps authoritative expirations but clears every grant when the declared count mismatches" do
      metadata =
        SavedResets.credit_list_snapshot(
          %{
            "available_count" => 3,
            "credits" => [
              available_credit("2026-07-18T00:40:11.968726Z", "2026-06-18T00:00:00Z"),
              available_credit("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z")
            ]
          },
          ~U[2026-06-23 10:00:00Z],
          "https://chatgpt.com/backend-api/wham/usage"
        )

      assert metadata["expires_detail_status"] == "authoritative_rows"

      assert metadata["available_expirations"] == [
               expiration_row("2026-07-18T00:40:11.968726Z", nil),
               expiration_row("2026-07-20T00:40:11.968726Z", nil)
             ]
    end

    test "keeps one grant only when every equivalent-expiration credit agrees" do
      metadata =
        SavedResets.credit_list_snapshot(
          %{
            "available_count" => 2,
            "credits" => [
              available_credit("2026-07-20T02:40:11.968726+02:00", "2026-06-20T02:00:00+02:00"),
              available_credit("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z")
            ]
          },
          ~U[2026-06-23 10:00:00Z],
          "https://chatgpt.com/backend-api/wham/usage"
        )

      assert metadata["available_expirations"] == [
               expiration_row("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z")
             ]
    end

    test "clears a grouped grant when it is ambiguous, missing, or malformed" do
      metadata =
        SavedResets.credit_list_snapshot(
          %{
            "available_count" => 4,
            "credits" => [
              available_credit("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z"),
              available_credit("2026-07-20T00:40:11.968726Z", "2026-06-19T00:00:00Z"),
              available_credit("2026-07-18T00:40:11.968726Z", nil),
              available_credit("2026-07-18T00:40:11.968726Z", "not-a-date")
            ]
          },
          ~U[2026-06-23 10:00:00Z],
          "https://chatgpt.com/backend-api/wham/usage"
        )

      assert metadata["available_expirations"] == [
               expiration_row("2026-07-18T00:40:11.968726Z", nil),
               expiration_row("2026-07-20T00:40:11.968726Z", nil)
             ]

      assert Enum.all?(metadata["available_expirations"], &Map.has_key?(&1, "granted_at"))
    end

    test "marks missing, non-list, and contradictory detail payloads incomplete" do
      previous_metadata = existing_expiration_metadata()
      observed_at = ~U[2026-06-23 10:00:00Z]

      for payload <- [
            %{"available_count" => 1},
            %{"available_count" => 1, "credits" => %{}},
            %{
              "available_count" => 0,
              "credits" => [
                available_credit("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z")
              ]
            },
            %{
              "available_count" => 1,
              "credits" => [available_credit("not-a-date", "2026-06-20T00:00:00Z")]
            },
            %{"available_count" => "not-a-number", "credits" => []}
          ] do
        metadata =
          SavedResets.credit_list_snapshot(
            payload,
            observed_at,
            "https://chatgpt.com/backend-api/wham/usage",
            previous_metadata
          )

        assert metadata["expires_detail_status"] == "incomplete"

        assert metadata["available_expirations"] ==
                 previous_metadata["saved_resets"]["available_expirations"]

        assert metadata["expires_observed_at"] == "2026-06-22T10:00:00Z"
        assert metadata["expires_refresh_attempted_at"] == "2026-06-23T10:00:00Z"
      end
    end

    test "does not treat a provider detail-status string as an internal classification marker" do
      metadata =
        SavedResets.usage_snapshot(
          %{
            "rate_limit_reset_credits" => %{
              "available_count" => 1,
              "expires_detail_status" => "incomplete",
              "available_expires_at" => ["2026-07-20T00:40:11.968726Z"]
            }
          },
          ~U[2026-06-23 10:00:00Z],
          "https://chatgpt.com/backend-api/wham/usage"
        )

      assert metadata["available_expires_at"] == ["2026-07-20T00:40:11.968726Z"]
      refute Map.has_key?(metadata, "expires_detail_status")
    end

    test "authoritative details replace prior expiration rows instead of merging departed grants" do
      metadata =
        SavedResets.credit_list_snapshot(
          %{
            "available_count" => 1,
            "credits" => [
              available_credit("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z")
            ]
          },
          ~U[2026-06-23 10:00:00Z],
          "https://chatgpt.com/backend-api/wham/usage",
          existing_expiration_metadata()
        )

      assert metadata["available_expirations"] == [
               expiration_row("2026-07-20T00:40:11.968726Z", "2026-06-20T00:00:00Z")
             ]
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
                 "first_seen_at" => "2026-06-20T09:00:00Z",
                 "granted_at" => nil
               },
               %{
                 "expires_at" => "2026-07-20T00:40:11.968726Z",
                 "first_seen_at" => "2026-06-23T10:00:00Z",
                 "granted_at" => nil
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

  defp available_credit(expires_at, granted_at) do
    %{
      "status" => "available",
      "expires_at" => expires_at,
      "granted_at" => granted_at,
      "id" => "provider-credit",
      "title" => "provider title",
      "raw_payload" => %{"ignored" => true}
    }
  end

  defp expiration_row(expires_at, granted_at) do
    %{
      "expires_at" => expires_at,
      "first_seen_at" => "2026-06-23T10:00:00Z",
      "granted_at" => granted_at
    }
  end

  defp existing_expiration_metadata do
    %{
      "saved_resets" => %{
        "available_expires_at" => ["2026-07-18T00:40:11.968726Z"],
        "available_expirations" => [
          %{
            "expires_at" => "2026-07-18T00:40:11.968726Z",
            "first_seen_at" => "2026-06-22T10:00:00Z",
            "granted_at" => "2026-06-18T00:00:00Z"
          }
        ],
        "next_expires_at" => "2026-07-18T00:40:11.968726Z",
        "expires_observed_at" => "2026-06-22T10:00:00Z",
        "expires_refresh_attempted_at" => "2026-06-22T10:00:00Z"
      }
    }
  end
end
