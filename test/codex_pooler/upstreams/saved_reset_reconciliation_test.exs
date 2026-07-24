defmodule CodexPooler.Upstreams.SavedResetReconciliationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.FirstSeenLedger

  @saved_reset_detail_max_bytes 1_048_576

  test "refresh_quota_from_usage stores sanitized saved reset usage snapshot" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {404, %{}},
           "/backend-api/codex/usage" => {404, %{}},
           "/wham/usage" => {404, %{}},
           "/backend-api/wham/usage" => {200, usage_payload(3)},
           "/backend-api/wham/rate-limit-reset-credits" => {200, reset_credits_payload()}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)

    assert %{
             status: "reported",
             available_count: 3,
             available?: true,
             reported?: true,
             expires_reported?: true,
             available_expires_at: [
               "2026-07-18T00:40:11.968726Z",
               "2026-07-20T00:40:11.968726Z"
             ],
             next_expires_at: "2026-07-18T00:40:11.968726Z",
             path_style: "chatgpt_api",
             usage_path: "/backend-api/wham/usage"
           } = SavedResets.snapshot(updated_identity)

    assert get_in(updated_identity.metadata, ["saved_resets", "source"]) == "codex_usage_api"
    assert is_binary(get_in(updated_identity.metadata, ["saved_resets", "observed_at"]))

    assert get_in(updated_identity.metadata, ["saved_resets", "available_expirations"]) == [
             %{
               "expires_at" => "2026-07-18T00:40:11.968726Z",
               "first_seen_at" =>
                 get_in(updated_identity.metadata, ["saved_resets", "expires_observed_at"]),
               "granted_at" => nil
             },
             %{
               "expires_at" => "2026-07-20T00:40:11.968726Z",
               "first_seen_at" =>
                 get_in(updated_identity.metadata, ["saved_resets", "expires_observed_at"]),
               "granted_at" => nil
             }
           ]

    metadata_json = Jason.encode!(updated_identity.metadata)
    assert metadata_json =~ "available_expires_at"
    assert metadata_json =~ "next_expires_at"
    refute metadata_json =~ "RateLimitResetCredit_"
    refute metadata_json =~ "credit_id"
    refute metadata_json =~ "redeem_request_id"
    refute metadata_json =~ "One free rate limit reset"
    refute metadata_json =~ "Referral reward"
  end

  test "refresh_quota_from_usage persists coherent grouped grants from FakeUpstream detail" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {404, %{}},
           "/backend-api/codex/usage" => {404, %{}},
           "/wham/usage" => {404, %{}},
           "/backend-api/wham/usage" => {200, usage_payload(2)},
           "/backend-api/wham/rate-limit-reset-credits" => {200, coherent_reset_credits_payload()}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    saved_resets = Repo.reload!(updated_identity).metadata["saved_resets"]

    assert saved_resets["available_expirations"] == [
             %{
               "expires_at" => "2026-07-20T00:40:11.968726Z",
               "first_seen_at" => saved_resets["expires_observed_at"],
               "granted_at" => "2026-06-20T00:00:00Z"
             }
           ]

    assert Enum.all?(saved_resets["available_expirations"], fn row ->
             row |> Map.keys() |> Enum.sort() == ["expires_at", "first_seen_at", "granted_at"]
           end)

    refute Jason.encode!(saved_resets) =~ "provider_only"

    assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
             "/backend-api/wham/usage",
             "/backend-api/wham/rate-limit-reset-credits"
           ]
  end

  test "a persisted nil grant prevents an immediate second detail request" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, usage_payload(2)},
           "/backend-api/wham/rate-limit-reset-credits" =>
             {200, ambiguous_reset_credits_payload()}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    assert {:ok, first_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    first_identity = Repo.reload!(first_identity)

    assert [%{"granted_at" => nil} = expiration] =
             first_identity.metadata["saved_resets"]["available_expirations"]

    assert Map.has_key?(expiration, "granted_at")

    assert {:ok, second_identity} =
             PoolReconciliation.refresh_quota_from_usage(first_identity, assignment)

    assert [%{"granted_at" => nil}] =
             Repo.reload!(second_identity).metadata["saved_resets"]["available_expirations"]

    assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
             "/backend-api/wham/usage",
             "/backend-api/wham/rate-limit-reset-credits",
             "/backend-api/wham/usage"
           ]
  end

  test "refresh_quota_from_usage fetches reset expirations when Codex usage reports saved resets" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {200, usage_payload(1)},
           "/backend-api/wham/rate-limit-reset-credits" => {200, reset_credits_payload()}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    assert %{
             available_count: 3,
             expires_reported?: true,
             next_expires_at: "2026-07-18T00:40:11.968726Z",
             path_style: "codex_api",
             usage_path: "/api/codex/usage"
           } = SavedResets.snapshot(Repo.reload!(updated_identity))

    assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
             "/api/codex/usage",
             "/backend-api/wham/rate-limit-reset-credits"
           ]
  end

  test "refresh_quota_from_usage preserves current first-seen expiration metadata" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {200, usage_payload(3)},
           "/backend-api/wham/rate-limit-reset-credits" => {200, reset_credits_payload()}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          Map.merge(
            %{"usage_base_url" => FakeUpstream.url(fake)},
            previous_expiration_metadata()
          )
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    saved_resets = Repo.reload!(updated_identity).metadata["saved_resets"]
    observed_at = saved_resets["expires_observed_at"]

    assert saved_resets["available_expires_at"] == [
             "2026-07-18T00:40:11.968726Z",
             "2026-07-20T00:40:11.968726Z"
           ]

    assert saved_resets["available_expirations"] == [
             %{
               "expires_at" => "2026-07-18T00:40:11.968726Z",
               "first_seen_at" => "2026-06-21T09:00:00Z",
               "granted_at" => nil
             },
             %{
               "expires_at" => "2026-07-20T00:40:11.968726Z",
               "first_seen_at" => observed_at,
               "granted_at" => nil
             }
           ]

    assert saved_resets["next_expires_at"] == "2026-07-18T00:40:11.968726Z"

    refute Enum.any?(saved_resets["available_expirations"], fn row ->
             row["expires_at"] == "2026-07-21T00:40:11.968726Z"
           end)

    refute Jason.encode!(saved_resets) =~ "not-a-date"

    assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
             "/api/codex/usage",
             "/backend-api/wham/rate-limit-reset-credits"
           ]
  end

  test "refresh_quota_from_usage reuses fresh expiration metadata without polling every time" do
    {:ok, fake} =
      FakeUpstream.start_link({:path_json, %{"/api/codex/usage" => {200, usage_payload(2)}}})

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          Map.merge(%{"usage_base_url" => FakeUpstream.url(fake)}, fresh_expiration_metadata(2))
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    assert %{
             available_count: 2,
             expires_reported?: true,
             available_expires_at: ["2026-07-18T00:40:11.968726Z"],
             available_expirations: [
               %{
                 expires_at: "2026-07-18T00:40:11.968726Z",
                 first_seen_at: "2026-06-21T09:00:00Z",
                 granted_at: nil
               }
             ],
             next_expires_at: "2026-07-18T00:40:11.968726Z"
           } = SavedResets.snapshot(Repo.reload!(updated_identity))

    assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
             "/api/codex/usage"
           ]
  end

  test "refresh_quota_from_usage stores unreported snapshot when usage omits reset credits" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {200, Map.delete(usage_payload(1), "rate_limit_reset_credits")}
         }}
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    assert %{
             status: "unreported",
             available_count: nil,
             available?: false,
             reported?: false,
             usage_path: "/api/codex/usage"
           } = SavedResets.snapshot(Repo.reload!(updated_identity))
  end

  test "visible then zero then the same expiration restores the original first seen from the ledger" do
    expiration = "2026-08-20T00:40:11.968726Z"
    granted_at = "2026-07-20T00:00:00Z"

    {:ok, fake} =
      FakeUpstream.start_link(saved_reset_mode(1, reset_credit_rows(expiration, granted_at)))

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    assert {:ok, visible_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    visible_identity = Repo.reload!(visible_identity)

    assert [
             %{
               "expires_at" => ^expiration,
               "first_seen_at" => original_first_seen,
               "granted_at" => ^granted_at
             }
           ] = visible_identity.metadata["saved_resets"]["available_expirations"]

    assert {:ok, ^original_first_seen} =
             FirstSeenLedger.lookup(visible_identity.saved_reset_first_seen_ledger, expiration)

    refute Jason.encode!(visible_identity.saved_reset_first_seen_ledger) =~ "granted_at"

    FakeUpstream.set_mode(fake, saved_reset_mode(0))

    assert {:ok, zero_identity} =
             PoolReconciliation.refresh_quota_from_usage(visible_identity, assignment)

    zero_identity = Repo.reload!(zero_identity)
    assert zero_identity.metadata["saved_resets"]["available_expirations"] == []

    assert zero_identity.saved_reset_first_seen_ledger ==
             visible_identity.saved_reset_first_seen_ledger

    FakeUpstream.set_mode(fake, saved_reset_mode(1, reset_credit_rows(expiration, granted_at)))

    assert {:ok, reappeared_identity} =
             PoolReconciliation.refresh_quota_from_usage(zero_identity, assignment)

    reappeared_identity = Repo.reload!(reappeared_identity)

    assert [
             %{
               "expires_at" => ^expiration,
               "first_seen_at" => ^original_first_seen,
               "granted_at" => ^granted_at
             }
           ] =
             reappeared_identity.metadata["saved_resets"]["available_expirations"]
  end

  test "a genuinely new expiration receives a new first seen and ledger entry" do
    original_expiration = "2026-08-20T00:40:11.968726Z"
    new_expiration = "2026-08-21T00:40:11.968726Z"
    original_first_seen = "2026-07-22T10:00:00.123456Z"

    ledger =
      ledger_with_entry(original_expiration, original_first_seen)

    {:ok, fake} =
      FakeUpstream.start_link(
        saved_reset_mode(1, reset_credit_rows(new_expiration, "2026-07-21T00:00:00Z"))
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          original_expiration
          |> saved_reset_metadata(original_first_seen)
          |> Map.merge(%{
            "usage_base_url" => FakeUpstream.url(fake),
            "usage_path" => "/api/codex/usage"
          })
      })

    identity =
      identity
      |> Ecto.Changeset.change(%{saved_reset_first_seen_ledger: ledger})
      |> Repo.update!()

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)

    assert {:ok, ^original_first_seen} =
             FirstSeenLedger.lookup(
               updated_identity.saved_reset_first_seen_ledger,
               original_expiration
             )

    assert {:ok, new_first_seen} =
             FirstSeenLedger.lookup(
               updated_identity.saved_reset_first_seen_ledger,
               new_expiration
             )

    assert new_first_seen != original_first_seen

    assert [%{"expires_at" => ^new_expiration, "first_seen_at" => ^new_first_seen}] =
             updated_identity.metadata["saved_resets"]["available_expirations"]
  end

  test "an empty ledger is lazy seeded from locked current metadata before authoritative zero" do
    expiration = "2026-08-20T00:40:11.968726Z"
    original_first_seen = "2026-07-22T10:00:00.123456Z"

    {:ok, fake} = FakeUpstream.start_link(saved_reset_mode(0))

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          expiration
          |> saved_reset_metadata(original_first_seen)
          |> Map.merge(%{
            "usage_base_url" => FakeUpstream.url(fake),
            "usage_path" => "/api/codex/usage"
          })
      })

    assert identity.saved_reset_first_seen_ledger == FirstSeenLedger.empty()

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)
    assert updated_identity.metadata["saved_resets"]["available_expirations"] == []

    assert {:ok, ^original_first_seen} =
             FirstSeenLedger.lookup(updated_identity.saved_reset_first_seen_ledger, expiration)
  end

  test "incomplete detail advances summary attempt but preserves expiration state and ledger" do
    expiration = "2026-08-20T00:40:11.968726Z"
    original_first_seen = "2026-07-22T10:00:00.123456Z"
    expires_observed_at = "2026-07-23T10:00:00.654321Z"
    ledger = ledger_with_entry(expiration, original_first_seen)

    {:ok, fake} =
      FakeUpstream.start_link(
        saved_reset_mode(4, %{"available_count" => 4, "credits" => [%{"status" => "available"}]})
      )

    metadata =
      saved_reset_metadata(expiration, original_first_seen,
        available_count: 1,
        expires_observed_at: expires_observed_at,
        expires_refresh_attempted_at: "2026-07-23T11:00:00.000001Z"
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          metadata
          |> Map.merge(%{"usage_base_url" => FakeUpstream.url(fake)})
          |> Map.put("usage_path", "/api/codex/usage")
      })

    identity =
      identity
      |> Ecto.Changeset.change(%{saved_reset_first_seen_ledger: ledger})
      |> Repo.update!()

    previous_saved_resets = identity.metadata["saved_resets"]

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)
    saved_resets = updated_identity.metadata["saved_resets"]

    assert saved_resets["available_count"] == 4
    assert saved_resets["available_expirations"] == previous_saved_resets["available_expirations"]
    assert saved_resets["available_expires_at"] == previous_saved_resets["available_expires_at"]
    assert saved_resets["next_expires_at"] == previous_saved_resets["next_expires_at"]
    assert saved_resets["expires_observed_at"] == expires_observed_at

    assert saved_resets["expires_refresh_attempted_at"] !=
             previous_saved_resets["expires_refresh_attempted_at"]

    assert updated_identity.saved_reset_first_seen_ledger == ledger
  end

  test "declared oversized detail follows incomplete preservation behavior" do
    body = oversized_reset_credit_body()

    assert byte_size(body) > @saved_reset_detail_max_bytes

    assert_oversized_detail_preserves_expiration_state(
      FakeUpstream.raw_response(body, headers: [{"content-type", "application/json"}])
    )
  end

  test "chunked oversized detail follows incomplete preservation behavior" do
    body = oversized_reset_credit_body()
    split_at = div(byte_size(body), 2)

    assert byte_size(body) > @saved_reset_detail_max_bytes

    assert_oversized_detail_preserves_expiration_state(
      FakeUpstream.chunked_response(
        [
          binary_part(body, 0, split_at),
          binary_part(body, split_at, byte_size(body) - split_at)
        ],
        headers: [{"content-type", "application/json"}]
      )
    )
  end

  test "under-limit detail retains more than 128 current expirations" do
    expirations =
      Enum.map(0..128, fn offset ->
        ~U[2026-08-01 00:00:00Z]
        |> DateTime.add(offset, :second)
        |> DateTime.to_iso8601()
      end)

    detail = %{
      "available_count" => length(expirations),
      "credits" =>
        Enum.map(expirations, fn expiration ->
          %{
            "status" => "available",
            "expires_at" => expiration,
            "granted_at" => "2026-07-20T00:00:00Z"
          }
        end)
    }

    assert byte_size(Jason.encode!(detail)) < @saved_reset_detail_max_bytes

    {:ok, fake} =
      FakeUpstream.start_link(saved_reset_mode(length(expirations), detail))

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)

    assert Enum.map(
             updated_identity.metadata["saved_resets"]["available_expirations"],
             & &1["expires_at"]
           ) == expirations

    assert length(updated_identity.saved_reset_first_seen_ledger["entries"]) == 129
  end

  test "oversized legacy snapshot is reused without lazy seeding its rows into the ledger" do
    rows = [
      %{
        "expires_at" => "2026-08-20T00:40:11.968726Z",
        "first_seen_at" => "2026-07-22T10:00:00.123456Z",
        "granted_at" => "2026-07-20T00:00:00Z",
        "legacy_padding" => String.duplicate("x", @saved_reset_detail_max_bytes)
      }
    ]

    metadata = fresh_saved_reset_metadata(rows)

    assert byte_size(Jason.encode!(metadata["saved_resets"]["available_expirations"])) >
             @saved_reset_detail_max_bytes

    {:ok, fake} = FakeUpstream.start_link(saved_reset_mode(length(rows)))

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          metadata
          |> Map.merge(%{"usage_base_url" => FakeUpstream.url(fake)})
          |> Map.put("usage_path", "/api/codex/usage")
      })

    assert identity.saved_reset_first_seen_ledger == FirstSeenLedger.empty()

    assert [[stored_size]] =
             Repo.query!(
               """
               SELECT pg_column_size(metadata -> 'saved_resets' -> 'available_expirations')
               FROM upstream_identities
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(identity.id)]
             ).rows

    assert stored_size > @saved_reset_detail_max_bytes

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)

    assert updated_identity.metadata["saved_resets"] == metadata["saved_resets"]
    assert updated_identity.saved_reset_first_seen_ledger == FirstSeenLedger.empty()
  end

  test "an opaque ledger version is never overwritten" do
    expiration = "2026-08-20T00:40:11.968726Z"
    opaque_ledger = %{"version" => 99, "entries" => [%{"future" => "contract"}]}

    {:ok, fake} =
      FakeUpstream.start_link(
        saved_reset_mode(1, reset_credit_rows(expiration, "2026-07-20T00:00:00Z"))
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    identity =
      identity
      |> Ecto.Changeset.change(%{saved_reset_first_seen_ledger: opaque_ledger})
      |> Repo.update!()

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)
    assert updated_identity.saved_reset_first_seen_ledger == opaque_ledger

    assert [%{"expires_at" => ^expiration}] =
             updated_identity.metadata["saved_resets"]["available_expirations"]
  end

  test "malformed version one ledger and current rows do not prevent lazy seeding valid history" do
    expiration = "2026-08-20T00:40:11.968726Z"
    original_first_seen = "2026-07-22T10:00:00.123456Z"
    malformed_expiration = "not-an-expiration"

    malformed_ledger = %{
      "version" => 1,
      "entries" => [
        %{"expires_at" => malformed_expiration, "first_seen_at" => "not-a-first-seen"}
      ]
    }

    metadata =
      saved_reset_metadata(expiration, original_first_seen)
      |> update_in(["saved_resets", "available_expirations"], fn rows ->
        [%{"expires_at" => malformed_expiration, "first_seen_at" => "not-a-first-seen"} | rows]
      end)

    {:ok, fake} = FakeUpstream.start_link(saved_reset_mode(0))

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          metadata
          |> Map.merge(%{"usage_base_url" => FakeUpstream.url(fake)})
          |> Map.put("usage_path", "/api/codex/usage")
      })

    identity =
      identity
      |> Ecto.Changeset.change(%{saved_reset_first_seen_ledger: malformed_ledger})
      |> Repo.update!()

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)

    assert {:ok, ^original_first_seen} =
             FirstSeenLedger.lookup(updated_identity.saved_reset_first_seen_ledger, expiration)

    assert FirstSeenLedger.lookup(
             updated_identity.saved_reset_first_seen_ledger,
             malformed_expiration
           ) == :error
  end

  test "an older delayed observation cannot replace a newer snapshot or ledger" do
    expiration = "2026-08-20T00:40:11.968726Z"
    original_first_seen = "2026-07-22T10:00:00.123456Z"
    future_observed_at = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.to_iso8601()
    ledger = ledger_with_entry(expiration, original_first_seen)

    newer_metadata =
      saved_reset_metadata(expiration, original_first_seen,
        observed_at: future_observed_at,
        expires_observed_at: future_observed_at,
        expires_refresh_attempted_at: future_observed_at
      )

    stale_metadata =
      saved_reset_metadata(expiration, original_first_seen,
        observed_at: "2026-07-23T10:00:00.654321Z"
      )

    {:ok, fake} = FakeUpstream.start_link(saved_reset_mode(0))

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          stale_metadata
          |> Map.merge(%{"usage_base_url" => FakeUpstream.url(fake)})
          |> Map.put("usage_path", "/api/codex/usage")
      })

    stale_identity = identity

    locked_identity =
      identity
      |> Ecto.Changeset.change(%{
        metadata:
          identity.metadata
          |> Map.put("saved_resets", newer_metadata["saved_resets"]),
        saved_reset_first_seen_ledger: ledger
      })
      |> Repo.update!()

    newer_saved_resets = locked_identity.metadata["saved_resets"]

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(stale_identity, assignment)

    updated_identity = Repo.reload!(updated_identity)
    assert updated_identity.metadata["saved_resets"] == newer_saved_resets
    assert updated_identity.saved_reset_first_seen_ledger == ledger
  end

  test "snapshot and ledger are written by one real identity update" do
    expiration = "2026-08-20T00:40:11.968726Z"

    {:ok, fake} =
      FakeUpstream.start_link(
        saved_reset_mode(1, reset_credit_rows(expiration, "2026-07-20T00:00:00Z"))
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    handler_id = "saved-reset-reconciliation-update-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = metadata[:query]

          if metadata[:repo] == Repo and metadata[:source] == "upstream_identities" and
               is_binary(query) and
               String.starts_with?(String.trim_leading(query), "UPDATE") do
            send(parent, {handler_id, query})
          end
        end,
        nil
      )

    try do
      assert {:ok, _updated_identity} =
               PoolReconciliation.refresh_quota_from_usage(identity, assignment)

      saved_reset_updates =
        handler_id
        |> drain_queries()
        |> Enum.filter(&String.contains?(&1, "saved_reset_first_seen_ledger"))

      assert [query] = saved_reset_updates
      assert query =~ ~s("metadata")
      assert query =~ ~s("saved_reset_first_seen_ledger")
    after
      :telemetry.detach(handler_id)
    end
  end

  defp fresh_expiration_metadata(available_count) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => available_count,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => observed_at,
        "usage_path" => "/api/codex/usage",
        "available_expires_at" => ["2026-07-18T00:40:11.968726Z"],
        "available_expirations" => [
          %{
            "expires_at" => "2026-07-18T00:40:11.968726Z",
            "first_seen_at" => "2026-06-21T09:00:00Z",
            "granted_at" => nil
          }
        ],
        "next_expires_at" => "2026-07-18T00:40:11.968726Z",
        "expires_observed_at" => observed_at,
        "expires_refresh_attempted_at" => observed_at,
        "reason" => nil
      }
    }
  end

  defp previous_expiration_metadata do
    %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => 2,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => "2026-06-22T10:00:00Z",
        "usage_path" => "/api/codex/usage",
        "available_expires_at" => [
          "2026-07-18T00:40:11.968726Z",
          "2026-07-21T00:40:11.968726Z"
        ],
        "available_expirations" => [
          %{
            "expires_at" => "2026-07-18T00:40:11.968726Z",
            "first_seen_at" => "2026-06-21T09:00:00Z"
          },
          %{
            "expires_at" => "2026-07-21T00:40:11.968726Z",
            "first_seen_at" => "2026-06-21T10:00:00Z"
          }
        ],
        "next_expires_at" => "2026-07-18T00:40:11.968726Z",
        "expires_observed_at" => "2026-06-22T10:00:00Z",
        "expires_refresh_attempted_at" => "2026-06-22T10:00:00Z",
        "reason" => nil
      }
    }
  end

  defp saved_reset_mode(available_count, detail \\ nil) do
    routes = %{"/api/codex/usage" => {200, usage_payload(available_count)}}

    routes =
      if is_map(detail) do
        Map.put(routes, "/backend-api/wham/rate-limit-reset-credits", {200, detail})
      else
        routes
      end

    {:path_json, routes}
  end

  defp assert_oversized_detail_preserves_expiration_state(detail_response) do
    expiration = "2026-08-20T00:40:11.968726Z"
    original_first_seen = "2026-07-22T10:00:00.123456Z"
    expires_observed_at = "2026-07-23T10:00:00.654321Z"
    ledger = ledger_with_entry(expiration, original_first_seen)

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" => {200, usage_payload(4)},
           "/backend-api/wham/rate-limit-reset-credits" => detail_response
         }}
      )

    metadata =
      saved_reset_metadata(expiration, original_first_seen,
        available_count: 1,
        expires_observed_at: expires_observed_at,
        expires_refresh_attempted_at: "2026-07-23T11:00:00.000001Z"
      )

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          metadata
          |> Map.merge(%{"usage_base_url" => FakeUpstream.url(fake)})
          |> Map.put("usage_path", "/api/codex/usage")
      })

    identity =
      identity
      |> Ecto.Changeset.change(%{saved_reset_first_seen_ledger: ledger})
      |> Repo.update!()

    previous_saved_resets = identity.metadata["saved_resets"]

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    updated_identity = Repo.reload!(updated_identity)
    saved_resets = updated_identity.metadata["saved_resets"]

    assert saved_resets["available_count"] == 4
    assert saved_resets["available_expirations"] == previous_saved_resets["available_expirations"]
    assert saved_resets["available_expires_at"] == previous_saved_resets["available_expires_at"]
    assert saved_resets["next_expires_at"] == previous_saved_resets["next_expires_at"]
    assert saved_resets["expires_observed_at"] == expires_observed_at

    assert saved_resets["expires_refresh_attempted_at"] !=
             previous_saved_resets["expires_refresh_attempted_at"]

    assert updated_identity.saved_reset_first_seen_ledger == ledger
  end

  defp oversized_reset_credit_body do
    Jason.encode!(%{
      "available_count" => 4,
      "credits" => [
        %{
          "status" => "available",
          "expires_at" => "2026-09-01T00:00:00Z",
          "granted_at" => "2026-07-20T00:00:00Z"
        }
      ],
      "padding" => String.duplicate("x", @saved_reset_detail_max_bytes)
    })
  end

  defp fresh_saved_reset_metadata(rows) do
    expirations = Enum.map(rows, & &1["expires_at"])
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => length(rows),
        "source" => "codex_reset_credits_api",
        "path_style" => "codex_api",
        "observed_at" => observed_at,
        "usage_path" => "/api/codex/usage",
        "available_expires_at" => expirations,
        "available_expirations" => rows,
        "next_expires_at" => List.first(expirations),
        "expires_observed_at" => observed_at,
        "expires_refresh_attempted_at" => observed_at,
        "reason" => nil
      }
    }
  end

  defp reset_credit_rows(expiration, granted_at) do
    %{
      "available_count" => 1,
      "credits" => [
        %{
          "status" => "available",
          "expires_at" => expiration,
          "granted_at" => granted_at,
          "provider_only" => "ignored"
        }
      ]
    }
  end

  defp saved_reset_metadata(expiration, first_seen_at, opts \\ []) do
    observed_at = Keyword.get(opts, :observed_at, "2026-07-23T10:00:00.654321Z")
    expires_observed_at = Keyword.get(opts, :expires_observed_at, observed_at)

    %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => Keyword.get(opts, :available_count, 1),
        "source" => "codex_reset_credits_api",
        "path_style" => "codex_api",
        "observed_at" => observed_at,
        "usage_path" => "/api/codex/usage",
        "available_expires_at" => [expiration],
        "available_expirations" => [
          %{
            "expires_at" => expiration,
            "first_seen_at" => first_seen_at,
            "granted_at" => "2026-07-20T00:00:00Z"
          }
        ],
        "next_expires_at" => expiration,
        "expires_observed_at" => expires_observed_at,
        "expires_refresh_attempted_at" =>
          Keyword.get(opts, :expires_refresh_attempted_at, expires_observed_at),
        "reason" => nil
      }
    }
  end

  defp ledger_with_entry(expiration, first_seen_at) do
    %{
      "version" => 1,
      "entries" => [
        %{"expires_at" => expiration, "first_seen_at" => first_seen_at}
      ]
    }
  end

  defp drain_queries(handler_id, queries \\ []) do
    receive do
      {^handler_id, query} -> drain_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp usage_payload(available_count) do
    %{
      "plan_type" => "pro",
      "rate_limit_reset_credits" => %{"available_count" => available_count},
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 10,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900
        }
      }
    }
  end

  defp reset_credits_payload do
    %{
      "available_count" => 3,
      "total_earned_count" => 4,
      "credits" => [
        %{
          "id" => "RateLimitResetCredit_early",
          "reset_type" => "codex_rate_limits",
          "status" => "available",
          "granted_at" => "2026-06-18T00:40:11.968726Z",
          "expires_at" => "2026-07-18T00:40:11.968726Z",
          "title" => "One free rate limit reset"
        },
        %{
          "id" => "RateLimitResetCredit_late",
          "reset_type" => "codex_rate_limits",
          "status" => "available",
          "granted_at" => "2026-06-20T00:40:11.968726Z",
          "expires_at" => "2026-07-20T00:40:11.968726Z",
          "description" => "Referral reward"
        },
        %{
          "id" => "RateLimitResetCredit_redeemed",
          "reset_type" => "codex_rate_limits",
          "status" => "redeemed",
          "expires_at" => "2026-07-10T00:40:11.968726Z"
        },
        %{
          "id" => "RateLimitResetCredit_invalid",
          "reset_type" => "codex_rate_limits",
          "status" => "available",
          "expires_at" => "not-a-date"
        }
      ]
    }
  end

  defp coherent_reset_credits_payload do
    %{
      "available_count" => 2,
      "credits" => [
        %{
          "id" => "provider-credit-one",
          "status" => "available",
          "expires_at" => "2026-07-20T02:40:11.968726+02:00",
          "granted_at" => "2026-06-20T02:00:00+02:00",
          "provider_only" => "ignored"
        },
        %{
          "id" => "provider-credit-two",
          "status" => "available",
          "expires_at" => "2026-07-20T00:40:11.968726Z",
          "granted_at" => "2026-06-20T00:00:00Z",
          "provider_only" => "ignored"
        }
      ]
    }
  end

  defp ambiguous_reset_credits_payload do
    %{
      "available_count" => 2,
      "credits" => [
        %{
          "status" => "available",
          "expires_at" => "2026-08-20T00:40:11.968726Z",
          "granted_at" => "2026-07-20T00:00:00Z"
        },
        %{
          "status" => "available",
          "expires_at" => "2026-08-20T00:40:11.968726Z"
        }
      ]
    }
  end
end
