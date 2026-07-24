defmodule CodexPooler.Upstreams.SavedResetRedemptionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.SavedResets.ProbeLease
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias Ecto.Adapters.SQL
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

    test "a stale consume-window crash resumes the same attempt and provider key" do
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

      crashed_attempt_id = Ecto.UUID.generate()

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: %{
            "status" => "redeeming",
            "phase" => "consuming",
            "attempt_id" => crashed_attempt_id,
            "generation" => 5,
            "trigger_kind" => "admin_manual",
            "started_at" => DateTime.to_iso8601(stale_started_at),
            "finished_at" => nil,
            "result" => nil
          }
        )

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment)

      # The resumed attempt reuses the crashed attempt's identity, so the
      # provider receives the byte-identical redeem_request_id and can
      # deduplicate instead of consuming a second credit.
      [consume | _] = FakeUpstream.requests(fake)

      expected_key =
        :sha256
        |> :crypto.hash("saved_reset_redeem:#{crashed_attempt_id}:5")
        |> binary_part(0, 16)
        |> then(fn raw -> elem(Ecto.UUID.load(raw), 1) end)

      assert consume.json["redeem_request_id"] == expected_key

      persisted = Repo.reload!(identity)
      assert get_in(persisted.metadata, ["saved_reset_redemption", "generation"]) == 5

      assert get_in(persisted.metadata, ["saved_reset_redemption", "attempt_id"]) ==
               crashed_attempt_id
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

    test "authoritative ChatGPT zero clears current expirations and preserves the durable ledger" do
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

      ledger = %{
        "version" => 1,
        "entries" => [
          %{
            "expires_at" => "2026-07-18T00:40:11.968726Z",
            "first_seen_at" => "2026-06-21T09:00:00Z"
          }
        ]
      }

      identity =
        identity
        |> Ecto.Changeset.change(saved_reset_first_seen_ledger: ledger)
        |> Repo.update!()

      observed_at = ~U[2026-07-24 03:00:00Z]

      assert {:ok, %{status: :noop, applied?: false, code: "no_credit"}} =
               SavedResetRedemption.redeem(assignment, started_at: observed_at)

      assert [%{method: "GET", path: "/backend-api/wham/rate-limit-reset-credits"}] =
               FakeUpstream.requests(fake)

      persisted = Repo.reload!(identity)
      saved_resets = persisted.metadata["saved_resets"]

      assert saved_resets["available_count"] == 0
      assert saved_resets["available_expires_at"] == []
      assert saved_resets["available_expirations"] == []
      assert saved_resets["next_expires_at"] == nil
      assert saved_resets["observed_at"] == "2026-07-24T03:00:00Z"
      assert saved_resets["expires_observed_at"] == "2026-07-24T03:00:00Z"
      assert saved_resets["expires_refresh_attempted_at"] == "2026-07-24T03:00:00Z"
      assert persisted.saved_reset_first_seen_ledger == ledger

      metadata_json = Jason.encode!(persisted.metadata)

      refute metadata_json =~ "used_credit"
      refute metadata_json =~ "redeem_request_id"
      refute metadata_json =~ "provider-credit"
      refute metadata_json =~ "Provider Title"
      refute metadata_json =~ "Provider description"
      refute metadata_json =~ "granted_at"
      refute metadata_json =~ "raw_payload"
    end

    test "an older no-credit observation finalizes lifecycle without overwriting snapshot or ledger" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200, %{"credits" => [], "available_count" => 0}}
           }}
        )

      newer_saved_resets =
        saved_resets_with_expirations()
        |> Map.put("observed_at", "2026-07-24T04:00:00Z")

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api",
          saved_resets: newer_saved_resets
        )

      opaque_ledger = %{"version" => 99, "payload" => %{"future" => true}}

      identity =
        identity
        |> Ecto.Changeset.change(saved_reset_first_seen_ledger: opaque_ledger)
        |> Repo.update!()

      assert {:ok, %{status: :noop, code: "no_credit"}} =
               SavedResetRedemption.redeem(assignment,
                 started_at: ~U[2026-07-24 03:00:00Z]
               )

      persisted = Repo.reload!(identity)
      assert persisted.metadata["saved_resets"] == newer_saved_resets
      assert persisted.saved_reset_first_seen_ledger == opaque_ledger
      assert get_in(persisted.metadata, ["saved_reset_redemption", "status"]) == "noop"
    end

    @tag :redemption_atomicity_manual_qa
    test "a newer no-credit observation replaces the snapshot and preserves the ledger" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200, %{"credits" => [], "available_count" => 0}}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api",
          saved_resets:
            saved_resets_with_expirations()
            |> Map.put("observed_at", "2026-07-24T02:00:00Z")
        )

      ledger = %{
        "version" => 1,
        "entries" => [
          %{
            "expires_at" => "2026-07-18T00:40:11.968726Z",
            "first_seen_at" => "2026-06-21T09:00:00Z"
          }
        ]
      }

      identity =
        identity
        |> Ecto.Changeset.change(saved_reset_first_seen_ledger: ledger)
        |> Repo.update!()

      assert {:ok, %{status: :noop, code: "no_credit"}} =
               SavedResetRedemption.redeem(assignment,
                 started_at: ~U[2026-07-24 03:00:00Z]
               )

      persisted = Repo.reload!(identity)
      assert persisted.metadata["saved_resets"]["observed_at"] == "2026-07-24T03:00:00Z"
      assert persisted.metadata["saved_resets"]["available_expirations"] == []
      assert persisted.saved_reset_first_seen_ledger == ledger
    end

    test "a superseded attempt cannot modify saved-reset state after the provider observation" do
      parent = self()
      release_ref = make_ref()

      {:ok, fake} =
        FakeUpstream.start_link(
          FakeUpstream.barrier_json_response(
            %{"credits" => [], "available_count" => 0},
            notify: parent,
            release_ref: release_ref
          )
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api",
          saved_resets: saved_resets_with_expirations()
        )

      task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())

          SavedResetRedemption.redeem(assignment,
            started_at: ~U[2026-07-24 03:00:00Z]
          )
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, fake_request_pid,
                      ^release_ref},
                     5_000

      superseded = %{
        "status" => "redeeming",
        "attempt_id" => Ecto.UUID.generate(),
        "generation" => 99,
        "trigger_kind" => "admin_manual",
        "started_at" => "2026-07-24T03:30:00Z",
        "finished_at" => nil,
        "result" => nil
      }

      update_redemption!(identity, superseded)
      before_release = Repo.reload!(identity)

      send(fake_request_pid, {:fake_upstream_release_timeout, release_ref})

      assert {:ok, %{status: :noop, code: "no_credit"}} = Task.await(task, 5_000)

      persisted = Repo.reload!(identity)
      assert persisted.metadata["saved_resets"] == before_release.metadata["saved_resets"]

      assert persisted.saved_reset_first_seen_ledger ==
               before_release.saved_reset_first_seen_ledger

      assert persisted.metadata["saved_reset_redemption"] == superseded
    end

    @tag :redemption_atomicity_manual_qa
    test "a newer reconciliation observation committed before finalization wins with one final update" do
      parent = self()
      release_ref = make_ref()

      {:ok, fake} =
        FakeUpstream.start_link(
          FakeUpstream.barrier_json_response(
            %{"credits" => [], "available_count" => 0},
            notify: parent,
            release_ref: release_ref
          )
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/backend-api/wham/usage", "chatgpt_api",
          saved_resets:
            saved_resets_with_expirations()
            |> Map.put("observed_at", "2026-07-24T02:00:00Z")
        )

      ledger = %{
        "version" => 1,
        "entries" => [
          %{
            "expires_at" => "2026-07-18T00:40:11.968726Z",
            "first_seen_at" => "2026-06-21T09:00:00Z"
          }
        ]
      }

      identity =
        identity
        |> Ecto.Changeset.change(saved_reset_first_seen_ledger: ledger)
        |> Repo.update!()

      task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())

          SavedResetRedemption.redeem(assignment,
            started_at: ~U[2026-07-24 03:00:00Z]
          )
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, fake_request_pid,
                      ^release_ref},
                     5_000

      newer_saved_resets =
        saved_resets_with_expirations()
        |> Map.put("observed_at", "2026-07-24T04:00:00Z")
        |> Map.put("available_count", 7)

      update_saved_resets!(identity, newer_saved_resets)

      handler_id = "saved-reset-final-update-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if self() == task.pid and identity_update_query?(metadata) do
              send(parent, {:saved_reset_identity_update, task.pid})
            end
          end,
          nil
        )

      try do
        send(fake_request_pid, {:fake_upstream_release_timeout, release_ref})

        assert {:ok, %{status: :noop, code: "no_credit"}} = Task.await(task, 5_000)

        assert drain_identity_updates(task.pid) == 1

        persisted = Repo.reload!(identity)
        assert persisted.metadata["saved_resets"] == newer_saved_resets
        assert persisted.saved_reset_first_seen_ledger == ledger
        assert get_in(persisted.metadata, ["saved_reset_redemption", "status"]) == "noop"
      after
        :telemetry.detach(handler_id)
      end
    end

    @tag :separate_connection_redemption_reconciliation_order
    test "an older reconciliation writer waits for redemption and cannot replace its newer snapshot" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/backend-api/wham/rate-limit-reset-credits" =>
               {200, %{"credits" => [], "available_count" => 0}},
             "/backend-api/wham/usage" => {200, usage_payload(9)}
           }}
        )

      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture =
        committed_no_credit_fixture!(
          fake,
          saved_resets_with_expirations()
          |> Map.put("observed_at", "2026-07-24T02:00:00Z")
        )

      on_exit(fn -> cleanup_committed_no_credit_fixture!(fixture) end)

      parent = self()
      barrier = make_ref()

      redemption_observed_at =
        DateTime.utc_now()
        |> DateTime.add(1, :day)
        |> DateTime.truncate(:microsecond)

      redemption_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {barrier, :redemption_backend, backend_pid!()})

            receive do
              {^barrier, :start_redemption} -> :ok
            after
              5_000 -> raise "timed out waiting to start saved-reset redemption"
            end

            SavedResetRedemption.redeem(fixture.assignment_id,
              started_at: redemption_observed_at
            )
          end)
        end)

      assert_receive {^barrier, :redemption_backend, redemption_backend_pid}, 5_000

      handler_id = "saved-reset-finalizer-lock-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if self() == redemption_task.pid and probe_identity_lock_query?(metadata) do
              lock_count = Process.get({__MODULE__, barrier, :identity_lock_count}, 0) + 1
              Process.put({__MODULE__, barrier, :identity_lock_count}, lock_count)

              if lock_count == 2 do
                send(parent, {barrier, :finalizer_locked})

                receive do
                  {^barrier, :release_finalizer} -> :ok
                after
                  5_000 -> raise "timed out waiting to release saved-reset finalizer"
                end
              end
            end
          end,
          nil
        )

      try do
        send(redemption_task.pid, {barrier, :start_redemption})
        assert_receive {^barrier, :finalizer_locked}, 5_000

        reconciliation_task =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              send(parent, {barrier, :reconciliation_backend, backend_pid!()})

              result =
                PoolReconciliation.refresh_quota_from_usage(
                  Repo.get!(UpstreamIdentity, fixture.identity_id),
                  Repo.get!(PoolUpstreamAssignment, fixture.assignment_id)
                )

              send(parent, {barrier, :reconciliation_result, result})
            end)
          end)

        assert_receive {^barrier, :reconciliation_backend, reconciliation_backend_pid}, 5_000

        observation =
          observe_blocked_probe_claim!(reconciliation_backend_pid, redemption_backend_pid)

        assert redemption_backend_pid in observation.blocking_pids
        assert observation.wait_event_type == "Lock"

        send(redemption_task.pid, {barrier, :release_finalizer})

        assert {:ok, %{status: :noop, code: "no_credit"}} =
                 Task.await(redemption_task, 5_000)

        assert_receive {^barrier, :reconciliation_result, {:ok, %UpstreamIdentity{}}}, 5_000
        Task.await(reconciliation_task, 5_000)

        persisted = run_unboxed(fn -> Repo.get!(UpstreamIdentity, fixture.identity_id) end)

        assert persisted.metadata["saved_resets"]["observed_at"] ==
                 DateTime.to_iso8601(redemption_observed_at)

        assert persisted.metadata["saved_resets"]["available_count"] == 0
        assert get_in(persisted.metadata, ["saved_reset_redemption", "status"]) == "noop"
        assert Enum.any?(FakeUpstream.requests(fake), &(&1.path == "/backend-api/wham/usage"))
      after
        :telemetry.detach(handler_id)
        send(redemption_task.pid, {barrier, :start_redemption})
        send(redemption_task.pid, {barrier, :release_finalizer})
      end
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

    @tag :separate_connection_probe_race
    test "concurrent probe claims serialize across separate PostgreSQL backends" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {500, %{"error" => "synthetic usage failure"}}
           }}
        )

      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_probe_claim_fixture!(fake)
      on_exit(fn -> cleanup_committed_probe_claim_fixture!(fixture) end)

      assert {:ok, %{applied?: true, phase: "consumed_pending_probe"}} =
               run_unboxed(fn -> SavedResetRedemption.redeem(fixture.assignment_id) end)

      consume_requests =
        fake
        |> FakeUpstream.requests()
        |> Enum.filter(&(&1.path == "/api/codex/rate-limit-reset-credits/consume"))

      assert length(consume_requests) == 1

      fixture = committed_probe_claim_context!(fixture)
      winner_probe = bound_probe!(fixture)
      loser_probe = bound_probe!(fixture)

      parent = self()
      barrier = make_ref()

      winner_task =
        start_probe_claim_task(parent, barrier, fixture, :winner, winner_probe)

      loser_task =
        start_probe_claim_task(parent, barrier, fixture, :loser, loser_probe)

      tasks = [winner_task, loser_task]

      try do
        assert_receive {^barrier, :claim_ready, winner_pid, :winner, winner_backend_pid},
                       5_000

        assert_receive {^barrier, :claim_ready, loser_pid, :loser, loser_backend_pid}, 5_000

        assert winner_pid == winner_task.pid
        assert loser_pid == loser_task.pid
        assert winner_pid != loser_pid
        assert winner_backend_pid != loser_backend_pid

        handler_id =
          "saved-reset-probe-lock-#{System.unique_integer([:positive])}"

        :ok =
          :telemetry.attach(
            handler_id,
            [:codex_pooler, :repo, :query],
            fn _event, _measurements, metadata, _config ->
              if self() == winner_task.pid and probe_identity_lock_query?(metadata) and
                   is_nil(Process.get({__MODULE__, barrier, :winner_paused})) do
                Process.put({__MODULE__, barrier, :winner_paused}, true)
                send(parent, {barrier, :winner_lock_acquired, winner_backend_pid})

                receive do
                  {^barrier, :release_winner} -> :ok
                after
                  5_000 -> raise "timed out waiting to release the saved-reset probe winner"
                end
              end
            end,
            nil
          )

        try do
          send(winner_task.pid, {barrier, :start_claim})

          assert_receive {^barrier, :claim_started, :winner, ^winner_backend_pid}, 5_000
          assert_receive {^barrier, :winner_lock_acquired, ^winner_backend_pid}, 5_000

          send(loser_task.pid, {barrier, :start_claim})

          assert_receive {^barrier, :claim_started, :loser, ^loser_backend_pid}, 5_000

          observation =
            observe_blocked_probe_claim!(loser_backend_pid, winner_backend_pid)

          assert winner_backend_pid in observation.blocking_pids
          assert observation.wait_event_type == "Lock"

          send(winner_task.pid, {barrier, :release_winner})

          winner_result = Task.await(winner_task, 5_000)

          assert {:winner, ^winner_backend_pid, {:ok, :claimed}} = winner_result

          loser_result = Task.await(loser_task, 5_000)

          assert {:loser, ^loser_backend_pid, {:error, :unavailable}} = loser_result

          persisted_probe = persisted_probe!(fixture.identity_id)

          assert persisted_probe == %{
                   "claimed_at" => persisted_probe["claimed_at"],
                   "scope" => %{
                     "effective_model" => winner_probe.effective_model,
                     "pool_upstream_assignment_id" => fixture.assignment_id,
                     "route_class" => winner_probe.route_class,
                     "upstream_identity_id" => fixture.identity_id
                   },
                   "token" => winner_probe.token,
                   "version" => 2
                 }

          assert is_binary(persisted_probe["claimed_at"])

          assert {:error, :unavailable} =
                   run_unboxed(fn ->
                     ProbeLease.claim(
                       fixture.identity_id,
                       fixture.generation,
                       fixture.attempt_id,
                       loser_probe
                     )
                   end)

          persisted_probe_after_retry = persisted_probe!(fixture.identity_id)
          assert persisted_probe_after_retry == persisted_probe

          if System.get_env("TASK3_MANUAL_QA") == "1" do
            result_labels =
              Enum.map_join([winner_result, loser_result], ",", fn
                {_role, _backend_pid, {:ok, :claimed}} -> "claimed"
                {_role, _backend_pid, {:error, :unavailable}} -> "unavailable"
              end)

            persisted_probe_holder_count =
              if is_binary(persisted_probe_after_retry["token"]), do: 1, else: 0

            IO.puts(
              "TASK3_MANUAL_QA backend_pids=#{winner_backend_pid},#{loser_backend_pid} " <>
                "results=#{result_labels} " <>
                "provider_consume_count=#{length(consume_requests)} " <>
                "persisted_probe_holder_count=#{persisted_probe_holder_count} " <>
                "immutable=#{persisted_probe_after_retry == persisted_probe}"
            )
          end
        after
          :telemetry.detach(handler_id)
        end
      after
        release_probe_claim_tasks(tasks, barrier)
      end
    end

    @tag :separate_connection_probe_reassignment_race
    test "probe claim validates assignment ownership after locking the identity" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {500, %{"error" => "synthetic usage failure"}}
           }}
        )

      on_exit(fn -> FakeUpstream.stop(fake) end)

      fixture = committed_probe_claim_fixture!(fake)
      on_exit(fn -> cleanup_committed_probe_claim_fixture!(fixture) end)

      assert {:ok, %{applied?: true, phase: "consumed_pending_probe"}} =
               run_unboxed(fn -> SavedResetRedemption.redeem(fixture.assignment_id) end)

      fixture = committed_probe_claim_context!(fixture)
      probe = bound_probe!(fixture)
      foreign_identity_id = fixture.foreign_identity_id
      parent = self()
      barrier = make_ref()

      claim_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {barrier, :claim_backend, backend_pid!()})

            ProbeLease.claim(
              fixture.identity_id,
              fixture.generation,
              fixture.attempt_id,
              probe
            )
          end)
        end)

      handler_id = "saved-reset-probe-identity-first-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:codex_pooler, :repo, :query],
          fn _event, _measurements, metadata, _config ->
            if self() == claim_task.pid and probe_identity_lock_query?(metadata) and
                 is_nil(Process.get({__MODULE__, barrier, :claim_paused})) do
              Process.put({__MODULE__, barrier, :claim_paused}, true)
              send(parent, {barrier, :identity_locked})

              receive do
                {^barrier, :release_claim} -> :ok
              after
                5_000 -> raise "timed out waiting to release the reassignment probe claim"
              end
            end
          end,
          nil
        )

      try do
        assert_receive {^barrier, :claim_backend, claim_backend_pid}, 5_000
        assert_receive {^barrier, :identity_locked}, 5_000

        reassignment_task =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              assignment = Repo.get!(PoolUpstreamAssignment, fixture.assignment_id)
              send(parent, {barrier, :reassignment_backend, backend_pid!()})

              assignment
              |> PoolUpstreamAssignment.changeset(%{
                upstream_identity_id: foreign_identity_id,
                updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
              })
              |> Repo.update!()
            end)
          end)

        assert_receive {^barrier, :reassignment_backend, reassignment_backend_pid}, 5_000
        assert claim_backend_pid != reassignment_backend_pid

        reassignment_result = Task.await(reassignment_task, 5_000)

        assert %PoolUpstreamAssignment{
                 upstream_identity_id: ^foreign_identity_id
               } = reassignment_result

        send(claim_task.pid, {barrier, :release_claim})

        assert Task.await(claim_task, 5_000) == {:error, :unavailable}
        assert persisted_probe!(fixture.identity_id) == nil
      after
        send(claim_task.pid, {barrier, :release_claim})
        :telemetry.detach(handler_id)
      end
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

  describe "gateway auto post-consume latch" do
    test "an applied auto consume awaiting quota convergence blocks another auto consume" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: applied_gateway_auto_redemption("confirmed_by_upstream", 5)
        )

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_awaiting_post_consume_quota"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)

      persisted = Repo.reload!(identity)

      assert get_in(persisted.metadata, ["saved_reset_redemption", "phase"]) ==
               "confirmed_by_upstream"
    end

    test "a converged auto consume still cools down inside the probe window" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: applied_gateway_auto_redemption("confirmed_by_quota", 5)
        )

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

      assert {:ok, %{status: :noop, applied?: false, code: "gateway_auto_consume_cooldown"}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "a converged auto consume past the cooldown re-arms a genuine new episode" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: applied_gateway_auto_redemption("confirmed_by_quota", 40)
        )

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [consume_request, _usage_request] = FakeUpstream.requests(fake)
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
    end

    test "manual redemption overrides the latch" do
      {:ok, fake} = codex_reset_fake(0)

      %{assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: applied_gateway_auto_redemption("confirmed_by_upstream", 5)
        )

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment)

      assert [consume_request, _usage_request] = FakeUpstream.requests(fake)
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
    end

    test "a legacy applied record inside the window cools down without latching forever" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: legacy_applied_gateway_auto_redemption(5)
        )

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

      assert {:ok, %{status: :noop, applied?: false, code: "gateway_auto_consume_cooldown"}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "the threshold trigger cannot bypass the latch" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: applied_gateway_auto_redemption("confirmed_by_upstream", 5)
        )

      identity =
        enable_saved_reset_auto_redeem!(identity, %{
          saved_reset_auto_redeem_trigger_mode: "threshold",
          saved_reset_auto_redeem_quota_threshold_percent: 60
        })

      upsert_weekly_pressure_quota!(identity, Decimal.new("95"))
      context = gateway_auto_context(assignment, identity, :threshold_pressure)

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_awaiting_post_consume_quota"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "a failed manual attempt does not disarm the automatic latch" do
      {:ok, fake} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {500, %{"error" => "unavailable"}},
             "/api/codex/usage" => {200, usage_payload(1)}
           }}
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: applied_gateway_auto_redemption("confirmed_by_quota", 5)
        )

      manual_result = SavedResetRedemption.redeem(assignment)
      refute match?({:ok, %{applied?: true}}, manual_result)

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

      assert {:ok, %{status: :noop, applied?: false, code: "gateway_auto_consume_cooldown"}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [manual_consume] = FakeUpstream.requests(fake)
      assert manual_consume.path == "/api/codex/rate-limit-reset-credits/consume"
    end

    test "a permanently latched sibling no longer vetoes the threshold trigger" do
      {:ok, latched_fake} = codex_reset_fake(0)
      {:ok, fake} = codex_reset_fake(0)

      %{identity: latched_identity} =
        assignment_with_fake(latched_fake, "/api/codex/usage", "codex_api",
          redemption: applied_gateway_auto_redemption("reblocked", 5)
        )

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api")

      identity =
        enable_saved_reset_auto_redeem!(identity, %{
          saved_reset_auto_redeem_trigger_mode: "threshold",
          saved_reset_auto_redeem_quota_threshold_percent: 60
        })

      upsert_weekly_pressure_quota!(identity, Decimal.new("95"))

      context = %{
        trigger: :threshold_pressure,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: identity.id,
        candidate_assignment_ids: [assignment.id],
        candidate_identity_ids: [latched_identity.id, identity.id],
        route_class: "proxy_http"
      }

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [consume_request | _rest] = FakeUpstream.requests(fake)
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
      assert [] = FakeUpstream.requests(latched_fake)
    end

    test "a manual applied consume latches the following automatic attempt" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption:
            applied_gateway_auto_redemption("confirmed_by_upstream", 5)
            |> Map.put("trigger_kind", "admin_manual")
        )

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

      assert {:ok,
              %{
                status: :noop,
                applied?: false,
                code: "gateway_auto_awaiting_post_consume_quota"
              }} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [] = FakeUpstream.requests(fake)
    end

    test "a legacy applied record past the window does not latch" do
      {:ok, fake} = codex_reset_fake(0)

      %{identity: identity, assignment: assignment} =
        assignment_with_fake(fake, "/api/codex/usage", "codex_api",
          redemption: legacy_applied_gateway_auto_redemption(40)
        )

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      context = gateway_auto_context(assignment, identity, :blocked_weekly_exhaustion)

      assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} =
               SavedResetRedemption.redeem(assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: context
               )

      assert [consume_request, _usage_request] = FakeUpstream.requests(fake)
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
    end
  end

  defp applied_gateway_auto_redemption(phase, consumed_minutes_ago) do
    consumed_at =
      DateTime.utc_now()
      |> DateTime.add(-consumed_minutes_ago, :minute)
      |> DateTime.truncate(:microsecond)

    %{
      "status" => "succeeded",
      "phase" => phase,
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 3,
      "trigger_kind" => "gateway_auto",
      "started_at" => DateTime.to_iso8601(consumed_at),
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "deadline_at" => consumed_at |> DateTime.add(15, :minute) |> DateTime.to_iso8601(),
      "finished_at" => DateTime.to_iso8601(consumed_at),
      "result" => %{"code" => "reset", "applied" => true}
    }
  end

  # Pre-lifecycle writers persisted status/trigger/started_at/result only.
  defp legacy_applied_gateway_auto_redemption(consumed_minutes_ago) do
    applied_gateway_auto_redemption("confirmed_by_quota", consumed_minutes_ago)
    |> Map.drop(["phase", "consumed_at", "deadline_at"])
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

  defp committed_probe_claim_fixture!(fake) do
    run_unboxed(fn ->
      unique = System.unique_integer([:positive])
      pool = pool_fixture(%{slug: "saved-reset-probe-race-#{unique}"})

      %{assignment: assignment, identity: identity} =
        active_upstream_assignment_fixture(pool, %{
          account_label: "Saved reset probe race #{unique}",
          chatgpt_account_id: "acct_probe_race_#{unique}",
          metadata: %{
            "usage_base_url" => FakeUpstream.url(fake),
            "saved_resets" => %{
              "status" => "reported",
              "available_count" => 1,
              "source" => "codex_usage_api",
              "path_style" => "codex_api",
              "observed_at" =>
                DateTime.utc_now()
                |> DateTime.truncate(:microsecond)
                |> DateTime.to_iso8601(),
              "usage_path" => "/api/codex/usage",
              "reason" => nil
            }
          }
        })

      foreign_identity =
        active_upstream_identity_fixture(%{
          account_label: "Saved reset reassignment target #{unique}",
          chatgpt_account_id: "acct_probe_reassignment_target_#{unique}"
        })

      %{
        assignment_id: assignment.id,
        foreign_identity_id: foreign_identity.id,
        identity_id: identity.id,
        pool_id: pool.id
      }
    end)
  end

  defp committed_no_credit_fixture!(fake, saved_resets) do
    run_unboxed(fn ->
      unique = System.unique_integer([:positive])
      pool = pool_fixture(%{slug: "saved-reset-redemption-order-#{unique}"})

      %{assignment: assignment, identity: identity} =
        active_upstream_assignment_fixture(pool, %{
          account_label: "Saved reset redemption order #{unique}",
          chatgpt_account_id: "acct_redemption_order_#{unique}",
          metadata: %{
            "usage_base_url" => FakeUpstream.url(fake),
            "usage_path" => "/backend-api/wham/usage",
            "saved_resets" => saved_resets
          }
        })

      %{assignment_id: assignment.id, identity_id: identity.id, pool_id: pool.id}
    end)
  end

  defp cleanup_committed_no_credit_fixture!(fixture) do
    run_unboxed(fn ->
      Repo.delete_all(
        from identity in UpstreamIdentity,
          where: identity.id == ^fixture.identity_id
      )

      Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool_id)
    end)
  end

  defp committed_probe_claim_context!(fixture) do
    run_unboxed(fn ->
      identity = Repo.get!(UpstreamIdentity, fixture.identity_id)
      redemption = identity.metadata["saved_reset_redemption"]

      assert redemption["phase"] == "consumed_pending_probe"
      assert is_integer(redemption["generation"])
      assert is_binary(redemption["attempt_id"])

      Map.merge(fixture, %{
        attempt_id: redemption["attempt_id"],
        generation: redemption["generation"]
      })
    end)
  end

  defp cleanup_committed_probe_claim_fixture!(fixture) do
    assert %{identities: 2, pools: 1} ==
             run_unboxed(fn ->
               {identity_count, _rows} =
                 Repo.delete_all(
                   from identity in UpstreamIdentity,
                     where: identity.id in ^[fixture.identity_id, fixture.foreign_identity_id]
                 )

               {pool_count, _rows} =
                 Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool_id)

               %{identities: identity_count, pools: pool_count}
             end)
  end

  defp bound_probe!(fixture) do
    assert {:ok, probe} =
             ResetProbe.new()
             |> ResetProbe.bind(
               fixture.assignment_id,
               fixture.identity_id,
               "gpt-5.4",
               "proxy_http"
             )

    probe
  end

  defp start_probe_claim_task(parent, barrier, fixture, role, probe) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        backend_pid = backend_pid!()
        send(parent, {barrier, :claim_ready, self(), role, backend_pid})

        receive do
          {^barrier, :start_claim} -> :ok
        after
          5_000 -> raise "timed out waiting to start the saved-reset probe claim"
        end

        send(parent, {barrier, :claim_started, role, backend_pid})

        result =
          ProbeLease.claim(
            fixture.identity_id,
            fixture.generation,
            fixture.attempt_id,
            probe
          )

        {role, backend_pid, result}
      end)
    end)
  end

  defp release_probe_claim_tasks(tasks, barrier) do
    Enum.each(tasks, fn task ->
      send(task.pid, {barrier, :start_claim})
      send(task.pid, {barrier, :release_winner})
    end)

    Enum.each(tasks, fn task ->
      if Process.alive?(task.pid) do
        release_probe_claim_task(task)
      end
    end)
  end

  defp release_probe_claim_task(task) do
    case Task.yield(task, 5_000) do
      {:ok, _result} -> :ok
      {:exit, _reason} -> :ok
      nil -> Task.shutdown(task, :brutal_kill)
    end
  end

  defp persisted_probe!(identity_id) do
    run_unboxed(fn ->
      identity = Repo.get!(UpstreamIdentity, identity_id)
      get_in(identity.metadata, ["saved_reset_redemption", "probe"])
    end)
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp probe_identity_lock_query?(metadata) do
    metadata[:repo] == Repo and metadata[:source] == "upstream_identities" and
      is_binary(metadata[:query]) and String.contains?(metadata[:query], "FOR UPDATE")
  end

  defp identity_update_query?(metadata) do
    metadata[:repo] == Repo and metadata[:source] == "upstream_identities" and
      is_binary(metadata[:query]) and
      String.starts_with?(String.trim_leading(metadata[:query]), "UPDATE")
  end

  defp drain_identity_updates(task_pid, count \\ 0) do
    receive do
      {:saved_reset_identity_update, ^task_pid} -> drain_identity_updates(task_pid, count + 1)
    after
      0 -> count
    end
  end

  defp observe_blocked_probe_claim!(waiter_pid, blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + 4_000
    do_observe_blocked_probe_claim!(waiter_pid, blocker_pid, deadline)
  end

  defp do_observe_blocked_probe_claim!(waiter_pid, blocker_pid, deadline) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT pg_blocking_pids($1), wait_event_type FROM pg_stat_activity WHERE pid = $1",
        [waiter_pid]
      )

    case rows do
      [[blocking_pids, wait_event_type]] ->
        if blocker_pid in blocking_pids and wait_event_type == "Lock" do
          %{blocking_pids: blocking_pids, wait_event_type: wait_event_type}
        else
          retry_blocked_probe_observation!(waiter_pid, blocker_pid, deadline)
        end

      _rows ->
        retry_blocked_probe_observation!(waiter_pid, blocker_pid, deadline)
    end
  end

  defp retry_blocked_probe_observation!(waiter_pid, blocker_pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("losing saved-reset probe claim never waited on the winning PostgreSQL backend")
    else
      do_observe_blocked_probe_claim!(waiter_pid, blocker_pid, deadline)
    end
  end

  defp run_unboxed(fun) do
    Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(5_000)
  end
end
