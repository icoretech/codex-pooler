defmodule CodexPooler.Upstreams.SavedResetReconciliationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResets
  alias CodexPooler.Upstreams.SavedResets.FirstSeenLedger
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetProjection
  alias CodexPoolerWeb.DateTimeDisplay

  alias Ecto.Adapters.SQL.Sandbox

  @saved_reset_detail_max_bytes 1_048_576

  test "scheduled reconciliation self-heals an applied reblocked lifecycle from canonical evidence" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    consumed_at = DateTime.add(now, -20, :hour)
    stale_observed_at = DateTime.add(now, -14, :hour)

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" =>
             {200,
              %{
                "plan_type" => "pro",
                "rate_limit_reset_credits" => %{"available_count" => 0},
                "rate_limit" => %{
                  "primary_window" => %{
                    "used_percent" => 20,
                    "limit_window_seconds" => 18_000,
                    "reset_after_seconds" => 900
                  },
                  "secondary_window" => %{
                    "used_percent" => 26,
                    "limit_window_seconds" => 604_800,
                    "resets_at" => now |> DateTime.add(2, :day) |> DateTime.to_iso8601()
                  }
                }
              }}
         }}
      )

    reblocked_redemption = %{
      "status" => "failed",
      "phase" => "reblocked",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 2,
      "trigger_kind" => "gateway_auto",
      "trigger_detail" => "exhausted",
      "started_at" => DateTime.to_iso8601(DateTime.add(consumed_at, -1, :minute)),
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "deadline_at" => consumed_at |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
      "finished_at" => DateTime.to_iso8601(consumed_at),
      "result" => %{"code" => "reset", "applied" => true}
    }

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        metadata: %{
          "base_url" => FakeUpstream.url(fake),
          "usage_base_url" => FakeUpstream.url(fake),
          "access_token_expires_at" => now |> DateTime.add(2, :day) |> DateTime.to_iso8601(),
          "saved_reset_redemption" => reblocked_redemption
        }
      })

    # Historical post-consume observations from other sources, now obsolete.
    upsert_source_evidence!(identity, Decimal.new("100"),
      source: "codex_rate_limit_event",
      observed_at: stale_observed_at,
      reset_at: DateTime.add(stale_observed_at, 2, :hour)
    )

    upsert_source_evidence!(identity, Decimal.new("100"),
      source: "codex_response_headers",
      window_kind: "primary",
      window_minutes: 300,
      observed_at: stale_observed_at,
      reset_at: DateTime.add(stale_observed_at, 1, :hour)
    )

    assert {:ok, result} = PoolReconciliation.reconcile_pool_account(pool, assignment)
    assert result.quota.code == "quota_refreshed"

    converged = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert converged["phase"] == "confirmed_by_quota"
    assert converged["status"] == "succeeded"
    assert converged["terminal_reason"] == "converged_confirmed_by_quota"

    assert Map.take(converged, ["attempt_id", "generation", "consumed_at", "result"]) ==
             Map.take(reblocked_redemption, ["attempt_id", "generation", "consumed_at", "result"])

    # Repeating reconciliation is idempotent: no reopened lifecycle, no drift.
    assert {:ok, second_result} = PoolReconciliation.reconcile_pool_account(pool, assignment)
    assert second_result.quota.code == "quota_refreshed"
    assert Repo.reload!(identity).metadata["saved_reset_redemption"] == converged

    # Reconciliation only read usage; convergence performed no provider
    # consume, list, or write request.
    request_paths = fake |> FakeUpstream.requests() |> Enum.map(& &1.path)
    assert request_paths != []
    assert Enum.all?(request_paths, &String.ends_with?(&1, "/usage"))

    # The admin read model reflects the recovered lifecycle after reload.
    snapshot =
      SavedResetProjection.snapshot(
        Repo.reload!(identity),
        DateTimeDisplay.preferences_for_user(nil)
      )

    assert snapshot.reset_lifecycle.phase == "confirmed_by_quota"
    assert snapshot.reset_lifecycle.label == "Reset confirmed by quota"
  end

  @tag :scheduler_boundary
  @tag :scheduler_boundary
  test "scheduled reconciliation accepts a pending weekly restart and confirms the reset before returning" do
    window_seconds = 10_080 * 60
    call_started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    candidate_at = DateTime.add(call_started_at, -180, :second)
    canonical_at = DateTime.add(candidate_at, -5, :minute)
    consumed_at = DateTime.add(candidate_at, -1, :minute)
    canonical_reset = DateTime.add(canonical_at, 5, :day)
    candidate_reset = DateTime.add(candidate_at, window_seconds, :second)

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" =>
             {200,
              %{
                "plan_type" => "pro",
                "rate_limit_reset_credits" => %{"available_count" => 0},
                "rate_limit" => %{
                  "secondary_window" => %{
                    "used_percent" => 0,
                    "limit_window_seconds" => window_seconds,
                    "reset_after_seconds" => window_seconds,
                    "resets_at" =>
                      call_started_at
                      |> DateTime.add(window_seconds, :second)
                      |> DateTime.to_iso8601()
                  }
                }
              }}
         }}
      )

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        metadata: %{
          "base_url" => FakeUpstream.url(fake),
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage",
          "access_token_expires_at" =>
            call_started_at |> DateTime.add(2, :day) |> DateTime.to_iso8601()
        }
      })

    assert {:ok, _canonical} =
             QuotaWindows.record_evidence(
               identity,
               account_weekly_evidence("100", canonical_at, canonical_reset),
               canonical_at
             )

    assert {:ok, pending} =
             QuotaWindows.record_evidence(
               identity,
               account_weekly_evidence("0", candidate_at, candidate_reset,
                 reset_after_seconds: window_seconds
               ),
               candidate_at
             )

    assert Decimal.equal?(pending.used_percent, Decimal.new("100"))
    assert {:ok, %{observed_at: ^candidate_at}} = EvidenceStore.parse_candidate(pending.metadata)

    redemption = %{
      "status" => "redeeming",
      "phase" => "consumed_pending_probe",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "trigger_kind" => "scheduled_expiry_rescue",
      "started_at" => consumed_at |> DateTime.add(-1, :minute) |> DateTime.to_iso8601(),
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "deadline_at" => consumed_at |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
      "finished_at" => DateTime.to_iso8601(consumed_at),
      "result" => %{"code" => "reset", "applied" => true}
    }

    identity =
      identity
      |> Ecto.Changeset.change(%{
        metadata: Map.put(identity.metadata || %{}, "saved_reset_redemption", redemption)
      })
      |> Repo.update!()

    assert {:ok, result} = PoolReconciliation.reconcile_pool_account(pool, assignment)
    assert result.quota.code == "quota_refreshed"

    canonical =
      identity
      |> QuotaWindows.list_evidence()
      |> Enum.find(&(&1.quota_key == "account" and &1.window_kind == "secondary"))

    assert %AccountQuotaWindow{} = canonical

    assert Decimal.equal?(canonical.used_percent, Decimal.new("0"))
    assert DateTime.compare(canonical.observed_at, candidate_at) == :gt
    assert EvidenceStore.parse_candidate(canonical.metadata) == :none

    converged = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert converged["phase"] == "confirmed_by_quota"
    assert converged["status"] == "succeeded"
    assert converged["terminal_reason"] == "converged_confirmed_by_quota"

    persisted_identity = Repo.reload!(identity)

    assert converged["finished_at"] ==
             get_in(persisted_identity.metadata, ["saved_resets", "observed_at"])

    requests = FakeUpstream.requests(fake)
    assert requests != []
    assert Enum.all?(requests, &(&1.method == "GET" and String.ends_with?(&1.path, "/usage")))
    refute Enum.any?(requests, &String.contains?(&1.path, "rate-limit-reset-credits"))
  end

  @tag :scheduler_boundary
  test "scheduled reconciliation leaves a consumed lifecycle pending when usage has no account descriptor" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    consumed_at = DateTime.add(now, -1, :minute)

    {:ok, fake} = FakeUpstream.start_link({:path_json, %{}})

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    canonical_at = DateTime.add(consumed_at, -5, :minute)

    assert {:ok, _canonical} =
             QuotaWindows.record_evidence(
               identity,
               account_weekly_evidence(
                 "100",
                 canonical_at,
                 DateTime.add(canonical_at, 5, :day)
               ),
               canonical_at
             )

    redemption = pending_redemption(consumed_at)
    put_redemption!(identity, redemption)

    model_window = %{
      quota_key: "codex_spark",
      quota_scope: "model",
      quota_family: "codex_spark",
      model: "gpt-example",
      upstream_model: "gpt-example",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("0"),
      reset_at: DateTime.add(now, 5, :day),
      source: "local_reconciliation",
      source_precision: "observed",
      freshness_state: "fresh"
    }

    assert {:ok, %{quota: %{code: "quota_refreshed"}}} =
             PoolReconciliation.reconcile_pool_account(pool, assignment,
               quota_windows: [model_window]
             )

    persisted = Repo.reload!(identity)
    assert persisted.metadata["saved_reset_redemption"] == redemption

    assert [
             %AccountQuotaWindow{
               quota_key: "account",
               used_percent: used_percent,
               observed_at: ^canonical_at
             },
             %AccountQuotaWindow{quota_key: "codex_spark", quota_scope: "model"}
           ] = QuotaWindows.list_evidence(identity)

    assert Decimal.equal?(used_percent, Decimal.new("100"))
    assert FakeUpstream.requests(fake) == []
  end

  @tag :scheduler_boundary
  test "scheduled reconciliation keeps an unconfirmed weekly restart candidate pending" do
    assert_pending_candidate_control(:valid)
  end

  @tag :scheduler_boundary
  test "scheduled reconciliation restarts a malformed weekly candidate without converging" do
    assert_pending_candidate_control(:malformed)
  end

  @tag :scheduler_boundary
  test "scheduled reconciliation reblocks an accepted exhausted account cycle before returning" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    consumed_at = DateTime.add(now, -1, :minute)
    window_seconds = 10_080 * 60

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" =>
             {200,
              %{
                "plan_type" => "pro",
                "rate_limit_reset_credits" => %{"available_count" => 0},
                "rate_limit" => %{
                  "secondary_window" => %{
                    "used_percent" => 100,
                    "limit_window_seconds" => window_seconds,
                    "reset_after_seconds" => 4 * 24 * 60 * 60
                  }
                }
              }}
         }}
      )

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    redemption = pending_redemption(consumed_at)
    put_redemption!(identity, redemption)

    assert {:ok, %{quota: %{code: "quota_refreshed"}}} =
             PoolReconciliation.reconcile_pool_account(pool, assignment)

    [canonical] = QuotaWindows.list_evidence(identity)
    assert Decimal.equal?(canonical.used_percent, Decimal.new("100"))
    assert DateTime.compare(canonical.observed_at, consumed_at) != :lt

    persisted = Repo.reload!(identity)
    converged = persisted.metadata["saved_reset_redemption"]
    assert converged["phase"] == "reblocked"
    assert converged["status"] == "failed"
    assert converged["terminal_reason"] == "converged_reblocked"

    assert converged["finished_at"] ==
             get_in(persisted.metadata, ["saved_resets", "observed_at"])
  end

  @tag :scheduler_boundary
  test "scheduled reconciliation fences a credential superseded after assignment loading" do
    assert_scheduler_superseded_control(:credential)
  end

  @tag :scheduler_boundary
  test "scheduled reconciliation fences an assignment superseded after assignment loading" do
    assert_scheduler_superseded_control(:assignment)
  end

  @tag :scheduler_boundary
  test "scheduled reconciliation preserves a concurrent newer lifecycle generation" do
    {pool, identity, assignment} = committed_scheduler_fixture()
    original = pending_redemption(DateTime.add(DateTime.utc_now(), -1, :minute))
    put_committed_redemption!(identity, original)

    parent = self()
    release_ref = make_ref()
    handler_id = {__MODULE__, :post_persistence_commit, release_ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = metadata[:query] |> to_string() |> String.trim() |> String.downcase()

          if query == "commit" and not Process.get(handler_id, false) do
            Process.put(handler_id, true)
            send(parent, {:quota_commit_completed, release_ref, self()})

            receive do
              {:release_after_new_generation, ^release_ref} -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    reconciliation =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          PoolReconciliation.reconcile_pool_account(pool, assignment,
            quota_windows: assignment.metadata["quota_windows"]
          )
        end)
      end)

    assert_receive {:quota_commit_completed, ^release_ref, reconciliation_pid}

    {canonical, newer} =
      Sandbox.unboxed_run(Repo, fn ->
        [canonical] = QuotaWindows.list_evidence(identity)
        consumed_at = DateTime.add(canonical.observed_at, 1, :microsecond)

        newer =
          consumed_at
          |> pending_redemption()
          |> Map.merge(%{"attempt_id" => Ecto.UUID.generate(), "generation" => 2})

        put_redemption!(Repo.get!(UpstreamIdentity, identity.id), newer)
        {canonical, newer}
      end)

    send(reconciliation_pid, {:release_after_new_generation, release_ref})

    assert {:ok, %{quota: %{code: "quota_refreshed"}}} = Task.await(reconciliation)
    assert Decimal.equal?(canonical.used_percent, Decimal.new("0"))

    persisted =
      Sandbox.unboxed_run(Repo, fn -> Repo.get!(UpstreamIdentity, identity.id) end)

    assert persisted.metadata["saved_reset_redemption"] == newer
  end

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
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(2, :day)
      |> DateTime.truncate(:microsecond)
      |> DateTime.to_iso8601()

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, usage_payload(2)},
           "/backend-api/wham/rate-limit-reset-credits" =>
             {200, ambiguous_reset_credits_payload(expires_at)}
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
    expiration =
      DateTime.utc_now()
      |> DateTime.add(5, :day)
      |> DateTime.truncate(:microsecond)
      |> DateTime.to_iso8601()

    {:ok, fake} =
      FakeUpstream.start_link({:path_json, %{"/api/codex/usage" => {200, usage_payload(2)}}})

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(), %{
        metadata:
          Map.merge(
            %{"usage_base_url" => FakeUpstream.url(fake)},
            fresh_expiration_metadata(2, expiration)
          )
      })

    assert {:ok, updated_identity} =
             PoolReconciliation.refresh_quota_from_usage(identity, assignment)

    assert %{
             available_count: 2,
             expires_reported?: true,
             available_expires_at: [^expiration],
             available_expirations: [
               %{
                 expires_at: ^expiration,
                 first_seen_at: "2026-06-21T09:00:00Z",
                 granted_at: nil
               }
             ],
             next_expires_at: ^expiration
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

  test "failed detail refreshes use adaptive backoff without changing expiration state or URL order" do
    for {expires_in, backoff} <- [
          {2 * 60 * 60, 15 * 60},
          {45 * 60, 5 * 60},
          {10 * 60, 60},
          {5 * 24 * 60 * 60, 6 * 60 * 60}
        ] do
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
      expiration = timestamp |> DateTime.add(expires_in, :second) |> DateTime.to_iso8601()
      observed_at = timestamp |> DateTime.add(-7, :hour) |> DateTime.to_iso8601()

      {:ok, fake} =
        FakeUpstream.start_link({:path_json, %{"/api/codex/usage" => {200, usage_payload(2)}}})

      metadata =
        expiration
        |> saved_reset_metadata(observed_at,
          available_count: 1,
          observed_at: observed_at,
          expires_observed_at: observed_at,
          expires_refresh_attempted_at: observed_at
        )
        |> Map.merge(%{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        })

      %{identity: identity, assignment: assignment} =
        active_upstream_assignment_fixture(pool_fixture(), %{metadata: metadata})

      previous_saved_resets = identity.metadata["saved_resets"]

      assert {:ok, failed_identity} =
               PoolReconciliation.refresh_quota_from_usage(identity, assignment)

      failed_identity = Repo.reload!(failed_identity)
      failed_saved_resets = failed_identity.metadata["saved_resets"]

      assert Map.take(failed_saved_resets, [
               "available_expirations",
               "available_expires_at",
               "next_expires_at",
               "expires_observed_at"
             ]) ==
               Map.take(previous_saved_resets, [
                 "available_expirations",
                 "available_expires_at",
                 "next_expires_at",
                 "expires_observed_at"
               ])

      assert failed_saved_resets["expires_refresh_attempted_at"] != observed_at

      assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
               "/api/codex/usage",
               "/backend-api/wham/rate-limit-reset-credits",
               "/wham/rate-limit-reset-credits"
             ]

      assert {:ok, suppressed_identity} =
               PoolReconciliation.refresh_quota_from_usage(failed_identity, assignment)

      suppressed_saved_resets = Repo.reload!(suppressed_identity).metadata["saved_resets"]

      assert Map.take(suppressed_saved_resets, [
               "available_expirations",
               "available_expires_at",
               "next_expires_at",
               "expires_observed_at",
               "expires_refresh_attempted_at"
             ]) ==
               Map.take(failed_saved_resets, [
                 "available_expirations",
                 "available_expires_at",
                 "next_expires_at",
                 "expires_observed_at",
                 "expires_refresh_attempted_at"
               ])

      assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
               "/api/codex/usage",
               "/backend-api/wham/rate-limit-reset-credits",
               "/wham/rate-limit-reset-credits",
               "/api/codex/usage"
             ]

      due_attempted_at =
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.add(-backoff, :second)
        |> DateTime.to_iso8601()

      due_identity =
        suppressed_identity
        |> Ecto.Changeset.change(%{
          metadata:
            put_in(
              suppressed_identity.metadata,
              ["saved_resets", "expires_refresh_attempted_at"],
              due_attempted_at
            )
        })
        |> Repo.update!()

      assert {:ok, _retried_identity} =
               PoolReconciliation.refresh_quota_from_usage(due_identity, assignment)

      assert Enum.map(FakeUpstream.requests(fake), & &1.path) == [
               "/api/codex/usage",
               "/backend-api/wham/rate-limit-reset-credits",
               "/wham/rate-limit-reset-credits",
               "/api/codex/usage",
               "/api/codex/usage",
               "/backend-api/wham/rate-limit-reset-credits",
               "/wham/rate-limit-reset-credits"
             ]
    end
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

  defp assert_pending_candidate_control(candidate_kind) do
    window_seconds = 10_080 * 60
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    candidate_at = DateTime.add(now, -60, :second)
    canonical_at = DateTime.add(candidate_at, -5, :minute)
    consumed_at = DateTime.add(candidate_at, -1, :minute)
    canonical_reset = DateTime.add(canonical_at, 5, :day)
    candidate_reset = DateTime.add(candidate_at, window_seconds, :second)

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/usage" =>
             {200,
              %{
                "plan_type" => "pro",
                "rate_limit_reset_credits" => %{"available_count" => 0},
                "rate_limit" => %{
                  "secondary_window" => %{
                    "used_percent" => 0,
                    "limit_window_seconds" => window_seconds,
                    "reset_after_seconds" => window_seconds,
                    "resets_at" =>
                      now
                      |> DateTime.add(window_seconds, :second)
                      |> DateTime.to_iso8601()
                  }
                }
              }}
         }}
      )

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        metadata: %{
          "usage_base_url" => FakeUpstream.url(fake),
          "usage_path" => "/api/codex/usage"
        }
      })

    assert {:ok, _canonical} =
             QuotaWindows.record_evidence(
               identity,
               account_weekly_evidence("100", canonical_at, canonical_reset),
               canonical_at
             )

    assert {:ok, pending} =
             QuotaWindows.record_evidence(
               identity,
               account_weekly_evidence("0", candidate_at, candidate_reset,
                 reset_after_seconds: window_seconds
               ),
               candidate_at
             )

    pending =
      if candidate_kind == :malformed do
        malformed_metadata =
          put_in(pending.metadata, ["__quota_confirmed_candidate_v1", "count"], 2)

        pending
        |> Ecto.Changeset.change(%{metadata: malformed_metadata})
        |> Repo.update!()
      else
        pending
      end

    expected_candidate_observed_at =
      case EvidenceStore.parse_candidate(pending.metadata) do
        {:ok, candidate} -> candidate.observed_at
        :none -> nil
      end

    redemption = pending_redemption(consumed_at)
    put_redemption!(identity, redemption)

    assert {:ok, %{quota: %{code: "quota_refreshed"}}} =
             PoolReconciliation.reconcile_pool_account(pool, assignment)

    canonical =
      identity
      |> QuotaWindows.list_evidence()
      |> Enum.find(&(&1.quota_key == "account" and &1.window_kind == "secondary"))

    assert Decimal.equal?(canonical.used_percent, Decimal.new("100"))
    assert {:ok, candidate} = EvidenceStore.parse_candidate(canonical.metadata)

    case {candidate_kind, expected_candidate_observed_at} do
      {:valid, expected_at} -> assert DateTime.compare(candidate.observed_at, expected_at) == :eq
      {:malformed, nil} -> assert DateTime.compare(candidate.observed_at, candidate_at) == :gt
    end

    assert Repo.reload!(identity).metadata["saved_reset_redemption"] == redemption

    requests = FakeUpstream.requests(fake)
    assert requests != []
    assert Enum.all?(requests, &(&1.method == "GET" and String.ends_with?(&1.path, "/usage")))
  end

  defp assert_scheduler_superseded_control(kind) do
    {pool, identity, assignment} = committed_scheduler_fixture()
    redemption = pending_redemption(DateTime.add(DateTime.utc_now(), -1, :minute))
    put_committed_redemption!(identity, redemption)

    parent = self()
    release_ref = make_ref()
    handler_id = {__MODULE__, :assignment_load, kind, release_ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = metadata[:query] |> to_string() |> String.trim_leading()

          if String.starts_with?(query, "SELECT") and
               String.contains?(query, ~s("pool_upstream_assignments")) and
               String.contains?(query, ~s("upstream_identities")) and
               not Process.get(handler_id, false) do
            Process.put(handler_id, true)
            send(parent, {:scheduler_assignment_loaded, release_ref, self()})

            receive do
              {:release_superseded_scheduler, ^release_ref} -> :ok
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    reconciliation =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          PoolReconciliation.reconcile_pool_account(pool, assignment,
            quota_windows: assignment.metadata["quota_windows"]
          )
        end)
      end)

    assert_receive {:scheduler_assignment_loaded, ^release_ref, reconciliation_pid}

    Sandbox.unboxed_run(Repo, fn -> supersede_scheduler_fixture!(kind, identity, assignment) end)
    send(reconciliation_pid, {:release_superseded_scheduler, release_ref})

    assert {:ok, result} = Task.await(reconciliation)
    assert result.quota.code == "quota_refresh_superseded"

    {persisted, windows} =
      Sandbox.unboxed_run(Repo, fn ->
        {Repo.get!(UpstreamIdentity, identity.id), QuotaWindows.list_evidence(identity)}
      end)

    assert persisted.metadata["saved_reset_redemption"] == redemption
    assert windows == []
  end

  defp supersede_scheduler_fixture!(:credential, identity, _assignment) do
    current = Repo.get!(UpstreamIdentity, identity.id)

    current
    |> UpstreamIdentity.changeset(%{
      metadata: CredentialFencing.advance_credential_epoch(current)
    })
    |> Repo.update!()
  end

  defp supersede_scheduler_fixture!(:assignment, _identity, assignment) do
    assignment
    |> then(&Repo.get!(PoolUpstreamAssignment, &1.id))
    |> PoolAssignments.disable_pool_assignment()
    |> then(fn result -> assert {:ok, _disabled} = result end)
  end

  defp committed_scheduler_fixture do
    quota_windows = [
      %{
        "quota_key" => "account",
        "quota_scope" => "account",
        "quota_family" => "account",
        "window_kind" => "secondary",
        "window_minutes" => 10_080,
        "used_percent" => 0,
        "reset_at" =>
          DateTime.utc_now()
          |> DateTime.add(5, :day)
          |> DateTime.truncate(:microsecond)
          |> DateTime.to_iso8601(),
        "source" => "local_reconciliation",
        "source_precision" => "observed",
        "freshness_state" => "fresh"
      }
    ]

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        pool = pool_fixture()

        %{identity: identity, assignment: assignment} =
          upstream_assignment_fixture(pool, %{
            identity_metadata: %{"quota_windows" => quota_windows},
            assignment_metadata: %{"quota_windows" => quota_windows}
          })

        {pool, identity, assignment}
      end)

    {pool, identity, _assignment} = fixture

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from(current_identity in UpstreamIdentity, where: current_identity.id == ^identity.id)
        )

        Repo.delete_all(
          from(current_pool in CodexPooler.Pools.Pool, where: current_pool.id == ^pool.id)
        )
      end)
    end)

    fixture
  end

  defp put_committed_redemption!(identity, redemption) do
    Sandbox.unboxed_run(Repo, fn ->
      identity
      |> then(&Repo.get!(UpstreamIdentity, &1.id))
      |> put_redemption!(redemption)
    end)
  end

  defp put_redemption!(identity, redemption) do
    identity
    |> Ecto.Changeset.change(%{
      metadata: Map.put(identity.metadata || %{}, "saved_reset_redemption", redemption)
    })
    |> Repo.update!()
  end

  defp pending_redemption(consumed_at) do
    %{
      "status" => "redeeming",
      "phase" => "consumed_pending_probe",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "trigger_kind" => "scheduled_expiry_rescue",
      "started_at" => consumed_at |> DateTime.add(-1, :minute) |> DateTime.to_iso8601(),
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "deadline_at" => consumed_at |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
      "finished_at" => DateTime.to_iso8601(consumed_at),
      "result" => %{"code" => "reset", "applied" => true}
    }
  end

  defp fresh_expiration_metadata(available_count, expiration) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => available_count,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => observed_at,
        "usage_path" => "/api/codex/usage",
        "available_expires_at" => [expiration],
        "available_expirations" => [
          %{
            "expires_at" => expiration,
            "first_seen_at" => "2026-06-21T09:00:00Z",
            "granted_at" => nil
          }
        ],
        "next_expires_at" => expiration,
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

  defp upsert_source_evidence!(identity, used_percent, opts) do
    observed_at = Keyword.fetch!(opts, :observed_at)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               %{
                 quota_key: "account",
                 window_kind: Keyword.get(opts, :window_kind, "secondary"),
                 window_minutes: Keyword.get(opts, :window_minutes, 10_080),
                 used_percent: used_percent,
                 reset_at: Keyword.get(opts, :reset_at, DateTime.add(observed_at, 2, :day)),
                 observed_at: observed_at,
                 last_sync_at: observed_at,
                 source: Keyword.fetch!(opts, :source),
                 source_precision: "observed",
                 quota_scope: "account",
                 quota_family: "account",
                 freshness_state: "fresh"
               }
             ])
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

  defp account_weekly_evidence(used_percent, observed_at, reset_at, opts \\ []) do
    metadata =
      case Keyword.fetch(opts, :reset_after_seconds) do
        {:ok, seconds} -> %{"reset_after_seconds" => seconds}
        :error -> %{}
      end

    %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      metadata: metadata
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

  defp ambiguous_reset_credits_payload(expires_at) do
    %{
      "available_count" => 2,
      "credits" => [
        %{
          "status" => "available",
          "expires_at" => expires_at,
          "granted_at" => "2026-07-20T00:00:00Z"
        },
        %{
          "status" => "available",
          "expires_at" => expires_at
        }
      ]
    }
  end
end
