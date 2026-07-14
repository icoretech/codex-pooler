defmodule CodexPooler.Upstreams.SavedResetRedemptionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    on_exit(fn -> :ok end)
  end

  describe "redeem/2" do
    test "redeems ChatGPT style credit with list and consume calls" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200,
                %{
                  "credits" => [%{"id" => "credit_1", "status" => "available"}],
                  "available_count" => 1
                }},
             "/backend-api/wham/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {404, %{}},
             "/backend-api/codex/usage" => {404, %{}},
             "/wham/usage" => {404, %{}},
             "/backend-api/wham/usage" => {200, usage_payload(0)}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api")

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment)

      requests = FakeUpstream.requests(fake)

      assert Enum.map(requests, &{&1.method, &1.path}) == [
               {"GET", "/backend-api/wham/rate-limit-reset-credits"},
               {"POST", "/backend-api/wham/rate-limit-reset-credits/consume"},
               {"GET", "/backend-api/wham/usage"}
             ]

      consume =
        Enum.find(requests, &(&1.path == "/backend-api/wham/rate-limit-reset-credits/consume"))

      assert %{"credit_id" => "credit_1", "redeem_request_id" => redeem_request_id} = consume.json
      assert is_binary(redeem_request_id)

      persisted = Repo.reload!(identity)
      assert get_in(persisted.metadata, ["saved_reset_redemption", "result", "code"]) == "reset"
      metadata_json = Jason.encode!(persisted.metadata)
      refute metadata_json =~ "credit_1"
      refute metadata_json =~ redeem_request_id
    end

    test "redeems Codex style credit without credit id" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      %{assignment: assignment} = assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment)

      requests = FakeUpstream.requests(fake)

      assert [
               %{method: "POST", path: "/api/codex/rate-limit-reset-credits/consume", json: body}
               | _
             ] = requests

      assert %{"redeem_request_id" => redeem_request_id} = body
      assert is_binary(redeem_request_id)
      refute Map.has_key?(body, "credit_id")
    end

    test "derives a stable idempotency key so a retry reuses the same redeem_request_id" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      assert {:ok, %{status: :succeeded, applied?: true}} =
               SavedResetRedemption.redeem(assignment)

      persisted = Repo.reload!(identity)
      attempt_id = get_in(persisted.metadata, ["saved_reset_redemption", "attempt_id"])
      generation = get_in(persisted.metadata, ["saved_reset_redemption", "generation"])

      [consume | _] = FakeUpstream.requests(fake)
      first_key = consume.json["redeem_request_id"]
      assert is_binary(first_key)

      # The key is a deterministic function of the persisted attempt id and
      # generation, so the same attempt reproduces it without persisting a
      # raw secret in the identity metadata.
      refute Jason.encode!(persisted.metadata) =~ first_key

      expected =
        :sha256
        |> :crypto.hash("saved_reset_redeem:#{attempt_id}:#{generation}")
        |> binary_part(0, 16)
        |> then(fn raw -> elem(Ecto.UUID.load(raw), 1) end)

      assert first_key == expected
    end

    test "keeps a consumed reset truthful when the post-reset usage refresh fails" do
      {:ok, fake} =
        FakeUpstream.start_link({:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           # Provider consumed the credit but the usage refresh fails / omits
           # the account window — the exact production deadlock shape.
           "/api/codex/usage" => {500, %{"error" => "usage unavailable"}}
         }})

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment)

      persisted = Repo.reload!(identity)
      redemption = persisted.metadata["saved_reset_redemption"]

      # Truthful: consumed and pending confirmation, not failed/not-applied.
      assert redemption["phase"] == "consumed_pending_probe"
      assert redemption["status"] == "redeeming"
      assert redemption["result"]["applied"] == true
      assert is_binary(redemption["consumed_at"])
      assert is_binary(redemption["deadline_at"])
    end

    test "a consumed pending reset blocks a second credit even after the stale window" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      stale_started_at =
        DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:microsecond)

      consumed_at =
        DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:microsecond)

      %{assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: %{
            "status" => "redeeming",
            "phase" => "consumed_pending_probe",
            "attempt_id" => Ecto.UUID.generate(),
            "generation" => 2,
            "trigger_kind" => "admin_manual",
            "started_at" => DateTime.to_iso8601(stale_started_at),
            "consumed_at" => DateTime.to_iso8601(consumed_at),
            "deadline_at" => consumed_at |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
            "finished_at" => nil,
            "result" => %{"code" => "reset", "applied" => true}
          }
        )

      assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(assignment)
      assert [] = FakeUpstream.requests(fake)
    end

    test "does not consume when no ChatGPT credit is usable and preserves expiration metadata" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200,
                %{
                  "credits" => [%{"id" => "used_credit", "status" => "redeemed"}],
                  "available_count" => 0
                }}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api",
          saved_resets: saved_resets_with_expirations()
        )

      assert {:ok, %{status: :noop, applied?: false, code: "no_credit"}} =
               SavedResetRedemption.redeem(assignment)

      assert [%{method: "GET", path: "/backend-api/wham/rate-limit-reset-credits"}] =
               FakeUpstream.requests(fake)

      saved_resets = Repo.reload!(identity).metadata["saved_resets"]

      assert saved_resets["available_count"] == 0
      assert saved_resets["available_expires_at"] == ["2026-07-18T00:40:11.968726Z"]

      assert saved_resets["available_expirations"] == [
               %{
                 "expires_at" => "2026-07-18T00:40:11.968726Z",
                 "first_seen_at" => "2026-06-21T09:00:00Z"
               }
             ]

      assert saved_resets["next_expires_at"] == "2026-07-18T00:40:11.968726Z"
      assert saved_resets["expires_observed_at"] == "2026-06-22T10:00:00Z"
      assert saved_resets["expires_refresh_attempted_at"] == "2026-06-22T10:00:00Z"

      metadata_json = Jason.encode!(Repo.reload!(identity).metadata)

      refute metadata_json =~ "used_credit"
      refute metadata_json =~ "redeem_request_id"
      refute metadata_json =~ "provider-credit"
      refute metadata_json =~ "Provider Title"
      refute metadata_json =~ "Provider description"
      refute metadata_json =~ "granted_at"
      refute metadata_json =~ "raw_payload"
    end

    test "fresh in-progress redemption blocks another attempt" do
      {:ok, fake} = FakeUpstream.start_link({:json, 200, %{}})
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api",
          redemption: %{
            "status" => "redeeming",
            "attempt_id" => Ecto.UUID.generate(),
            "generation" => 1,
            "trigger_kind" => "admin_manual",
            "started_at" => DateTime.to_iso8601(now),
            "finished_at" => nil,
            "result" => nil
          }
        )

      assert {:error, :redemption_in_progress} = SavedResetRedemption.redeem(assignment)
      assert [] = FakeUpstream.requests(fake)
    end

    test "stale admin in-progress redemption is recovered by manual attempt" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      stale_started_at =
        DateTime.utc_now()
        |> DateTime.add(-5, :minute)
        |> DateTime.truncate(:microsecond)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: %{
            "status" => "redeeming",
            "attempt_id" => Ecto.UUID.generate(),
            "generation" => 1,
            "trigger_kind" => "admin_manual",
            "started_at" => DateTime.to_iso8601(stale_started_at),
            "finished_at" => nil,
            "result" => nil
          }
        )

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment)

      assert [consume_request, usage_request] = FakeUpstream.requests(fake)

      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
      assert usage_request.path == "/api/codex/usage"

      persisted = Repo.reload!(identity)
      assert get_in(persisted.metadata, ["saved_reset_redemption", "status"]) == "succeeded"
      assert get_in(persisted.metadata, ["saved_reset_redemption", "generation"]) == 3
      assert get_in(persisted.metadata, ["saved_reset_redemption", "result", "code"]) == "reset"
    end

    test "gateway auto does not consume when persisted policy was disabled after candidate selection" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity, source: "codex_response_headers")
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)

      update_identity!(stale_identity, %{saved_reset_auto_redeem_enabled: false})

      assert {:ok, %{status: :noop, applied?: false}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto does not consume when persisted count was reduced to keep credits" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity =
        enable_saved_reset_auto_redeem!(identity, %{saved_reset_auto_redeem_keep_credits: 1})

      upsert_weekly_exhausted_quota!(stale_identity, source: "codex_response_headers")
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)

      update_saved_resets!(stale_identity, %{"available_count" => 1})

      assert {:ok, %{status: :noop, applied?: false}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto does not consume when persisted saved-reset count is unreported" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity)
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)

      update_saved_resets!(stale_identity, %{"status" => "unreported", "available_count" => nil})

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_saved_reset_unavailable"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)

      persisted = Repo.reload!(stale_identity)
      refute get_in(persisted.metadata, ["saved_reset_redemption", "status"]) == "redeeming"
    end

    test "gateway auto does not consume when persisted weekly quota no longer matches trigger" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity, source: "codex_response_headers")
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)

      upsert_weekly_pressure_quota!(stale_identity, Decimal.new("20"))

      assert {:ok, %{status: :noop, applied?: false}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto selects same-source exhaustion before logical cross-source ranking" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)

      upsert_weekly_exhausted_quota!(identity)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 weekly_quota_attrs(Decimal.new("99"), source: "codex_response_headers")
               ])

      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [consume_request, usage_request] = FakeUpstream.requests(fake)
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
      assert usage_request.path == "/api/codex/usage"
    end

    test "gateway auto rejects mismatched context without marking redemption" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity)

      context =
        assignment
        |> gateway_auto_context(stale_identity, :blocked_weekly_exhaustion)
        |> Map.merge(%{
          upstream_identity_id: Ecto.UUID.generate(),
          candidate_identity_ids: [Ecto.UUID.generate()]
        })

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_context_mismatch"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)

      persisted = Repo.reload!(stale_identity)
      refute get_in(persisted.metadata, ["saved_reset_redemption", "status"]) == "redeeming"
    end

    test "gateway auto does not consume when persisted identity has fresh in-progress redemption" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity)
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)

      update_redemption!(stale_identity, redemption_metadata("gateway_auto", DateTime.utc_now()))

      assert {:error, :redemption_in_progress} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto does not consume when persisted identity has stale gateway auto metadata" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(stale_identity)
      context = gateway_auto_context(assignment, stale_identity, :blocked_weekly_exhaustion)
      started_at = DateTime.utc_now() |> DateTime.add(-5, :minute)

      update_redemption!(stale_identity, redemption_metadata("gateway_auto", started_at))

      assert {:error, :redemption_in_progress} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto does not consume when persisted identity lost expiring eligibility" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          saved_resets:
            saved_resets_with_expirations()
            |> Map.merge(expiring_saved_reset_attrs())
            |> Map.put("path_style", "codex_api")
            |> Map.put("usage_path", "/api/codex/usage")
        )

      stale_identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_pressure_quota!(stale_identity, Decimal.new("25"))
      context = gateway_auto_context(assignment, stale_identity, :expiring_reset)

      update_saved_resets!(stale_identity, %{
        "available_expires_at" => [],
        "available_expirations" => [],
        "next_expires_at" => nil
      })

      assert {:ok, %{status: :noop, applied?: false}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto rejects malformed context without provider request" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)

      assert {:ok, %{status: :noop, applied?: false}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: %{trigger: :blocked_weekly_exhaustion}
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto rejects non-keyword list malformed context without provider request" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_context_invalid"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: [:bad]
               )

      assert [] = FakeUpstream.requests(fake)

      persisted = Repo.reload!(identity)
      refute Map.has_key?(persisted.metadata || %{}, "saved_reset_redemption")
    end

    test "gateway auto returns an error without provider request when persisted assignment is inactive" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)
      update_assignment!(assignment, %{status: PoolUpstreamAssignment.paused_status()})

      assert {:error, %{code: :pool_assignment_not_found}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end
  end

  describe "concurrent gateway redemption (multi-node safety)" do
    test "two concurrent redeems on the same identity consume exactly one credit" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)
      parent = self()

      results =
        for _index <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            SavedResetRedemption.redeem(assignment,
              trigger_kind: "gateway_auto",
              gateway_auto_context: context,
              receive_timeout: 15_000
            )
          end)
        end
        |> Task.await_many(15_000)

      # Exactly one attempt consumed a credit; the other was blocked in progress.
      assert Enum.count(results, &match?({:ok, %{applied?: true}}, &1)) == 1

      # The provider saw exactly one consume POST — no double consumption.
      consume_requests =
        fake
        |> FakeUpstream.requests()
        |> Enum.filter(&(&1.path == "/api/codex/rate-limit-reset-credits/consume"))

      assert length(consume_requests) == 1

      persisted = Repo.reload!(identity)
      redemption = persisted.metadata["saved_reset_redemption"]
      assert redemption["result"]["code"] == "reset"
      assert redemption["result"]["applied"] == true
    end

    test "concurrent probe claims after a shared consume yield a single holder" do
      # Both requests observe the same consumed_pending_probe identity and race to
      # claim the one-shot probe; exactly one token may hold it.
      consumed_at =
        DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:microsecond)

      %{identity: identity} =
        active_upstream_assignment_fixture(pool_fixture(), %{
          metadata: %{
            "saved_reset_redemption" => %{
              "status" => "redeeming",
              "phase" => "consumed_pending_probe",
              "attempt_id" => Ecto.UUID.generate(),
              "generation" => 4,
              "trigger_kind" => "gateway_auto",
              "consumed_at" => DateTime.to_iso8601(consumed_at),
              "deadline_at" =>
                consumed_at |> RedemptionLifecycle.deadline_at() |> DateTime.to_iso8601(),
              "result" => %{"code" => "reset", "applied" => true}
            }
          }
        })

      generation = 4

      attempt_id =
        get_in(Repo.reload!(identity).metadata, ["saved_reset_redemption", "attempt_id"])

      parent = self()

      results =
        for index <- 1..3 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            CodexPooler.Upstreams.SavedResets.ProbeLease.claim(
              identity,
              generation,
              attempt_id,
              "token-#{index}"
            )
          end)
        end
        |> Task.await_many(15_000)

      assert Enum.count(results, &match?({:ok, :claimed}, &1)) == 1
      assert Enum.count(results, &match?({:error, :unavailable}, &1)) == 2
    end
  end

  describe "AutoEligibility.validate_locked_gateway_auto/4" do
    test "gateway auto noops when the locked identity is disabled or deleted" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      for status <- [UpstreamIdentity.disabled_status(), UpstreamIdentity.deleted_status()] do
        locked_identity = %{identity | status: status}

        assert {:noop, "gateway_auto_identity_unavailable"} =
                 AutoEligibility.validate_locked_gateway_auto(
                   locked_identity,
                   assignment,
                   context,
                   timestamp
                 )
      end

      assert [] = FakeUpstream.requests(fake)
    end

    test "gateway auto noops when the current assignment is inactive or reassigned" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      inactive_assignment = %{assignment | status: PoolUpstreamAssignment.paused_status()}

      assert {:noop, "gateway_auto_assignment_unavailable"} =
               AutoEligibility.validate_locked_gateway_auto(
                 identity,
                 inactive_assignment,
                 context,
                 timestamp
               )

      reassigned_assignment = %{assignment | upstream_identity_id: Ecto.UUID.generate()}

      assert {:noop, "gateway_auto_context_mismatch"} =
               AutoEligibility.validate_locked_gateway_auto(
                 identity,
                 reassigned_assignment,
                 context,
                 timestamp
               )

      assert [] = FakeUpstream.requests(fake)
    end
  end

  defp codex_reset_fake(available_count) do
    FakeUpstream.start_link(
      {:path_json,
       %{
         "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
         "/api/codex/usage" => {200, usage_payload(available_count)}
       }}
    )
  end

  defp assignment_with_fake(fake, usage_path, path_style, opts \\ []) do
    saved_resets =
      Keyword.get(opts, :saved_resets, %{
        "status" => "reported",
        "available_count" => 1,
        "source" => "codex_usage_api",
        "path_style" => path_style,
        "observed_at" =>
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
        "usage_path" => usage_path,
        "reason" => nil
      })

    metadata = %{
      "usage_base_url" => FakeUpstream.url(fake),
      "saved_resets" => saved_resets
    }

    metadata =
      case Keyword.get(opts, :redemption) do
        nil -> metadata
        redemption -> Map.put(metadata, "saved_reset_redemption", redemption)
      end

    active_upstream_assignment_fixture(pool_fixture(), %{metadata: metadata})
  end

  defp saved_resets_with_expirations do
    %{
      "status" => "reported",
      "available_count" => 1,
      "source" => "codex_usage_api",
      "path_style" => "chatgpt_api",
      "observed_at" => "2026-06-22T10:00:00Z",
      "usage_path" => "/backend-api/wham/usage",
      "available_expires_at" => ["2026-07-18T00:40:11.968726Z"],
      "available_expirations" => [
        %{
          "expires_at" => "2026-07-18T00:40:11.968726Z",
          "first_seen_at" => "2026-06-21T09:00:00Z"
        },
        %{
          "expires_at" => "not-a-date",
          "first_seen_at" => "2026-06-20T09:00:00Z"
        }
      ],
      "next_expires_at" => "2026-07-18T00:40:11.968726Z",
      "expires_observed_at" => "2026-06-22T10:00:00Z",
      "expires_refresh_attempted_at" => "2026-06-22T10:00:00Z",
      "credit_id" => "provider-credit",
      "title" => "Provider Title",
      "description" => "Provider description",
      "granted_at" => "2026-06-20T00:00:00Z",
      "raw_payload" => %{"unsafe" => true},
      "reason" => nil
    }
  end

  defp expiring_saved_reset_attrs do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = timestamp |> DateTime.add(1, :hour) |> DateTime.to_iso8601()
    observed_at = DateTime.to_iso8601(timestamp)

    %{
      "available_expires_at" => [expires_at],
      "available_expirations" => [%{"expires_at" => expires_at, "first_seen_at" => observed_at}],
      "next_expires_at" => expires_at,
      "expires_observed_at" => observed_at,
      "expires_refresh_attempted_at" => observed_at
    }
  end

  defp gateway_auto_context(assignment, identity, trigger) do
    %{
      trigger: trigger,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      candidate_assignment_ids: [assignment.id],
      candidate_identity_ids: [identity.id],
      route_class: "proxy_http"
    }
  end

  defp enable_saved_reset_auto_redeem!(%UpstreamIdentity{} = identity, attrs \\ %{}) do
    update_identity!(
      identity,
      Map.merge(
        %{
          saved_reset_auto_redeem_enabled: true,
          saved_reset_auto_redeem_min_blocked_minutes: 60,
          saved_reset_auto_redeem_keep_credits: 0,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        },
        attrs
      )
    )
  end

  defp update_identity!(%UpstreamIdentity{} = identity, attrs) do
    identity
    |> UpstreamIdentity.changeset(attrs)
    |> Repo.update!()
  end

  defp update_saved_resets!(%UpstreamIdentity{} = identity, attrs) do
    persisted = Repo.reload!(identity)
    metadata = persisted.metadata || %{}
    saved_resets = Map.merge(metadata["saved_resets"] || %{}, attrs)

    update_identity!(persisted, %{metadata: Map.put(metadata, "saved_resets", saved_resets)})
  end

  defp update_redemption!(%UpstreamIdentity{} = identity, redemption) do
    persisted = Repo.reload!(identity)
    metadata = persisted.metadata || %{}

    update_identity!(persisted, %{
      metadata: Map.put(metadata, "saved_reset_redemption", redemption)
    })
  end

  defp update_assignment!(%PoolUpstreamAssignment{} = assignment, attrs) do
    assignment
    |> Repo.reload!()
    |> PoolUpstreamAssignment.changeset(
      Map.put(attrs, :updated_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    )
    |> Repo.update!()
  end

  defp redemption_metadata(trigger_kind, started_at) do
    %{
      "status" => "redeeming",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "trigger_kind" => trigger_kind,
      "started_at" => started_at |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "finished_at" => nil,
      "result" => nil
    }
  end

  defp upsert_weekly_exhausted_quota!(identity, overrides \\ []) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               weekly_quota_attrs(Decimal.new("100"), overrides)
             ])
  end

  defp upsert_weekly_pressure_quota!(identity, used_percent) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [weekly_quota_attrs(used_percent)])
  end

  defp weekly_quota_attrs(used_percent, overrides \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Map.merge(
      %{
        quota_key: "account",
        window_kind: "secondary",
        window_minutes: 10_080,
        used_percent: used_percent,
        reset_at: DateTime.add(now, 2, :hour),
        observed_at: now,
        last_sync_at: now,
        source: "codex_usage_api",
        source_precision: "observed",
        quota_scope: "account",
        quota_family: "account",
        freshness_state: "fresh"
      },
      Map.new(overrides)
    )
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
end
